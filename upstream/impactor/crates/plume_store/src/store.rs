use std::collections::HashMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use plume_core::Error;

use crate::{GsaAccount, RefreshDevice};

#[derive(Debug, Serialize, Deserialize, Default, Clone)]
pub struct AccountStore {
    selected_account: Option<String>,      // Email
    accounts: HashMap<String, GsaAccount>, // Email -> GsaAccount
    #[serde(default)]
    refreshes: HashMap<String, RefreshDevice>, // UDID -> RefreshDevice (apps?)
    #[serde(default)]
    locale: Option<String>, // None = system locale
    #[serde(skip)]
    path: Option<PathBuf>,
}

impl AccountStore {
    pub async fn load(path: &Option<PathBuf>) -> Result<Self, Error> {
        if let Some(path) = path {
            let mut settings = if !path.exists() {
                Self::default()
            } else {
                let contents = tokio::fs::read_to_string(path).await?;
                secrets::decode(&contents)?
            };
            settings.path = Some(path.clone());
            Ok(settings)
        } else {
            Ok(Self::default())
        }
    }

    pub fn load_sync(path: &Option<PathBuf>) -> Result<Self, Error> {
        if let Some(path) = path {
            let mut settings = if !path.exists() {
                Self::default()
            } else {
                let contents = std::fs::read_to_string(path)?;
                secrets::decode(&contents)?
            };
            settings.path = Some(path.clone());
            Ok(settings)
        } else {
            Ok(Self::default())
        }
    }

    pub async fn save(&self) -> Result<(), Error> {
        if let Some(path) = &self.path {
            if let Some(parent) = path.parent() {
                tokio::fs::create_dir_all(parent).await?;
            }

            tokio::fs::write(path, secrets::encode(self)?).await?;
        }
        Ok(())
    }

    pub fn save_sync(&self) -> Result<(), Error> {
        if let Some(path) = &self.path {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }

            std::fs::write(path, secrets::encode(self)?)?;
        }
        Ok(())
    }

    pub fn accounts(&self) -> &HashMap<String, GsaAccount> {
        &self.accounts
    }

    pub fn path(&self) -> Option<PathBuf> {
        self.path.clone()
    }

    pub fn get_account(&self, email: &str) -> Option<&GsaAccount> {
        self.accounts.get(email)
    }

    pub async fn accounts_add(&mut self, account: GsaAccount) -> Result<(), Error> {
        let email = account.email().clone();
        self.accounts.insert(email.clone(), account);
        self.selected_account = Some(email);
        self.save().await
    }

    pub fn accounts_add_sync(&mut self, account: GsaAccount) -> Result<(), Error> {
        let email = account.email().clone();
        self.accounts.insert(email.clone(), account);
        self.selected_account = Some(email);
        self.save_sync()
    }

    pub async fn accounts_remove(&mut self, email: &str) -> Result<(), Error> {
        self.accounts.remove(email);
        secrets::forget(email);
        if self.selected_account.as_ref() == Some(&email.to_string()) {
            self.selected_account = None;
        }
        self.save().await
    }

    pub fn accounts_remove_sync(&mut self, email: &str) -> Result<(), Error> {
        self.accounts.remove(email);
        secrets::forget(email);
        if self.selected_account.as_ref() == Some(&email.to_string()) {
            self.selected_account = None;
        }
        self.save_sync()
    }

    pub async fn account_select(&mut self, email: &str) -> Result<(), Error> {
        if self.accounts.contains_key(email) {
            self.selected_account = Some(email.to_string());
            self.save().await
        } else {
            Err(Error::Parse) // we need better errors
        }
    }

    pub fn account_select_sync(&mut self, email: &str) -> Result<(), Error> {
        if self.accounts.contains_key(email) {
            self.selected_account = Some(email.to_string());
            self.save_sync()
        } else {
            Err(Error::Parse) // we need better errors
        }
    }

    pub fn selected_account(&self) -> Option<&GsaAccount> {
        if let Some(email) = &self.selected_account {
            self.accounts.get(email)
        } else {
            None
        }
    }

    pub fn locale(&self) -> Option<&str> {
        self.locale.as_deref()
    }

    pub fn set_locale_sync(&mut self, locale: Option<String>) -> Result<(), Error> {
        self.locale = locale;
        self.save_sync()
    }

    pub async fn accounts_add_from_session(
        &mut self,
        email: String,
        account: plume_core::auth::Account,
    ) -> Result<(), Error> {
        let first_name = account.get_name().0;
        let s = plume_core::developer::DeveloperSession::using_account(account).await?;
        let teams_response = s.qh_list_teams().await?;
        let adsid = s.adsid().clone();
        let xcode_gs_token = s.xcode_gs_token().clone();

        let team_id = if teams_response.teams.is_empty() {
            "".to_string()
        } else {
            teams_response.teams[0].team_id.clone()
        };

        let account = GsaAccount::new(email, first_name, adsid, xcode_gs_token, team_id);

        self.accounts_add(account).await?;

        Ok(())
    }

    pub async fn update_account_team(&mut self, email: &str, team_id: String) -> Result<(), Error> {
        if let Some(account) = self.accounts.get_mut(email) {
            account.set_team_id(team_id);
            self.save().await
        } else {
            Err(Error::Parse)
        }
    }

    pub fn update_account_team_sync(&mut self, email: &str, team_id: String) -> Result<(), Error> {
        if let Some(account) = self.accounts.get_mut(email) {
            account.set_team_id(team_id);
            self.save_sync()
        } else {
            Err(Error::Parse)
        }
    }

    pub fn refreshes(&self) -> &HashMap<String, RefreshDevice> {
        &self.refreshes
    }

    pub fn get_refresh_device(&self, udid: &str) -> Option<&RefreshDevice> {
        self.refreshes.get(udid)
    }

    pub async fn add_or_update_refresh_device(
        &mut self,
        device: RefreshDevice,
    ) -> Result<(), Error> {
        self.refreshes.insert(device.udid.clone(), device);
        self.save().await
    }

    pub fn add_or_update_refresh_device_sync(
        &mut self,
        device: RefreshDevice,
    ) -> Result<(), Error> {
        self.refreshes.insert(device.udid.clone(), device);
        self.save_sync()
    }

    pub async fn remove_refresh_device(&mut self, udid: &str) -> Result<(), Error> {
        self.refreshes.remove(udid);
        self.save().await
    }

    pub fn remove_refresh_device_sync(&mut self, udid: &str) -> Result<(), Error> {
        self.refreshes.remove(udid);
        self.save_sync()
    }
}

/// [GatePass] Session tokens (adsid + xcode_gs_token) stay in accounts.json (owner-only file)
/// by default. With GATEPASS_KEYCHAIN=1 they move to the macOS Keychain instead: safer, but
/// macOS may ask for the login password after app updates unless the app has a Developer ID.
mod secrets {
    use super::AccountStore;
    use plume_core::Error;
    use serde_json::Value;

    pub fn encode(store: &AccountStore) -> Result<String, Error> {
        let mut value = serde_json::to_value(store)?;
        if let Some(accounts) = value.get_mut("accounts").and_then(|a| a.as_object_mut()) {
            for (email, acc) in accounts.iter_mut() {
                stash(email, acc);
            }
        }
        Ok(serde_json::to_string_pretty(&value)?)
    }

    pub fn decode(contents: &str) -> Result<AccountStore, Error> {
        let mut value: Value = serde_json::from_str(contents)?;
        if let Some(accounts) = value.get_mut("accounts").and_then(|a| a.as_object_mut()) {
            for (email, acc) in accounts.iter_mut() {
                restore(email, acc);
            }
        }
        Ok(serde_json::from_value(value)?)
    }

    #[cfg(target_os = "macos")]
    // [GatePass] v2 name: items made by the old ad-hoc-signed builds are left alone so the
    // stable-signed engine never triggers a Keychain password prompt.
    const SERVICE: &str = "app.gatepass.sideloader.session";

    #[cfg(target_os = "macos")]
    fn enabled() -> bool {
        std::env::var("GATEPASS_KEYCHAIN").map(|v| v == "1").unwrap_or(false)
    }

    #[cfg(target_os = "macos")]
    fn stash(email: &str, acc: &mut Value) {
        use security_framework::passwords::set_generic_password;
        if !enabled() {
            return;
        }
        let adsid = acc.get("adsid").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let token = acc.get("xcode_gs_token").and_then(|v| v.as_str()).unwrap_or("").to_string();
        if token.is_empty() {
            return;
        }
        let payload = serde_json::json!({ "adsid": adsid, "token": token }).to_string();
        if set_generic_password(SERVICE, email, payload.as_bytes()).is_ok() {
            acc["adsid"] = Value::String(String::new());
            acc["xcode_gs_token"] = Value::String(String::new());
        }
    }

    #[cfg(target_os = "macos")]
    fn restore(email: &str, acc: &mut Value) {
        use security_framework::passwords::get_generic_password;
        if !enabled() {
            return;
        }
        let has_token = acc.get("xcode_gs_token").and_then(|v| v.as_str()).map(|s| !s.is_empty()).unwrap_or(false);
        if has_token {
            return;
        }
        if let Ok(bytes) = get_generic_password(SERVICE, email) {
            if let Ok(v) = serde_json::from_slice::<Value>(&bytes) {
                acc["adsid"] = v["adsid"].clone();
                acc["xcode_gs_token"] = v["token"].clone();
            }
        }
    }

    #[cfg(target_os = "macos")]
    pub fn forget(email: &str) {
        if !enabled() {
            return;
        }
        let _ = security_framework::passwords::delete_generic_password(SERVICE, email);
    }

    #[cfg(not(target_os = "macos"))]
    fn stash(_: &str, _: &mut Value) {}
    #[cfg(not(target_os = "macos"))]
    fn restore(_: &str, _: &mut Value) {}
    #[cfg(not(target_os = "macos"))]
    pub fn forget(_: &str) {}
}
