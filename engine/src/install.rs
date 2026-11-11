use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow};
use chrono::{DateTime, Utc};
use plume_core::{CertificateIdentity, MobileProvision, developer::DeveloperSession};
use plume_store::{AccountStore, GsaAccount, RefreshApp, RefreshDevice};
use plume_utils::{Bundle, Package, PlistInfoTrait, Signer, SignerMode, SignerOptions};
use serde_json::json;

use crate::events::{emit, progress, prompt};
use crate::{anisette, data_path, devices, load_store};

pub fn ipa_info(ipa: PathBuf, icon_out: Option<PathBuf>) -> Result<()> {
    let pkg = Package::new(ipa)?;
    let mut icon_path = None;
    if let (Some(out), Some(data)) = (icon_out, pkg.app_icon_data.as_ref()) {
        std::fs::write(&out, data)?;
        icon_path = Some(out);
    }
    emit(json!({
        "type": "ipa_info",
        "name": pkg.get_name(),
        "bundleId": pkg.get_bundle_identifier(),
        "version": pkg.get_version(),
        "iconPath": icon_path,
    }));
    pkg.remove_package_stage();
    Ok(())
}

/// Ask the app before revoking an old certificate (breaks other sideloaders' installs).
pub fn confirm_cert_reset() -> bool {
    prompt(json!({
        "type": "prompt",
        "kind": "confirm",
        "title": "Certificate replacement needed",
        "message": "This Apple ID has the maximum number of certificates. GatePass will revoke an old one. Apps installed with another tool (Sideloadly, AltStore) using that certificate will stop working.",
    }))
    .map(|a| a == "yes")
    .unwrap_or(false)
}

pub async fn session_for(account: &GsaAccount) -> Result<(DeveloperSession, String)> {
    let session = DeveloperSession::new(
        account.adsid().clone(),
        account.xcode_gs_token().clone(),
        anisette(),
    )
    .await?;
    let teams = session.qh_list_teams().await?.teams;
    let team_id = if !account.team_id().is_empty()
        && teams.iter().any(|t| &t.team_id == account.team_id())
    {
        account.team_id().clone()
    } else {
        teams
            .first()
            .ok_or_else(|| anyhow!("No teams available for this Apple ID"))?
            .team_id
            .clone()
    };
    Ok((session, team_id))
}

pub async fn identity(session: &DeveloperSession, team_id: &String) -> Result<CertificateIdentity> {
    let _critical = crate::events::Critical::enter();
    let mut on_reset = confirm_cert_reset;
    Ok(CertificateIdentity::new_with_session(
        session,
        data_path(),
        None,
        team_id,
        false,
        Some(&mut on_reset),
    )
    .await?)
}

pub fn refresh_date(bundle_dir: &Path) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
    let prov = MobileProvision::load_with_path(bundle_dir.join("embedded.mobileprovision")).ok()?;
    let expires: DateTime<Utc> = std::time::SystemTime::from(prov.expiration_date().clone()).into();
    // Refresh 2 days before expiry, so a weekly connection is always in time.
    Some((expires, expires - chrono::Duration::days(2)))
}

/// Advanced options (shown in the app only when Developer mode is on).
#[derive(clap::Args, Default, Clone, Debug)]
pub struct InstallOpts {
    /// Custom app name
    #[arg(long)]
    pub name: Option<String>,
    /// Custom bundle identifier
    #[arg(long)]
    pub bundle_id: Option<String>,
    /// Custom app version
    #[arg(long)]
    pub app_version: Option<String>,
    /// Try to support older iOS versions
    #[arg(long)]
    pub min_os: bool,
    /// Enable UIFileSharing (Files app access)
    #[arg(long)]
    pub file_sharing: bool,
    /// Force iPad fullscreen
    #[arg(long)]
    pub ipad_fullscreen: bool,
    /// Remove app extensions (PlugIns) — saves App IDs
    #[arg(long)]
    pub remove_extensions: bool,
    /// Remove UISupportedDevices limitation
    #[arg(long)]
    pub remove_device_limit: bool,
    /// Inject a tweak (.dylib, .deb, .framework); repeatable
    #[arg(long = "tweak")]
    pub tweaks: Vec<PathBuf>,
    /// Ad-hoc sign (no Apple ID; only for jailbroken / TrollStore devices)
    #[arg(long)]
    pub adhoc: bool,
    /// Save the signed .ipa here instead of installing
    #[arg(long)]
    pub export: Option<PathBuf>,
    /// Don't track this app for auto-refresh
    #[arg(long)]
    pub no_refresh: bool,
}

fn strip_bundle(bundle_dir: &Path, opts: &InstallOpts) -> Result<()> {
    if opts.remove_extensions {
        for sub in ["PlugIns", "Extensions"] {
            let dir = bundle_dir.join(sub);
            if dir.exists() {
                std::fs::remove_dir_all(&dir)?;
            }
        }
    }
    if opts.remove_device_limit {
        let info = bundle_dir.join("Info.plist");
        let mut dict: plist::Dictionary = plist::from_file(&info)?;
        if dict.remove("UISupportedDevices").is_some() {
            plist::to_file_binary(&info, &dict)?;
        }
    }
    Ok(())
}

pub async fn install(ipa: PathBuf, udid: Option<String>, opts: InstallOpts) -> Result<()> {
    progress("Preparing…", 5);
    let mut store = load_store().await?;
    let account = if opts.adhoc {
        None
    } else {
        Some(
            store
                .selected_account()
                .ok_or_else(|| anyhow!("No account selected"))?
                .clone(),
        )
    };

    let device = match &udid {
        Some(u) => {
            progress("Looking for device…", 10);
            Some(devices::find(u).await?)
        }
        None if opts.export.is_some() => None,
        None => return Err(anyhow!("Device not found: no device selected")),
    };

    progress("Opening IPA…", 15);
    let package = Package::new(ipa.clone())?;
    let mut options = SignerOptions::default();
    package.load_into_signer_options(&mut options);
    options.custom_name = opts.name.clone().filter(|s| !s.trim().is_empty());
    options.custom_identifier = opts.bundle_id.clone().filter(|s| !s.trim().is_empty());
    options.custom_version = opts.app_version.clone().filter(|s| !s.trim().is_empty());
    options.features.support_minimum_os_version = opts.min_os;
    options.features.support_file_sharing = opts.file_sharing;
    options.features.support_ipad_fullscreen = opts.ipad_fullscreen;
    if !opts.tweaks.is_empty() {
        options.tweaks = Some(opts.tweaks.clone());
    }
    options.mode = if opts.adhoc { SignerMode::Adhoc } else { SignerMode::Pem };

    progress("Unpacking…", 25);
    let bundle = package.get_package_bundle()?;
    strip_bundle(bundle.bundle_dir(), &opts)?;

    if let Some(account) = &account {
        progress("Checking Apple ID…", 30);
        let (session, team_id) = session_for(account).await?;
        let ident = identity(&session, &team_id).await?;
        if let Some(dev) = &device {
            progress("Registering device…", 38);
            session.qh_ensure_device(&team_id, &dev.name, &dev.udid).await?;
        }
        let mut signer = Signer::new(Some(ident), options);
        progress("Signing…", 50);
        signer.modify_bundle(&bundle, &Some(team_id.clone())).await?;
        signer.register_bundle(&bundle, &session, &team_id, false).await?;
        signer.sign_bundle(&bundle).await?;
    } else {
        let mut signer = Signer::new(None, options);
        progress("Ad-hoc signing…", 50);
        signer.modify_bundle(&bundle, &None).await?;
        signer.sign_bundle(&bundle).await?;
    }

    if let Some(out) = &opts.export {
        progress("Saving IPA…", 85);
        let archive = package.get_archive_based_on_path(bundle.bundle_dir())?;
        tokio::fs::copy(&archive, out).await?;
        package.remove_package_stage();
        emit(json!({ "type": "done", "exported": out }));
        return Ok(());
    }

    let device = device.expect("device checked above");
    progress("Sending to device…", 70);
    device
        .install_app(bundle.bundle_dir(), |p: i32| async move {
            progress("Installing…", 70 + p / 4);
        })
        .await?;

    let mut tracked = None;
    if let (Some(account), false) = (&account, opts.no_refresh) {
        progress("Saving for auto-refresh…", 96);
        tracked = Some(save_for_refresh(&mut store, account, &device, &bundle).await?);
    }

    package.remove_package_stage();
    emit(json!({
        "type": "done",
        "app": tracked.map(|t| json!({
            "name": t.name,
            "bundleId": t.bundle_id,
            "refreshAt": t.scheduled_refresh,
            "expiresAt": refresh_date(&t.path).map(|d| d.0),
        })),
    }));
    Ok(())
}

/// Keep a signed copy of the bundle so it can be re-signed later without the original IPA.
async fn save_for_refresh(
    store: &mut AccountStore,
    account: &GsaAccount,
    device: &plume_utils::Device,
    bundle: &Bundle,
) -> Result<RefreshApp> {
    let _critical = crate::events::Critical::enter();
    let bundle_id = bundle.get_bundle_identifier();
    let dir = data_path().join("apps").join(&device.udid);
    tokio::fs::create_dir_all(&dir).await?;
    let dest = dir.join(format!(
        "{}.app",
        bundle_id.clone().unwrap_or_else(|| uuid::Uuid::new_v4().to_string())
    ));
    if dest.exists() {
        tokio::fs::remove_dir_all(&dest).await?;
    }
    plume_utils::copy_dir_recursively(bundle.bundle_dir(), &dest).await?;

    let scheduled_refresh = refresh_date(&dest)
        .map(|d| d.1)
        .unwrap_or_else(|| Utc::now() + chrono::Duration::days(5));

    let app = RefreshApp {
        path: dest,
        name: bundle.get_name(),
        bundle_id: bundle_id.clone(),
        scheduled_refresh,
    };

    let mut rd = store
        .get_refresh_device(&device.udid)
        .cloned()
        .unwrap_or_else(|| RefreshDevice {
            udid: device.udid.clone(),
            name: device.name.clone(),
            account: account.email().clone(),
            apps: Vec::new(),
            is_mac: false,
        });
    rd.account = account.email().clone();
    rd.name = device.name.clone();
    rd.apps.retain(|a| a.bundle_id != bundle_id);
    rd.apps.push(app.clone());
    store.add_or_update_refresh_device(rd).await?;
    Ok(app)
}
