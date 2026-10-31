use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::StreamExt;
use reqwest::Method;
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;

use crate::adapters::{self, array, text};
use crate::api::types::*;
use crate::error::{BridgeError, Result};
use crate::events::SseDecoder;
use crate::persistence::{Store, unknown};
use crate::security::validate_session;
use crate::transport::{MAX_FILE, Transport};

pub struct Engine {
    pub computer: Computer,
    pub transport: Transport,
    pub store: Arc<Store>,
    writes: tokio::sync::Mutex<()>,
    subscriptions: Mutex<HashMap<String, Arc<CancellationToken>>>,
}

mod attachments;
mod controls;
mod creation;
mod notifications;
mod subscriptions;

impl Engine {
    pub fn new(
        computer: Computer,
        path: &str,
        platform: &str,
        credentials: Option<&str>,
    ) -> Result<Self> {
        let transport = Transport::for_computer(&computer, platform, credentials)?;
        let store = Arc::new(Store::open(path)?);
        Ok(Self {
            computer,
            transport,
            store,
            writes: tokio::sync::Mutex::new(()),
            subscriptions: Mutex::new(HashMap::new()),
        })
    }

    pub async fn clients(&self) -> Result<Vec<ClientInfo>> {
        let value = self.transport.get("/api/clients", &[]).await?;
        Ok(array(&value, "clients")
            .iter()
            .filter_map(|row| {
                let provider = match row["id"].as_str()? {
                    "codex" => Provider::Codex,
                    "claude" => Provider::Claude,
                    "deepseek" => Provider::Deepseek,
                    _ => return None,
                };
                Some(ClientInfo {
                    provider,
                    enabled: row["enabled"] == true,
                    connected: row["connected"] == true,
                    readable: row["enabled"] == true
                        && (row["connected"] == true
                            || provider == Provider::Claude && row["cliAvailable"] == true
                            || provider == Provider::Codex),
                    reason: row
                        .get("reason")
                        .or_else(|| row.get("error"))
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .into(),
                })
            })
            .collect())
    }

    pub async fn snapshot(&self, session: &SessionRef) -> Result<SessionSnapshot> {
        validate_session(session, &self.computer.id)?;
        if !self.transport.status().authenticated {
            return Err(BridgeError::Unauthenticated);
        }
        adapters::snapshot(&self.transport, session).await
    }

    async fn preflight(&self, session: &SessionRef, token: &str) -> Result<SessionSnapshot> {
        let current = self.snapshot(session).await?;
        if token.is_empty() || current.control_token != token {
            return Err(BridgeError::Invalid(
                "Session state or account changed. Refresh before trying again".into(),
            ));
        }
        Ok(current)
    }

    async fn mutate(
        &self,
        session: &SessionRef,
        current: &SessionSnapshot,
        action: &str,
        id: &str,
        mut body: Value,
    ) -> Result<OperationOutcome> {
        if session.provider != Provider::Codex {
            body["sessionId"] = json!(session.id);
            body["id"] = json!(id);
            if action == "resume" {
                body.as_object_mut().unwrap().remove("activate");
            }
        }
        let scope = Store::scope(session, &current.account_identity)?;
        // Validate and serialize before committing intent; no network write precedes this commit.
        if serde_json::to_vec(&body)?.len() > 512_000 {
            return Err(BridgeError::TooLarge);
        }
        if let Some(existing) = self.store.begin(id, &scope, action, &body)? {
            return Ok(existing);
        }
        let (path, query) = adapters::route(session, action);
        let result = self.transport.post(&path, &query, &body).await;
        let outcome = classify(id, session.provider, action, result);
        self.store.finish(&outcome)?;
        Ok(outcome)
    }

    pub fn cancel(&self, id: &str) {
        if let Some(token) = self.subscriptions.lock().unwrap().remove(id) {
            token.cancel();
        }
    }

    pub fn pause(&self) {
        for (_, token) in self.subscriptions.lock().unwrap().drain() {
            token.cancel();
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.pause();
    }
}

fn classify(id: &str, provider: Provider, action: &str, result: Result<Value>) -> OperationOutcome {
    match result {
        Ok(value) => {
            let accepted = matches!(value["status"].as_str(), Some("accepted" | "ready"))
                || provider == Provider::Codex
                    && (value["applied"] == true
                        || value["ok"] == true
                        || value["accepted"] == true
                        || value["interrupted"] == true);
            let blocked = value["status"] == "blocked"
                && (action == "resume"
                    || action == "create" && value["code"] == "workspace-trust-required");
            OperationOutcome {
                id: id.into(),
                kind: if accepted {
                    OutcomeKind::Accepted
                } else if blocked {
                    OutcomeKind::NotSubmitted
                } else {
                    OutcomeKind::Unknown
                },
                message: if accepted {
                    "Gateway acknowledged the operation".into()
                } else {
                    value["message"]
                        .as_str()
                        .unwrap_or(
                            "Check the result on the computer; this operation will not be replayed",
                        )
                        .into()
                },
                created_session: None,
            }
        }
        Err(BridgeError::Http {
            status: 400,
            code,
            message,
        }) if code == "send_not_submitted" => OperationOutcome {
            id: id.into(),
            kind: OutcomeKind::NotSubmitted,
            message,
            created_session: None,
        },
        Err(error) => unknown(id, &error.to_string()),
    }
}
