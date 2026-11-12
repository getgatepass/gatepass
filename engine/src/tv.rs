//! Apple TVs paired with a code (tvOS 17+).
//!
//! An Apple TV paired this way never shows up in macOS' usbmuxd: tvOS ignores classic
//! lockdown pairing records. Like Xcode, we keep the remote-pairing key instead and
//! reach every service (install, profiles, app list) through an encrypted tunnel:
//!
//!   `_remotepairing._tcp` → pair-verify → createListener → TLS-PSK tunnel
//!   → user-space TCP → RSD handshake → service
//!
//! Saved TVs live in `<data>/appletv/<udid>.json` (name, model) plus
//! `<udid>.rppairing` (the key; owner-only like everything in the data dir).

use std::collections::HashMap;
use std::net::IpAddr;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow};
use idevice::{
    RsdService,
    installation_proxy::InstallationProxyClient,
    lockdown::LockdownClient,
    misagent::MisagentClient,
    remote_pairing::{
        PeerDevice, RemotePairingClient, RpPairingFile, RpPairingSocket,
        connect_tls_psk_tunnel_native,
    },
    rsd::RsdHandshake,
    tcp::{adapter::Adapter, handle::AdapterHandle},
    utils::installation,
};
use mdns_sd::{ServiceDaemon, ServiceEvent};
use serde::{Deserialize, Serialize};
use tokio::net::TcpStream;

use crate::data_path;

/// Always advertised by an Apple TV that can be paired; the only service that opens tunnels.
pub const TUNNEL_SERVICE: &str = "_remotepairing._tcp.local.";
pub const HOST_NAME: &str = "GatePass";
const LOCKDOWN_TRUSTED: &str = "com.apple.mobile.lockdown.remote.trusted";

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct SavedTv {
    pub udid: String,
    pub name: String,
    pub product_type: Option<String>,
    pub os_version: Option<String>,
}

fn dir() -> PathBuf {
    let d = data_path().join("appletv");
    let _ = std::fs::create_dir_all(&d);
    d
}

pub fn save(tv: &SavedTv, key: &RpPairingFile) -> Result<()> {
    let d = dir();
    std::fs::write(d.join(format!("{}.rppairing", tv.udid)), key.to_bytes())?;
    std::fs::write(d.join(format!("{}.json", tv.udid)), serde_json::to_vec_pretty(tv)?)?;
    Ok(())
}

/// All saved TVs with their pairing keys.
pub fn saved() -> Vec<(SavedTv, RpPairingFile)> {
    let Ok(entries) = std::fs::read_dir(dir()) else { return vec![] };
    entries
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
        .filter_map(|e| {
            let tv: SavedTv = serde_json::from_slice(&std::fs::read(e.path()).ok()?).ok()?;
            let key = std::fs::read(e.path().with_extension("rppairing")).ok()?;
            Some((tv, RpPairingFile::from_bytes(&key).ok()?))
        })
        .collect()
}

pub fn is_saved(udid: &str) -> bool {
    dir().join(format!("{udid}.json")).exists()
}

/// Where each saved TV is right now: browse `_remotepairing._tcp` and match the
/// advertisement's `authTag` against each TV's identity key (it rotates identifiers,
/// so this is the only stable way to recognise it).
pub fn locate(tvs: &[(SavedTv, RpPairingFile)], timeout: Duration) -> HashMap<String, (IpAddr, u16)> {
    let mut found = HashMap::new();
    if tvs.is_empty() {
        return found;
    }
    let Ok(mdns) = ServiceDaemon::new() else { return found };
    let Ok(rx) = mdns.browse(TUNNEL_SERVICE) else { return found };
    let deadline = Instant::now() + timeout;
    while let Some(left) = deadline.checked_duration_since(Instant::now()) {
        let Ok(event) = rx.recv_timeout(left) else { break };
        let ServiceEvent::ServiceResolved(info) = event else { continue };
        let (Some(identifier), Some(tag)) = (
            info.get_property_val_str("identifier"),
            info.get_property_val_str("authTag"),
        ) else {
            continue;
        };
        let mut addrs: Vec<IpAddr> = info.get_addresses().iter().copied().collect();
        addrs.sort_by_key(|a| !a.is_ipv4());
        let Some(addr) = addrs.first().copied() else { continue };
        for (tv, key) in tvs {
            if let Some(irk) = key.alt_irk() {
                if PeerDevice::validate_auth_tag(irk, identifier, tag) {
                    found.insert(tv.udid.clone(), (addr, info.get_port()));
                }
            }
        }
        if found.len() == tvs.len() {
            break;
        }
    }
    let _ = mdns.shutdown();
    found
}

pub async fn tcp(ip: IpAddr, port: u16) -> Result<TcpStream> {
    tokio::time::timeout(Duration::from_secs(10), TcpStream::connect((ip, port)))
        .await
        .map_err(|_| anyhow!("Apple TV at {ip} didn't answer. Is it on the same Wi-Fi network?"))?
        .with_context(|| format!("Can't connect to Apple TV at {ip}:{port}"))
}

type Control = RemotePairingClient<'static, RpPairingSocket<TcpStream>>;

/// Pair-verify on the TV's tunnel service. Fails when the TV no longer trusts this Mac.
async fn verify(ip: IpAddr, port: u16, key: RpPairingFile) -> Result<Control> {
    // The control connection must outlive the tunnel it opened; this process is short-lived.
    let key: &'static mut RpPairingFile = Box::leak(Box::new(key));
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(tcp(ip, port).await?), HOST_NAME, key);
    rpc.attempt_pair_verify().await?;
    rpc.validate_pairing()
        .await
        .map_err(|e| anyhow!("This Apple TV no longer trusts this Mac — pair it again with a code ({e})"))?;
    Ok(rpc)
}

/// True when the TV at `ip:port` still accepts our key.
pub async fn still_trusted(ip: IpAddr, port: u16, key: RpPairingFile) -> bool {
    matches!(
        tokio::time::timeout(Duration::from_secs(6), verify(ip, port, key)).await,
        Ok(Ok(_))
    )
}

/// An open tunnel to an Apple TV.
pub struct TvConn {
    pub info: SavedTv,
    adapter: AdapterHandle,
    rsd: RsdHandshake,
    _control: Control,
}

impl std::fmt::Debug for TvConn {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "TvConn({})", self.info.udid)
    }
}

impl TvConn {
    /// Open a tunnel to the TV at `ip:port` (its `_remotepairing._tcp` service).
    pub async fn open(info: SavedTv, ip: IpAddr, port: u16, key: RpPairingFile) -> Result<Self> {
        let mut control = verify(ip, port, key).await?;
        let listener = control
            .create_tcp_listener()
            .await
            .map_err(|e| anyhow!("Apple TV didn't open a secure connection ({e})"))?;
        let psk = control.encryption_key().to_vec();
        let tunnel = connect_tls_psk_tunnel_native(Box::new(tcp(ip, listener).await?), &psk).await?;
        let t = tunnel.info.clone();
        let mut adapter = Adapter::new(
            Box::new(tunnel.into_inner()),
            t.client_address.parse()?,
            t.server_address.parse()?,
        );
        adapter.set_mss((t.mtu as usize).saturating_sub(60));
        let mut adapter = adapter.to_async_handle();
        let rsd = RsdHandshake::new(adapter.connect(t.server_rsd_port).await?).await?;
        Ok(Self { info, adapter, rsd, _control: control })
    }

    /// Find a saved TV on the network and open a tunnel to it.
    pub async fn connect(udid: &str) -> Result<Self> {
        let all = saved();
        let (info, key) = all
            .iter()
            .find(|(t, _)| t.udid == udid)
            .cloned()
            .ok_or_else(|| anyhow!("Device {udid} not found"))?;
        let lookup = vec![(info.clone(), key.clone())];
        let place = tokio::task::spawn_blocking(move || locate(&lookup, Duration::from_secs(6)))
            .await?
            .remove(udid);
        let (ip, port) = place.ok_or_else(|| {
            anyhow!("{} wasn't found on the network. Is it on and on the same Wi-Fi?", info.name)
        })?;
        Self::open(info, ip, port, key).await
    }

    /// Lockdown values (UDID, name, model, version) read through the tunnel.
    pub async fn lockdown_value(&mut self, key: &str) -> Result<Option<String>> {
        let port = self
            .rsd
            .services
            .get(LOCKDOWN_TRUSTED)
            .ok_or_else(|| anyhow!("This Apple TV doesn't offer lockdown over the tunnel"))?
            .port;
        let mut lockdown =
            <LockdownClient as RsdService>::from_stream(Box::new(self.adapter.connect(port).await?))
                .await?;
        Ok(lockdown
            .get_value(Some(key), None)
            .await
            .ok()
            .and_then(|v| v.as_string().map(str::to_string)))
    }

    pub async fn install_app<F, Fut>(&mut self, app: &PathBuf, progress: F) -> Result<()>
    where
        F: Fn(i32) -> Fut + Clone + Send + 'static,
        Fut: std::future::Future<Output = ()> + Send,
    {
        let cb = move |(p, _): (u64, ())| {
            let progress = progress.clone();
            async move { progress(p as i32).await }
        };
        installation::install_package_with_callback_rsd(
            &mut self.adapter,
            &mut self.rsd,
            app,
            None,
            cb,
            (),
        )
        .await?;
        Ok(())
    }

    pub async fn install_profile(&mut self, profile: Vec<u8>) -> Result<()> {
        let mut mc = MisagentClient::connect_rsd(&mut self.adapter, &mut self.rsd).await?;
        mc.install(profile).await?;
        Ok(())
    }

    pub async fn user_apps(&mut self) -> Result<Vec<(String, String)>> {
        let mut ip = InstallationProxyClient::connect_rsd(&mut self.adapter, &mut self.rsd).await?;
        let apps = ip.get_apps(Some("User"), None).await?;
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
}
