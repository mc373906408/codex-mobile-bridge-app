//! Account operations have no mobile redemption or purchase entry point.
use super::types::*;
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

#[flutter_rust_bridge::frb(opaque)]
pub struct CloudDiscoveryClient {
    credentials: Zeroizing<String>,
    origin: String,
    account_id: String,
    cancel: CancellationToken,
}

impl CloudDiscoveryClient {
    pub async fn open(
        credentials: String,
        origin: String,
        account_id: String,
    ) -> anyhow::Result<Self> {
        crate::relay::credential_state(&credentials, &origin, &account_id)?;
        Ok(Self {
            credentials: Zeroizing::new(credentials),
            origin,
            account_id,
            cancel: CancellationToken::new(),
        })
    }

    pub async fn devices(&self) -> anyhow::Result<Vec<CloudDiscoveredDevice>> {
        tokio::select! {
            _ = self.cancel.cancelled() => Err(anyhow::anyhow!("Operation cancelled")),
            result = crate::relay::devices(&self.credentials, &self.origin, &self.account_id) => Ok(result?),
        }
    }

    pub async fn cancel(&self) {
        self.cancel.cancel();
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn cloud_origin(origin: String) -> anyhow::Result<String> {
    crate::cloud_crypto::exact_origin(&origin)?;
    Ok(origin)
}

pub fn cloud_credential_state(
    credentials: String,
    origin: String,
    account_id: String,
) -> anyhow::Result<CloudCredentialState> {
    Ok(crate::relay::credential_state(
        &credentials,
        &origin,
        &account_id,
    )?)
}

pub fn cloud_binding_credentials(binding: String, account: String) -> anyhow::Result<String> {
    Ok(crate::relay::updated_binding_credentials(
        &binding, &account,
    )?)
}

pub fn cloud_signed_out_credentials(
    credentials: String,
    origin: String,
    account_id: String,
) -> anyhow::Result<String> {
    Ok(crate::relay::signed_out_credentials(
        &credentials,
        &origin,
        &account_id,
    )?)
}

pub async fn cloud_logout(
    credentials: String,
    origin: String,
    account_id: String,
) -> anyhow::Result<()> {
    Ok(crate::relay::account_logout(&credentials, &origin, &account_id).await?)
}

pub async fn cloud_capabilities(origin: String) -> anyhow::Result<CloudCapabilities> {
    Ok(crate::relay::capabilities(&origin).await?)
}
pub async fn cloud_login(
    origin: String,
    login: String,
    password: String,
    saved: Option<String>,
) -> anyhow::Result<CloudLogin> {
    Ok(crate::relay::login(origin, login, password, saved).await?)
}
pub async fn cloud_refresh(
    credentials: String,
    origin: String,
    account_id: String,
) -> anyhow::Result<String> {
    Ok(crate::relay::refresh(credentials, origin, account_id).await?)
}
pub async fn cloud_entitlement(
    credentials: String,
    origin: String,
    account_id: String,
) -> anyhow::Result<CloudEntitlement> {
    Ok(crate::relay::entitlement(&credentials, &origin, &account_id).await?)
}
pub fn prepare_relay_discovery(
    device: CloudDiscoveredDevice,
    credentials: String,
    device_name: String,
) -> anyhow::Result<RelayEnrollment> {
    Ok(crate::relay::prepare_discovery(
        device,
        &credentials,
        device_name,
    )?)
}

pub fn cloud_relay_safety_code(
    connection: RelayConnection,
    credentials: String,
) -> anyhow::Result<String> {
    Ok(crate::relay::Relay::new(&connection, &credentials)?.saved_safety_code()?)
}

pub async fn cloud_withdraw_push(
    connection: RelayConnection,
    credentials: String,
) -> anyhow::Result<()> {
    Ok(crate::relay::Relay::new(&connection, &credentials)?
        .endpoint(String::new(), String::new(), String::new(), false, false)
        .await?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    use serde_json::json;
    use std::{
        sync::Arc,
        time::{Duration, SystemTime, UNIX_EPOCH},
    };
    use uuid::Uuid;
    use wiremock::{
        Mock, MockServer, ResponseTemplate,
        matchers::{method, path},
    };

    #[tokio::test]
    async fn cancelling_directory_discovery_aborts_the_native_http_read_without_a_retry() {
        let server = MockServer::start().await;
        let account = Uuid::new_v4().to_string();
        let credentials = json!({"origin":server.uri(),"account_id":account,"login":"user",
            "access_token":"a".repeat(43),"refresh_token":"r".repeat(43),
            "access_deadline":SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs()+3600,
            "installation_id":Uuid::new_v4(),"control_private":STANDARD.encode([7;32]),"device_token":"d".repeat(43)}).to_string();
        let client = Arc::new(
            CloudDiscoveryClient::open(credentials, server.uri(), account)
                .await
                .unwrap(),
        );
        Mock::given(method("GET"))
            .and(path("/v1/capabilities"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_json(json!({}))
                    .set_delay(Duration::from_secs(20)),
            )
            .mount(&server)
            .await;
        let running = client.clone();
        let task = tokio::spawn(async move { running.devices().await });
        for _ in 0..100 {
            if !server.received_requests().await.unwrap().is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        client.cancel().await;
        let result = tokio::time::timeout(Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(result.unwrap_err().to_string(), "Operation cancelled");
        assert!(
            server
                .received_requests()
                .await
                .unwrap()
                .iter()
                .all(|request| request.method == "GET" && request.url.path() == "/v1/capabilities")
        );
    }
}
