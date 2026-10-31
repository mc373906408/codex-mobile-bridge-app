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

    pub async fn send(
        &self,
        session: &SessionRef,
        token: &str,
        id: &str,
        message: String,
        attachments: Vec<String>,
        steer: bool,
    ) -> Result<OperationOutcome> {
        let _guard = self.writes.lock().await;
        let current = self.preflight(session, token).await?;
        if !current.capabilities.send
            || steer && !current.capabilities.steer
            || current.running && !steer
        {
            return Err(BridgeError::Invalid(
                "This session cannot use the selected send mode".into(),
            ));
        }
        if (message.trim().is_empty() && attachments.is_empty())
            || message.chars().count() > 100_000
            || attachments.len() > 8
        {
            return Err(BridgeError::Invalid("Message is empty or too large".into()));
        }
        if !attachments.is_empty() && !current.capabilities.attachments {
            return Err(BridgeError::Invalid("Attachments are not supported".into()));
        }
        for attachment in &attachments {
            uuid::Uuid::parse_str(attachment)
                .map_err(|_| BridgeError::Invalid("Invalid attachment ID".into()))?;
        }
        let body = json!({"text":message,"attachments":attachments,"mode":if steer {"steer"} else {"send"},"id":id});
        self.mutate(session, &current, "send", id, body).await
    }

    pub async fn stop(
        &self,
        session: &SessionRef,
        token: &str,
        id: &str,
    ) -> Result<OperationOutcome> {
        let _guard = self.writes.lock().await;
        let current = self.preflight(session, token).await?;
        if !current.capabilities.stop {
            return Err(BridgeError::Invalid(
                "There is no confirmed running task to stop".into(),
            ));
        }
        self.mutate(session, &current, "stop", id, json!({})).await
    }

    pub async fn resume(
        &self,
        session: &SessionRef,
        token: &str,
        id: &str,
    ) -> Result<OperationOutcome> {
        let _guard = self.writes.lock().await;
        let current = self.preflight(session, token).await?;
        if !current.capabilities.resume {
            return Err(BridgeError::Invalid("Resume is not available".into()));
        }
        self.mutate(
            session,
            &current,
            if session.provider == Provider::Codex {
                "reconnect"
            } else {
                "resume"
            },
            id,
            json!({"activate":true}),
        )
        .await
    }

    pub async fn respond(
        &self,
        session: &SessionRef,
        token: &str,
        id: &str,
        request_id: &str,
        accept: bool,
        answers: Vec<QuestionAnswer>,
    ) -> Result<OperationOutcome> {
        let _guard = self.writes.lock().await;
        let current = self.preflight(session, token).await?;
        let approval = current
            .approvals
            .iter()
            .find(|request| request.id == request_id)
            .ok_or_else(|| {
                BridgeError::Invalid("This approval has expired or was already handled".into())
            })?;
        if !current.capabilities.approve
            || !approval.supported
            || (accept && !approval.can_accept)
            || (!accept && !approval.can_decline)
        {
            return Err(BridgeError::Invalid(
                "Handle this request on the computer".into(),
            ));
        }
        let mut answer_map = serde_json::Map::new();
        if approval.kind == ApprovalKind::Questions {
            if answers.len() != approval.questions.len() {
                return Err(BridgeError::Invalid("Answer every question".into()));
            }
            for question in &approval.questions {
                let answer = answers
                    .iter()
                    .find(|a| a.question_id == question.id)
                    .ok_or_else(|| BridgeError::Invalid("Missing answer".into()))?;
                if answer.values.is_empty()
                    || answer
                        .values
                        .iter()
                        .any(|a| a.trim().is_empty() || a.chars().count() > 20_000)
                {
                    return Err(BridgeError::Invalid("Invalid answer".into()));
                }
                answer_map.insert(
                    question.id.clone(),
                    if session.provider == Provider::Codex {
                        json!(answer.values)
                    } else {
                        json!({"answers":answer.values})
                    },
                );
            }
        }
        let decision = if accept { "accept" } else { "decline" };
        let wire_id: Value = serde_json::from_str(&approval.wire_id)?;
        let body = if session.provider == Provider::Codex {
            json!({"requestId":wire_id,"response":if approval.kind==ApprovalKind::Questions {json!({"answers":answer_map})} else {json!({"decision":decision})}})
        } else {
            json!({"requestId":wire_id,"decision":decision,"answers":answer_map})
        };
        self.mutate(session, &current, "respond", id, body).await
    }

    pub async fn settings(
        &self,
        session: &SessionRef,
        token: &str,
        id: &str,
        model: String,
        effort: String,
    ) -> Result<OperationOutcome> {
        let _guard = self.writes.lock().await;
        let current = self.preflight(session, token).await?;
        if !current.capabilities.models {
            return Err(BridgeError::Invalid(
                "Model settings are not available".into(),
            ));
        }
        let models = adapters::catalog(&self.transport, session).await?;
        let offered = models
            .iter()
            .find(|option| option.id == model)
            .ok_or_else(|| BridgeError::Invalid("Select an advertised model".into()))?;
        if !offered.efforts.is_empty() && !offered.efforts.contains(&effort) {
            return Err(BridgeError::Invalid(
                "Select an advertised reasoning effort".into(),
            ));
        }
        let mut body = json!({"model":model});
        if !offered.efforts.is_empty() {
            body["effort"] = json!(effort);
        }
        self.mutate(session, &current, "settings", id, body).await
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

    pub async fn create(
        &self,
        project: ProjectOption,
        title: String,
        message: String,
        id: &str,
    ) -> Result<OperationOutcome> {
        let _guard = self.writes.lock().await;
        if title.chars().count() > 120
            || title.trim().is_empty()
            || message.chars().count() > 100_000
        {
            return Err(BridgeError::Invalid(
                "Invalid new-chat title or message".into(),
            ));
        }
        if !self.transport.authenticate().await?.authenticated {
            return Err(BridgeError::Unauthenticated);
        }
        let projects =
            adapters::projects(&self.transport, project.provider, &project.environment).await?;
        let offered = projects
            .into_iter()
            .find(|p| p.key == project.key && p.environment == project.environment)
            .ok_or_else(|| BridgeError::Invalid("The project is no longer available".into()))?;
        if offered.requires_message && message.trim().is_empty() {
            return Err(BridgeError::Invalid(
                "This client requires an opening message".into(),
            ));
        }
        let scope_session = SessionRef {
            computer_id: self.computer.id.clone(),
            provider: project.provider,
            environment: project.environment.clone(),
            id: format!("create:{}", project.key),
        };
        let scope = Store::scope(&scope_session, &self.transport.identity())?;
        let body = if project.provider == Provider::Codex {
            json!({"id":id,"project":project.key,"title":title})
        } else {
            json!({"id":id,"projectKey":project.key,"title":title,"text":message})
        };
        if let Some(existing) = self.store.begin(id, &scope, "create", &body)? {
            return Ok(existing);
        }
        let (path, query) = if project.provider == Provider::Codex {
            (
                "/api/sessions".into(),
                if project.environment.starts_with("wsl:") {
                    vec![("entry", project.environment.clone())]
                } else {
                    vec![]
                },
            )
        } else {
            (
                format!("/api/desktop-sessions/{}/create", project.provider.slug()),
                vec![],
            )
        };
        let result = self.transport.post(&path, &query, &body).await;
        let mut outcome = classify(
            id,
            project.provider,
            "create",
            result
                .as_ref()
                .map(Clone::clone)
                .map_err(|_| BridgeError::Network),
        );
        if let Ok(value) = result {
            let sid = if project.provider == Provider::Codex {
                value["id"].as_str()
            } else {
                value["sessionId"]
                    .as_str()
                    .or_else(|| value["session"]["id"].as_str())
            };
            if let Some(sid) = sid.filter(|sid| *sid != id) {
                let created = SessionRef {
                    computer_id: self.computer.id.clone(),
                    provider: project.provider,
                    environment: value["host"]
                        .as_str()
                        .unwrap_or(&project.environment)
                        .into(),
                    id: sid.into(),
                };
                if validate_session(&created, &self.computer.id).is_ok()
                    && (outcome.kind == OutcomeKind::Accepted
                        || project.provider == Provider::Codex && value.get("opened").is_some())
                {
                    outcome.kind = OutcomeKind::Accepted;
                    outcome.message =
                        "Chat created; continuing is a separate explicit action".into();
                    outcome.created_session = Some(created);
                }
            }
        }
        self.store.finish(&outcome)?;
        Ok(outcome)
    }

    pub async fn upload(
        &self,
        session: &SessionRef,
        token: &str,
        id: &str,
        name: String,
        bytes: Vec<u8>,
    ) -> Result<Attachment> {
        let _guard = self.writes.lock().await;
        let current = self.preflight(session, token).await?;
        if !current.capabilities.attachments
            || bytes.is_empty()
            || bytes.len() > MAX_FILE
            || name.is_empty()
            || name.len() > 255
            || name.chars().any(char::is_control)
        {
            return Err(BridgeError::Invalid(
                "Attachment is unsupported or exceeds 20 MiB".into(),
            ));
        }
        uuid::Uuid::parse_str(id).map_err(|_| BridgeError::Invalid("Invalid upload ID".into()))?;
        let image = bytes.starts_with(b"\x89PNG\r\n\x1a\n")
            || bytes.starts_with(b"\xff\xd8\xff")
            || bytes.starts_with(b"GIF8")
            || bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP");
        if !image && !current.capabilities.arbitrary_files {
            return Err(BridgeError::Invalid(
                "This client accepts image attachments only".into(),
            ));
        }
        use sha2::{Digest, Sha256};
        let scope = Store::scope(session, &current.account_identity)?;
        let body = json!({"name":name,"sha256":format!("{:x}", Sha256::digest(&bytes))});
        let attachment = Attachment {
            id: id.into(),
            name: name.clone(),
            image,
            source: "upload".into(),
        };
        if let Some(existing) = self.store.begin(id, &scope, "upload", &body)? {
            return if existing.kind == OutcomeKind::Accepted {
                Ok(attachment)
            } else {
                Err(BridgeError::Invalid(existing.message))
            };
        }
        let (path, mut query) = adapters::route(session, "uploads");
        query.push(("id", id.into()));
        query.push(("name", name.clone()));
        let result = async {
            let response = self
                .transport
                .request(
                    Method::POST,
                    &path,
                    &query,
                    Some(bytes),
                    "application/octet-stream",
                )
                .await?;
            Transport::decode(response).await
        }
        .await;
        let outcome = match result {
            Ok(result) if result["id"].as_str() == Some(id) => OperationOutcome {
                id: id.into(),
                kind: OutcomeKind::Accepted,
                message: "Attachment stored by the gateway".into(),
                created_session: None,
            },
            Ok(_) => unknown(id, "Upload was not acknowledged; check it on the computer"),
            Err(error) => unknown(id, &error.to_string()),
        };
        self.store.finish(&outcome)?;
        if outcome.kind == OutcomeKind::Accepted {
            Ok(attachment)
        } else {
            Err(BridgeError::Invalid(outcome.message))
        }
    }

    pub async fn image(&self, session: &SessionRef, attachment: &Attachment) -> Result<Vec<u8>> {
        validate_session(session, &self.computer.id)?;
        let (path, query) =
            if attachment.source == "upload" && uuid::Uuid::parse_str(&attachment.id).is_ok() {
                let (path, mut query) =
                    adapters::route(session, &format!("uploads/{}/preview", attachment.id));
                query.push(("variant", "original".into()));
                (path, query)
            } else if session.provider == Provider::Codex
                && attachment.source == "desktop"
                && attachment.id.len() == 64
                && attachment.id.bytes().all(|b| b.is_ascii_hexdigit())
            {
                adapters::route(session, &format!("desktop-images/{}", attachment.id))
            } else {
                return Err(BridgeError::Invalid("Unsupported image reference".into()));
            };
        let response = self
            .transport
            .request(Method::GET, &path, &query, None, "")
            .await?;
        if !response.status().is_success() {
            Transport::decode(response).await?;
            return Err(BridgeError::Invalid("Image is unavailable".into()));
        }
        let mime = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default();
        if !["image/png", "image/jpeg", "image/gif", "image/webp"]
            .iter()
            .any(|allowed| mime.split(';').next() == Some(*allowed))
        {
            return Err(BridgeError::Invalid(
                "Only raster images are rendered".into(),
            ));
        }
        Transport::bounded_bytes(response, MAX_FILE).await
    }

    pub async fn inbox(&self) -> Result<Vec<InboxEntry>> {
        if !self.transport.status().notifications {
            return Ok(vec![]);
        }
        let value = self
            .transport
            .get("/api/mobile/events", &[("after", "0".into())])
            .await?;
        Ok(array(&value, "events")
            .iter()
            .rev()
            .take(100)
            .map(|event| {
                let host = event["host"].as_str().unwrap_or("local");
                let provider = match host {
                    "desktop:claude" => Provider::Claude,
                    "desktop:deepseek" => Provider::Deepseek,
                    _ => Provider::Codex,
                };
                let session = event
                    .get("threadId")
                    .or_else(|| event.get("sessionId"))
                    .and_then(Value::as_str)
                    .map(|id| SessionRef {
                        computer_id: self.computer.id.clone(),
                        provider,
                        // Desktop events identify the provider, not the execution host.
                        // The UI resolves the original host from a fresh session list before opening.
                        environment: if provider == Provider::Codex {
                            host
                        } else {
                            "local"
                        }
                        .into(),
                        id: id.into(),
                    })
                    .filter(|session| validate_session(session, &self.computer.id).is_ok());
                InboxEntry {
                    id: cloud_notification(&self.computer, event)
                        .map(|(id, _)| format!("cloud:{id}"))
                        .unwrap_or_else(|| {
                            crate::security::fingerprint(&(
                                &self.computer.id,
                                self.transport.identity(),
                                &value["streamId"],
                                &event["id"],
                            ))
                        }),
                    title: text(event, "title"),
                    body: text(event, "body"),
                    session,
                }
            })
            .collect())
    }

    pub async fn notification_events(&self) -> Result<NotificationBatch> {
        tokio::time::timeout(std::time::Duration::from_secs(15), async {
            let status = self.transport.authenticate_if_needed().await?;
            if !status.authenticated {
                return Err(BridgeError::Unauthenticated);
            }
            if !status.notifications {
                return Ok(NotificationBatch {
                    enabled: false,
                    scope: String::new(),
                    events: vec![],
                });
            }
            let epoch = self.transport.authentication_epoch();
            let identity = self.transport.identity();
            let value = self
                .transport
                .get("/api/mobile/events", &[("after", "0".into())])
                .await?;
            if epoch != self.transport.authentication_epoch()
                || !self.transport.status().authenticated
            {
                return Err(BridgeError::Cancelled);
            }
            let stream = value["streamId"]
                .as_str()
                .filter(|v| !v.is_empty() && v.len() <= 256)
                .ok_or_else(|| {
                    BridgeError::Protocol("missing notification stream identity".into())
                })?;
            let events = value["events"]
                .as_array()
                .ok_or_else(|| BridgeError::Protocol("missing notification events".into()))?;
            let scope = if self.computer.connection_type == ConnectionType::Relay {
                value["notification_scope"]
                    .as_str()
                    .filter(|s| {
                        s.len() == 64
                            && s.bytes()
                                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                    })
                    .map(String::from)
            } else {
                None
            }
            .unwrap_or_else(|| {
                crate::security::fingerprint(&(&self.computer.id, &identity, stream))
            });
            let events = events
                .iter()
                .rev()
                .take(200)
                .filter_map(|event| {
                    let id = event["id"]
                        .as_str()
                        .filter(|v| !v.is_empty() && v.len() <= 256)?;
                    let kind = event["kind"]
                        .as_str()
                        .filter(|v| matches!(*v, "completion" | "request"))?;
                    let created_at = event["createdAt"]
                        .as_f64()
                        .filter(|v| v.is_finite() && *v > 0.0)?;
                    let host = event["host"].as_str().unwrap_or("local");
                    let provider = match host {
                        "desktop:claude" => Provider::Claude,
                        "desktop:deepseek" => Provider::Deepseek,
                        _ => Provider::Codex,
                    };
                    let session = event
                        .get("threadId")
                        .or_else(|| event.get("sessionId"))
                        .and_then(Value::as_str)
                        .map(|id| SessionRef {
                            computer_id: self.computer.id.clone(),
                            provider,
                            environment: if provider == Provider::Codex {
                                host
                            } else {
                                "local"
                            }
                            .into(),
                            id: id.into(),
                        })
                        .filter(|session| validate_session(session, &self.computer.id).is_ok());
                    let cloud = cloud_notification(&self.computer, event);
                    Some(NotificationEvent {
                        // Match the inbox ID without exposing any notification content.
                        id: cloud
                            .as_ref()
                            .map(|(id, _)| format!("cloud:{id}"))
                            .unwrap_or_else(|| {
                                crate::security::fingerprint(&(
                                    &self.computer.id,
                                    &identity,
                                    &value["streamId"],
                                    &serde_json::Value::String(id.into()),
                                ))
                            }),
                        kind: kind.into(),
                        created_at,
                        session,
                        notification_id: cloud.as_ref().map(|(id, _)| id.clone()),
                        expires_at: cloud.map(|(_, expires)| expires),
                    })
                })
                .collect();
            Ok(NotificationBatch {
                enabled: true,
                scope,
                events,
            })
        })
        .await
        .map_err(|_| BridgeError::Network)?
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

    pub async fn watch(
        &self,
        session: SessionRef,
        id: String,
        mut emit: impl FnMut(GatewayEvent) -> bool + Send,
    ) -> Result<()> {
        validate_session(&session, &self.computer.id)?;
        let token = Arc::new(CancellationToken::new());
        let previous = self
            .subscriptions
            .lock()
            .unwrap()
            .insert(id.clone(), token.clone());
        if let Some(previous) = previous {
            previous.cancel();
        }
        let work = async {
            let mut failures = 0u32;
            let mut use_sse =
                session.provider == Provider::Codex && self.transport.status().transport == "sse";
            loop {
                let result = async {
                    let current = self.snapshot(&session).await?;
                    let sequence = current.sequence;
                    let running = current.running;
                    if !emit(GatewayEvent {
                        subscription_id: id.clone(),
                        snapshot: Some(current),
                        authentication_required: false,
                        message: String::new(),
                    }) {
                        return Err(BridgeError::Cancelled);
                    }
                    if use_sse {
                        self.sse(&session, &id, &mut emit).await
                    } else if session.provider == Provider::Codex {
                        let (path, mut query) = adapters::route(&session, "poll");
                        query.push(("after", sequence.to_string()));
                        self.transport.get(&path, &query).await?;
                        Ok(())
                    } else {
                        tokio::time::sleep(Duration::from_secs(if running { 1 } else { 3 })).await;
                        Ok(())
                    }
                }
                .await;
                match result {
                    Ok(()) => {
                        failures = 0;
                    }
                    Err(BridgeError::Cancelled) => break,
                    Err(error) => {
                        let auth = matches!(error, BridgeError::Unauthenticated);
                        if !emit(GatewayEvent {
                            subscription_id: id.clone(),
                            snapshot: None,
                            authentication_required: auth,
                            message: error.to_string(),
                        }) || auth
                        {
                            break;
                        }
                        failures = failures.saturating_add(1);
                        if failures >= 3 {
                            use_sse = false;
                        }
                        tokio::time::sleep(Duration::from_millis(500 * (1u64 << failures.min(5))))
                            .await;
                    }
                }
            }
        };
        tokio::select! { _=token.cancelled()=>{}, _=work=>{} }
        let mut subscriptions = self.subscriptions.lock().unwrap();
        // A cancelled stream must not remove a newer subscription with the same ID.
        if subscriptions
            .get(&id)
            .is_some_and(|active| Arc::ptr_eq(active, &token))
        {
            subscriptions.remove(&id);
        }
        Ok(())
    }

    async fn sse(
        &self,
        session: &SessionRef,
        id: &str,
        emit: &mut (impl FnMut(GatewayEvent) -> bool + Send),
    ) -> Result<()> {
        let (path, query) = adapters::route(session, "events");
        let epoch = self.transport.authentication_epoch();
        let response = self
            .transport
            .request(Method::GET, &path, &query, None, "")
            .await?;
        if !response.status().is_success() {
            Transport::decode(response).await?;
            return Err(BridgeError::Network);
        }
        if !response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .starts_with("text/event-stream")
        {
            return Err(BridgeError::Protocol("expected an event stream".into()));
        }
        let mut stream = response.bytes_stream();
        let mut decoder = SseDecoder::default();
        while let Some(chunk) = stream.next().await {
            for event in decoder.feed(&chunk?)? {
                match event.as_str() {
                    "logout" => {
                        self.transport.invalidate_epoch(Some(epoch));
                        return Err(BridgeError::Unauthenticated);
                    }
                    "state" => {
                        // SSE is a live invalidation signal; the bounded timeline retains stable page keys.
                        let snapshot = self.snapshot(session).await?;
                        if !emit(GatewayEvent {
                            subscription_id: id.into(),
                            snapshot: Some(snapshot),
                            authentication_required: false,
                            message: String::new(),
                        }) {
                            return Err(BridgeError::Cancelled);
                        }
                    }
                    _ => {}
                }
            }
        }
        Err(BridgeError::Network)
    }
}

pub(crate) fn cloud_notification(computer: &Computer, event: &Value) -> Option<(String, i64)> {
    if computer.connection_type != ConnectionType::Relay || computer.relay.is_none() {
        return None;
    }
    let id = event["notification_id"].as_str()?;
    if uuid::Uuid::parse_str(id).ok()?.to_string() != id
        || event["notification_event_id"].as_str()? != format!("cloud:{id}")
    {
        return None;
    }
    let expires = event["notification_expires_at"].as_i64()?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs() as i64;
    (expires > now && expires <= now + 3600).then(|| (id.into(), expires))
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
