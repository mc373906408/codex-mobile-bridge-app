use serde_json::Value;

use super::{approvals, array, finish_snapshot, messages, text};
use crate::api::types::*;
use crate::error::{BridgeError, Result};
use crate::transport::Transport;

const SESSION_PAGE_SIZE: usize = 100;

pub async fn sessions(
    transport: &Transport,
    computer: &str,
    query: &str,
    offset: u32,
) -> Result<SessionPage> {
    let value = transport
        .get(
            "/api/sessions",
            &[
                ("q", query.chars().take(200).collect()),
                ("offset", offset.to_string()),
                ("source", "all".into()),
            ],
        )
        .await?;
    parse_sessions(&value, computer, offset)
}

pub(crate) fn parse_sessions(value: &Value, computer: &str, offset: u32) -> Result<SessionPage> {
    let raw = value["sessions"]
        .as_array()
        .ok_or_else(|| BridgeError::Protocol("missing session list".into()))?;
    let rows = raw
        .iter()
        .map(|row| session_row(row, computer))
        .collect::<Result<Vec<_>>>()?;
    Ok(SessionPage {
        sessions: rows,
        next_offset: if raw.len() >= SESSION_PAGE_SIZE {
            Some(offset + raw.len() as u32)
        } else {
            None
        },
        notice: String::new(),
        environment_issues: super::environment_issues::parse(value)?,
    })
}

fn session_row(row: &Value, computer: &str) -> Result<SessionSummary> {
    let id = row["id"]
        .as_str()
        .and_then(|id| uuid::Uuid::parse_str(id).ok())
        .ok_or_else(|| BridgeError::Protocol("invalid session identifier".into()))?;
    let environment = row["host"]
        .as_str()
        .filter(|host| !host.trim().is_empty())
        .ok_or_else(|| BridgeError::Protocol("missing session execution host".into()))?;
    Ok(SessionSummary {
        session: SessionRef {
            computer_id: computer.into(),
            provider: Provider::Codex,
            environment: environment.into(),
            id: id.to_string(),
        },
        title: text(row, "title"),
        cwd: text(row, "cwd"),
        updated_at: row
            .get("updatedAt")
            .map(Value::to_string)
            .unwrap_or_default(),
        status: text(row, "status"),
        backend: text(row, "source"),
        environment_label: text(row, "hostLabel"),
    })
}

fn parse_history(value: &Value) -> Result<HistoryPage> {
    let rows = value["rows"]
        .as_array()
        .ok_or_else(|| BridgeError::Protocol("missing timeline rows".into()))?;
    Ok(HistoryPage {
        messages: messages(rows),
        before: value["before"].as_str().map(str::to_owned),
        has_more: value["hasMore"] == true,
        epoch: text(value, "epoch"),
        reset: value["reset"] == true,
    })
}

pub async fn history(
    transport: &Transport,
    session: &SessionRef,
    before: Option<&str>,
) -> Result<HistoryPage> {
    let mut query = vec![
        ("host", session.environment.clone()),
        ("limit", "40".into()),
    ];
    if let Some(before) = before {
        query.push(("before", before.into()));
    }
    let value = transport
        .get(&format!("/api/sessions/{}/timeline", session.id), &query)
        .await?;
    parse_history(&value)
}

pub async fn snapshot(transport: &Transport, session: &SessionRef) -> Result<SessionSnapshot> {
    let value = transport
        .get(
            &format!("/api/sessions/{}/timeline", session.id),
            &[
                ("host", session.environment.clone()),
                ("limit", "40".into()),
            ],
        )
        .await?;
    parse_snapshot(&value, session, &transport.identity())
}

pub fn parse_snapshot(
    value: &Value,
    session: &SessionRef,
    identity: &str,
) -> Result<SessionSnapshot> {
    let meta = &value["meta"];
    if meta["id"].as_str() != Some(&session.id)
        || meta["host"]
            .as_str()
            .is_some_and(|host| host != session.environment)
    {
        return Err(BridgeError::Protocol("timeline identity changed".into()));
    }
    let connected = meta["connected"] == true;
    let running = matches!(
        meta["status"].as_str(),
        Some("active" | "inProgress" | "running")
    );
    let access = &meta["access"];
    let capabilities = CapabilitySet {
        send: connected && access["canSend"] == true,
        steer: connected && running && access["canSend"] == true,
        stop: connected && running && access["canInterrupt"] == true,
        approve: connected && access["canApprove"] == true,
        resume: access["canReconnect"] == true && !connected,
        models: connected && access["canChangeModel"] == true,
        attachments: connected && access["canSend"] == true,
        arbitrary_files: connected && access["canSend"] == true,
    };
    let requests = if capabilities.approve {
        approvals(array(meta, "requests"), Provider::Codex)
    } else {
        vec![]
    };
    Ok(finish_snapshot(
        SessionSnapshot {
            session: session.clone(),
            title: text(meta, "title"),
            cwd: text(meta, "cwd"),
            connected,
            running,
            status: text(meta, "status"),
            model: text(meta, "model"),
            effort: text(meta, "effort"),
            capabilities,
            approvals: requests,
            history: parse_history(value)?,
            control_token: String::new(),
            account_identity: String::new(),
            sequence: value["sequence"].as_i64().unwrap_or(-1),
            notice: text(meta, "connectionError"),
        },
        meta,
        identity,
    ))
}
