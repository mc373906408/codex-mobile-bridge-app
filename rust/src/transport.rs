use std::collections::BTreeMap;
use std::sync::RwLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use futures_util::StreamExt;
use reqwest::{Client, Method, Response, header};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::api::types::AuthStatus;
use crate::error::{BridgeError, Result};
use crate::security::GatewayAddress;

const MAX_JSON: usize = 8 * 1024 * 1024;
pub const MAX_FILE: usize = 20 * 1024 * 1024;

#[derive(Clone, Default, Deserialize, Serialize)]
struct Credentials {
    base_url: String,
    cookies: BTreeMap<String, String>,
    csrf: String,
    draft_identity: String,
}

pub struct Transport {
    pub address: GatewayAddress,
    client: Client,
    credentials: RwLock<Credentials>,
    status: RwLock<AuthStatus>,
    auth_lock: tokio::sync::Mutex<()>,
    credential_epoch: AtomicU64,
}

impl Transport {
    pub fn new(base_url: &str, platform: &str, saved: Option<&str>) -> Result<Self> {
        if !matches!(platform, "Android" | "iOS") {
            return Err(BridgeError::Invalid("Unsupported mobile platform".into()));
        }
        let (address, pairing) = GatewayAddress::parse(base_url)?;
        if pairing.is_some() {
            return Err(BridgeError::Address(
                "pairing secrets must not be saved as an address".into(),
            ));
        }
        let credentials = if let Some(saved) = saved {
            let value: Credentials = serde_json::from_str(saved)?;
            if value.base_url != address.base {
                return Err(BridgeError::Invalid(
                    "Credentials belong to a different gateway address".into(),
                ));
            }
            value
        } else {
            Credentials {
                base_url: address.base.clone(),
                ..Default::default()
            }
        };
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .connect_timeout(Duration::from_secs(10))
            .read_timeout(Duration::from_secs(30))
            .user_agent(format!("BridgeMobile/0.1.0-{platform} BridgeNative/0.1.0"))
            .build()?;
        Ok(Self {
            address,
            client,
            credentials: RwLock::new(credentials),
            status: RwLock::new(AuthStatus::default()),
            auth_lock: tokio::sync::Mutex::new(()),
            credential_epoch: AtomicU64::new(0),
        })
    }

    pub fn export_credentials(&self) -> Result<Option<String>> {
        let credentials = self.credentials.read().unwrap();
        if credentials.csrf.is_empty() {
            return Ok(None);
        }
        Ok(Some(serde_json::to_string(&*credentials)?))
    }

    pub fn identity(&self) -> String {
        self.credentials.read().unwrap().draft_identity.clone()
    }

    pub fn status(&self) -> AuthStatus {
        self.status.read().unwrap().clone()
    }

    pub fn invalidate(&self) {
        self.invalidate_epoch(None);
    }

    pub(crate) fn authentication_epoch(&self) -> u64 {
        self.credential_epoch.load(Ordering::Acquire)
    }

    pub(crate) fn invalidate_epoch(&self, expected: Option<u64>) {
        let mut credentials = self.credentials.write().unwrap();
        if expected.is_some_and(|epoch| epoch != self.credential_epoch.load(Ordering::Acquire)) {
            return;
        }
        self.credential_epoch.fetch_add(1, Ordering::AcqRel);
        *credentials = Credentials {
            base_url: self.address.base.clone(),
            ..Default::default()
        };
        *self.status.write().unwrap() = AuthStatus::default();
    }

    fn begin_authentication(&self) {
        let _credentials = self.credentials.write().unwrap();
        self.credential_epoch.fetch_add(1, Ordering::AcqRel);
        *self.status.write().unwrap() = AuthStatus::default();
    }

    fn capture_cookies(&self, response: &Response, epoch: u64) {
        let mut credentials = self.credentials.write().unwrap();
        if self.credential_epoch.load(Ordering::Acquire) != epoch {
            return;
        }
        for header in response.headers().get_all(header::SET_COOKIE) {
            let Ok(raw) = header.to_str() else { continue };
            let Ok(cookie) = cookie::Cookie::parse(raw.to_owned()) else {
                continue;
            };
            let name = cookie.name();
            if name != "codex_mobile_session" && !name.starts_with("codex_mobile_session_") {
                continue;
            }
            if cookie.secure() == Some(true) && !self.address.base.starts_with("https://") {
                continue;
            }
            if cookie.value().is_empty()
                || cookie.max_age().is_some_and(|age| age.whole_seconds() <= 0)
            {
                credentials.cookies.remove(name);
            } else {
                // The gateway has exactly one auth cookie, and may rename it.
                credentials.cookies.clear();
                credentials
                    .cookies
                    .insert(name.to_owned(), cookie.value().to_owned());
            }
        }
    }

    pub async fn request(
        &self,
        method: Method,
        path: &str,
        query: &[(&str, String)],
        body: Option<Vec<u8>>,
        content_type: &str,
    ) -> Result<Response> {
        let url = self.address.endpoint(path, query)?;
        let (cookie, csrf, epoch) = {
            let value = self.credentials.read().unwrap();
            (
                value
                    .cookies
                    .iter()
                    .map(|(k, v)| format!("{k}={v}"))
                    .collect::<Vec<_>>()
                    .join("; "),
                value.csrf.clone(),
                self.credential_epoch.load(Ordering::Acquire),
            )
        };
        let mut request = self
            .client
            .request(method.clone(), url)
            .header(header::ORIGIN, &self.address.origin)
            .header(header::ACCEPT, "application/json")
            .header(header::CACHE_CONTROL, "no-store");
        if !path.ends_with("/events") {
            request = request.timeout(Duration::from_secs(60));
        }
        if !cookie.is_empty() {
            request = request.header(header::COOKIE, cookie);
        }
        if method != Method::GET {
            if !csrf.is_empty() {
                request = request.header("X-CSRF-Token", csrf);
            }
            let bytes = body.unwrap_or_else(|| b"{}".to_vec());
            request = request
                .header(header::CONTENT_TYPE, content_type)
                .header(header::CONTENT_LENGTH, bytes.len())
                .body(bytes);
        }
        let response = request.send().await?;
        if response.status().is_redirection() {
            return Err(BridgeError::Redirect);
        }
        if response.status().as_u16() == 401 {
            // A late response from an old read must not revoke a newer login.
            self.invalidate_epoch(Some(epoch));
            return Err(BridgeError::Unauthenticated);
        }
        if response.status().is_success() {
            self.capture_cookies(&response, epoch);
        }
        Ok(response)
    }

    pub async fn bounded_bytes(response: Response, limit: usize) -> Result<Vec<u8>> {
        if response
            .content_length()
            .is_some_and(|length| length > limit as u64)
        {
            return Err(BridgeError::TooLarge);
        }
        let mut stream = response.bytes_stream();
        let mut data = Vec::new();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            if data.len() + chunk.len() > limit {
                return Err(BridgeError::TooLarge);
            }
            data.extend_from_slice(&chunk);
        }
        Ok(data)
    }

    pub async fn decode(response: Response) -> Result<Value> {
        let status = response.status();
        let bytes = Self::bounded_bytes(response, MAX_JSON).await?;
        let value: Value = serde_json::from_slice(&bytes)?;
        if !status.is_success() {
            return Err(BridgeError::Http {
                status: status.as_u16(),
                code: value
                    .get("code")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                message: value
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("Request failed")
                    .chars()
                    .take(500)
                    .collect(),
            });
        }
        if !value.is_object() {
            return Err(BridgeError::Protocol("expected an object".into()));
        }
        Ok(value)
    }

    pub async fn get(&self, path: &str, query: &[(&str, String)]) -> Result<Value> {
        Self::decode(
            self.request(Method::GET, path, query, None, "application/json")
                .await?,
        )
        .await
    }

    pub async fn post(&self, path: &str, query: &[(&str, String)], value: &Value) -> Result<Value> {
        let body = serde_json::to_vec(value)?;
        if body.len() > 512_000 {
            return Err(BridgeError::TooLarge);
        }
        let request = self.request(Method::POST, path, query, Some(body), "application/json");
        let response = tokio::time::timeout(Duration::from_secs(60), request)
            .await
            .map_err(|_| BridgeError::Network)??;
        Self::decode(response).await
    }

    pub async fn authenticate(&self) -> Result<AuthStatus> {
        let _guard = self.auth_lock.lock().await;
        self.begin_authentication();
        self.authenticate_inner().await
    }

    async fn authenticate_inner(&self) -> Result<AuthStatus> {
        let value = self.get("/api/auth", &[]).await?;
        if value["authenticated"] != true {
            self.invalidate();
            return Ok(AuthStatus {
                passwordless: value["passwordless"] == true,
                ..Default::default()
            });
        }
        let csrf = value["csrf"]
            .as_str()
            .filter(|v| !v.is_empty())
            .ok_or_else(|| BridgeError::Protocol("missing CSRF token".into()))?;
        let mut credentials = self.credentials.write().unwrap();
        credentials.csrf = csrf.to_owned();
        credentials.draft_identity = value["draftIdentity"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| crate::security::fingerprint(&(&self.address.base, csrf)));
        let status = AuthStatus {
            authenticated: true,
            computer_name: value["computer"]["name"]
                .as_str()
                .unwrap_or_default()
                .into(),
            platform: value["computer"]["platform"]
                .as_str()
                .unwrap_or_default()
                .into(),
            passwordless: value["passwordless"] == true,
            notifications: value["notifications"] == true,
            transport: if value["transport"] == "poll" {
                "poll"
            } else {
                "sse"
            }
            .into(),
        };
        *self.status.write().unwrap() = status.clone();
        Ok(status)
    }

    pub async fn login(&self, username: String, password: String) -> Result<AuthStatus> {
        let _guard = self.auth_lock.lock().await;
        if username.len() > 200 || password.len() > 1000 {
            return Err(BridgeError::Invalid("Invalid login input".into()));
        }
        self.begin_authentication();
        self.post(
            "/api/login",
            &[],
            &json!({"username":username,"password":password,"remember":true}),
        )
        .await?;
        self.authenticate_inner().await
    }

    pub async fn pair(&self, token: String) -> Result<AuthStatus> {
        let _guard = self.auth_lock.lock().await;
        if token.len() != 43
            || !token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err(BridgeError::Invalid(
                "Invalid or expired pairing code".into(),
            ));
        }
        self.begin_authentication();
        self.post("/api/pair", &[], &json!({"token":token})).await?;
        self.authenticate_inner().await
    }

    pub async fn logout(&self) -> Result<()> {
        let _guard = self.auth_lock.lock().await;
        let result = self.post("/api/logout", &[], &json!({})).await;
        self.invalidate();
        result.map(|_| ())
    }
}
