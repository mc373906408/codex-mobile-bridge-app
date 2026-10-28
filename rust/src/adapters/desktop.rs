use serde_json::Value;

use super::{approvals, array, finish_snapshot, messages, text};
use crate::api::types::*;
use crate::error::{BridgeError, Result};
use crate::transport::Transport;

pub async fn sessions(
    transport: &Transport,
    computer: &str,
    provider: Provider,
    query: &str,
    offset: u32,
) -> Result<SessionPage> {
    let value = transport
        .get(
            &format!("/api/desktop-sessions/{}/list", provider.slug()),
            &[],
        )
        .await?;
    let raw = value["sessions"]
        .as_array()
        .ok_or_else(|| BridgeError::Protocol("missing desktop session list".into()))?;
    let query = query.to_lowercase();
    let all: Vec<_> = raw
        .iter()
        .filter(|row| {
            query.is_empty()
                || format!("{} {}", text(row, "title"), text(row, "cwd"))
                    .to_lowercase()
                    .contains(&query)
        })
        .filter_map(|row| {
            let id = row["id"].as_str()?.to_owned();
            Some(SessionSummary {
                session: SessionRef {
                    computer_id: computer.into(),
                    provider,
                    environment: row["host"].as_str().unwrap_or("local").into(),
                    id,
                },
                title: text(row, "title"),
                cwd: text(row, "cwd"),
                updated_at: row
                    .get("updatedAt")
                    .map(Value::to_string)
                    .unwrap_or_default(),
                status: text(row, "status"),
                backend: text(row, "backend"),
            })
        })
        .collect();
    let has_more = all.len() > offset as usize + 100;
    Ok(SessionPage {
        sessions: all.into_iter().skip(offset as usize).take(100).collect(),
        next_offset: has_more.then_some(offset + 100),
        notice: if value["connected"] == false {
            "Client unavailable; configure it on the computer".into()
        } else {
            text(&value, "notice")
        },
    })
}

pub fn parse_history(value: &Value) -> Result<HistoryPage> {
    let rows = value["messages"]
        .as_array()
        .ok_or_else(|| BridgeError::Protocol("missing desktop history".into()))?;
    Ok(HistoryPage {
        messages: messages(rows),
        before: value["history"]["before"].as_str().map(str::to_owned),
        has_more: value["history"]["hasMore"] == true,
        epoch: value["history"]["epoch"]
            .as_str()
            .unwrap_or_default()
            .into(),
        reset: value["history"]["reset"] == true,
    })
}

pub async fn detail(
    transport: &Transport,
    session: &SessionRef,
    before: Option<&str>,
) -> Result<Value> {
    let mut query = vec![
        ("sessionId", session.id.clone()),
        ("historyLimit", "40".into()),
    ];
    if let Some(before) = before {
        query.push(("historyBefore", before.into()));
    }
    transport
        .get(
            &format!("/api/desktop-sessions/{}/detail", session.provider.slug()),
            &query,
        )
        .await
}

pub fn parse_snapshot(
    value: &Value,
    session: &SessionRef,
    identity: &str,
    claude: bool,
) -> Result<SessionSnapshot> {
    let state = &value["session"];
    if state["id"].as_str() != Some(&session.id)
        || state["host"]
            .as_str()
            .is_some_and(|host| host != session.environment)
    {
        return Err(BridgeError::Protocol(
            "desktop session identity changed".into(),
        ));
    }
    let cli = claude && state["backend"] == "cli";
    let connected = value["connected"] != false
        && if cli {
            matches!(
                state["connectionState"].as_str(),
                Some("ready" | "active" | "awaiting")
            )
        } else {
            value["connected"] == true || state["connected"] == true
        };
    let caps = if value["capabilities"].is_object() {
        &value["capabilities"]
    } else {
        &state["capabilities"]
    };
    let running = state["status"] == "active";
    // These v2.1.6 desktop adapters have baseline send/stop/respond methods;
    // the optional booleans only restrict them. Unknown backends stay read-only.
    let known = if claude {
        matches!(state["backend"].as_str(), Some("cli" | "code" | "cowork"))
    } else {
        state["backend"] == "deepseek"
    };
    let capabilities = CapabilitySet {
        send: connected && known && caps["send"] != false,
        steer: connected && running && caps["steer"] == true,
        stop: connected && known && running && caps["stop"] != false,
        approve: connected && known && caps["respond"] != false,
        resume: cli && caps["resume"] == true,
        models: connected && caps["models"] == true,
        attachments: connected && caps["attachments"] == true,
        arbitrary_files: connected && cli && caps["attachments"] == true,
    };
    let requests = if capabilities.approve {
        approvals(array(state, "requests"), session.provider)
    } else {
        vec![]
    };
    let meta = serde_json::json!({"draftAccountIdentity":value.get("draftAccountIdentity").or_else(||state.get("draftAccountIdentity")),
        "runtime":state.get("runtime"),"provider":state.get("provider"),
        "activeTurnId":state.get("activeTurnId").or_else(||state.get("turnId"))});
    Ok(finish_snapshot(
        SessionSnapshot {
            session: session.clone(),
            title: text(state, "title"),
            cwd: text(state, "cwd"),
            connected,
            running,
            status: text(state, "status"),
            model: text(state, "model"),
            effort: text(state, "effort"),
            capabilities,
            approvals: requests,
            history: parse_history(value)?,
            control_token: String::new(),
            account_identity: String::new(),
            sequence: 0,
            notice: text(value, "notice"),
        },
        &meta,
        identity,
    ))
}
