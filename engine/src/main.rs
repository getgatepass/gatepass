//! gatepass-engine — headless backend for the GatePass macOS app.
//!
//! Every command writes newline-delimited JSON events to stdout. When the
//! engine needs something from the user (2FA code, confirmation) it emits an
//! event with `"type": "prompt"` and reads exactly one line from stdin.
//! Human-readable logs go to stderr.

mod devices;
mod events;
mod install;
mod refresh;

use std::path::PathBuf;

use anyhow::{Result, anyhow};
use clap::{Parser, Subcommand};
use plume_core::{AnisetteConfiguration, auth::Account};
use plume_store::AccountStore;
use serde_json::json;

use events::{emit, prompt};

#[derive(Parser)]
#[command(name = "gatepass-engine", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// List connected devices (USB and Wi-Fi)
    Devices,
    /// Log in with an Apple ID. Reads {"email","password"} JSON from stdin.
    Login,
    /// Log out (remove the saved account)
    Logout {
        #[arg(long)]
        email: Option<String>,
    },
    /// Show saved accounts
    Accounts,
    /// Free-account limits: App IDs left this week, active apps per device
    Quota,
    /// Read name/bundle id/version/icon from an .ipa without installing
    IpaInfo {
        #[arg(long)]
        ipa: PathBuf,
        /// Where to write the icon PNG (optional)
        #[arg(long)]
        icon_out: Option<PathBuf>,
    },
    /// Sign an .ipa with the saved Apple ID and install it on a device
    Install {
        #[arg(long)]
        ipa: PathBuf,
        #[arg(long)]
        udid: Option<String>,
        #[command(flatten)]
        opts: install::InstallOpts,
    },
    /// List apps tracked for auto-refresh, with expiry dates
    Apps,
    /// Refresh tracked apps on a connected device
    Refresh {
        #[arg(long)]
        udid: String,
        /// Refresh even if not yet due
        #[arg(long)]
        force: bool,
        /// Only this bundle id
        #[arg(long)]
        bundle_id: Option<String>,
    },
    /// Stop tracking an app for refresh
    Forget {
        #[arg(long)]
        udid: String,
        #[arg(long)]
        bundle_id: String,
    },
    /// List user-installed apps on a device
    Installed {
        #[arg(long)]
        udid: String,
    },
}

/// Everything we write (tokens fallback, private keys, signed apps) is private to this user.
fn lock_down_permissions() {
    unsafe { libc::umask(0o077) };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(data_path(), std::fs::Permissions::from_mode(0o700));
        // Session tokens may live in this file (default storage), so owner-only.
        let _ = std::fs::set_permissions(store_path(), std::fs::Permissions::from_mode(0o600));
    }
}

pub fn data_path() -> PathBuf {
    let dir = std::env::var("GATEPASS_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into()))
                .join("Library/Application Support/GatePass")
        });
    std::fs::create_dir_all(&dir).ok();
    dir
}

pub fn store_path() -> PathBuf {
    data_path().join("accounts.json")
}

pub fn anisette() -> AnisetteConfiguration {
    AnisetteConfiguration::default().set_configuration_path(data_path())
}

pub async fn load_store() -> Result<AccountStore> {
    Ok(AccountStore::load(&Some(store_path())).await?)
}

#[tokio::main]
async fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .target(env_logger::Target::Stderr)
        .init();
    let _ = rustls::crypto::ring::default_provider().install_default();
    lock_down_permissions();

    let cli = Cli::parse();
    let result = match cli.command {
        Command::Devices => devices::list().await,
        Command::Login => login().await,
        Command::Logout { email } => logout(email).await,
        Command::Accounts => accounts().await,
        Command::Quota => quota().await,
        Command::IpaInfo { ipa, icon_out } => install::ipa_info(ipa, icon_out),
        Command::Install { ipa, udid, opts } => install::install(ipa, udid, opts).await,
        Command::Apps => refresh::list_apps().await,
        Command::Refresh {
            udid,
            force,
            bundle_id,
        } => refresh::refresh(udid, force, bundle_id).await,
        Command::Forget { udid, bundle_id } => refresh::forget(udid, bundle_id).await,
        Command::Installed { udid } => devices::print_user_apps(&udid).await,
    };

    if let Err(e) = result {
        emit(json!({ "type": "error", "message": friendly_error(&e) }));
        std::process::exit(1);
    }
}

/// Turn low-level errors into messages a normal person understands.
fn friendly_error(e: &anyhow::Error) -> String {
    let raw = format!("{e:#}");
    let lower = raw.to_lowercase();
    let hint = if lower.contains("no account") {
        "You're not signed in. Sign in with your Apple ID."
    } else if lower.contains("7460") || lower.contains("too many certificates") {
        "This Apple ID has too many certificates. Try again — GatePass will replace an old one."
    } else if lower.contains("maximum") && lower.contains("app id") {
        "A free Apple ID allows 10 new App IDs per week. Wait a few days or reuse an IPA you already installed."
    } else if lower.contains("2fa") && lower.contains("403") {
        "Apple refused to send a verification code. Your password is correct — try again in a few minutes. If it keeps happening, check whether your Apple ID uses security keys; those aren't supported."
    } else if lower.contains("429") {
        "Too many sign-in attempts. Apple has temporarily blocked requests — wait 10–15 minutes."
    } else if lower.contains("-20101") || lower.contains("-20970") || lower.contains("entered incorrectly") {
        "Incorrect email or password."
    } else if lower.contains("-21669") || lower.contains("verification code") || lower.contains("-21667") {
        "Incorrect verification code. Try again."
    } else if lower.contains("sign-in cancelled") {
        "Sign-in was cancelled."
    } else if lower.contains("not found") && lower.contains("device") {
        "Device not found. Make sure it's connected by cable or on the same Wi-Fi network."
    } else if lower.contains("pair") {
        "This device isn't paired with this Mac. Unlock it and tap \"Trust\"."
    } else {
        ""
    };
    if hint.is_empty() {
        raw
    } else {
        format!("{hint}\n\nDetails: {raw}")
    }
}

async fn login() -> Result<()> {
    #[derive(serde::Deserialize)]
    struct Creds {
        email: String,
        password: String,
    }
    let mut line = String::new();
    std::io::stdin().read_line(&mut line)?;
    let creds: Creds =
        serde_json::from_str(line.trim()).map_err(|_| anyhow!("Expected credentials JSON on stdin"))?;

    let email = creds.email.trim().to_string();
    let (e2, p2) = (email.clone(), creds.password.clone());
    let login_closure = move || -> Result<(String, String), String> { Ok((e2.clone(), p2.clone())) };

    let tfa_closure = |req: plume_core::auth::TwoFactorRequest| -> Result<
        plume_core::auth::TwoFactorAction,
        String,
    > {
        use plume_core::auth::{TwoFactorAction, TwoFactorMethod};
        let phones: Vec<_> = req
            .trusted_phone_numbers
            .iter()
            .map(|p| json!({ "id": p.id, "lastTwo": p.last_two_digits }))
            .collect();
        let answer = prompt(json!({
            "type": "prompt",
            "kind": "two_factor",
            "method": match req.method { TwoFactorMethod::Sms => "sms", TwoFactorMethod::Device => "device" },
            "phones": phones,
        }))
        .map_err(|e| e.to_string())?;

        if let Some(id) = answer.strip_prefix("sms:") {
            let id: u32 = id.parse().map_err(|_| "Invalid phone id".to_string())?;
            return Ok(TwoFactorAction::SendSms(id));
        }
        if answer.is_empty() {
            return Err("Sign-in cancelled".into());
        }
        Ok(TwoFactorAction::SubmitCode(answer))
    };

    emit(json!({ "type": "progress", "stage": "Signing in…", "percent": 10 }));
    let account = Account::login(login_closure, tfa_closure, anisette()).await?;

    emit(json!({ "type": "progress", "stage": "Saving account…", "percent": 80 }));
    let mut store = load_store().await?;
    let _critical = events::Critical::enter();
    store.accounts_add_from_session(email.clone(), account).await?;

    let first_name = store
        .get_account(&email)
        .map(|a| a.first_name().clone())
        .unwrap_or_default();
    emit(json!({ "type": "done", "account": { "email": email, "firstName": first_name } }));
    Ok(())
}

async fn logout(email: Option<String>) -> Result<()> {
    let mut store = load_store().await?;
    let email = match email {
        Some(e) => e,
        None => store
            .selected_account()
            .ok_or_else(|| anyhow!("No account logged in"))?
            .email()
            .clone(),
    };
    store.accounts_remove(&email).await?;
    emit(json!({ "type": "done" }));
    Ok(())
}

async fn accounts() -> Result<()> {
    let store = load_store().await?;
    // Re-save once so tokens from older versions move from accounts.json into the Keychain.
    if std::fs::read_to_string(store_path()).map(|s| s.contains("\"xcode_gs_token\": \"") && !s.contains("\"xcode_gs_token\": \"\"")).unwrap_or(false) {
        store.save().await?;
    }
    let selected = store.selected_account().map(|a| a.email().clone());
    let list: Vec<_> = store
        .accounts()
        .values()
        // No session token (e.g. Keychain item missing) = must sign in again.
        .filter(|a| !a.xcode_gs_token().is_empty())
        .map(|a| {
            json!({
                "email": a.email(),
                "firstName": a.first_name(),
                "teamId": a.team_id(),
                "selected": Some(a.email()) == selected.as_ref(),
            })
        })
        .collect();
    emit(json!({ "type": "accounts", "accounts": list }));
    Ok(())
}

/// Apple's free-account limits: 10 new App IDs per rolling 7 days, 3 active sideloaded apps per device.
async fn quota() -> Result<()> {
    let store = load_store().await?;
    let account = store
        .selected_account()
        .ok_or_else(|| anyhow!("No account selected"))?
        .clone();
    let (session, team_id) = install::session_for(&account).await?;
    let resp = session.qh_list_app_ids(&team_id).await?;
    let used = resp.app_ids.len() as i64;
    let max = resp.max_quantity.unwrap_or(10);
    let (available, exact) = match resp.available_quantity {
        Some(a) => (a, true),
        None => ((max - used).max(0), false),
    };
    let app_ids: Vec<_> = resp.app_ids.iter().map(|a| a.identifier.clone()).collect();

    let devices: Vec<_> = store
        .refreshes()
        .values()
        .map(|rd| json!({ "udid": rd.udid, "name": rd.name, "active": rd.apps.len(), "limit": 3 }))
        .collect();

    emit(json!({
        "type": "quota",
        "appIds": { "available": available, "max": max, "used": used, "exact": exact, "identifiers": app_ids },
        "devices": devices,
    }));
    Ok(())
}
