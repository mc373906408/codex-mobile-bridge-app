//! P2P is a runtime path of the same authenticated cloud binding.
use super::*;
use std::sync::{
    Mutex, Weak,
    atomic::{AtomicU64, Ordering},
};

#[derive(Default)]
pub(super) struct Links {
    relay: Mutex<Option<Weak<session::Session>>>,
    direct: Mutex<Option<Arc<session::Session>>>,
    epoch: AtomicU64,
    pub relay_tx: AtomicU64,
    pub relay_rx: AtomicU64,
    pub p2p_tx: AtomicU64,
    pub p2p_rx: AtomicU64,
}

impl Links {
    pub fn direct(&self) -> Option<Arc<session::Session>> {
        self.direct
            .lock()
            .unwrap()
            .as_ref()
            .filter(|s| !s.closed.is_cancelled() && !s.quiesce.is_cancelled())
            .cloned()
    }
    pub fn connected(&self) -> bool {
        self.direct().is_some()
            || self
                .relay
                .lock()
                .unwrap()
                .as_ref()
                .and_then(Weak::upgrade)
                .is_some_and(|s| !s.closed.is_cancelled() && !s.quiesce.is_cancelled())
    }
    pub fn register(&self, session: &Arc<session::Session>, direct: bool) {
        if direct {
            if let Some(old) = self.direct.lock().unwrap().replace(session.clone()) {
                old.quiesce.cancel();
            }
        } else {
            *self.relay.lock().unwrap() = Some(Arc::downgrade(session));
        }
    }
    pub fn pause(&self, revoke: bool) {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        if let Some(session) = self.direct.lock().unwrap().take() {
            if revoke {
                session.closed.cancel();
            } else {
                session.quiesce.cancel();
            }
        }
    }
    pub fn snapshot(&self) -> RelayTransportStatus {
        RelayTransportStatus {
            path: if self.direct().is_some() {
                "p2p"
            } else {
                "relay"
            }
            .into(),
            connected: self.connected(),
            relay_sent: self.relay_tx.load(Ordering::Relaxed),
            relay_received: self.relay_rx.load(Ordering::Relaxed),
            p2p_sent: self.p2p_tx.load(Ordering::Relaxed),
            p2p_received: self.p2p_rx.load(Ordering::Relaxed),
        }
    }
}

pub(super) fn check_signal(
    links: Arc<Links>,
    authority: Arc<RwLock<BindingSecrets>>,
    signal: Value,
    status: tokio::sync::watch::Sender<String>,
) {
    let secret = authority.read().unwrap().clone();
    if signal["kind"] != "access_changed"
        || signal["origin"] != secret.connection.origin
        || signal["account_id"] != secret.connection.account_id
        || signal["device_id"] != secret.installation_id
        || (signal["binding_id"] != "" && signal["binding_id"] != secret.connection.binding_id)
    {
        return;
    }
    let epoch = links.epoch.load(Ordering::Acquire);
    tokio::spawn(async move {
        // Only server TLS messages reach this path. A fresh result also prevents
        // a delayed expiry notice from undoing a renewal or local reauthorization.
        let result = api(
            &secret.connection.origin,
            "/v1/mobile/bindings",
            Method::GET,
            None,
            &secret.device_token,
        )
        .await;
        if links.epoch.load(Ordering::Acquire) != epoch
            || authority.read().unwrap().device_token != secret.device_token
        {
            return;
        }
        let denied = match result {
            Ok(value) => {
                value["access"]["origin"] == secret.connection.origin
                    && value["access"]["account_id"] == secret.connection.account_id
                    && value["access"]["device_id"] == secret.installation_id
                    && value["bindings"].as_array().is_some_and(|rows| {
                        rows.iter().any(|row| {
                            row["id"] == secret.connection.binding_id
                                && row["access_allowed"] == false
                        })
                    })
            }
            Err(BridgeError::Relay(code)) => matches!(
                code.as_str(),
                "access_denied"
                    | "authentication_required"
                    | "entitlement_required"
                    | "login_required"
            ),
            Err(BridgeError::Http {
                status: 401..=403, ..
            }) => true,
            _ => false,
        };
        if denied {
            links.pause(true);
            if let Some(relay) = links.relay.lock().unwrap().as_ref().and_then(Weak::upgrade) {
                relay.closed.cancel();
            }
            status.send_replace("access_denied".into());
        }
    });
}

pub(super) fn upgrade(
    links: Arc<Links>,
    secret: BindingSecrets,
    offer: tokio::sync::oneshot::Receiver<Value>,
    status: tokio::sync::watch::Sender<String>,
) {
    let epoch = links.epoch.load(Ordering::Acquire);
    tokio::spawn(async move {
        let Ok(Ok(value)) = tokio::time::timeout(Duration::from_secs(40), offer).await else {
            return;
        };
        while links.epoch.load(Ordering::Acquire) == epoch {
            let attempt = async {
                if value["kind"] != "p2p_offer"
                    || value["protocol"] != "easytier-v1"
                    || value["binding_id"] != secret.connection.binding_id
                {
                    return Err(invalid());
                }
                let settings: bridge_p2p::Settings =
                    serde_json::from_value(value["settings"].clone())?;
                if settings.desktop || value["offer_id"] != settings.network {
                    return Err(invalid());
                }
                let runtime = bridge_p2p::Runtime::start(settings)
                    .await
                    .map_err(|_| BridgeError::Network)?;
                let mut request = format!("ws://127.0.0.1:{}/bridge-p2p", runtime.local_port)
                    .into_client_request()
                    .map_err(|_| invalid())?;
                request.headers_mut().insert(
                    "X-Bridge-Binding",
                    secret
                        .connection
                        .binding_id
                        .parse()
                        .map_err(|_| invalid())?,
                );
                request.headers_mut().insert(
                    "X-Bridge-P2P",
                    value["offer_id"]
                        .as_str()
                        .ok_or_else(invalid)?
                        .parse()
                        .map_err(|_| invalid())?,
                );
                request
                    .headers_mut()
                    .insert("Sec-WebSocket-Protocol", "bridge-p2p-v1".parse().unwrap());
                // Retry only connection establishment. No business request exists yet.
                let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
                loop {
                    if links.epoch.load(Ordering::Acquire) != epoch {
                        return Err(BridgeError::Cancelled);
                    }
                    let connected = tokio::time::timeout(
                        Duration::from_secs(5),
                        tokio_tungstenite::connect_async_with_config(
                            request.clone(),
                            Some(socket_config()),
                            false,
                        ),
                    )
                    .await;
                    if let Ok(Ok((socket, response))) = connected {
                        if response
                            .headers()
                            .get("Sec-WebSocket-Protocol")
                            .and_then(|v| v.to_str().ok())
                            != Some("bridge-p2p-v1")
                        {
                            return Err(invalid());
                        }
                        let mut channel = authenticate_channel(&secret, socket, false, None)
                            .await?
                            .ok_or_else(invalid)?;
                        channel.direct = true;
                        channel.p2p_available = false;
                        channel.runtime = Some(runtime);
                        channel.links = Some(links.clone());
                        return Ok(channel);
                    }
                    if tokio::time::Instant::now() >= deadline {
                        return Err(BridgeError::Network);
                    }
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            };
            let outcome = attempt.await;
            if let Err(error) = &outcome {
                eprintln!(
                    "p2p_upgrade_failed category={:?}",
                    std::mem::discriminant(error)
                );
            }
            if let Ok(channel) = outcome
                && links.epoch.load(Ordering::Acquire) == epoch
            {
                let session = session::Session::start(channel, status.clone());
                links.register(&session, true);
                if let Some(relay) = links.relay.lock().unwrap().as_ref().and_then(Weak::upgrade) {
                    relay.migrate_events();
                }
                status.send_replace("connected".into());
                session.closed.cancelled().await;
            }
            if links.epoch.load(Ordering::Acquire) != epoch {
                break;
            }
            if links
                .relay
                .lock()
                .unwrap()
                .as_ref()
                .and_then(Weak::upgrade)
                .is_none_or(|s| s.closed.is_cancelled())
            {
                break;
            }
            tokio::time::sleep(Duration::from_secs(15)).await;
        }
    });
}
