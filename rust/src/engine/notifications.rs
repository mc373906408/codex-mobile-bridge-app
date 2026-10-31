use super::*;

const MAX_INBOX_EVENTS: usize = 100;
const MAX_NOTIFICATION_EVENTS: usize = 200;
const MAX_EVENT_ID_BYTES: usize = 256;
const NOTIFICATION_SCOPE_HEX_BYTES: usize = 64;
const NOTIFICATION_TIMEOUT_SECONDS: u64 = 15;
const MAX_NOTIFICATION_LIFETIME_SECONDS: i64 = 3600;

struct NotificationContext<'a> {
    computer: &'a Computer,
    identity: &'a str,
    stream: &'a Value,
}

impl Engine {
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
            .take(MAX_INBOX_EVENTS)
            .map(|event| {
                let identity = self.transport.identity();
                let context = NotificationContext {
                    computer: &self.computer,
                    identity: &identity,
                    stream: &value["streamId"],
                };
                let cloud = cloud_notification(&self.computer, event);
                InboxEntry {
                    id: event_identity(&context, event, cloud.as_ref().map(|(id, _)| id.as_str())),
                    title: text(event, "title"),
                    body: text(event, "body"),
                    session: notification_session(&self.computer, event),
                }
            })
            .collect())
    }

    pub async fn notification_events(&self) -> Result<NotificationBatch> {
        tokio::time::timeout(
            Duration::from_secs(NOTIFICATION_TIMEOUT_SECONDS),
            self.read_notification_batch(),
        )
        .await
        .map_err(|_| BridgeError::Network)?
    }

    async fn read_notification_batch(&self) -> Result<NotificationBatch> {
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
        if epoch != self.transport.authentication_epoch() || !self.transport.status().authenticated
        {
            return Err(BridgeError::Cancelled);
        }
        let stream = value["streamId"]
            .as_str()
            .filter(|stream| !stream.is_empty() && stream.len() <= MAX_EVENT_ID_BYTES)
            .ok_or_else(|| BridgeError::Protocol("missing notification stream identity".into()))?;
        let events = value["events"]
            .as_array()
            .ok_or_else(|| BridgeError::Protocol("missing notification events".into()))?;
        let context = NotificationContext {
            computer: &self.computer,
            identity: &identity,
            stream: &value["streamId"],
        };
        let scope = notification_scope(&context, &value, stream);
        let events = events
            .iter()
            .rev()
            .take(MAX_NOTIFICATION_EVENTS)
            .filter_map(|event| parse_notification(&context, event))
            .collect();
        Ok(NotificationBatch {
            enabled: true,
            scope,
            events,
        })
    }
}

fn notification_session(computer: &Computer, event: &Value) -> Option<SessionRef> {
    let host = event["host"].as_str().unwrap_or("local");
    let provider = match host {
        "desktop:claude" => Provider::Claude,
        "desktop:deepseek" => Provider::Deepseek,
        _ => Provider::Codex,
    };
    event
        .get("threadId")
        .or_else(|| event.get("sessionId"))
        .and_then(Value::as_str)
        .map(|id| SessionRef {
            computer_id: computer.id.clone(),
            provider,
            // Desktop events name the provider, not the original execution host.
            environment: if provider == Provider::Codex {
                host
            } else {
                "local"
            }
            .into(),
            id: id.into(),
        })
        .filter(|session| validate_session(session, &computer.id).is_ok())
}

fn notification_scope(context: &NotificationContext<'_>, value: &Value, stream: &str) -> String {
    let scope = if context.computer.connection_type == ConnectionType::Relay {
        value["notification_scope"].as_str().filter(|scope| {
            scope.len() == NOTIFICATION_SCOPE_HEX_BYTES
                && scope
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        })
    } else {
        None
    };
    scope.map(String::from).unwrap_or_else(|| {
        crate::security::fingerprint(&(&context.computer.id, context.identity, stream))
    })
}

fn event_identity(
    context: &NotificationContext<'_>,
    event: &Value,
    cloud_id: Option<&str>,
) -> String {
    cloud_id.map(|id| format!("cloud:{id}")).unwrap_or_else(|| {
        crate::security::fingerprint(&(
            &context.computer.id,
            context.identity,
            context.stream,
            &event["id"],
        ))
    })
}

fn parse_notification(
    context: &NotificationContext<'_>,
    event: &Value,
) -> Option<NotificationEvent> {
    event["id"]
        .as_str()
        .filter(|id| !id.is_empty() && id.len() <= MAX_EVENT_ID_BYTES)?;
    let kind = event["kind"]
        .as_str()
        .filter(|kind| matches!(*kind, "completion" | "request"))?;
    let created_at = event["createdAt"]
        .as_f64()
        .filter(|value| value.is_finite() && *value > 0.0)?;
    let cloud = cloud_notification(context.computer, event);
    Some(NotificationEvent {
        id: event_identity(context, event, cloud.as_ref().map(|(id, _)| id.as_str())),
        kind: kind.into(),
        created_at,
        session: notification_session(context.computer, event),
        notification_id: cloud.as_ref().map(|(id, _)| id.clone()),
        expires_at: cloud.map(|(_, expires)| expires),
    })
}

fn cloud_notification(computer: &Computer, event: &Value) -> Option<(String, i64)> {
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
    (expires > now && expires <= now + MAX_NOTIFICATION_LIFETIME_SECONDS)
        .then(|| (id.into(), expires))
}
