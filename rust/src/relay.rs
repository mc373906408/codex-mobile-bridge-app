use std::sync::RwLock;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use futures_util::{SinkExt, StreamExt};
use reqwest::{Client, Method, Response};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::net::TcpStream;
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream,
    tungstenite::{Message, client::IntoClientRequest, protocol::WebSocketConfig},
};
use uuid::Uuid;
use zeroize::Zeroize;

use crate::api::types::*;
use crate::cloud_crypto::{self, ControlCipher, Frame, MAX_CHUNK};
use crate::error::{BridgeError, Result};
use crate::transport::{MAX_FILE, Transport};

fn invalid() -> BridgeError {
    BridgeError::Protocol("encrypted relay authentication failed".into())
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
    access_deadline: i64,
    installation_id: String,
    control_private: String,
    #[serde(default)]
    device_token: String,
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
}
impl Drop for BindingSecrets {
    fn drop(&mut self) {
        self.device_token.zeroize();
        self.control_private.zeroize();
        self.preview_private.zeroize();
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Invitation {
    v: u8,
    origin: String,
    gateway_id: String,
    desktop_public_key: String,
    pairing_id: String,
    secret: String,
}

fn invitation(raw: &str) -> Result<Invitation> {
    if raw.len() > 4096 {
        return Err(invalid());
    }
    let url = url::Url::parse(raw).map_err(|_| invalid())?;
    let query: Vec<_> = url.query_pairs().collect();
    if url.scheme() != "bridge-relay"
        || url.host_str() != Some("pair")
        || !url.path().is_empty()
        || url.fragment().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
        || query.len() != 1
        || query[0].0 != "data"
    {
        return Err(invalid());
    }
    let data = URL_SAFE_NO_PAD
        .decode(query[0].1.as_bytes())
        .map_err(|_| invalid())?;
    let value: Invitation = serde_json::from_slice(&data)?;
    checked(cloud_crypto::exact_origin(&value.origin))?;
    checked(cloud_crypto::key(&value.desktop_public_key))?;
    id(&value.gateway_id)?;
    id(&value.pairing_id)?;
    if value.v != 1
        || value.secret.len() != 43
        || !value
            .secret
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err(invalid());
    }
    Ok(value)
}

pub(crate) fn invitation_origin(raw: &str) -> Result<String> {
    Ok(invitation(raw)?.origin)
}

fn api_client() -> Result<Client> {
    Ok(Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .retry(reqwest::retry::never())
        .https_only(true)
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(20))
        .user_agent("BridgeMobile/1")
        .build()?)
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
    if v["control_noise"] != "Noise_KK_25519_ChaChaPoly_BLAKE2s"
        || v["preview_noise"] != "Noise_K_25519_ChaChaPoly_BLAKE2s"
        || !v["relay_protocols"]
            .as_array()
            .is_some_and(|a| a.contains(&json!(1)))
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
                access_deadline: 0,
                installation_id: Uuid::new_v4().to_string(),
                control_private: b64(&key.private),
                device_token: String::new(),
            }
        }
    };
    secret.login = v["account"]["login"].as_str().ok_or_else(invalid)?.into();
    secret.access_token = v["access_token"].as_str().ok_or_else(invalid)?.into();
    secret.refresh_token = v["refresh_token"].as_str().ok_or_else(invalid)?.into();
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
        Some(json!({"id":account.installation_id,"control_public_key":b64(&public),"name":""})),
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
        .filter(|s| !s.is_empty())
        .ok_or_else(invalid)?
        .into();
    Ok(())
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
        secret.refresh_token.zeroize();
        secret.refresh_token.clear();
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

pub(crate) fn updated_binding_credentials(binding: &str, account: &str) -> Result<String> {
    let mut binding: BindingSecrets = serde_json::from_str(binding)?;
    let account: AccountSecrets = serde_json::from_str(account)?;
    if binding.connection.origin != account.origin
        || binding.connection.account_id != account.account_id
        || binding.installation_id != account.installation_id
        || binding.control_private != account.control_private
        || account.device_token.is_empty()
    {
        return Err(invalid());
    }
    binding.device_token = account.device_token.clone();
    Ok(serde_json::to_string(&binding)?)
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
    let v = api(
        &origin,
        "/v1/auth/refresh",
        Method::POST,
        Some(json!({"refresh_token":secret.refresh_token})),
        "",
    )
    .await?;
    if v["account"]["id"] != secret.account_id {
        return Err(invalid());
    }
    secret.access_token = v["access_token"].as_str().ok_or_else(invalid)?.into();
    secret.refresh_token = v["refresh_token"].as_str().ok_or_else(invalid)?.into();
    secret.access_deadline = now() + v["expires_in"].as_i64().ok_or_else(invalid)?;
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

pub(crate) async fn enroll(qr: &str, raw: &str, name: String) -> Result<RelayEnrollment> {
    let invitation = invitation(qr)?;
    let mut account: AccountSecrets = serde_json::from_str(raw)?;
    if account.origin != invitation.origin {
        return Err(invalid());
    }
    let private = checked(cloud_crypto::key(&account.control_private))?;
    let public = snow::Builder::new(
        "Noise_KK_25519_ChaChaPoly_BLAKE2s"
            .parse()
            .map_err(|_| invalid())?,
    )
    .generate_keypair()
    .map_err(|_| invalid())?;
    // Derive the pinned static public key with the same X25519 implementation used by Noise.
    let control_public = checked(cloud_crypto::public_key(&private))?;
    if account.device_token.is_empty() {
        enroll_installation(&mut account).await?;
    }
    // One installation token serves all locally pinned bindings. Pairing a
    // second desktop must not silently invalidate the first desktop's token.
    let device_token = account.device_token.clone();
    let binding = api(
        &account.origin,
        &format!("/v1/pairings/{}/join", invitation.pairing_id),
        Method::POST,
        Some(json!({})),
        &device_token,
    )
    .await?;
    let binding_id = binding["id"].as_str().ok_or_else(invalid)?.to_owned();
    id(&binding_id)?;
    if binding["gateway_id"] != invitation.gateway_id
        || binding["gateway_public_key"] != invitation.desktop_public_key
        || binding["mobile_public_key"] != b64(&control_public)
        || binding["installation_id"] != account.installation_id
    {
        return Err(invalid());
    }
    let connection = RelayConnection {
        origin: account.origin.clone(),
        account_id: account.account_id.clone(),
        gateway_id: invitation.gateway_id,
        binding_id,
        desktop_public_key: invitation.desktop_public_key,
    };
    let secret = BindingSecrets {
        connection: connection.clone(),
        installation_id: account.installation_id.clone(),
        device_token,
        control_private: account.control_private.clone(),
        control_public: b64(&control_public),
        preview_private: b64(&public.private),
        preview_public: b64(&public.public),
        desktop_preview_public: String::new(),
    };
    Ok(RelayEnrollment {
        computer: Computer {
            id: Uuid::new_v4().to_string(),
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

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;
struct Channel {
    socket: Socket,
    cipher: ControlCipher,
    binding: Uuid,
    channel: Uuid,
}
impl Channel {
    async fn send_data(&mut self, data: &[u8]) -> Result<()> {
        let payload = checked(self.cipher.encrypt(data))?;
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
    secret: RwLock<BindingSecrets>,
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
        let secret: BindingSecrets = serde_json::from_str(saved)?;
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
        Ok(Self {
            secret: RwLock::new(secret),
        })
    }
    pub(crate) fn export(&self) -> Result<String> {
        Ok(serde_json::to_string(&*self.secret.read().unwrap())?)
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
    pub(crate) async fn confirm(&self, qr: &str) -> Result<()> {
        let invitation = invitation(qr)?;
        let s = self.secret.read().unwrap().clone();
        if s.connection.origin != invitation.origin
            || s.connection.gateway_id != invitation.gateway_id
            || s.connection.desktop_public_key != invitation.desktop_public_key
        {
            return Err(invalid());
        }
        let mut channel = self.connect(Some(&invitation.secret)).await?;
        let _ = channel.socket.close(None).await;
        Ok(())
    }
    async fn connect(&self, pairing: Option<&str>) -> Result<Channel> {
        let s = self.secret.read().unwrap().clone();
        let url = format!(
            "{}/v1/ws/mobile",
            s.connection.origin.replacen("https://", "wss://", 1)
        );
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
        headers.insert("Sec-WebSocket-Protocol", "bridge-relay-v1".parse().unwrap());
        let config = WebSocketConfig::default()
            .read_buffer_size(32768)
            .write_buffer_size(0)
            .max_write_buffer_size(2 * (MAX_CHUNK + 50))
            .max_message_size(Some(MAX_CHUNK + 50))
            .max_frame_size(Some(MAX_CHUNK + 50));
        let (mut socket, response) = tokio::time::timeout(
            Duration::from_secs(15),
            tokio_tungstenite::connect_async_with_config(request, Some(config), false),
        )
        .await
        .map_err(|_| BridgeError::Network)?
        .map_err(|_| BridgeError::Network)?;
        if response
            .headers()
            .get("Sec-WebSocket-Protocol")
            .and_then(|v| v.to_str().ok())
            != Some("bridge-relay-v1")
        {
            return Err(invalid());
        }
        let open = read_frame(&mut socket, 15).await?;
        let desktop = checked(cloud_crypto::key(&s.connection.desktop_public_key))?;
        if open.kind != 1
            || open.binding != id(&s.connection.binding_id)?
            || open.payload != desktop
        {
            return Err(invalid());
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
            return Err(invalid());
        }
        checked(cloud_crypto::handshake_read(
            &mut handshake,
            &second.payload,
        ))?;
        let mut channel = Channel {
            socket,
            cipher: checked(ControlCipher::new(handshake))?,
            binding: open.binding,
            channel: open.channel,
        };
        if channel.control(15).await? != json!({"kind":"ready"}) {
            return Err(invalid());
        }
        channel.send(json!({"kind":"key_confirm"})).await?;
        if channel.control(15).await? != json!({"kind":"key_confirmed"}) {
            return Err(invalid());
        }
        channel
            .send(match pairing {
                Some(secret) => {
                    json!({"kind":"pair","secret":secret,"preview_public_key":s.preview_public})
                }
                None => json!({"kind":"authorize","preview_public_key":s.preview_public}),
            })
            .await?;
        let mut authorized = channel.control(15).await?;
        if pairing.is_some() && authorized == json!({"kind":"pair_pending"}) {
            authorized = channel.control(300).await?;
        }
        let preview = authorized["desktop_preview_public_key"]
            .as_str()
            .ok_or_else(invalid)?;
        checked(cloud_crypto::key(preview))?;
        if authorized["kind"] != "authorized"
            || (!s.desktop_preview_public.is_empty() && s.desktop_preview_public != preview)
        {
            return Err(invalid());
        }
        if s.desktop_preview_public.is_empty() {
            if pairing.is_none() {
                return Err(invalid());
            }
            self.secret.write().unwrap().desktop_preview_public = preview.into();
        }
        Ok(channel)
    }
    pub(crate) async fn request(
        &self,
        method: Method,
        path: &str,
        body: Option<Vec<u8>>,
        content_type: &str,
    ) -> Result<Response> {
        if !matches!(method, Method::GET | Method::POST) {
            return Err(invalid());
        }
        let body = if method == Method::GET {
            Vec::new()
        } else {
            body.unwrap_or_else(|| b"{}".to_vec())
        };
        if body.len() > MAX_FILE {
            return Err(BridgeError::TooLarge);
        }
        let mut channel = self.connect(None).await?;
        channel.send(json!({"kind":"request","id":Uuid::new_v4(),"method":method.as_str(),"path":path,
            "content_type":if content_type.is_empty() { "application/json" } else { content_type },"headers":{},"length":body.len()})).await?;
        let mut credits = credit(&channel.control(15).await?)?;
        for chunk in body.chunks(MAX_CHUNK - 1) {
            if credits == 0 {
                credits = credit(&channel.control(15).await?)?;
            }
            credits -= 1;
            let mut data = vec![1];
            data.extend_from_slice(chunk);
            channel.send_data(&data).await?;
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
            if key == "Content-Type" {
                sse = text.starts_with("text/event-stream");
            }
            response = response.header(key, text);
        }
        let (tx, rx) =
            tokio::sync::mpsc::channel::<std::result::Result<Vec<u8>, std::io::Error>>(4);
        channel.send(json!({"kind":"credit","count":4})).await?;
        tokio::spawn(async move {
            let mut total = 0usize;
            let result: Result<()> = async {
                loop {
                    let data = tokio::select! { _ = tx.closed() => return Ok(()), v = channel.receive(80) => v? };
                    if data.first() == Some(&1) {
                        total = total.saturating_add(data.len()-1);
                        if !sse && total > MAX_FILE { return Err(BridgeError::TooLarge); }
                        if tx.send(Ok(data[1..].to_vec())).await.is_err() { return Ok(()); }
                        channel.send(json!({"kind":"credit","count":1})).await?;
                    } else if data.first() == Some(&0) && serde_json::from_slice::<Value>(&data[1..])? == json!({"kind":"response_end"}) {
                        return Ok(());
                    } else { return Err(invalid()); }
                }
            }.await;
            if result.is_err() {
                let _ = tx
                    .send(Err(std::io::Error::other("encrypted relay disconnected")))
                    .await;
            }
            let _ = channel.socket.close(None).await;
        });
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
    fn explicit_origin_and_invitation_boundaries() {
        let value = json!({"v":1,"origin":"https://relay.test","gateway_id":Uuid::new_v4(),"desktop_public_key":b64(&[7;32]),"pairing_id":Uuid::new_v4(),"secret":"a".repeat(43)});
        let qr = format!(
            "bridge-relay://pair?data={}",
            URL_SAFE_NO_PAD.encode(serde_json::to_vec(&value).unwrap())
        );
        assert_eq!(invitation_origin(&qr).unwrap(), "https://relay.test");
        assert!(invitation_origin(&(qr.clone() + "&other=1")).is_err());
        assert!(invitation_origin(&(qr + "#secret")).is_err());
        assert!(cloud_crypto::exact_origin("https://RELAY.test").is_err());
        assert!(cloud_crypto::exact_origin("https://relay.test:443").is_err());
    }

    fn secrets() -> (AccountSecrets, BindingSecrets) {
        let account = AccountSecrets {
            origin: "https://relay.test".into(),
            account_id: Uuid::new_v4().to_string(),
            login: "user".into(),
            access_token: "access".into(),
            refresh_token: "refresh".into(),
            access_deadline: now() + 3600,
            installation_id: Uuid::new_v4().to_string(),
            control_private: b64(&[7; 32]),
            device_token: "a".repeat(43),
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
        };
        (account, binding)
    }

    #[test]
    fn account_token_rotation_preserves_all_pins_and_preview_keys() {
        let (account, binding) = secrets();
        let raw = serde_json::to_string(&binding).unwrap();
        let updated =
            updated_binding_credentials(&raw, &serde_json::to_string(&account).unwrap()).unwrap();
        let mut expected: Value = serde_json::from_str(&raw).unwrap();
        expected["device_token"] = account.device_token.clone().into();
        assert_eq!(serde_json::from_str::<Value>(&updated).unwrap(), expected);
    }

    #[test]
    fn token_updates_reject_origin_account_installation_and_control_key_changes() {
        let (account, binding) = secrets();
        let raw = serde_json::to_string(&binding).unwrap();
        let value = serde_json::to_value(&account).unwrap();
        for (field, changed) in [
            ("origin", "https://other.test"),
            ("account_id", "other-account"),
            ("installation_id", "other-installation"),
            ("control_private", "other-key"),
            ("device_token", ""),
        ] {
            let mut altered = value.clone();
            altered[field] = changed.into();
            assert!(updated_binding_credentials(&raw, &altered.to_string()).is_err());
        }
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
    fn refresh_consumption_is_explicit_and_cannot_be_reused() {
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
            ""
        );
        assert!(credential_state(&consumed, &account.origin, &account.account_id).is_err());
        assert!(credential_state(&raw, "https://other.test", &account.account_id).is_err());
    }
}
