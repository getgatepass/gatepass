use anyhow::{Result, anyhow};
use chrono::Utc;
use plume_core::developer::DeveloperSession;
use plume_store::{AccountStore, GsaAccount, RefreshApp, RefreshDevice};
use plume_utils::{Bundle, PlistInfoTrait, Signer, SignerMode, SignerOptions};
use serde_json::json;

use crate::events::{emit, progress};
use crate::install::{claim_app_id, identity, profile_team, refresh_date, rename_bundle_id, session_for};
use crate::{devices, load_store};

/// The saved Apple ID an app belongs to: the one that installed it, or for apps tracked
/// before 0.1.8 the saved account whose team signed it. `None` = unknown.
pub fn app_account(store: &AccountStore, app: &RefreshApp) -> Option<String> {
    if let Some(email) = &app.account {
        return Some(email.clone());
    }
    let team = profile_team(&app.path)?;
    store
        .accounts()
        .values()
        .find(|a| a.team_id() == &team && !a.xcode_gs_token().is_empty())
        .map(|a| a.email().clone())
}

/// A saved account that can still sign (it has a session token).
fn signed_in(store: &AccountStore, email: &str) -> Option<GsaAccount> {
    store.get_account(email).filter(|a| !a.xcode_gs_token().is_empty()).cloned()
}

pub async fn list_apps() -> Result<()> {
    let store = load_store().await?;
    let devices: Vec<_> = store
        .refreshes()
        .values()
        .map(|rd| {
            let apps: Vec<_> = rd
                .apps
                .iter()
                .map(|a| {
                    let account = app_account(&store, a);
                    let signed = account.as_deref().and_then(|e| signed_in(&store, e)).is_some();
                    json!({
                        "name": a.name,
                        "bundleId": a.bundle_id,
                        "refreshAt": a.scheduled_refresh,
                        "expiresAt": refresh_date(&a.path).map(|d| d.0),
                        "due": a.scheduled_refresh <= Utc::now(),
                        "account": account,
                        "accountSignedIn": signed,
                    })
                })
                .collect();
            json!({ "udid": rd.udid, "name": rd.name, "account": rd.account, "apps": apps })
        })
        .collect();
    emit(json!({ "type": "apps", "devices": devices }));
    Ok(())
}

pub async fn forget(udid: String, bundle_id: String) -> Result<()> {
    let mut store = load_store().await?;
    if let Some(mut rd) = store.get_refresh_device(&udid).cloned() {
        if let Some(app) = rd.apps.iter().find(|a| a.bundle_id.as_deref() == Some(&bundle_id)) {
            tokio::fs::remove_dir_all(&app.path).await.ok();
        }
        rd.apps.retain(|a| a.bundle_id.as_deref() != Some(&bundle_id));
        let _critical = crate::events::Critical::enter();
        store.add_or_update_refresh_device(rd).await?;
    }
    emit(json!({ "type": "done" }));
    Ok(())
}

/// Refresh tracked apps. Each app is signed with the Apple ID that installed it. `with`
/// signs them with that Apple ID instead; an app moving to another team gets that team's
/// identifiers and is reinstalled (see `move_to_team`).
pub async fn refresh(udid: String, force: bool, only: Option<String>, with: Option<String>) -> Result<()> {
    let mut store = load_store().await?;
    let mut rd = store
        .get_refresh_device(&udid)
        .cloned()
        .ok_or_else(|| anyhow!("No tracked apps for this device"))?;
    if let Some(email) = &with {
        if signed_in(&store, email).is_none() {
            return Err(anyhow!("Apple ID {email} isn't signed in. Sign in to it first."));
        }
    }

    let now = Utc::now();
    let targets: Vec<usize> = rd
        .apps
        .iter()
        .enumerate()
        .filter(|(_, a)| force || a.scheduled_refresh <= now)
        .filter(|(_, a)| only.is_none() || a.bundle_id == only)
        .map(|(i, _)| i)
        .collect();

    // Group by Apple ID. Apps whose Apple ID is signed out are skipped: moving them to another
    // Apple ID reinstalls them without their data, so the person decides that in the app.
    let mut groups: Vec<(GsaAccount, Vec<usize>)> = Vec::new();
    let mut skipped = Vec::new();
    for idx in targets {
        let app = &rd.apps[idx];
        let email = with.clone().or_else(|| app_account(&store, app));
        match email.as_deref().and_then(|e| signed_in(&store, e)) {
            Some(account) => match groups.iter_mut().find(|(a, _)| a.email() == account.email()) {
                Some((_, list)) => list.push(idx),
                None => groups.push((account, vec![idx])),
            },
            None => skipped.push(json!({ "name": app.name, "bundleId": app.bundle_id, "account": email })),
        }
    }

    if groups.is_empty() {
        if only.is_some() && !skipped.is_empty() {
            return Err(anyhow!(
                "The Apple ID this app was installed with isn't signed in. Sign in to it again, or refresh the app with another Apple ID."
            ));
        }
        emit(json!({ "type": "done", "refreshed": [], "skipped": skipped }));
        return Ok(());
    }

    progress("Looking for device…", 5);
    let mut device = devices::find(&udid).await?;

    let mut refreshed = Vec::new();
    let mut dropped: Vec<usize> = Vec::new();
    let mut failure: Option<anyhow::Error> = None;
    let total: i32 = groups.iter().map(|(_, l)| l.len() as i32).sum();
    let mut n = 0;
    for (account, list) in groups {
        let end = n + list.len() as i32;
        let result = refresh_group(
            &mut rd, &list, &mut dropped, &account, &mut device, &mut refreshed, &mut n, total,
        )
        .await;
        if let Err(e) = result {
            let e = e.context(format!("Apple ID {}", account.email()));
            log::error!("{e:#}");
            failure.get_or_insert(e);
        }
        n = end; // apps skipped by a failed sign-in still count for progress
    }

    dropped.sort_unstable();
    for idx in dropped.into_iter().rev() {
        rd.apps.remove(idx);
    }
    if let Some(selected) = store.selected_account() {
        rd.account = selected.email().clone();
    }
    {
        let _critical = crate::events::Critical::enter();
        store.add_or_update_refresh_device(rd).await?;
    }
    if let Some(e) = failure {
        return Err(e);
    }
    emit(json!({ "type": "done", "refreshed": refreshed, "skipped": skipped }));
    Ok(())
}

/// Refresh some apps with one Apple ID. Errors from single apps are logged and the first is
/// returned after the others had their turn.
#[allow(clippy::too_many_arguments)]
async fn refresh_group(
    rd: &mut RefreshDevice,
    list: &[usize],
    dropped: &mut Vec<usize>,
    account: &GsaAccount,
    device: &mut devices::Target,
    refreshed: &mut Vec<serde_json::Value>,
    n: &mut i32,
    total: i32,
) -> Result<()> {
    progress(&format!("Checking Apple ID {}…", account.email()), 10 + (*n * 85 / total));
    let (session, team_id) = session_for(account).await?;
    session.set_tvos(device.is_apple_tv().await);
    session
        .qh_ensure_device(&team_id, &device.name().to_string(), &device.udid().to_string())
        .await?;
    let ident = identity(&session, &team_id).await?;
    let identity_is_new = ident.new;
    let mut signer = Signer::new(
        Some(ident),
        SignerOptions {
            mode: SignerMode::Pem,
            ..Default::default()
        },
    );

    let mut failure: Option<anyhow::Error> = None;
    let step = 85 / total;
    for &idx in list {
        let base = 10 + (*n * 85 / total);
        *n += 1;
        match refresh_one(
            rd, idx, dropped, &session, &team_id, account, &mut signer, device, identity_is_new, base, step,
        )
        .await
        {
            Ok(Some(done)) => refreshed.push(done),
            Ok(None) => {}
            // Keep going: one app failing shouldn't stop the others or lose their new dates.
            Err(e) => {
                log::error!("Refreshing {:?} failed: {e:#}", rd.apps[idx].name);
                failure.get_or_insert(e);
            }
        }
    }
    match failure {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

#[allow(clippy::too_many_arguments)]
async fn refresh_one(
    rd: &mut RefreshDevice,
    idx: usize,
    dropped: &mut Vec<usize>,
    session: &DeveloperSession,
    team_id: &String,
    account: &GsaAccount,
    signer: &mut Signer,
    device: &mut devices::Target,
    identity_is_new: bool,
    base: i32,
    step: i32,
) -> Result<Option<serde_json::Value>> {
    let app = rd.apps[idx].clone();
    let label = app.name.clone().unwrap_or_else(|| "app".into());
    progress(&format!("Refreshing {label}"), base);

    let bundle = Bundle::new(app.path.clone())?;
    let old_id = bundle
        .get_bundle_identifier()
        .ok_or_else(|| anyhow!("{label} has no bundle identifier"))?;

    // Signed by another team (the Apple ID changed): take this team's identifiers.
    let other_team = profile_team(&app.path).filter(|t| t != team_id);
    if let Some(old_team) = &other_team {
        let new_id = move_to_team(&old_id, old_team, team_id);
        if new_id != old_id {
            rename_bundle_id(&bundle, &old_id, &new_id)?;
        }
    }
    // Make sure the app's identifier is ours; another team may hold it (9401).
    let id = claim_app_id(session, team_id, &bundle).await?;

    signer.provisioning_files.clear();
    signer.register_bundle(&bundle, session, team_id, other_team.is_none() && id == old_id).await?;
    signer.sign_bundle(&bundle).await?;

    let old_installed = device.is_app_installed(&old_id).await.unwrap_or(false);
    if id == old_id {
        if old_installed && !identity_is_new && other_team.is_none() {
            // Same team and certificate: fresh provisioning profiles are enough. Fast, no reinstall.
            for p in &signer.provisioning_files {
                device.install_profile(p).await?;
            }
        } else {
            if old_installed && other_team.is_some() {
                // iOS won't update an app signed by another team in place.
                device.uninstall_app(&old_id).await?;
            }
            install(device, &app.path, base, step).await?;
        }
        rd.apps[idx].account = Some(account.email().clone());
    } else {
        // New identifier: it's a different app to iOS. Remove the old one (it also frees one
        // of the 3 app slots) and install the new one. The app starts without its old data.
        log::info!("{label}: {old_id} -> {id} (team {team_id})");
        if old_installed {
            device.uninstall_app(&old_id).await?;
        }
        let new_path = app.path.with_file_name(format!("{id}.app"));
        if new_path != app.path {
            if new_path.exists() {
                tokio::fs::remove_dir_all(&new_path).await?;
            }
            tokio::fs::rename(&app.path, &new_path).await?;
        }
        install(device, &new_path, base, step).await?;
        // Already tracked under the new identifier (installed again by hand): keep that entry.
        if let Some(other) = rd.apps.iter().position(|a| a.bundle_id.as_deref() == Some(id.as_str())) {
            rd.apps[other].path = new_path.clone();
            rd.apps[other].account = Some(account.email().clone());
            if let Some((_, next)) = refresh_date(&new_path) {
                rd.apps[other].scheduled_refresh = next;
            }
            dropped.push(idx);
            return Ok(Some(json!({ "name": app.name, "bundleId": id })));
        }
        rd.apps[idx].bundle_id = Some(id.clone());
        rd.apps[idx].path = new_path;
        rd.apps[idx].account = Some(account.email().clone());
    }

    if let Some((_, next)) = refresh_date(&rd.apps[idx].path) {
        rd.apps[idx].scheduled_refresh = next;
    }
    Ok(Some(json!({ "name": app.name, "bundleId": id })))
}

async fn install(device: &mut devices::Target, path: &std::path::Path, base: i32, step: i32) -> Result<()> {
    device
        .install_app(&path.to_path_buf(), move |p: i32| async move {
            progress("Installing…", base + p * step / 100);
        })
        .await
}

/// The identifier an app gets in a new team: GatePass adds ".<team>" to the original, so
/// swap the old team for the new one. Already ending in the new team, it stays (if another
/// team holds it, `claim_app_id` adds ".gp"); anything else gets ".<team>" added.
fn move_to_team(id: &str, old_team: &str, new_team: &str) -> String {
    if id.ends_with(&format!(".{new_team}")) || id.ends_with(&format!(".{new_team}.gp")) {
        return id.to_string();
    }
    let base = id.strip_suffix(".gp").unwrap_or(id);
    match base.strip_suffix(&format!(".{old_team}")) {
        Some(original) => format!("{original}.{new_team}"),
        None => format!("{base}.{new_team}"),
    }
}

#[cfg(test)]
mod tests {
    use super::move_to_team;

    #[test]
    fn identifiers_follow_the_team() {
        assert_eq!(move_to_team("com.a.app.OLDTEAM001", "OLDTEAM001", "NEWTEAM002"), "com.a.app.NEWTEAM002");
        assert_eq!(move_to_team("com.a.app.OLDTEAM001.gp", "OLDTEAM001", "NEWTEAM002"), "com.a.app.NEWTEAM002");
        assert_eq!(move_to_team("com.a.app.NEWTEAM002", "OLDTEAM001", "NEWTEAM002"), "com.a.app.NEWTEAM002");
        assert_eq!(move_to_team("com.custom", "OLDTEAM001", "NEWTEAM002"), "com.custom.NEWTEAM002");
    }
}
