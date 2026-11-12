//! Apple TV pairing over Wi-Fi.
//!
//! Apple TVs have no USB port, so the first connection goes through Apple's
//! "remote pairing" protocol: the TV shows a PIN (Settings → Remotes and Devices →
//! Remote App and Devices), the user types it on the Mac, and both sides derive a
//! shared key. tvOS ignores classic lockdown pairing records, so (like Xcode) we keep
//! that key and talk to the TV through an encrypted tunnel; see `tv.rs`.

use std::collections::HashMap;
use std::net::IpAddr;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow};
use idevice::remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket};
use mdns_sd::{ServiceDaemon, ServiceEvent};
use serde_json::json;

use crate::events::{emit, progress, prompt};

/// Advertised by an Apple TV while its "Remote App and Devices" screen is open.
const MANUAL_PAIRING_SERVICE: &str = "_remotepairing-manual-pairing._tcp.local.";
use crate::tv::TUNNEL_SERVICE;
use crate::tv::HOST_NAME;

/// Look for Apple TVs that are showing the pairing screen.
pub async fn scan(seconds: u64) -> Result<()> {
    let found = tokio::task::spawn_blocking(move || browse(Duration::from_secs(seconds))).await??;
    emit(json!({ "type": "pairables", "devices": found }));
    Ok(())
}

fn browse(timeout: Duration) -> Result<Vec<serde_json::Value>> {
    let mdns = ServiceDaemon::new().context("Can't start Bonjour browsing")?;
    let rx = mdns.browse(MANUAL_PAIRING_SERVICE)?;
    let deadline = Instant::now() + timeout;
    let mut found: HashMap<String, serde_json::Value> = HashMap::new();

    while let Some(left) = deadline.checked_duration_since(Instant::now()) {
        let Ok(event) = rx.recv_timeout(left) else { break };
        if let ServiceEvent::ServiceResolved(info) = event {
            // Prefer IPv4: link-local IPv6 needs a scope id we don't get here.
            let mut addrs: Vec<IpAddr> = info.get_addresses().iter().copied().collect();
            addrs.sort_by_key(|a| !a.is_ipv4());
            let Some(addr) = addrs.first() else { continue };
            let props: HashMap<String, String> = info
                .get_properties()
                .iter()
                .map(|p| (p.key().to_string(), p.val_str().to_string()))
                .collect();
            let instance = info
                .get_fullname()
                .trim_end_matches(MANUAL_PAIRING_SERVICE)
                .trim_end_matches('.')
                .to_string();
            let name = props
                .get("name")
                .cloned()
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| {
                    info.get_hostname()
                        .trim_end_matches('.')
                        .trim_end_matches(".local")
                        .replace('-', " ")
                });
            log::info!("Pairable device {instance}: {addr}:{} {props:?}", info.get_port());
            found.insert(
                instance.clone(),
                json!({
                    "id": instance,
                    "name": name,
                    "host": addr.to_string(),
                    "port": info.get_port(),
                    "model": props.get("model"),
                }),
            );
        }
    }
    let _ = mdns.shutdown();
    Ok(found.into_values().collect())
}

/// Port of the device's tunnel service (`_remotepairing._tcp`) at `ip`. Its identifier
/// differs from the pairing service's, so the address is what ties the two together.
fn find_tunnel_port(ip: IpAddr, timeout: Duration) -> Result<Option<u16>> {
    let mdns = ServiceDaemon::new().context("Can't start Bonjour browsing")?;
    let rx = mdns.browse(TUNNEL_SERVICE)?;
    let deadline = Instant::now() + timeout;
    let mut port = None;
    while let Some(left) = deadline.checked_duration_since(Instant::now()) {
        let Ok(event) = rx.recv_timeout(left) else { break };
        if let ServiceEvent::ServiceResolved(info) = event {
            if info.get_addresses().contains(&ip) {
                log::info!("Tunnel service {} at {ip}:{}", info.get_fullname(), info.get_port());
                port = Some(info.get_port());
                break;
            }
        }
    }
    let _ = mdns.shutdown();
    Ok(port)
}

/// Pair with an Apple TV at `host:port` (from `scan`), asking the user for the PIN on screen.
pub async fn pair(host: String, port: u16) -> Result<()> {
    let ip: IpAddr = host.parse().map_err(|_| anyhow!("Invalid address {host}"))?;

    progress("Connecting to Apple TV…", 10);
    let stream = connect(ip, port).await?;
    let mut rp_file = RpPairingFile::generate(HOST_NAME);
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), HOST_NAME, &mut rp_file);

    progress("Waiting for the code…", 20);
    rpc.connect(
        async |_| {
            let answer = tokio::task::spawn_blocking(|| {
                prompt(json!({
                    "type": "prompt",
                    "kind": "pin",
                    "title": "Enter the code from your Apple TV",
                    "message": "The 6-digit code is shown on the TV screen.",
                }))
                .unwrap_or_default()
            })
            .await
            .unwrap_or_default();
            answer.trim().to_string()
        },
        0u8,
    )
    .await
    .map_err(|e| anyhow!("Pairing failed — check the code and try again ({e})"))?;
    drop(rpc);

    // The pairing service can't open tunnels ("Tunnel listener creator not set").
    // Reconnect to the device's tunnel service and verify with the new keys; this must
    // not ask for a code again.
    progress("Verifying pairing…", 38);
    let tunnel_service_port = tokio::task::spawn_blocking(move || {
        find_tunnel_port(ip, Duration::from_secs(10))
    })
    .await??
    .ok_or_else(|| anyhow!("Apple TV paired, but its connection service wasn't found on the network. Try again."))?;
    let mut conn = crate::tv::TvConn::open(
        crate::tv::SavedTv { udid: String::new(), name: String::new(), product_type: None, os_version: None },
        ip,
        tunnel_service_port,
        rp_file.clone(),
    )
    .await
    .map_err(|e| anyhow!("Apple TV paired, but the secure connection failed ({e:#})"))?;

    progress("Reading device info…", 70);
    let udid = conn
        .lockdown_value("UniqueDeviceID")
        .await?
        .ok_or_else(|| anyhow!("Apple TV didn't report its UDID"))?;
    let info = crate::tv::SavedTv {
        udid: udid.clone(),
        name: conn.lockdown_value("DeviceName").await?.unwrap_or_else(|| "Apple TV".into()),
        product_type: conn.lockdown_value("ProductType").await?,
        os_version: conn.lockdown_value("ProductVersion").await?,
    };

    progress("Saving pairing…", 90);
    let _critical = crate::events::Critical::enter();
    crate::tv::save(&info, &rp_file)?;

    emit(json!({
        "type": "done",
        "device": { "udid": udid, "name": info.name },
        "visible": true,
    }));
    Ok(())
}

async fn connect(ip: IpAddr, port: u16) -> Result<tokio::net::TcpStream> {
    tokio::time::timeout(Duration::from_secs(10), tokio::net::TcpStream::connect((ip, port)))
        .await
        .map_err(|_| anyhow!("Apple TV at {ip} didn't answer. Is it on the same Wi-Fi network?"))?
        .with_context(|| format!("Can't connect to Apple TV at {ip}:{port}"))
}
