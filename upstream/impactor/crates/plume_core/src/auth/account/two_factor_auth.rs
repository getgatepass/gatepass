use std::str::FromStr;

use crate::Error;
use base64::{Engine, engine::general_purpose};
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};

use crate::auth::{Account, AuthenticationExtras, LoginState, PhoneNumber, VerifyBody, VerifyCode};

impl Account {
    pub async fn send_2fa_to_devices(&self) -> Result<LoginState, Error> {
        // [GatePass] with server anisette Apple wants JSON content types here (plist gets 200
        // but nothing is delivered). Local sign-in keeps the original plist request.
        let remote = self.get_anisette().await.user_agent.is_some();
        let headers = self.build_2fa_headers(remote).await;

        let res = self
            .client
            .get("https://gsa.apple.com/auth/verify/trusteddevice")
            .headers(headers)
            .send()
            .await?;

        let status_code = res.status();

        if !status_code.is_success() {
            return Err(Error::AuthSrpWithMessage(
                status_code.as_u16() as i64,
                if remote {
                    "Failed to send 2FA to devices (sign-in through a public anisette server)"
                } else {
                    "Failed to send 2FA to devices"
                }
                .to_string(),
            ));
        }

        return Ok(LoginState::Needs2FAVerification);
    }

    pub async fn send_sms_2fa_to_devices(&self, phone_id: u32) -> Result<LoginState, Error> {
        let headers = self.build_2fa_headers(true).await;

        let body = VerifyBody {
            phone_number: PhoneNumber { id: phone_id },
            mode: "sms".to_string(),
            security_code: None,
        };

        let res = self
            .client
            .put("https://gsa.apple.com/auth/verify/phone")
            .headers(headers)
            .json(&body)
            .send()
            .await?;

        let status_code = res.status();

        if !status_code.is_success() {
            return Err(Error::AuthSrpWithMessage(
                status_code.as_u16() as i64,
                "Failed to send SMS 2FA to devices".to_string(),
            ));
        }

        return Ok(LoginState::NeedsSMS2FAVerification(body));
    }

    pub async fn get_auth_extras(&self) -> Result<AuthenticationExtras, Error> {
        let headers = self.build_2fa_headers(true);

        let req = self
            .client
            .get("https://gsa.apple.com/auth")
            .headers(headers.await)
            .header("Accept", "application/json")
            .send()
            .await?;
        let status = req.status().as_u16();
        let mut new_state = req.json::<AuthenticationExtras>().await?;
        if status == 201 {
            new_state.new_state = Some(LoginState::NeedsSMS2FAVerification(VerifyBody {
                phone_number: PhoneNumber {
                    id: new_state.trusted_phone_numbers.first().unwrap().id,
                },
                mode: "sms".to_string(),
                security_code: None,
            }));
        }

        Ok(new_state)
    }

    pub async fn verify_2fa(&self, code: String) -> Result<LoginState, Error> {
        let headers = self.build_2fa_headers(false);
        let res = self
            .client
            .get("https://gsa.apple.com/grandslam/GsService2/validate")
            .headers(headers.await)
            .header(
                HeaderName::from_str("security-code").unwrap(),
                HeaderValue::from_str(&code).unwrap(),
            )
            .send()
            .await?;

        let res: plist::Dictionary = plist::from_bytes(res.text().await?.as_bytes())?;

        super::check_error(&res)?;

        Ok(LoginState::NeedsLogin)
    }

    pub async fn verify_sms_2fa(
        &self,
        code: String,
        mut body: VerifyBody,
    ) -> Result<LoginState, Error> {
        let headers = self.build_2fa_headers(true).await;
        body.security_code = Some(VerifyCode { code });
        let res = self
            .client
            .post("https://gsa.apple.com/auth/verify/phone/securitycode")
            .headers(headers)
            .json(&body)
            .send()
            .await?;

        let status_code = res.status();

        // TODO: 423 http code may occur, in this case we to ask for sending
        // last code sent (unlikely it would even work), or try again later
        if !status_code.is_success() {
            return Err(Error::Bad2faCode);
        }

        Ok(LoginState::NeedsLogin)
    }

    async fn build_2fa_headers(&self, sms: bool) -> HeaderMap {
        let spd = self.spd.as_ref().unwrap();
        let dsid = spd.get("adsid").unwrap().as_string().unwrap();
        let token = spd.get("GsIdmsToken").unwrap().as_string().unwrap();

        let identity_token = general_purpose::STANDARD.encode(format!("{}:{}", dsid, token));

        let mut headers = HeaderMap::new();
        // [GatePass] an anisette one-time password is single-use; reusing the sign-in's makes
        // Apple refuse or silently drop 2FA requests. Fetch a fresh one for every request.
        let current = self.get_anisette().await;
        let remote = current.user_agent.is_some();
        let valid_anisette = if remote { self.fresh_anisette().await } else { current };
        // [GatePass] with server anisette send only what isideload/iloader send.
        let anisette_headers = if remote {
            let all = valid_anisette.generate_headers(false, true, false);
            [
                "X-Mme-Device-Id",
                "X-Apple-I-MD",
                "X-Apple-I-MD-M",
                "X-Apple-I-MD-RINFO",
                "X-Mme-Client-Info",
            ]
            .iter()
            .filter_map(|k| all.get(*k).map(|v| (k.to_string(), v.clone())))
            .collect::<std::collections::HashMap<_, _>>()
        } else {
            valid_anisette.generate_headers(false, true, true)
        };
        for (k, v) in anisette_headers {
            headers.insert(
                HeaderName::from_bytes(k.as_bytes()).unwrap(),
                HeaderValue::from_str(&v).unwrap(),
            );
        }
        if !sms {
            headers.insert("Content-Type", HeaderValue::from_static("text/x-xml-plist"));
            headers.insert("Accept", HeaderValue::from_static("text/x-xml-plist"));
        } else {
            headers.insert("Content-Type", HeaderValue::from_static("application/json"));
            headers.insert("Accept", HeaderValue::from_static("application/json"));
        }
        if remote {
            headers.insert(
                "User-Agent",
                HeaderValue::from_str(&valid_anisette.gsa_user_agent()).unwrap(),
            );
            headers.insert(
                "X-Xcode-Version",
                HeaderValue::from_static(crate::auth::GSA_XCODE_VERSION),
            );
            headers.insert("X-Apple-App-Info", HeaderValue::from_static("com.apple.gs.xcode.auth"));
            headers.insert("Connection", HeaderValue::from_static("close"));
        } else {
            headers.insert("User-Agent", HeaderValue::from_static("Xcode"));
        }
        headers.insert("Accept-Language", HeaderValue::from_static("en-us"));
        headers.append(
            "X-Apple-Identity-Token",
            HeaderValue::from_str(&identity_token).unwrap(),
        );

        if remote {
            // isideload sends no Loc header
        } else if let Ok(locale) = valid_anisette.get_header("x-apple-locale") {
            headers.insert("Loc", HeaderValue::from_str(&locale).unwrap());
        }

        headers
    }
}
