mod p2p;
mod session;
mod tls;

use std::sync::{Arc, OnceLock, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use futures_util::{SinkExt, StreamExt};
use reqwest::{Client, Method, Response};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::net::TcpStream;
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream,
    tungstenite::{Message, client::IntoClientRequest, protocol::WebSocketConfig},
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;
use zeroize::Zeroize;

use crate::api::types::*;
use crate::cloud_crypto::{self, ControlCipher, Frame, MAX_CHUNK};
use crate::error::{BridgeError, Result};
use crate::transport::{MAX_FILE, Transport};

fn invalid() -> BridgeError {
    BridgeError::Protocol("encrypted relay authentication failed".into())
}
fn pairing_error(stage: &'static str) -> BridgeError {
    BridgeError::Protocol(format!("relay pairing validation failed: {stage}"))
}
fn checked<T>(value: anyhow::Result<T>) -> Result<T> {
    value.map_err(|_| invalid())
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn id(value: &str) -> Result<Uuid> {
    Uuid::parse_str(value).map_err(|_| invalid())
}
fn b64(value: &[u8]) -> String {
    STANDARD.encode(value)
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct AccountSecrets {
    origin: String,
    account_id: String,
    login: String,
    access_token: String,
    refresh_token: String,
    #[serde(default)]
    refresh_request_id: String,
    access_deadline: i64,
    installation_id: String,
    control_private: String,
    #[serde(default)]
    device_token: String,
    #[serde(default, skip_serializing, rename = "replacement_installation")]
    _retired_registration: serde::de::IgnoredAny,
}
impl Drop for AccountSecrets {
    fn drop(&mut self) {
        self.access_token.zeroize();
        self.refresh_token.zeroize();
        self.control_private.zeroize();
        self.device_token.zeroize();
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BindingSecrets {
    connection: RelayConnection,
    installation_id: String,
    device_token: String,
    control_private: String,
    control_public: String,
    preview_private: String,
    preview_public: String,
    desktop_preview_public: String,
    device_name: String,
    pairing_code: String,
}
impl Drop for BindingSecrets {
    fn drop(&mut self) {
        self.device_token.zeroize();
        self.control_private.zeroize();
        self.preview_private.zeroize();
    }
}

fn websocket_url(origin: &str) -> Result<String> {
    let url = checked(cloud_crypto::exact_origin(origin))?;
    let scheme = if url.scheme() == "https" { "wss" } else { "ws" };
    Ok(format!(
        "{scheme}://{}/v1/ws/mobile",
        origin.split_once("://").unwrap().1
    ))
}

fn api_client() -> Result<Client> {
    crate::crypto_provider();
    static CLIENT: OnceLock<Client> = OnceLock::new();
    if let Some(client) = CLIENT.get() {
        return Ok(client.clone());
    }
    let client = Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .retry(reqwest::retry::never())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(20))
        .user_agent("BridgeMobile/1")
        .build()?;
    let _ = CLIENT.set(client.clone());
    Ok(client)
}

async fn api(
    origin: &str,
    path: &str,
    method: Method,
    body: Option<Value>,
    token: &str,
) -> Result<Value> {
    checked(cloud_crypto::exact_origin(origin))?;
    if !path.starts_with("/v1/") || path.contains(['?', '#', '\\']) || path.contains("..") {
        return Err(invalid());
    }
    let mut request = api_client()?.request(method, format!("{origin}{path}"));
    if let Some(body) = body {
        request = request.json(&body);
    }
    if !token.is_empty() {
        request = request.bearer_auth(token);
    }
    let response = request.send().await?;
    if response.status().is_redirection() {
        return Err(BridgeError::Redirect);
    }
    let status = response.status();
    let bytes = Transport::bounded_bytes(response, 65536).await?;
    let value: Value = serde_json::from_slice(&bytes)?;
    if !status.is_success() {
        return Err(BridgeError::Http {
            status: status.as_u16(),
            code: value["code"].as_str().unwrap_or("unavailable").into(),
            message: "Cloud account or service access is unavailable".into(),
        });
    }
    Ok(value)
}

pub(crate) async fn capabilities(origin: &str) -> Result<CloudCapabilities> {
    let v = api(origin, "/v1/capabilities", Method::GET, None, "").await?;
    if !v["relay_protocols"]
        .as_array()
        .is_some_and(|a| a.contains(&json!(2)))
    {
        return Err(BridgeError::Relay("protocol_upgrade_required".into()));
    }
    if v["control_noise"] != "Noise_KK_25519_ChaChaPoly_BLAKE2s"
        || v["preview_noise"] != "Noise_K_25519_ChaChaPoly_BLAKE2s"
    {
        return Err(invalid());
    }
    Ok(CloudCapabilities {
        mode: v["mode"].as_str().unwrap_or_default().into(),
        login: v["login"].as_str().unwrap_or_default().into(),
        registration: v["registration"] == true,
        entitlement_required: v["entitlement_required"] == true,
        umeng: v["push"]["umeng"] == true,
        apns: v["push"]["apns"] == true,
        umeng_app_id: v["push"]["umeng_app_id"]
            .as_str()
            .unwrap_or_default()
            .into(),
        apns_app_id: v["push"]["apns_app_id"].as_str().unwrap_or_default().into(),
        automatic_discovery: v["device_discovery"] == "account_directory_v2"
            && v["pairing_method"] == "desktop_qr_v1",
    })
}

pub(crate) async fn login(
    origin: String,
    login: String,
    mut password: String,
    saved: Option<String>,
) -> Result<CloudLogin> {
    capabilities(&origin).await?;
    let response = api(
        &origin,
        "/v1/auth/login",
        Method::POST,
        Some(json!({"login":login,"password":password})),
        "",
    )
    .await;
    password.zeroize();
    let v = response?;
    let account = v["account"]["id"].as_str().ok_or_else(invalid)?.to_owned();
    id(&account)?;
    let prior = saved
        .as_deref()
        .map(serde_json::from_str::<AccountSecrets>)
        .transpose()?;
    let mut secret = match prior {
        Some(prior) if prior.origin == origin && prior.account_id == account => prior,
        _ => {
            let key = checked(cloud_crypto::new_keypair())?;
            AccountSecrets {
                origin: origin.clone(),
                account_id: account.clone(),
                login: String::new(),
                access_token: String::new(),
                refresh_token: String::new(),
                refresh_request_id: String::new(),
                access_deadline: 0,
                installation_id: Uuid::new_v4().to_string(),
                control_private: b64(&key.private),
                device_token: String::new(),
                _retired_registration: serde::de::IgnoredAny,
            }
        }
    };
    secret.login = v["account"]["login"].as_str().ok_or_else(invalid)?.into();
    secret.access_token = v["access_token"].as_str().ok_or_else(invalid)?.into();
    secret.refresh_token = v["refresh_token"].as_str().ok_or_else(invalid)?.into();
    secret.refresh_request_id.clear();
    secret.access_deadline = now() + v["expires_in"].as_i64().ok_or_else(invalid)?;
    enroll_installation(&mut secret).await?;
    Ok(CloudLogin {
        account_id: secret.account_id.clone(),
        login: secret.login.clone(),
        credentials: serde_json::to_string(&secret)?,
    })
}

async fn enroll_installation(account: &mut AccountSecrets) -> Result<()> {
    let private = checked(cloud_crypto::key(&account.control_private))?;
    let public = checked(cloud_crypto::public_key(&private))?;
    let device = api(
        &account.origin,
        "/v1/installations/enroll",
        Method::POST,
        Some(json!({"id":account.installation_id,"control_public_key":b64(&public),"name":
            if cfg!(target_os = "android") { "Android phone" } else if cfg!(target_os = "ios") { "iPhone" } else { "Phone" }})),
        &account.access_token,
    )
    .await?;
    if device["id"] != account.installation_id
        || device["account_id"] != account.account_id
        || device["control_public_key"] != b64(&public)
    {
        return Err(invalid());
    }
    account.device_token = device["device_token"]
        .as_str()
        .filter(|s| s.len() == 43)
        .ok_or_else(invalid)?
        .into();
    Ok(())
}

fn device_account(raw: &str, origin: &str, account_id: &str) -> Result<AccountSecrets> {
    checked(cloud_crypto::exact_origin(origin))?;
    let account: AccountSecrets = serde_json::from_str(raw)?;
    if account.origin != origin
        || account.account_id != account_id
        || account.device_token.len() != 43
        || account.access_token.is_empty()
    {
        return Err(invalid());
    }
    Ok(account)
}

pub(crate) fn credential_state(
    raw: &str,
    origin: &str,
    account: &str,
) -> Result<CloudCredentialState> {
    checked(cloud_crypto::exact_origin(origin))?;
    let mut secret: AccountSecrets = serde_json::from_str(raw)?;
    if secret.origin != origin || secret.account_id != account {
        return Err(invalid());
    }
    id(account)?;
    let consumed_credentials = if secret.access_deadline <= now() + 30 {
        if secret.refresh_token.is_empty() {
            return Err(BridgeError::Unauthenticated);
        }
        if secret.refresh_request_id.is_empty() {
            secret.refresh_request_id = Uuid::new_v4().to_string();
        }
        Some(serde_json::to_string(&secret)?)
    } else {
        None
    };
    Ok(CloudCredentialState {
        origin: origin.into(),
        account_id: account.into(),
        login: secret.login.clone(),
        consumed_credentials,
    })
}

pub(crate) fn updated_binding_credentials(binding: &str, account: &str) -> Result<Option<String>> {
    let mut binding = serde_json::from_str::<BindingSecrets>(binding)?;
    let account: AccountSecrets = serde_json::from_str(account)?;
    if binding.connection.origin != account.origin
        || binding.connection.account_id != account.account_id
        || account.device_token.len() != 43
    {
        return Err(invalid());
    }
    if binding.installation_id != account.installation_id {
        return Ok(None);
    }
    if binding.control_private != account.control_private {
        return Err(invalid());
    }
    binding.device_token = account.device_token.clone();
    Ok(Some(serde_json::to_string(&binding)?))
}

pub(crate) fn signed_out_credentials(raw: &str, origin: &str, account: &str) -> Result<String> {
    checked(cloud_crypto::exact_origin(origin))?;
    let mut secret: AccountSecrets = serde_json::from_str(raw)?;
    if secret.origin != origin || secret.account_id != account {
        return Err(invalid());
    }
    secret.access_token.zeroize();
    secret.access_token.clear();
    secret.refresh_token.zeroize();
    secret.refresh_token.clear();
    secret.refresh_request_id.clear();
    secret.device_token.zeroize();
    secret.device_token.clear();
    secret.access_deadline = 0;
    // Retain the installation/key identity so an explicit later login can
    // restore existing pins, without retaining any usable cloud session.
    Ok(serde_json::to_string(&secret)?)
}

pub(crate) async fn account_logout(raw: &str, origin: &str, account: &str) -> Result<()> {
    let secret: AccountSecrets = serde_json::from_str(raw)?;
    if secret.origin != origin || secret.account_id != account {
        return Err(invalid());
    }
    api(
        origin,
        "/v1/auth/logout",
        Method::POST,
        Some(json!({})),
        &secret.access_token,
    )
    .await?;
    Ok(())
}

pub(crate) async fn refresh(raw: String, origin: String, account_id: String) -> Result<String> {
    let mut secret: AccountSecrets = serde_json::from_str(&raw)?;
    if secret.origin != origin || secret.account_id != account_id || secret.refresh_token.is_empty()
    {
        return Err(invalid());
    }
    if secret.refresh_request_id.is_empty() {
        return Err(invalid());
    }
    let started = now();
    let v = api(
        &origin,
        "/v1/auth/refresh",
        Method::POST,
        Some(json!({"refresh_token":secret.refresh_token,"request_id":secret.refresh_request_id})),
        "",
    )
    .await?;
    if v["account"]["id"] != secret.account_id {
        return Err(invalid());
    }
    secret.access_token = v["access_token"].as_str().ok_or_else(invalid)?.into();
    secret.refresh_token = v["refresh_token"].as_str().ok_or_else(invalid)?.into();
    secret.refresh_request_id.clear();
    secret.access_deadline = started + v["expires_in"].as_i64().ok_or_else(invalid)?;
    Ok(serde_json::to_string(&secret)?)
}

pub(crate) async fn entitlement(
    raw: &str,
    origin: &str,
    account: &str,
) -> Result<CloudEntitlement> {
    let secret: AccountSecrets = serde_json::from_str(raw)?;
    if secret.origin != origin || secret.account_id != account {
        return Err(invalid());
    }
    let v = api(
        origin,
        "/v1/account/entitlement",
        Method::GET,
        None,
        &secret.access_token,
    )
    .await?;
    Ok(CloudEntitlement {
        active: v["active"] == true,
        required: v["required"] == true,
        expires_at: v["expires_at"].as_str().map(str::to_owned),
    })
}

fn new_binding(
    gateway: CloudGateway,
    binding_id: String,
    raw: &str,
    device_name: String,
) -> Result<RelayEnrollment> {
    let account: AccountSecrets = serde_json::from_str(raw)?;
    if account.origin != gateway.origin
        || account.device_token.len() != 43
        || device_name.is_empty()
        || device_name.len() > 100
        || device_name.chars().any(char::is_control)
    {
        return Err(invalid());
    }
    checked(cloud_crypto::exact_origin(&account.origin))?;
    id(&gateway.id)?;
    checked(cloud_crypto::key(&gateway.control_public_key))?;
    let private = checked(cloud_crypto::key(&account.control_private))?;
    let control_public = checked(cloud_crypto::public_key(&private))?;
    let preview = checked(cloud_crypto::new_keypair())?;
    let name = gateway.name.clone();
    let connection = RelayConnection {
        origin: account.origin.clone(),
        account_id: account.account_id.clone(),
        gateway_id: gateway.id,
        binding_id: binding_id.clone(),
        desktop_public_key: gateway.control_public_key,
    };
    let secret = BindingSecrets {
        connection: connection.clone(),
        installation_id: account.installation_id.clone(),
        device_token: account.device_token.clone(),
        control_private: account.control_private.clone(),
        control_public: b64(&control_public),
        preview_private: b64(&preview.private),
        preview_public: b64(&preview.public),
        desktop_preview_public: String::new(),
        device_name,
        pairing_code: String::new(),
    };
    Ok(RelayEnrollment {
        computer: Computer {
            id: binding_id,
            name,
            base_url: account.origin.clone(),
            connection_type: ConnectionType::Relay,
            relay: Some(connection),
        },
        account_credentials: serde_json::to_string(&account)?,
        binding_credentials: serde_json::to_string(&secret)?,
        mobile_control_public_key: secret.control_public.clone(),
        mobile_preview_public_key: secret.preview_public.clone(),
    })
}

pub(crate) async fn devices(
    raw: &str,
    origin: &str,
    account_id: &str,
) -> Result<Vec<CloudDiscoveredDevice>> {
    let account = device_account(raw, origin, account_id)?;
    if !capabilities(origin).await?.automatic_discovery {
        return Err(BridgeError::Protocol(
            "Automatic device discovery requires matching server, desktop and phone versions"
                .into(),
        ));
    }
    let response = api(
        origin,
        "/v1/mobile/bindings",
        Method::GET,
        None,
        &account.device_token,
    )
    .await?;
    let values = response["bindings"]
        .as_array()
        .filter(|v| v.len() <= 200)
        .ok_or_else(invalid)?;
    let scoped_access = response["access"]["version"] == 1
        && response["access"]["origin"] == origin
        && response["access"]["account_id"] == account_id
        && response["access"]["device_id"] == account.installation_id;
    if !scoped_access {
        return Err(invalid());
    }
    let mut bindings = std::collections::HashMap::new();
    for value in values {
        let device = parse_binding(&account, value)?;
        let key = device.gateway.id.clone();
        match bindings.entry(key) {
            std::collections::hash_map::Entry::Vacant(entry) => {
                entry.insert(device);
            }
            std::collections::hash_map::Entry::Occupied(mut entry) => {
                if entry.get().status == device.status
                    || (entry.get().status != CloudDeviceStatus::Pending
                        && device.status != CloudDeviceStatus::Pending)
                    || entry.get().gateway.control_public_key != device.gateway.control_public_key
                {
                    return Err(invalid());
                }
                if device.status == CloudDeviceStatus::Pending {
                    entry.insert(device);
                }
            }
        }
    }
    let gateways = response["gateways"]
        .as_array()
        .filter(|items| items.len() <= 100)
        .ok_or_else(invalid)?;
    let mut seen = std::collections::HashSet::new();
    let mut result = Vec::with_capacity(gateways.len());
    for value in gateways {
        let gateway = parse_gateway(
            origin,
            &value["id"],
            &value["name"],
            &value["control_public_key"],
            value["online"] == true,
        )?;
        if !seen.insert(gateway.id.clone()) {
            return Err(invalid());
        }
        if let Some(mut device) = bindings.remove(&gateway.id) {
            if device.gateway.control_public_key != gateway.control_public_key {
                return Err(invalid());
            }
            device.gateway = gateway;
            result.push(device);
        } else {
            result.push(CloudDiscoveredDevice {
                gateway,
                binding_id: String::new(),
                status: CloudDeviceStatus::Unpaired,
                access_revision: 0,
                access_allowed: false,
            });
        }
    }
    Ok(result)
}

fn parse_gateway(
    origin: &str,
    id_value: &Value,
    name: &Value,
    key: &Value,
    online: bool,
) -> Result<CloudGateway> {
    let gateway = id_value.as_str().ok_or_else(invalid)?;
    id(gateway)?;
    let key = key.as_str().ok_or_else(invalid)?;
    checked(cloud_crypto::key(key))?;
    let name = name
        .as_str()
        .filter(|value| {
            !value.is_empty() && value.len() <= 100 && !value.chars().any(char::is_control)
        })
        .ok_or_else(invalid)?;
    Ok(CloudGateway {
        origin: origin.into(),
        id: gateway.into(),
        name: name.into(),
        control_public_key: key.into(),
        online,
    })
}

fn parse_binding(account: &AccountSecrets, value: &Value) -> Result<CloudDiscoveredDevice> {
    let binding = value["id"].as_str().ok_or_else(invalid)?;
    id(binding)?;
    let public = b64(&checked(cloud_crypto::public_key(&checked(
        cloud_crypto::key(&account.control_private),
    )?))?);
    if value["installation_id"] != account.installation_id || value["mobile_public_key"] != public {
        return Err(invalid());
    }
    let status = match value["status"].as_str() {
        Some("pending") => CloudDeviceStatus::Pending,
        Some("active") => CloudDeviceStatus::Active,
        Some("disabled") => CloudDeviceStatus::Disabled,
        Some("revoked") => CloudDeviceStatus::Revoked,
        _ => return Err(invalid()),
    };
    Ok(CloudDiscoveredDevice {
        gateway: parse_gateway(
            &account.origin,
            &value["gateway_id"],
            &value["gateway_name"],
            &value["gateway_public_key"],
            value["gateway_online"] == true,
        )?,
        binding_id: binding.into(),
        status: if value["device_revoked"] == true {
            CloudDeviceStatus::Revoked
        } else {
            status
        },
        access_revision: value["access_revision"]
            .as_i64()
            .filter(|value| *value >= 0)
            .ok_or_else(invalid)?,
        access_allowed: value["access_allowed"] == true,
    })
}

pub(crate) async fn request_pairing(
    raw: &str,
    gateway: CloudGateway,
    account_id: &str,
    replace: Option<String>,
) -> Result<CloudDiscoveredDevice> {
    let account = device_account(raw, &gateway.origin, account_id)?;
    id(&gateway.id)?;
    checked(cloud_crypto::key(&gateway.control_public_key))?;
    if let Some(previous) = &replace {
        id(previous)?;
    }
    let response = api(
        &gateway.origin,
        "/v1/mobile/pair",
        Method::POST,
        Some(json!({
            "gateway_id": gateway.id, "gateway_public_key": gateway.control_public_key,
            "replace_binding_id": replace.as_deref().unwrap_or_default(),
        })),
        &account.device_token,
    )
    .await?;
    let device = parse_binding(&account, &response)?;
    if device.status != CloudDeviceStatus::Pending
        || device.gateway.id != gateway.id
        || device.gateway.control_public_key != gateway.control_public_key
        || response["replaces_binding_id"].as_str() != replace.as_deref()
    {
        return Err(invalid());
    }
    Ok(device)
}

pub(crate) fn prepare_discovery(
    device: CloudDiscoveredDevice,
    raw: &str,
    device_name: String,
) -> Result<RelayEnrollment> {
    id(&device.binding_id)?;
    if device.status != CloudDeviceStatus::Pending {
        return Err(BridgeError::Invalid(
            "Saved cloud pairing keys are unavailable".into(),
        ));
    }
    new_binding(device.gateway, device.binding_id, raw, device_name)
}

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;
struct Channel {
    socket: Socket,
    cipher: ControlCipher,
    binding: Uuid,
    channel: Uuid,
    direct: bool,
    p2p_available: bool,
    runtime: Option<bridge_p2p::Runtime>,
    links: Option<Arc<p2p::Links>>,
    authority: Option<Arc<RwLock<BindingSecrets>>>,
}
impl Channel {
    async fn send_data(&mut self, data: &[u8]) -> Result<()> {
        let payload = checked(self.cipher.encrypt(data))?;
        if let Some(links) = &self.links {
            let counter = if self.direct {
                &links.p2p_tx
            } else {
                &links.relay_tx
            };
            counter.fetch_add(
                (payload.len() + 34) as u64,
                std::sync::atomic::Ordering::Relaxed,
            );
        }
        send_frame(
            &mut self.socket,
            &Frame {
                kind: 2,
                binding: self.binding,
                channel: self.channel,
                payload,
            },
        )
        .await
    }
    async fn send(&mut self, value: Value) -> Result<()> {
        let mut raw = vec![0];
        raw.extend(serde_json::to_vec(&value)?);
        self.send_data(&raw).await
    }
    async fn receive(&mut self, timeout: u64) -> Result<Vec<u8>> {
        let frame = read_frame(&mut self.socket, timeout).await?;
        if frame.kind != 2 || frame.binding != self.binding || frame.channel != self.channel {
            return Err(invalid());
        }
        checked(self.cipher.decrypt(&frame.payload))
    }
    async fn control(&mut self, timeout: u64) -> Result<Value> {
        let data = self.receive(timeout).await?;
        if data.first() != Some(&0) {
            return Err(invalid());
        }
        Ok(serde_json::from_slice(&data[1..])?)
    }
}

async fn send_frame(socket: &mut Socket, frame: &Frame) -> Result<()> {
    let raw = checked(frame.encode())?;
    tokio::time::timeout(
        Duration::from_secs(5),
        socket.send(Message::Binary(raw.into())),
    )
    .await
    .map_err(|_| BridgeError::Network)?
    .map_err(|_| BridgeError::Network)
}
async fn read_frame(socket: &mut Socket, timeout: u64) -> Result<Frame> {
    tokio::time::timeout(Duration::from_secs(timeout), async {
        loop {
            match socket.next().await {
                Some(Ok(Message::Binary(raw))) => return checked(Frame::decode(&raw)),
                Some(Ok(Message::Ping(data))) => socket
                    .send(Message::Pong(data))
                    .await
                    .map_err(|_| BridgeError::Network)?,
                Some(Ok(Message::Pong(_))) => {}
                _ => return Err(BridgeError::Network),
            }
        }
    })
    .await
    .map_err(|_| BridgeError::Network)?
}

pub(crate) struct Relay {
    secret: Arc<RwLock<BindingSecrets>>,
    discovery_cancel: RwLock<CancellationToken>,
    session: tokio::sync::Mutex<SessionCache>,
    status: tokio::sync::watch::Sender<String>,
    connect_cancel: RwLock<CancellationToken>,
    observer_cancel: RwLock<CancellationToken>,
    generation: std::sync::atomic::AtomicU64,
    links: Arc<p2p::Links>,
}
#[derive(Default)]
struct SessionCache {
    active: Option<Arc<session::Session>>,
    failures: u32,
    next: Option<tokio::time::Instant>,
}

#[derive(Debug, PartialEq, Eq)]
enum PairingRecovery {
    AuthorizeExistingBinding,
    RequestDesktopApproval,
    WaitForDesktopApproval,
    NoAction,
}

fn pairing_recovery(
    status: &str,
    gateway_online: bool,
    local_proof_ready: bool,
) -> PairingRecovery {
    if !gateway_online {
        return PairingRecovery::NoAction;
    }
    match status {
        "active" => PairingRecovery::AuthorizeExistingBinding,
        "pending" if !local_proof_ready => PairingRecovery::RequestDesktopApproval,
        "pending" => PairingRecovery::WaitForDesktopApproval,
        _ => PairingRecovery::NoAction,
    }
}
impl Relay {
    pub(crate) fn new(connection: &RelayConnection, saved: &str) -> Result<Self> {
        checked(cloud_crypto::exact_origin(&connection.origin))?;
        for value in [
            &connection.account_id,
            &connection.gateway_id,
            &connection.binding_id,
        ] {
            id(value)?;
        }
        let mut secret = serde_json::from_str::<BindingSecrets>(saved)?;
        if &secret.connection != connection || secret.device_token.len() != 43 {
            return Err(invalid());
        }
        let private = checked(cloud_crypto::key(&secret.control_private))?;
        if b64(&checked(cloud_crypto::public_key(&private))?) != secret.control_public {
            return Err(invalid());
        }
        let preview = checked(cloud_crypto::key(&secret.preview_private))?;
        if b64(&checked(cloud_crypto::public_key(&preview))?) != secret.preview_public {
            return Err(invalid());
        }
        if secret.device_name.is_empty() {
            secret.device_name = "Phone".into();
        }
        Ok(Self {
            secret: Arc::new(RwLock::new(secret)),
            discovery_cancel: RwLock::new(CancellationToken::new()),
            session: tokio::sync::Mutex::new(SessionCache::default()),
            status: tokio::sync::watch::channel("disconnected".into()).0,
            connect_cancel: RwLock::new(CancellationToken::new()),
            observer_cancel: RwLock::new(CancellationToken::new()),
            generation: std::sync::atomic::AtomicU64::new(0),
            links: Arc::new(p2p::Links::default()),
        })
    }
    pub(crate) fn export(&self) -> Result<String> {
        Ok(serde_json::to_string(&*self.secret.read().unwrap())?)
    }
    pub(crate) fn saved_safety_code(&self) -> Result<String> {
        let s = self.secret.read().unwrap();
        if s.pairing_code.is_empty() {
            return Ok(String::new());
        }
        let private = zeroize::Zeroizing::new(checked(cloud_crypto::key(&s.control_private))?);
        let desktop = checked(cloud_crypto::key(&s.connection.desktop_public_key))?;
        let code = checked(cloud_crypto::pairing_safety_code(
            &s.connection.origin,
            id(&s.connection.gateway_id)?,
            id(&s.connection.binding_id)?,
            private.as_ref(),
            &desktop,
            &desktop,
            &checked(cloud_crypto::key(&s.control_public))?,
            &checked(cloud_crypto::key(&s.desktop_preview_public))?,
            &checked(cloud_crypto::key(&s.preview_public))?,
        ))?;
        if code != s.pairing_code {
            return Err(invalid());
        }
        Ok(code)
    }
    pub(crate) fn preview_credentials(&self) -> Result<String> {
        let s = self.secret.read().unwrap();
        checked(cloud_crypto::key(&s.desktop_preview_public))?;
        Ok(serde_json::to_string(
            &bridge_preview::PreviewCredentials {
                origin: s.connection.origin.clone(),
                binding_id: s.connection.binding_id.clone(),
                gateway_id: s.connection.gateway_id.clone(),
                private_key: s.preview_private.clone(),
                desktop_public_key: s.desktop_preview_public.clone(),
            },
        )?)
    }
    fn check_binding(&self, record: &Value) -> Result<String> {
        let s = self.secret.read().unwrap();
        if record["id"] != s.connection.binding_id
            || record["gateway_id"] != s.connection.gateway_id
            || record["installation_id"] != s.installation_id
            || record["gateway_public_key"] != s.connection.desktop_public_key
            || record["mobile_public_key"] != s.control_public
        {
            return Err(invalid());
        }
        record["status"]
            .as_str()
            .filter(|v| matches!(*v, "pending" | "active" | "disabled" | "revoked"))
            .map(str::to_owned)
            .ok_or_else(invalid)
    }
    pub(crate) async fn pairing_state(&self) -> Result<RelayPairingState> {
        let cancel = self.discovery_cancel.read().unwrap().clone();
        tokio::select! {
            _ = cancel.cancelled() => Err(BridgeError::Network),
            result = self.read_pairing_state() => result,
        }
    }
    pub(crate) fn cancel_discovery(&self) {
        let mut cancel = self.discovery_cancel.write().unwrap();
        cancel.cancel();
        *cancel = CancellationToken::new();
    }
    async fn read_pairing_state(&self) -> Result<RelayPairingState> {
        let s = self.secret.read().unwrap().clone();
        let value = api(
            &s.connection.origin,
            &format!("/v1/bindings/{}", s.connection.binding_id),
            Method::GET,
            None,
            &s.device_token,
        )
        .await?;
        let mut status = self.check_binding(&value)?;
        if value["device_revoked"] == true {
            status = "revoked".into();
        }
        let proof_ready = !s.pairing_code.is_empty() && !s.desktop_preview_public.is_empty();
        match pairing_recovery(&status, value["gateway_online"] == true, proof_ready) {
            PairingRecovery::AuthorizeExistingBinding => {
                self.session().await?;
            }
            PairingRecovery::RequestDesktopApproval => {
                let _ = self.connect(Authorization::Pair(None)).await?;
            }
            PairingRecovery::WaitForDesktopApproval | PairingRecovery::NoAction => {}
        }
        Ok(RelayPairingState {
            status,
            safety_code: self.secret.read().unwrap().pairing_code.clone(),
        })
    }
    pub(crate) async fn confirm_pairing_scan(&self, payload: &str) -> Result<RelayPairingState> {
        let token = scan_token(&self.secret.read().unwrap(), payload)?;
        let cancel = self.discovery_cancel.read().unwrap().clone();
        tokio::select! {
            _ = cancel.cancelled() => return Err(BridgeError::Cancelled),
            result = self.connect(Authorization::Pair(Some(token))) => { result?; }
        }
        Ok(RelayPairingState {
            status: "pending".into(),
            safety_code: self.secret.read().unwrap().pairing_code.clone(),
        })
    }

    async fn connect(&self, authorization: Authorization<'_>) -> Result<Option<Channel>> {
        let s = self.secret.read().unwrap().clone();
        let url = websocket_url(&s.connection.origin)?;
        let mut request = url.into_client_request().map_err(|_| invalid())?;
        let headers = request.headers_mut();
        headers.insert(
            "Authorization",
            format!("Bearer {}", s.device_token)
                .parse()
                .map_err(|_| invalid())?,
        );
        headers.insert(
            "X-Bridge-Binding",
            s.connection.binding_id.parse().map_err(|_| invalid())?,
        );
        headers.insert("Sec-WebSocket-Protocol", "bridge-relay-v2".parse().unwrap());
        headers.insert("X-Bridge-Control", "access-v1".parse().unwrap());
        let config = socket_config();
        let (socket, response) = tls::connect(request, config).await?;
        if response
            .headers()
            .get("Sec-WebSocket-Protocol")
            .and_then(|v| v.to_str().ok())
            != Some("bridge-relay-v2")
        {
            return Err(invalid());
        }
        authenticate_channel(&s, socket, authorization, Some(&self.secret)).await
    }
}

fn socket_config() -> WebSocketConfig {
    WebSocketConfig::default()
        .read_buffer_size(32768)
        .write_buffer_size(0)
        .max_write_buffer_size(2 * (MAX_CHUNK + 50))
        .max_message_size(Some(MAX_CHUNK + 50))
        .max_frame_size(Some(MAX_CHUNK + 50))
}

#[derive(Clone, Copy)]
enum Authorization<'a> {
    Existing,
    Pair(Option<&'a str>),
}

fn scan_token<'a>(secret: &BindingSecrets, payload: &'a str) -> Result<&'a str> {
    let mismatch =
        || BridgeError::Invalid("This QR code does not match the current cloud pairing".into());
    let mut fields = payload.split(':');
    if payload.len() > 150
        || fields.next() != Some("bridge-pair")
        || fields.next() != Some("v1")
        || fields.next() != Some(secret.connection.binding_id.as_str())
        || secret.pairing_code.is_empty()
        || fields.next() != Some(secret.pairing_code.replace(' ', "").as_str())
    {
        return Err(mismatch());
    }
    let token = fields
        .next()
        .filter(|token| {
            token.len() == 32
                && token
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        })
        .ok_or_else(mismatch)?;
    if fields.next().is_some() {
        return Err(mismatch());
    }
    Ok(token)
}

async fn authenticate_channel(
    s: &BindingSecrets,
    mut socket: Socket,
    authorization: Authorization<'_>,
    save: Option<&RwLock<BindingSecrets>>,
) -> Result<Option<Channel>> {
    let open = read_frame(&mut socket, 15).await?;
    let desktop = checked(cloud_crypto::key(&s.connection.desktop_public_key))?;
    if open.kind != 1 || open.binding != id(&s.connection.binding_id)? || open.payload != desktop {
        return Err(pairing_error("desktop identity frame"));
    }
    let mobile = checked(cloud_crypto::key(&s.control_public))?;
    let private = zeroize::Zeroizing::new(checked(cloud_crypto::key(&s.control_private))?);
    let p = checked(cloud_crypto::control_prologue(
        &s.connection.origin,
        id(&s.connection.gateway_id)?,
        open.binding,
        open.channel,
        &desktop,
        &mobile,
    ))?;
    let mut handshake = checked(cloud_crypto::handshake(
        private.as_ref(),
        &desktop,
        &p,
        true,
    ))?;
    let first = checked(cloud_crypto::handshake_write(&mut handshake))?;
    send_frame(
        &mut socket,
        &Frame {
            kind: 2,
            binding: open.binding,
            channel: open.channel,
            payload: first,
        },
    )
    .await?;
    let second = read_frame(&mut socket, 15).await?;
    if second.kind != 2 || second.binding != open.binding || second.channel != open.channel {
        return Err(pairing_error("handshake frame"));
    }
    checked(cloud_crypto::handshake_read(
        &mut handshake,
        &second.payload,
    ))
    .map_err(|_| pairing_error("Noise identity"))?;
    let mut channel = Channel {
        socket,
        cipher: checked(ControlCipher::new(handshake))?,
        binding: open.binding,
        channel: open.channel,
        direct: false,
        p2p_available: false,
        runtime: None,
        links: None,
        authority: None,
    };
    if channel
        .control(15)
        .await
        .map_err(|_| pairing_error("desktop ready response"))?
        != json!({"kind":"ready"})
    {
        return Err(pairing_error("desktop ready response"));
    }
    channel.send(json!({"kind":"key_confirm"})).await?;
    if channel
        .control(15)
        .await
        .map_err(|_| pairing_error("key confirmation response"))?
        != json!({"kind":"key_confirmed"})
    {
        return Err(pairing_error("key confirmation response"));
    }
    let pairing = matches!(authorization, Authorization::Pair(_));
    let mut request = if pairing {
        json!({"kind":"pair","device_name":s.device_name,"preview_public_key":s.preview_public})
    } else {
        json!({"kind":"authorize","preview_public_key":s.preview_public})
    };
    if let Authorization::Pair(Some(token)) = authorization {
        request["scan_token"] = token.into();
    }
    channel.send(request).await?;
    let response_frame = match read_frame(&mut channel.socket, 15).await {
        Ok(frame) => frame,
        Err(BridgeError::Network) => {
            return Err(pairing_error(
                "desktop gateway disconnected during secure pairing",
            ));
        }
        Err(BridgeError::Protocol(_)) => {
            return Err(pairing_error("desktop gateway sent an invalid relay frame"));
        }
        Err(error) => return Err(error),
    };
    if response_frame.binding != channel.binding || response_frame.channel != channel.channel {
        return Err(pairing_error("desktop gateway response route changed"));
    }
    if response_frame.kind == 3 {
        if !pairing && s.pairing_code.is_empty() {
            return Err(BridgeError::Invalid(
                "The desktop could not verify the saved cloud pairing keys".into(),
            ));
        }
        return Err(pairing_error(
            "desktop gateway closed the channel before pairing completed",
        ));
    }
    if response_frame.kind != 2 {
        return Err(pairing_error(
            "desktop gateway returned a non-control authorization frame",
        ));
    }
    let authorized_data = channel
        .cipher
        .decrypt(&response_frame.payload)
        .map_err(|_| pairing_error("desktop gateway secure response authentication failed"))?;
    if authorized_data.first() != Some(&0) {
        return Err(pairing_error(
            "desktop gateway returned a non-control authorization frame",
        ));
    }
    let authorized: Value = serde_json::from_slice(&authorized_data[1..])
        .map_err(|_| pairing_error("desktop gateway authorization response was invalid"))?;
    channel.p2p_available = authorized["p2p"] == true;
    let preview = authorized["desktop_preview_public_key"]
        .as_str()
        .ok_or_else(|| pairing_error("desktop preview key"))?;
    let desktop_preview = checked(cloud_crypto::key(preview))?;
    if !s.desktop_preview_public.is_empty() && s.desktop_preview_public != preview {
        return Err(pairing_error("desktop preview key changed"));
    }
    let code = checked(cloud_crypto::pairing_safety_code(
        &s.connection.origin,
        id(&s.connection.gateway_id)?,
        open.binding,
        private.as_ref(),
        &desktop,
        &desktop,
        &mobile,
        &desktop_preview,
        &checked(cloud_crypto::key(&s.preview_public))?,
    ))?;
    if !s.pairing_code.is_empty() && s.pairing_code != code {
        return Err(pairing_error("saved safety code changed"));
    }
    if pairing && authorized["kind"] == "pair_pending" {
        if authorized["safety_code"] != code
            || matches!(authorization, Authorization::Pair(Some(_)))
                && authorized["scan_verified"] != true
        {
            return Err(pairing_error("desktop safety code mismatch"));
        }
        {
            let mut saved = save
                .ok_or_else(|| pairing_error("binding credentials unavailable"))?
                .write()
                .unwrap();
            saved.desktop_preview_public = preview.into();
            saved.pairing_code = code;
        }
        let _ = channel.socket.close(None).await;
        return Ok(None);
    }
    if pairing || authorized["kind"] != "authorized" {
        return Err(pairing_error("desktop authorization was not confirmed"));
    }
    let mut saved = save
        .ok_or_else(|| pairing_error("binding credentials unavailable"))?
        .write()
        .unwrap();
    saved.desktop_preview_public = preview.into();
    saved.pairing_code = code;
    Ok(Some(channel))
}

impl Relay {
    pub(crate) fn transport_status(&self) -> RelayTransportStatus {
        self.links.snapshot()
    }
    pub(crate) fn replace_credentials(&self, raw: &str) -> Result<()> {
        let replacement: BindingSecrets = serde_json::from_str(raw)?;
        let mut current = self.secret.write().unwrap();
        if replacement.connection != current.connection
            || replacement.control_private != current.control_private
            || replacement.preview_private != current.preview_private
            || replacement.device_token.len() != 43
            || replacement.installation_id != current.installation_id
        {
            return Err(invalid());
        }
        *current = replacement;
        Ok(())
    }
    pub(crate) fn connection_status(&self) -> tokio::sync::watch::Receiver<String> {
        self.status.subscribe()
    }
    pub(crate) fn connected_generation(&self) -> Option<u64> {
        (self.links.connected() || self.status.borrow().as_str() == "connected")
            .then(|| self.generation.load(std::sync::atomic::Ordering::Acquire))
    }
    pub(crate) async fn ensure_session(&self) -> Result<u64> {
        self.session().await?;
        self.connected_generation().ok_or(BridgeError::Network)
    }
    pub(crate) fn connection_observer(&self) -> CancellationToken {
        let mut token = self.observer_cancel.write().unwrap();
        token.cancel();
        *token = CancellationToken::new();
        let paused = self.status.borrow().as_str() == "paused";
        if paused {
            self.status.send_replace("disconnected".into());
        }
        token.clone()
    }
    pub(crate) fn cancel_connection_observer(&self) {
        self.observer_cancel.read().unwrap().cancel();
    }
    pub(crate) async fn pause(&self) {
        self.links.pause(false);
        self.cancel_connection_observer();
        {
            let mut token = self.connect_cancel.write().unwrap();
            token.cancel();
            *token = CancellationToken::new();
        }
        let mut cache = self.session.lock().await;
        if let Some(active) = &cache.active {
            active.quiesce.cancel();
        }
        cache.next = None;
        self.status.send_replace("paused".into());
    }
    pub(crate) async fn revoke(&self) {
        self.links.pause(true);
        self.pause().await;
        let mut cache = self.session.lock().await;
        if let Some(active) = cache.active.take() {
            active.closed.cancel();
        }
    }
    async fn session(&self) -> Result<Arc<session::Session>> {
        if let Some(direct) = self.links.direct() {
            return Ok(direct);
        }
        let cancelled = self.connect_cancel.read().unwrap().clone();
        // All callers share one handshake/backoff; business requests are never replayed.
        let mut cache = tokio::select! { _ = cancelled.cancelled() => return Err(BridgeError::Cancelled), value=self.session.lock()=>value };
        if let Some(active) = &cache.active
            && !active.closed.is_cancelled()
        {
            if active.quiesce.is_cancelled() {
                tokio::select! {_=cancelled.cancelled()=>return Err(BridgeError::Cancelled),_=active.closed.cancelled()=>{}}
            } else {
                return Ok(active.clone());
            }
        }
        if let Some(next) = cache.next {
            tokio::select! {_=cancelled.cancelled()=>return Err(BridgeError::Cancelled),_=tokio::time::sleep_until(next)=>{}}
        }
        self.status.send_replace("connecting".into());
        let connected = tokio::select! {_=cancelled.cancelled()=>Err(BridgeError::Cancelled), result=self.connect(Authorization::Existing)=>result};
        match connected {
            Ok(Some(mut channel)) => {
                self.generation
                    .fetch_add(1, std::sync::atomic::Ordering::AcqRel);
                channel.links = Some(self.links.clone());
                channel.authority = Some(self.secret.clone());
                let available = channel.p2p_available;
                let active = session::Session::start(channel, self.status.clone());
                self.links.register(&active, false);
                if available && let Some(offer) = active.take_offer() {
                    p2p::upgrade(
                        self.links.clone(),
                        self.secret.read().unwrap().clone(),
                        offer,
                        self.status.clone(),
                    );
                }
                cache.active = Some(active.clone());
                cache.failures = 0;
                cache.next = None;
                self.status.send_replace("connected".into());
                Ok(active)
            }
            result => {
                cache.failures = cache.failures.saturating_add(1);
                let base = (1u64 << cache.failures.saturating_sub(1).min(4)).min(15);
                let jitter = u64::from(Uuid::new_v4().as_bytes()[0]) * 2;
                cache.next = Some(
                    tokio::time::Instant::now()
                        + Duration::from_millis((base * 1000 + jitter).min(15_000)),
                );
                let error = result.err().unwrap_or_else(invalid);
                let state = match &error {
                    BridgeError::Relay(code) => code.as_str(),
                    BridgeError::Tls => "certificate",
                    BridgeError::Cancelled => "paused",
                    _ => "reconnecting",
                };
                self.status.send_replace(state.into());
                Err(error)
            }
        }
    }
    #[cfg(test)]
    pub(crate) async fn request(
        &self,
        method: Method,
        path: &str,
        body: Option<Vec<u8>>,
        content_type: &str,
    ) -> Result<Response> {
        self.request_with_headers(
            method,
            path,
            body,
            content_type,
            &std::collections::BTreeMap::new(),
        )
        .await
    }

    pub(crate) async fn request_with_headers(
        &self,
        method: Method,
        path: &str,
        body: Option<Vec<u8>>,
        content_type: &str,
        headers: &std::collections::BTreeMap<String, String>,
    ) -> Result<Response> {
        let body = crate::transport::request_body(&method, body)?;
        let event = method == Method::GET
            && path
                .split('?')
                .next()
                .is_some_and(|p| p.ends_with("/events") && p != "/api/mobile/events");
        let mut channel = self
            .session()
            .await?
            .open_request(!matches!(method, Method::GET | Method::HEAD), event)
            .await?;
        if body.len() > 1024 * 1024
            || ["/files/", "/upload", "/download"]
                .iter()
                .any(|part| path.contains(part))
        {
            channel.large()?;
        }
        channel.send(json!({"kind":"request","id":Uuid::new_v4(),"method":method.as_str(),"path":path,
            "content_type":if content_type.is_empty() { "application/json" } else { content_type },"headers":headers,"length":body.len()})).await?;
        let mut credits = credit(&channel.control(15).await?)?;
        for chunk in body.chunks(MAX_CHUNK - 9) {
            if credits == 0 {
                credits = credit(&channel.control(15).await?)?;
            }
            credits -= 1;
            channel.send_body(chunk).await?;
        }
        channel.send(json!({"kind":"request_end"})).await?;
        let start = loop {
            let value = channel.control(80).await?;
            if value["kind"] == "credit" {
                credit(&value)?;
                continue;
            }
            break value;
        };
        if start["kind"] != "response_start" {
            return Err(invalid());
        }
        let status = start["status"]
            .as_u64()
            .filter(|v| (100..600).contains(v))
            .ok_or_else(invalid)? as u16;
        if (300..400).contains(&status) {
            return Err(BridgeError::Redirect);
        }
        let headers = start["headers"].as_object().ok_or_else(invalid)?;
        let mut response = http::Response::builder().status(status);
        let mut sse = false;
        for (key, value) in headers {
            if ![
                "Content-Type",
                "Content-Length",
                "ETag",
                "Content-Range",
                "Accept-Ranges",
            ]
            .contains(&key.as_str())
            {
                return Err(invalid());
            }
            let text = value
                .as_str()
                .filter(|v| v.len() <= 256)
                .ok_or_else(invalid)?;
            if key == "Content-Length"
                && text.parse::<u64>().map_err(|_| invalid())? > MAX_FILE as u64
            {
                return Err(BridgeError::TooLarge);
            }
            if key == "Content-Length" && text.parse::<u64>().map_err(|_| invalid())? > 1024 * 1024
            {
                channel.large()?;
            }
            if key == "Content-Type" {
                sse = text.starts_with("text/event-stream");
            }
            response = response.header(key, text);
        }
        let (tx, rx) =
            tokio::sync::mpsc::channel::<std::result::Result<Vec<u8>, std::io::Error>>(4);
        channel.send(json!({"kind":"credit","count":4})).await?;
        tokio::spawn(receive_response_body(channel, tx, sse));
        let stream = futures_util::stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|part| (part, rx))
        });
        Ok(response
            .body(reqwest::Body::wrap_stream(stream))
            .map_err(|_| invalid())?
            .into())
    }
    pub(crate) async fn endpoint(
        &self,
        platform: String,
        app_id: String,
        token: String,
        enabled: bool,
        consent: bool,
    ) -> Result<()> {
        let s = self.secret.read().unwrap().clone();
        api(&s.connection.origin, "/v1/push/endpoints", Method::POST,
            Some(json!({"binding_id":s.connection.binding_id,"platform":platform,"app_id":app_id,"token":token,"enabled":enabled,"consent":consent})), &s.device_token).await?;
        Ok(())
    }
    pub(crate) async fn acknowledge(&self, ids: Vec<String>) -> Result<()> {
        let s = self.secret.read().unwrap().clone();
        if ids.len() > 100 {
            return Err(invalid());
        }
        for value in &ids {
            id(value)?;
        }
        api(
            &s.connection.origin,
            "/v1/push/ack",
            Method::POST,
            Some(json!({"binding_id":s.connection.binding_id,"notification_ids":ids})),
            &s.device_token,
        )
        .await?;
        Ok(())
    }
}

async fn receive_response_body(
    mut channel: session::Substream,
    tx: tokio::sync::mpsc::Sender<std::result::Result<Vec<u8>, std::io::Error>>,
    sse: bool,
) {
    let mut total = 0usize;
    let mut credit_writable = true;
    let result: Result<()> = async {
        loop {
            let data =
                tokio::select! { _ = tx.closed() => return Ok(()), v = channel.receive(80) => v? };
            if data.first() == Some(&1) {
                total = total.saturating_add(data.len() - 1);
                if !sse && total > MAX_FILE {
                    return Err(BridgeError::TooLarge);
                }
                if tx.send(Ok(data[1..].to_vec())).await.is_err() {
                    return Ok(());
                }
                if credit_writable {
                    // The desktop can finish and close after sending its last
                    // window. A failed trailing credit must not discard the
                    // authenticated response_end already queued for reading.
                    credit_writable = channel
                        .send(json!({"kind":"credit","count":1}))
                        .await
                        .is_ok();
                }
            } else if data.first() == Some(&0)
                && serde_json::from_slice::<Value>(&data[1..])? == json!({"kind":"response_end"})
            {
                channel.finish().await;
                return Ok(());
            } else {
                return Err(invalid());
            }
        }
    }
    .await;
    if result.is_err() {
        let _ = tx
            .send(Err(std::io::Error::other("encrypted relay disconnected")))
            .await;
    }
}

impl Drop for Relay {
    fn drop(&mut self) {
        self.links.pause(true);
        if let Some(active) = self.session.get_mut().active.take() {
            active.closed.cancel();
        }
    }
}

#[cfg(test)]
#[path = "relay/response_tests.rs"]
mod response_tests;

#[cfg(test)]
mod p2p_fixture_test;

fn credit(value: &Value) -> Result<usize> {
    if value["kind"] != "credit" {
        return Err(invalid());
    }
    value["count"]
        .as_u64()
        .filter(|v| (1..=4).contains(v))
        .map(|v| v as usize)
        .ok_or_else(invalid)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn active_cloud_binding_recovers_local_proof_by_authorizing_not_repairing() {
        assert_eq!(
            pairing_recovery("active", true, false),
            PairingRecovery::AuthorizeExistingBinding
        );
        assert_eq!(
            pairing_recovery("active", true, true),
            PairingRecovery::AuthorizeExistingBinding
        );
        assert_eq!(
            pairing_recovery("pending", true, false),
            PairingRecovery::RequestDesktopApproval
        );
        assert_eq!(
            pairing_recovery("pending", true, true),
            PairingRecovery::WaitForDesktopApproval
        );
        assert_eq!(
            pairing_recovery("active", false, false),
            PairingRecovery::NoAction
        );
    }

    #[test]
    fn binding_credentials_require_the_current_complete_format() {
        let (_, saved) = secrets();
        let mut value = serde_json::to_value(&saved).unwrap();
        value["request_attempted"] = json!(true);
        assert!(Relay::new(&saved.connection, &value.to_string()).is_err());
        value.as_object_mut().unwrap().remove("request_attempted");
        value.as_object_mut().unwrap().remove("pairing_code");
        assert!(Relay::new(&saved.connection, &value.to_string()).is_err());
    }

    #[tokio::test]
    async fn a_revoked_request_is_observed_without_creating_or_replaying_a_request() {
        use wiremock::{
            Mock, MockServer, ResponseTemplate,
            matchers::{method, path},
        };
        let server = MockServer::start().await;
        let (_, mut saved) = secrets();
        saved.connection.origin = server.uri();
        saved.control_public = b64(&cloud_crypto::public_key(
            &cloud_crypto::key(&saved.control_private).unwrap(),
        )
        .unwrap());
        saved.preview_public = b64(&cloud_crypto::public_key(
            &cloud_crypto::key(&saved.preview_private).unwrap(),
        )
        .unwrap());
        let connection = saved.connection.clone();
        let client = Relay::new(&connection, &serde_json::to_string(&saved).unwrap()).unwrap();
        Mock::given(method("GET")).and(path(format!("/v1/bindings/{}",connection.binding_id)))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"id":connection.binding_id,"gateway_id":connection.gateway_id,
                "installation_id":saved.installation_id,"gateway_public_key":connection.desktop_public_key,"mobile_public_key":saved.control_public,"status":"revoked"}))).mount(&server).await;
        assert_eq!(client.pairing_state().await.unwrap().status, "revoked");
        assert!(
            server
                .received_requests()
                .await
                .unwrap()
                .iter()
                .all(|request| request.method == "GET")
        );
    }

    #[test]
    fn explicit_origin_boundaries() {
        assert!(cloud_crypto::exact_origin("https://RELAY.test").is_err());
        assert!(cloud_crypto::exact_origin("https://relay.test:443").is_err());
    }

    #[test]
    fn pending_pairing_uses_the_server_binding_and_local_preview_key() {
        let (account, _) = secrets();
        let binding = Uuid::new_v4().to_string();
        let prepared = prepare_discovery(
            CloudDiscoveredDevice {
                gateway: CloudGateway {
                    origin: account.origin.clone(),
                    id: Uuid::new_v4().to_string(),
                    name: "Desktop".into(),
                    control_public_key: b64(&cloud_crypto::public_key(&[8; 32]).unwrap()),
                    online: false,
                },
                binding_id: binding.clone(),
                status: CloudDeviceStatus::Pending,
                access_revision: 0,
                access_allowed: true,
            },
            &serde_json::to_string(&account).unwrap(),
            "Phone".into(),
        )
        .unwrap();
        assert_eq!(prepared.computer.id, binding);
        assert_eq!(
            prepared.computer.relay.as_ref().unwrap().binding_id,
            binding
        );
        let client = Relay::new(
            prepared.computer.relay.as_ref().unwrap(),
            &prepared.binding_credentials,
        )
        .unwrap();
        assert!(!client.export().unwrap().contains("request_attempted"));
        assert!(!client.export().unwrap().contains("expires_at"));
        assert_eq!(
            client.secret.read().unwrap().installation_id,
            account.installation_id
        );
        assert_eq!(
            client.secret.read().unwrap().control_private,
            account.control_private
        );
    }

    #[test]
    fn persisted_safety_codes_are_rederived_from_the_pinned_keys_without_network_io() {
        let (_, mut saved) = secrets();
        saved.control_public = b64(&cloud_crypto::public_key(
            &cloud_crypto::key(&saved.control_private).unwrap(),
        )
        .unwrap());
        saved.preview_public = b64(&cloud_crypto::public_key(
            &cloud_crypto::key(&saved.preview_private).unwrap(),
        )
        .unwrap());
        saved.pairing_code = cloud_crypto::pairing_safety_code(
            &saved.connection.origin,
            id(&saved.connection.gateway_id).unwrap(),
            id(&saved.connection.binding_id).unwrap(),
            &cloud_crypto::key(&saved.control_private).unwrap(),
            &cloud_crypto::key(&saved.connection.desktop_public_key).unwrap(),
            &cloud_crypto::key(&saved.connection.desktop_public_key).unwrap(),
            &cloud_crypto::key(&saved.control_public).unwrap(),
            &cloud_crypto::key(&saved.desktop_preview_public).unwrap(),
            &cloud_crypto::key(&saved.preview_public).unwrap(),
        )
        .unwrap();
        let client =
            Relay::new(&saved.connection, &serde_json::to_string(&saved).unwrap()).unwrap();
        assert_eq!(client.saved_safety_code().unwrap(), saved.pairing_code);
        saved.pairing_code.replace_range(..1, "X");
        let altered =
            Relay::new(&saved.connection, &serde_json::to_string(&saved).unwrap()).unwrap();
        assert!(altered.saved_safety_code().is_err());
    }

    #[tokio::test]
    async fn automatic_directory_is_read_only_and_validates_account_identity_and_versions() {
        use wiremock::{
            Mock, MockServer, ResponseTemplate,
            matchers::{method, path},
        };
        let server = MockServer::start().await;
        let (mut account, _) = secrets();
        account.origin = server.uri();
        let raw = serde_json::to_string(&account).unwrap();
        let caps = json!({"control_noise":"Noise_KK_25519_ChaChaPoly_BLAKE2s", "preview_noise":"Noise_K_25519_ChaChaPoly_BLAKE2s",
            "relay_protocols":[2],"device_discovery":"account_directory_v2","pairing_method":"desktop_qr_v1"});
        let record = json!({"id":Uuid::new_v4(),"gateway_id":Uuid::new_v4(),"installation_id":account.installation_id,
            "mobile_public_key":b64(&cloud_crypto::public_key(&cloud_crypto::key(&account.control_private).unwrap()).unwrap()),
            "gateway_public_key":b64(&cloud_crypto::public_key(&[8;32]).unwrap()),"gateway_name":"Offline desktop",
            "status":"disabled","access_revision":7,"gateway_online":false});
        Mock::given(method("GET"))
            .and(path("/v1/capabilities"))
            .respond_with(ResponseTemplate::new(200).set_body_json(caps.clone()))
            .mount(&server)
            .await;
        let scope = json!({"version":1,"origin":account.origin,"account_id":account.account_id,"device_id":account.installation_id});
        let gateway = json!({"id":record["gateway_id"],"name":record["gateway_name"],"control_public_key":record["gateway_public_key"]});
        let unpaired = json!({"id":Uuid::new_v4(),"name":"Another desktop","control_public_key":record["gateway_public_key"],"online":true});
        Mock::given(method("GET"))
            .and(path("/v1/mobile/bindings"))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(json!({"bindings":[record.clone()],"gateways":[gateway.clone(),unpaired],"access":scope.clone()})),
            )
            .mount(&server)
            .await;
        let result = devices(&raw, &account.origin, &account.account_id)
            .await
            .unwrap();
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].status, CloudDeviceStatus::Disabled);
        assert_eq!(result[1].status, CloudDeviceStatus::Unpaired);
        assert!(result[1].binding_id.is_empty());
        assert!(!result[1].access_allowed);
        assert!(!result[0].gateway.online);
        assert!(
            devices(&raw, &account.origin, &Uuid::new_v4().to_string())
                .await
                .is_err()
        );
        assert!(
            server
                .received_requests()
                .await
                .unwrap()
                .iter()
                .all(|request| request.method == "GET")
        );
        server.reset().await;
        Mock::given(method("GET"))
            .and(path("/v1/capabilities"))
            .respond_with(ResponseTemplate::new(200).set_body_json(caps.clone()))
            .mount(&server)
            .await;
        let mut changed = record;
        changed["installation_id"] = json!(Uuid::new_v4());
        Mock::given(method("GET"))
            .and(path("/v1/mobile/bindings"))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(
                    json!({"bindings":[changed],"gateways":[gateway],"access":scope}),
                ),
            )
            .mount(&server)
            .await;
        assert!(
            devices(&raw, &account.origin, &account.account_id)
                .await
                .is_err()
        );
        server.reset().await;
        let mut old = caps;
        old.as_object_mut().unwrap().remove("device_discovery");
        Mock::given(method("GET"))
            .and(path("/v1/capabilities"))
            .respond_with(ResponseTemplate::new(200).set_body_json(old))
            .mount(&server)
            .await;
        assert!(
            devices(&raw, &account.origin, &account.account_id)
                .await
                .is_err()
        );
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn disabled_directory_state_does_not_attempt_a_socket_or_a_write() {
        use wiremock::{
            Mock, MockServer, ResponseTemplate,
            matchers::{method, path},
        };
        let server = MockServer::start().await;
        let (_, mut saved) = secrets();
        saved.connection.origin = server.uri();
        saved.control_public = b64(&cloud_crypto::public_key(
            &cloud_crypto::key(&saved.control_private).unwrap(),
        )
        .unwrap());
        saved.preview_public = b64(&cloud_crypto::public_key(
            &cloud_crypto::key(&saved.preview_private).unwrap(),
        )
        .unwrap());
        let client =
            Relay::new(&saved.connection, &serde_json::to_string(&saved).unwrap()).unwrap();
        Mock::given(method("GET")).and(path(format!("/v1/bindings/{}", saved.connection.binding_id))).respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "id":saved.connection.binding_id,"gateway_id":saved.connection.gateway_id,"installation_id":saved.installation_id,
            "gateway_public_key":saved.connection.desktop_public_key,"mobile_public_key":saved.control_public,"status":"disabled","gateway_online":true
        }))).mount(&server).await;
        assert_eq!(client.pairing_state().await.unwrap().status, "disabled");
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
    }

    #[test]
    fn websocket_scheme_follows_the_explicit_origin() {
        assert_eq!(
            websocket_url("http://relay.test:8787").unwrap(),
            "ws://relay.test:8787/v1/ws/mobile"
        );
        assert_eq!(
            websocket_url("https://relay.test:8787").unwrap(),
            "wss://relay.test:8787/v1/ws/mobile"
        );
        assert!(websocket_url("ftp://relay.test").is_err());
        assert!(websocket_url("http://relay.test/path").is_err());
    }

    #[tokio::test]
    async fn explicit_http_capabilities_are_accepted_but_redirects_are_not() {
        use wiremock::{
            Mock, MockServer, ResponseTemplate,
            matchers::{method, path},
        };
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/v1/capabilities"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "control_noise":"Noise_KK_25519_ChaChaPoly_BLAKE2s",
                "preview_noise":"Noise_K_25519_ChaChaPoly_BLAKE2s",
                "relay_protocols":[2],"mode":"selfhost","login":"username"
            })))
            .mount(&server)
            .await;
        assert_eq!(capabilities(&server.uri()).await.unwrap().mode, "selfhost");
        server.reset().await;
        Mock::given(method("GET"))
            .and(path("/v1/capabilities"))
            .respond_with(
                ResponseTemplate::new(302)
                    .insert_header("Location", "http://different.test/v1/capabilities"),
            )
            .mount(&server)
            .await;
        assert!(matches!(
            capabilities(&server.uri()).await,
            Err(BridgeError::Redirect)
        ));
    }

    pub(super) fn secrets() -> (AccountSecrets, BindingSecrets) {
        let account = AccountSecrets {
            origin: "https://relay.test".into(),
            account_id: Uuid::new_v4().to_string(),
            login: "user".into(),
            access_token: "access".into(),
            refresh_token: "refresh".into(),
            refresh_request_id: String::new(),
            access_deadline: now() + 3600,
            installation_id: Uuid::new_v4().to_string(),
            control_private: b64(&[7; 32]),
            device_token: "a".repeat(43),
            _retired_registration: serde::de::IgnoredAny,
        };
        let binding = BindingSecrets {
            connection: RelayConnection {
                origin: account.origin.clone(),
                account_id: account.account_id.clone(),
                gateway_id: Uuid::new_v4().to_string(),
                binding_id: Uuid::new_v4().to_string(),
                desktop_public_key: b64(&[9; 32]),
            },
            installation_id: account.installation_id.clone(),
            device_token: "b".repeat(43),
            control_private: account.control_private.clone(),
            control_public: b64(&[8; 32]),
            preview_private: b64(&[10; 32]),
            preview_public: b64(&[11; 32]),
            desktop_preview_public: b64(&[12; 32]),
            device_name: "Test phone".into(),
            pairing_code: String::new(),
        };
        (account, binding)
    }

    #[test]
    fn account_token_rotation_preserves_all_pins_and_preview_keys() {
        let (account, binding) = secrets();
        let raw = serde_json::to_string(&binding).unwrap();
        let updated = updated_binding_credentials(&raw, &serde_json::to_string(&account).unwrap())
            .unwrap()
            .unwrap();
        let mut expected: Value = serde_json::from_str(&raw).unwrap();
        expected["device_token"] = account.device_token.clone().into();
        assert_eq!(serde_json::from_str::<Value>(&updated).unwrap(), expected);
    }

    #[test]
    fn token_updates_reject_other_origins_accounts_and_control_keys_and_skip_retired_installations()
    {
        let (account, binding) = secrets();
        let raw = serde_json::to_string(&binding).unwrap();
        let value = serde_json::to_value(&account).unwrap();
        for (field, changed) in [
            ("origin", "https://other.test"),
            ("account_id", "other-account"),
            ("control_private", "other-key"),
            ("device_token", ""),
        ] {
            let mut altered = value.clone();
            altered[field] = changed.into();
            assert!(updated_binding_credentials(&raw, &altered.to_string()).is_err());
        }
        let mut retired = value;
        retired["installation_id"] = Uuid::new_v4().to_string().into();
        assert_eq!(
            updated_binding_credentials(&raw, &retired.to_string()).unwrap(),
            None
        );
    }

    #[tokio::test]
    async fn explicit_pairing_targets_one_gateway_and_the_exact_previous_binding() {
        use wiremock::{
            Mock, MockServer, ResponseTemplate,
            matchers::{body_json, method, path},
        };
        let server = MockServer::start().await;
        let (mut account, binding) = secrets();
        account.origin = server.uri();
        let raw = serde_json::to_string(&account).unwrap();
        let previous = binding.connection.binding_id.clone();
        let gateway = CloudGateway {
            id: binding.connection.gateway_id.clone(),
            origin: account.origin.clone(),
            name: "Desktop".into(),
            control_public_key: binding.connection.desktop_public_key.clone(),
            online: true,
        };
        let pending = Uuid::new_v4().to_string();
        let mobile = b64(&cloud_crypto::public_key(
            &cloud_crypto::key(&account.control_private).unwrap(),
        )
        .unwrap());
        let request = json!({"gateway_id":gateway.id,"gateway_public_key":gateway.control_public_key,"replace_binding_id":previous});
        let response = json!({"id":pending,"installation_id":account.installation_id,"mobile_public_key":mobile,
            "gateway_id":gateway.id,"gateway_name":gateway.name,"gateway_public_key":gateway.control_public_key,
            "status":"pending","access_revision":0,"replaces_binding_id":previous});
        Mock::given(method("POST"))
            .and(path("/v1/mobile/pair"))
            .and(body_json(request))
            .respond_with(ResponseTemplate::new(200).set_body_json(response))
            .expect(1)
            .mount(&server)
            .await;
        let device = request_pairing(&raw, gateway, &account.account_id, Some(previous))
            .await
            .unwrap();
        assert_eq!(device.binding_id, pending);
        assert!(!device.access_allowed);
    }

    #[test]
    fn pairing_qr_is_bound_to_the_pending_binding_and_full_noise_proof() {
        let (_, mut binding) = secrets();
        binding.pairing_code = ["ABCDEF12"; 8].join(" ");
        let nonce = "0a".repeat(16);
        let code = format!(
            "bridge-pair:v1:{}:{}:{nonce}",
            binding.connection.binding_id,
            binding.pairing_code.replace(' ', "")
        );
        assert_eq!(scan_token(&binding, &code).unwrap(), nonce);
        assert!(scan_token(&binding, &code.replace("ABCDEF12", "ABCDEF13")).is_err());
        assert!(
            scan_token(
                &binding,
                &code.replace(&binding.connection.binding_id, &Uuid::new_v4().to_string())
            )
            .is_err()
        );
        assert!(scan_token(&binding, &format!("{code}:extra")).is_err());
        assert!(scan_token(&binding, "https://unrelated.example/").is_err());
    }

    #[test]
    fn signed_out_credentials_scrub_authority_but_keep_installation_identity() {
        let (account, _) = secrets();
        let raw = serde_json::to_string(&account).unwrap();
        let signed_out =
            signed_out_credentials(&raw, &account.origin, &account.account_id).unwrap();
        let value: Value = serde_json::from_str(&signed_out).unwrap();
        for field in ["access_token", "refresh_token", "device_token"] {
            assert_eq!(value[field], "");
        }
        assert_eq!(value["control_private"], account.control_private);
        assert_eq!(value["installation_id"], account.installation_id);
        assert!(credential_state(&signed_out, &account.origin, &account.account_id).is_err());
        assert!(signed_out_credentials(&raw, "https://other.test", &account.account_id).is_err());
    }

    #[test]
    fn refresh_attempt_is_persisted_and_reused_after_lost_response() {
        let (mut account, _) = secrets();
        let raw = serde_json::to_string(&account).unwrap();
        assert!(
            credential_state(&raw, &account.origin, &account.account_id)
                .unwrap()
                .consumed_credentials
                .is_none()
        );
        account.access_deadline = 0;
        let raw = serde_json::to_string(&account).unwrap();
        let consumed = credential_state(&raw, &account.origin, &account.account_id)
            .unwrap()
            .consumed_credentials
            .unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&consumed).unwrap()["refresh_token"],
            "refresh"
        );
        let retry = credential_state(&consumed, &account.origin, &account.account_id)
            .unwrap()
            .consumed_credentials
            .unwrap();
        assert_eq!(retry, consumed);
        assert!(
            serde_json::from_str::<Value>(&consumed).unwrap()["refresh_request_id"]
                .as_str()
                .is_some_and(|v| Uuid::parse_str(v).is_ok())
        );
        assert!(credential_state(&raw, "https://other.test", &account.account_id).is_err());
    }
}
