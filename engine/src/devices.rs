use anyhow::{Result, anyhow};
use idevice::{
    IdeviceService,
    lockdown::LockdownClient,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice},
};
use plume_utils::Device;
use serde_json::{Value, json};

use crate::events::emit;

const LABEL: &str = "gatepass";

fn connection_name(d: &UsbmuxdDevice) -> &'static str {
    match d.connection_type {
        Connection::Usb => "usb",
        Connection::Network(_) => "wifi",
        Connection::Unknown(_) => "unknown",
    }
}

async fn describe(d: &UsbmuxdDevice) -> Value {
    let mut info = json!({
        "udid": d.udid,
        "connection": connection_name(d),
        "name": Value::Null,
        "productType": Value::Null,
        "osVersion": Value::Null,
        "deviceClass": Value::Null,
    });

    if let Ok(mut lockdown) =
        LockdownClient::connect(&d.to_provider(UsbmuxdAddr::default(), LABEL)).await
    {
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
    }
    info
}

/// All usbmuxd devices, deduplicated by UDID (USB wins over Wi-Fi).
async fn raw_devices() -> Result<Vec<UsbmuxdDevice>> {
    let mut muxer = UsbmuxdConnection::default()
        .await
        .map_err(|e| anyhow!("Cannot reach usbmuxd: {e}"))?;
    let mut all = muxer.get_devices().await?;
    all.sort_by_key(|d| !matches!(d.connection_type, Connection::Usb));
    let mut seen = std::collections::HashSet::new();
    all.retain(|d| seen.insert(d.udid.clone()));
    Ok(all)
}

pub async fn list() -> Result<()> {
    let devices = raw_devices().await?;
    let described = futures::future::join_all(devices.iter().map(describe)).await;
    emit(json!({ "type": "devices", "devices": described }));
    Ok(())
}

/// Find a connected device by UDID, preferring a USB connection.
pub async fn find(udid: &str) -> Result<Device> {
    let d = raw_devices()
        .await?
        .into_iter()
        .find(|d| d.udid == udid)
        .ok_or_else(|| anyhow!("Device {udid} not found"))?;
    Ok(Device::new(d).await)
}

/// User-installed apps on the device: (bundle id, display name, signer team if known).
pub async fn user_apps(udid: &str) -> Result<Vec<(String, String)>> {
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
    let apps = user_apps(udid).await?;
    emit(json!({
        "type": "installed",
        "apps": apps.iter().map(|(id, name)| json!({ "bundleId": id, "name": name })).collect::<Vec<_>>(),
    }));
    Ok(())
}
