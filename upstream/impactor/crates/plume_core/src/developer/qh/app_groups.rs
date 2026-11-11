use plist::{Dictionary, Value};
use serde::Deserialize;

use crate::Error;

use super::{DeveloperSession, QHResponseMeta};
use crate::developer::strip_invalid_chars;
use crate::developer_endpoint;

impl DeveloperSession {
    pub async fn qh_list_app_groups(&self, team_id: &String) -> Result<AppGroupsResponse, Error> {
        let endpoint = developer_endpoint!("/QH65B2/ios/listApplicationGroups.action");

        let mut body = Dictionary::new();
        body.insert("teamId".to_string(), Value::String(team_id.clone()));

        let response = self.qh_send_request(&endpoint, Some(body)).await?;
        let response_data: AppGroupsResponse = plist::from_value(&Value::Dictionary(response))?;

        Ok(response_data)
    }

    pub async fn qh_add_app_group(
        &self,
        team_id: &String,
        name: &String,
        identifier: &String,
    ) -> Result<AppGroupResponse, Error> {
        let endpoint = developer_endpoint!("/QH65B2/ios/addApplicationGroup.action");

        let mut body = Dictionary::new();
        body.insert("teamId".to_string(), Value::String(team_id.clone()));
        body.insert("name".to_string(), Value::String(strip_invalid_chars(name)));
        body.insert("identifier".to_string(), Value::String(identifier.clone()));

        let response = self.qh_send_request(&endpoint, Some(body)).await?;
        let response_data: AppGroupResponse = plist::from_value(&Value::Dictionary(response))?;

        Ok(response_data)
    }

    pub async fn qh_get_app_group(
        &self,
        team_id: &String,
        app_group_identifier: &String,
    ) -> Result<Option<ApplicationGroup>, Error> {
        let response_data = self.qh_list_app_groups(team_id).await?;

        let app_group = response_data
            .application_group_list
            .into_iter()
            .find(|group| group.identifier == *app_group_identifier);

        Ok(app_group)
    }

    /// [GatePass] App group identifiers are global on Apple's side: one made (and possibly
    /// deleted) by another tool can be "not available" forever. In that case reuse or create
    /// a suffixed variant (`<id>.2`, `<id>.3`, …); the provisioning profile then carries the
    /// working name into the app's entitlements.
    pub async fn qh_ensure_app_group(
        &self,
        team_id: &String,
        name: &String,
        identifier: &String,
    ) -> Result<ApplicationGroup, Error> {
        let candidates: Vec<String> = std::iter::once(identifier.clone())
            .chain((2..=6).map(|n| format!("{identifier}.{n}")))
            .collect();

        let mut existing = self.qh_list_app_groups(team_id).await?.application_group_list;
        for candidate in &candidates {
            if let Some(pos) = existing.iter().position(|g| &g.identifier == candidate) {
                return Ok(existing.swap_remove(pos));
            }
        }

        let mut last_err = None;
        for candidate in &candidates {
            match self.qh_add_app_group(team_id, name, candidate).await {
                Ok(response) => return Ok(response.application_group),
                Err(e) if e.to_string().contains("not available") => {
                    log::warn!("app group {candidate} is taken, trying another name");
                    last_err = Some(e);
                }
                Err(e) => return Err(e),
            }
        }
        Err(last_err.expect("candidates is never empty"))
    }

    pub async fn qh_assign_app_group(
        &self,
        team_id: &String,
        app_id_id: &String,
        app_group_ids: &Vec<String>,
    ) -> Result<QHResponseMeta, Error> {
        let endpoint = developer_endpoint!("/QH65B2/ios/assignApplicationGroupToAppId.action");

        let mut body = Dictionary::new();
        body.insert("teamId".to_string(), Value::String(team_id.clone()));
        body.insert("appIdId".to_string(), Value::String(app_id_id.clone()));
        body.insert(
            "applicationGroups".to_string(),
            Value::Array(
                app_group_ids
                    .iter()
                    .map(|s| Value::String(s.clone()))
                    .collect(),
            ),
        );

        let response = self.qh_send_request(&endpoint, Some(body)).await?;
        let response_data: QHResponseMeta = plist::from_value(&Value::Dictionary(response))?;

        Ok(response_data)
    }
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct AppGroupsResponse {
    pub application_group_list: Vec<ApplicationGroup>,
    #[serde(flatten)]
    pub meta: QHResponseMeta,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct AppGroupResponse {
    pub application_group: ApplicationGroup,
    #[serde(flatten)]
    pub meta: QHResponseMeta,
}

#[allow(dead_code)]
#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ApplicationGroup {
    pub application_group: String, // this is the actual identifier
    pub name: String,
    pub status: String,
    prefix: String,
    pub identifier: String, // this is the group.identifier
}
