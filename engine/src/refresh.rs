use anyhow::{Result, anyhow};
use chrono::Utc;
use plume_utils::{Bundle, Signer, SignerMode, SignerOptions};
use serde_json::json;

use crate::events::{emit, progress};
use crate::install::{identity, refresh_date, session_for};
use crate::{devices, load_store};

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
                    json!({
                        "name": a.name,
                        "bundleId": a.bundle_id,
                        "refreshAt": a.scheduled_refresh,
                        "expiresAt": refresh_date(&a.path).map(|d| d.0),
                        "due": a.scheduled_refresh <= Utc::now(),
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

pub async fn refresh(udid: String, force: bool, only: Option<String>) -> Result<()> {
    let mut store = load_store().await?;
    let mut rd = store
        .get_refresh_device(&udid)
        .cloned()
        .ok_or_else(|| anyhow!("No tracked apps for this device"))?;

    let now = Utc::now();
    let targets: Vec<usize> = rd
        .apps
        .iter()
        .enumerate()
        .filter(|(_, a)| force || a.scheduled_refresh <= now)
        .filter(|(_, a)| only.is_none() || a.bundle_id == only)
        .map(|(i, _)| i)
        .collect();

    if targets.is_empty() {
        emit(json!({ "type": "done", "refreshed": [] }));
        return Ok(());
    }

    let account = store
        .get_account(&rd.account)
        .ok_or_else(|| anyhow!("No account {} saved — log in again", rd.account))?
        .clone();

    progress("Looking for device…", 5);
    let device = devices::find(&udid).await?;

    progress("Checking Apple ID…", 10);
    let (session, team_id) = session_for(&account).await?;
    session
        .qh_ensure_device(&team_id, &device.name, &device.udid)
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

    let mut refreshed = Vec::new();
    let total = targets.len() as i32;
    for (n, idx) in targets.into_iter().enumerate() {
        let app = rd.apps[idx].clone();
        let label = app.name.clone().unwrap_or_else(|| "app".into());
        let base = 15 + (n as i32 * 80 / total);
        progress(&format!("Refreshing {label}"), base);

        let bundle = Bundle::new(app.path.clone())?;
        signer.provisioning_files.clear();
        signer.register_bundle(&bundle, &session, &team_id, true).await?;

        let installed = match app.bundle_id.as_deref() {
            Some(id) => device.is_app_installed(id).await.unwrap_or(false),
            None => false,
        };

        if installed && !identity_is_new {
            // Same certificate: pushing fresh provisioning profiles is enough. Fast, no reinstall.
            for p in &signer.provisioning_files {
                device.install_profile(p).await?;
            }
            // Keep the stored copy's profile current so the expiry date we show is right.
            signer.sign_bundle(&bundle).await?;
        } else {
            signer.sign_bundle(&bundle).await?;
            let step = 80 / total;
            device
                .install_app(&app.path, move |p: i32| async move {
                    progress("Installing…", base + p * step / 100);
                })
                .await?;
        }

        if let Some((_, next)) = refresh_date(&app.path) {
            rd.apps[idx].scheduled_refresh = next;
        }
        refreshed.push(json!({ "name": app.name, "bundleId": app.bundle_id }));
    }

    {
        let _critical = crate::events::Critical::enter();
        store.add_or_update_refresh_device(rd).await?;
    }
    emit(json!({ "type": "done", "refreshed": refreshed }));
    Ok(())
}
