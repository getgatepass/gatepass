//! A library to generate "anisette" data. Docs are coming soon.
//!
//! If you want an async API, enable the `async` feature.
//!
//! If you want remote anisette, make sure the `remote-anisette` feature is enabled. (it's currently on by default)

use crate::adi_proxy::{ADIProxyAnisetteProvider, ConfigurableADIProxy};
use crate::anisette_headers_provider::AnisetteHeadersProvider;
use adi_proxy::ADIError;
use std::io;
use std::path::PathBuf;
use thiserror::Error;

pub mod adi_proxy;
pub mod anisette_headers_provider;
pub mod store_services_core;

// [GatePass] real-Mac anisette via AOSKit (see aos_kit.rs)
#[cfg(target_os = "macos")]
pub mod aos_kit;

#[cfg(feature = "remote-anisette-v3")]
pub mod remote_anisette_v3;

#[allow(dead_code)]
pub struct AnisetteHeaders;

#[allow(dead_code)]
#[derive(Debug, Error)]
pub enum AnisetteError {
    #[allow(dead_code)]
    #[error("Unsupported device")]
    UnsupportedDevice,
    #[error("Invalid argument {0}")]
    InvalidArgument(String),
    #[error("Anisette not provisioned!")]
    AnisetteNotProvisioned,
    #[error("Plist serialization error {0}")]
    PlistError(#[from] plist::Error),
    #[error("Request Error {0}")]
    ReqwestError(#[from] reqwest::Error),
    #[cfg(feature = "remote-anisette-v3")]
    #[error("Provisioning socket error {0}")]
    WsError(#[from] tokio_tungstenite::tungstenite::error::Error),
    #[cfg(feature = "remote-anisette-v3")]
    #[error("JSON error {0}")]
    SerdeError(#[from] serde_json::Error),
    #[error("IO error {0}")]
    IOError(#[from] io::Error),
    #[error("ADI error {0}")]
    ADIError(#[from] ADIError),
    #[error("Invalid library format")]
    InvalidLibraryFormat,
    #[error("Misc")]
    Misc,
    #[error("Missing Libraries")]
    MissingLibraries,
    #[error("{0}")]
    Anyhow(#[from] anyhow::Error),
}

pub const DEFAULT_ANISETTE_URL: &str = "https://ani.f1sh.me/";

pub const DEFAULT_ANISETTE_URL_V3: &str = "https://ani.sidestore.io";

/// [GatePass] Public v3 servers tried in order. ani.sidestore.io advertises macOS 13.1;
/// mac-ani.jkcoxson.com advertises macOS 10.12, which Apple may reject during 2FA,
/// so it is only the last resort.
pub const FALLBACK_ANISETTE_URLS_V3: &[&str] =
    &["https://ani.sidestore.io", "https://mac-ani.jkcoxson.com"];

#[derive(Clone, Debug)]
pub struct AnisetteConfiguration {
    anisette_url: String,
    anisette_url_v3: String,
    configuration_path: PathBuf,
    macos_serial: String,
}

impl Default for AnisetteConfiguration {
    fn default() -> Self {
        AnisetteConfiguration::new()
    }
}

impl AnisetteConfiguration {
    pub fn new() -> AnisetteConfiguration {
        AnisetteConfiguration {
            anisette_url: DEFAULT_ANISETTE_URL.to_string(),
            anisette_url_v3: DEFAULT_ANISETTE_URL_V3.to_string(),
            configuration_path: PathBuf::new(),
            macos_serial: "0".to_string(),
        }
    }

    pub fn anisette_url(&self) -> &String {
        &self.anisette_url
    }

    pub fn configuration_path(&self) -> &PathBuf {
        &self.configuration_path
    }

    pub fn set_anisette_url(mut self, anisette_url: String) -> AnisetteConfiguration {
        self.anisette_url = anisette_url;
        self
    }

    pub fn set_macos_serial(mut self, macos_serial: String) -> AnisetteConfiguration {
        self.macos_serial = macos_serial;
        self
    }

    pub fn set_configuration_path(mut self, configuration_path: PathBuf) -> AnisetteConfiguration {
        self.configuration_path = configuration_path;
        self
    }
}

pub enum AnisetteHeadersProviderType {
    Local,
    Remote,
}

pub struct AnisetteHeadersProviderRes {
    pub provider: Box<dyn AnisetteHeadersProvider>,
    pub provider_type: AnisetteHeadersProviderType,
}

impl AnisetteHeadersProviderRes {
    pub fn local(provider: Box<dyn AnisetteHeadersProvider>) -> AnisetteHeadersProviderRes {
        AnisetteHeadersProviderRes {
            provider,
            provider_type: AnisetteHeadersProviderType::Local,
        }
    }

    pub fn remote(provider: Box<dyn AnisetteHeadersProvider>) -> AnisetteHeadersProviderRes {
        AnisetteHeadersProviderRes {
            provider,
            provider_type: AnisetteHeadersProviderType::Remote,
        }
    }
}

impl AnisetteHeaders {
    pub fn get_anisette_headers_provider(
        configuration: AnisetteConfiguration,
    ) -> Result<AnisetteHeadersProviderRes, AnisetteError> {
        // [GatePass] On macOS use the machine's own identity. Apple rejects identities
        // from public anisette servers (403 during 2FA, -80045 at login), so the default
        // never falls back to them.
        // GATEPASS_ANISETTE: "local" (default), "auto" (local, then public server) or
        // "remote" — the latter two only for debugging.
        #[cfg(target_os = "macos")]
        {
            let policy = std::env::var("GATEPASS_ANISETTE").unwrap_or_else(|_| "local".into());
            if policy != "remote" {
                match aos_kit::AOSKitAnisetteProvider::new() {
                    Ok(p) => {
                        log::info!("Using local AOSKit anisette");
                        return Ok(AnisetteHeadersProviderRes::local(Box::new(p)));
                    }
                    Err(e) if policy == "local" => {
                        log::error!("Local AOSKit anisette unavailable: {e}");
                        return Err(e);
                    }
                    Err(e) => log::warn!("Local AOSKit anisette unavailable ({e}), falling back"),
                }
            }
        }

        // StoreServicesCore needs Android libraries we don't ship on macOS.
        #[cfg(not(target_os = "macos"))]
        if let Ok(ssc_anisette_headers_provider) =
            AnisetteHeaders::get_ssc_anisette_headers_provider(configuration.clone())
        {
            return Ok(ssc_anisette_headers_provider);
        }

        #[cfg(feature = "remote-anisette-v3")]
        return Ok(AnisetteHeadersProviderRes::remote(Box::new(
            remote_anisette_v3::RemoteAnisetteProviderV3::new(
                configuration.anisette_url_v3,
                configuration.configuration_path.clone(),
                configuration.macos_serial.clone(),
            ),
        )));

        #[cfg(not(feature = "remote-anisette-v3"))]
        Err(AnisetteError::UnsupportedDevice)
    }

    pub fn get_ssc_anisette_headers_provider(
        configuration: AnisetteConfiguration,
    ) -> Result<AnisetteHeadersProviderRes, AnisetteError> {
        let mut ssc_adi_proxy = store_services_core::StoreServicesCoreADIProxy::new(
            configuration.configuration_path(),
        )?;
        let config_path = configuration.configuration_path();
        ssc_adi_proxy.set_provisioning_path(config_path.to_str().ok_or(
            AnisetteError::InvalidArgument("configuration.configuration_path".to_string()),
        )?)?;
        Ok(AnisetteHeadersProviderRes::local(Box::new(
            ADIProxyAnisetteProvider::new(ssc_adi_proxy, config_path.to_path_buf())?,
        )))
    }
}

#[cfg(test)]
mod tests {
    use log::LevelFilter;
    use simplelog::{ColorChoice, ConfigBuilder, TermLogger, TerminalMode};

    pub fn init_logger() {
        if TermLogger::init(
            LevelFilter::Trace,
            ConfigBuilder::new()
                .set_target_level(LevelFilter::Error)
                .add_filter_allow_str("omnisette")
                .build(),
            TerminalMode::Mixed,
            ColorChoice::Auto,
        )
        .is_ok()
        {}
    }

    #[cfg(not(feature = "async"))]
    #[test]
    fn fetch_anisette_auto() -> Result<()> {
        use crate::{AnisetteConfiguration, AnisetteHeaders};
        use log::info;
        use std::path::PathBuf;

        crate::tests::init_logger();

        let mut provider = AnisetteHeaders::get_anisette_headers_provider(
            AnisetteConfiguration::new()
                .set_configuration_path(PathBuf::new().join("anisette_test")),
        )?;
        info!(
            "Headers: {:?}",
            provider.provider.get_authentication_headers()?
        );
        Ok(())
    }
}
