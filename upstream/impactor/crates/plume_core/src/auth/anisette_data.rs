use std::collections::HashMap;
use std::time::SystemTime;

use omnisette::{AnisetteConfiguration, AnisetteHeaders};

use crate::Error;

#[derive(Debug, Clone)]
pub struct AnisetteData {
    pub base_headers: HashMap<String, String>,
    /// [GatePass] User-Agent matching a remote server's identity, if any.
    pub user_agent: Option<String>,
    pub generated_at: SystemTime,
    pub config: AnisetteConfiguration,
}

impl AnisetteData {
    pub async fn new(config: AnisetteConfiguration) -> Result<Self, Error> {
        let mut b = AnisetteHeaders::get_anisette_headers_provider(config.clone())?;
        let mut base_headers = b.provider.get_authentication_headers().await?;
        let user_agent = base_headers.remove(omnisette::USER_AGENT_PSEUDO_HEADER);

        Ok(AnisetteData {
            base_headers,
            user_agent,
            generated_at: SystemTime::now(),
            config,
        })
    }

    /// User-Agent for GrandSlam requests: the remote server's own when there is one.
    pub fn gsa_user_agent(&self) -> String {
        self.user_agent
            .clone()
            .unwrap_or_else(|| "akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0".to_string())
    }

    pub fn needs_refresh(&self) -> bool {
        let elapsed = self.generated_at.elapsed().unwrap();
        elapsed.as_secs() > 60
    }

    pub fn is_valid(&self) -> bool {
        let elapsed = self.generated_at.elapsed().unwrap();
        elapsed.as_secs() < 90
    }

    pub async fn refresh(&self) -> Result<Self, crate::Error> {
        Self::new(self.config.clone()).await
    }

    pub fn generate_headers(
        &self,
        cpd: bool,
        client_info: bool,
        app_info: bool,
    ) -> HashMap<String, String> {
        if !self.is_valid() {
            panic!("Invalid data!")
        }

        let mut headers = self.base_headers.clone();
        let old_client_info = headers.remove("X-Mme-Client-Info");

        if client_info {
            let client_info = match old_client_info {
                Some(v) => {
                    let temp = v.as_str();

                    temp.replace(
                        temp.split('<').nth(3).unwrap().split('>').nth(0).unwrap(),
                        "com.apple.AuthKit/1 (com.apple.akd/1.0)",
                    )
                }
                None => {
                    return headers;
                }
            };
            headers.insert("X-Mme-Client-Info".to_owned(), client_info.to_owned());
        }

        if app_info {
            headers.insert(
                "X-Apple-App-Info".to_owned(),
                "com.apple.gs.xcode.auth".to_owned(),
            );
            headers.insert("X-Xcode-Version".to_owned(), "11.2 (11B41)".to_owned());
        }

        if cpd {
            headers.insert("bootstrap".to_owned(), "true".to_owned());
            headers.insert("icscrec".to_owned(), "true".to_owned());
            headers.insert("loc".to_owned(), "en_GB".to_owned());
            headers.insert("pbe".to_owned(), "false".to_owned());
            headers.insert("prkgen".to_owned(), "true".to_owned());
            headers.insert("svct".to_owned(), "iCloud".to_owned());
        }

        headers
    }

    /// [GatePass] Client data for GrandSlam sign-in requests. With a remote server's identity,
    /// send only the fields current clients send (AltSign PR #61 / SideStep); Apple otherwise
    /// offers only SMS for the verification code, which it then refuses.
    pub fn sign_in_cpd(&self) -> plist::Dictionary {
        if self.user_agent.is_none() {
            return self.to_plist(true, false, false);
        }
        let mut d = plist::Dictionary::new();
        for (k, v) in [
            ("bootstrap", "true"),
            ("icscrec", "true"),
            ("pbe", "false"),
            ("prkgen", "true"),
            ("svct", "iCloud"),
            ("loc", "en_US"),
        ] {
            d.insert(k.to_string(), plist::Value::String(v.to_string()));
        }
        for key in ["X-Apple-I-MD", "X-Apple-I-MD-M", "X-Mme-Device-Id"] {
            if let Some(v) = self.base_headers.get(key) {
                d.insert(key.to_string(), plist::Value::String(v.clone()));
            }
        }
        d
    }

    pub fn to_plist(&self, cpd: bool, client_info: bool, app_info: bool) -> plist::Dictionary {
        let mut plist = plist::Dictionary::new();
        for (key, value) in self.generate_headers(cpd, client_info, app_info).iter() {
            plist.insert(key.to_owned(), plist::Value::String(value.to_owned()));
        }

        plist
    }

    pub fn get_header(&self, header: &str) -> Result<String, Error> {
        let headers = self
            .generate_headers(true, true, true)
            .iter()
            .map(|(k, v)| (k.to_lowercase(), v.clone())) // [GatePass] keep values' case
            .collect::<HashMap<String, String>>();

        match headers.get(&header.to_lowercase()) {
            Some(v) => Ok(v.to_string()),
            None => Err(Error::DeveloperSessionRequestFailed),
        }
    }
}
