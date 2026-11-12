use anyhow::{Result, anyhow};
use idevice::{
    IdeviceService,
    lockdown::LockdownClient,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice},
};
use std::path::PathBuf;

use plume_utils::Device;
use plume_core::MobileProvision;
use serde_json::{Value, json};

use crate::events::emit;
use crate::tv;

const LABEL: &str = "gatepass";

fn connection_name(d: &UsbmuxdDevice) -> &'static str {
    match d.connection_type {
        Connection::Usb => "usb",
        Connection::Network(_) => "wifi",
        Connection::Unknown(_) => "unknown",
    }
}

/// Reads device info and checks that this Mac is really trusted.
///
/// macOS keeps listing a Wi-Fi device as long as it still has an old pairing record,
/// even after the user removed this Mac on the device. Starting a lockdown session with
/// that record is the only reliable test.
async fn describe(d: &UsbmuxdDevice) -> Value {
    let mut info = json!({
        "udid": d.udid,
        "connection": connection_name(d),
        "name": Value::Null,
        "productType": Value::Null,
        "osVersion": Value::Null,
        "deviceClass": Value::Null,
        "paired": false,
    });

    let Ok(mut lockdown) =
        LockdownClient::connect(&d.to_provider(UsbmuxdAddr::default(), LABEL)).await
    else {
        return info;
    };

    let paired = match UsbmuxdConnection::default().await {
        Ok(mut muxer) => match muxer.get_pair_record(&d.udid).await {
            Ok(record) => lockdown.start_session(&record).await.is_ok(),
            Err(_) => false,
        },
        Err(_) => false,
    };
    info["paired"] = json!(paired);

    if let Ok(values) = lockdown.get_value(None, None).await {
        if let Some(dict) = values.as_dictionary() {
            for (json_key, plist_key) in [
                ("name", "DeviceName"),
                ("productType", "ProductType"),
                ("osVersion", "ProductVersion"),
                ("deviceClass", "DeviceClass"),
            ] {
                if let Some(s) = dict.get(plist_key).and_then(|v| v.as_string()) {
                    info[json_key] = json!(s);
                }
            }
        }
    }
    info
}

/// Same device reported twice (dashes/case differ between USB and network entries).
fn udid_key(udid: &str) -> String {
    udid.replace('-', "").to_uppercase()
}

/// All usbmuxd devices, deduplicated by UDID (USB wins over Wi-Fi).
async fn raw_devices() -> Result<Vec<UsbmuxdDevice>> {
    let mut muxer = UsbmuxdConnection::default()
        .await
        .map_err(|e| anyhow!("Cannot reach usbmuxd: {e}"))?;
    let mut all = muxer.get_devices().await?;
    all.sort_by_key(|d| !matches!(d.connection_type, Connection::Usb));
    let mut seen = std::collections::HashSet::new();
    all.retain(|d| seen.insert(udid_key(&d.udid)));
    Ok(all)
}

pub async fn list() -> Result<()> {
    let (mux, tvs) = tokio::join!(
        async {
            let devices = raw_devices().await?;
            Ok::<_, anyhow::Error>(futures::future::join_all(devices.iter().map(describe)).await)
        },
        paired_tvs()
    );
    // A Wi-Fi device that no longer trusts this Mac can't be used; it has to be paired again
    // (Apple TV: with a code). USB devices stay visible so the user sees the "Trust" step.
    let mut usable: Vec<Value> = mux?
        .into_iter()
        .filter(|d| d["paired"] == json!(true) || d["connection"] == json!("usb"))
        .collect();
    for tv in tvs {
        if !usable.iter().any(|d| d["udid"] == tv["udid"]) {
            usable.push(tv);
        }
    }
    emit(json!({ "type": "devices", "devices": usable }));
    Ok(())
}

/// Apple TVs paired with a code that are on the network and still trust this Mac.
async fn paired_tvs() -> Vec<Value> {
    let saved = tv::saved();
    if saved.is_empty() {
        return vec![];
    }
    let lookup = saved.clone();
    let places = tokio::task::spawn_blocking(move || tv::locate(&lookup, std::time::Duration::from_secs(2)))
        .await
        .unwrap_or_default();
    let checks = saved.into_iter().filter_map(|(info, key)| {
        let (ip, port) = *places.get(&info.udid)?;
        Some(async move {
            tv::still_trusted(ip, port, key).await.then(|| {
                json!({
                    "udid": info.udid,
                    "connection": "wifi",
                    "name": info.name,
                    "productType": info.product_type,
                    "osVersion": info.os_version,
                    "deviceClass": "AppleTV",
                    "paired": true,
                })
            })
        })
    });
    futures::future::join_all(checks).await.into_iter().flatten().collect()
}

/// A device we can install to: through usbmuxd (cable or Wi-Fi), or an Apple TV
/// paired with a code, through its encrypted tunnel.
pub enum Target {
    Mux(Device),
    Tv(Box<tv::TvConn>),
}

impl Target {
    pub fn udid(&self) -> &str {
        match self {
            Target::Mux(d) => &d.udid,
            Target::Tv(t) => &t.info.udid,
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Target::Mux(d) => &d.name,
            Target::Tv(t) => &t.info.name,
        }
    }

    pub async fn is_apple_tv(&self) -> bool {
        match self {
            Target::Mux(d) => is_apple_tv(d).await,
            Target::Tv(_) => true,
        }
    }

    pub async fn install_app<F, Fut>(&mut self, app: &PathBuf, progress: F) -> Result<()>
    where
        F: Fn(i32) -> Fut + Clone + Send + 'static,
        Fut: std::future::Future<Output = ()> + Send,
    {
        match self {
            Target::Mux(d) => Ok(d.install_app(app, progress).await?),
            Target::Tv(t) => t.install_app(app, progress).await,
        }
    }

    pub async fn install_profile(&mut self, profile: &MobileProvision) -> Result<()> {
        match self {
            Target::Mux(d) => Ok(d.install_profile(profile).await?),
            Target::Tv(t) => t.install_profile(profile.data.clone()).await,
        }
    }

    pub async fn user_apps(&mut self) -> Result<Vec<(String, String)>> {
        match self {
            Target::Mux(d) => mux_user_apps(&d.udid).await,
            Target::Tv(t) => t.user_apps().await,
        }
    }

    pub async fn is_app_installed(&mut self, bundle_id: &str) -> Result<bool> {
        Ok(self.user_apps().await?.iter().any(|(id, _)| id == bundle_id))
    }
}

/// Find a device by UDID: usbmuxd first (USB preferred), then Apple TVs paired with a code.
pub async fn find(udid: &str) -> Result<Target> {
    if let Some(d) = raw_devices().await?.into_iter().find(|d| d.udid == udid) {
        if !tv::is_saved(udid) {
            return Ok(Target::Mux(Device::new(d).await));
        }
    }
    if tv::is_saved(udid) {
        return Ok(Target::Tv(Box::new(tv::TvConn::connect(udid).await?)));
    }
    Err(anyhow!("Device {udid} not found"))
}

/// User-installed apps on a usbmuxd device: (bundle id, display name).
async fn mux_user_apps(udid: &str) -> Result<Vec<(String, String)>> {
    use idevice::installation_proxy::InstallationProxyClient;
    let d = raw_devices()
        .await?
        .into_iter()
        .find(|d| d.udid == udid)
        .ok_or_else(|| anyhow!("Device {udid} not found"))?;
    let provider = d.to_provider(UsbmuxdAddr::default(), LABEL);
    let mut proxy = InstallationProxyClient::connect(&provider).await?;
    let apps = proxy.get_apps(Some("User"), None).await?;
    Ok(apps
        .into_iter()
        .map(|(id, info)| {
            let name = info
                .as_dictionary()
                .and_then(|d| d.get("CFBundleDisplayName").or_else(|| d.get("CFBundleName")))
                .and_then(|v| v.as_string())
                .unwrap_or("")
                .to_string();
            (id, name)
        })
        .collect())
}

pub async fn print_user_apps(udid: &str) -> Result<()> {
    let apps = find(udid).await?.user_apps().await?;
    emit(json!({
        "type": "installed",
        "apps": apps.iter().map(|(id, name)| json!({ "bundleId": id, "name": name })).collect::<Vec<_>>(),
    }));
    Ok(())
}

/// True for an Apple TV. ProductType ("AppleTV14,1") is readable without a session;
/// DeviceClass is a fallback.
pub async fn is_apple_tv(device: &Device) -> bool {
    let Some(d) = &device.usbmuxd_device else {
        return false;
    };
    let Ok(mut lockdown) =
        LockdownClient::connect(&d.to_provider(UsbmuxdAddr::default(), LABEL)).await
    else {
        return false;
    };
    for (key, value) in [("ProductType", "AppleTV"), ("DeviceClass", "AppleTV")] {
        if let Ok(v) = lockdown.get_value(Some(key), None).await {
            if v.as_string().is_some_and(|s| s.starts_with(value)) {
                return true;
            }
        }
    }
    false
}
