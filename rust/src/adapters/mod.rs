pub mod claude;
pub mod codex;
pub mod deepseek;
mod desktop;

use serde_json::{Value, json};

use crate::api::types::*;
use crate::error::{BridgeError, Result};
use crate::security::fingerprint;
use crate::transport::Transport;

pub fn text(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

pub fn array<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value
        .get(key)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

fn clipped(value: &str) -> (String, bool) {
    let text: String = value.chars().take(32_768).collect();
    let truncated = text.len() < value.len();
    (text, truncated)
}

pub fn messages(rows: &[Value]) -> Vec<ChatMessage> {
    rows.iter()
        .rev()
        .take(200)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .map(|row| {
            let raw = text(row, "text");
            let (body, clipped_text) = clipped(&raw);
            let (output, clipped_output) = clipped(&text(row, "output"));
            let id = row
                .get("key")
                .or_else(|| row.get("id"))
                .filter(|v| !v.is_null())
                .map(|v| {
                    v.as_str()
                        .map(str::to_owned)
                        .unwrap_or_else(|| v.to_string())
                })
                .unwrap_or_else(|| fingerprint(row));
            let attachments = array(row, "attachments")
                .iter()
                .filter_map(|item| {
                    let upload = item
                        .get("uploadId")
                        .or_else(|| item.get("id"))
                        .and_then(Value::as_str);
                    let desktop = item.get("desktopId").and_then(Value::as_str);
                    let (id, source) =
                        if let Some(id) = upload.filter(|id| uuid::Uuid::parse_str(id).is_ok()) {
                            (id, "upload")
                        } else {
                            let id = desktop.filter(|id| {
                                id.len() == 64 && id.bytes().all(|c| c.is_ascii_hexdigit())
                            })?;
                            (id, "desktop")
                        };
                    Some(Attachment {
                        id: id.into(),
                        name: text(item, "name"),
                        image: item["image"] == true
                            || text(item, "mime").starts_with("image/")
                            || matches!(
                                text(item, "type").as_str(),
                                "image" | "localImage" | "toolImage"
                            ),
                        source: source.into(),
                    })
                })
                .take(8)
                .collect();
            ChatMessage {
                id,
                role: text(row, "role"),
                title: text(row, "title"),
                text: body,
                output,
                truncated: clipped_text || clipped_output || row["truncated"] == true,
                attachments,
            }
        })
        .collect()
}

fn questions(params: &Value) -> Vec<ApprovalQuestion> {
    array(params, "questions")
        .iter()
        .take(8)
        .enumerate()
        .map(|(index, q)| ApprovalQuestion {
            id: q
                .get("id")
                .or_else(|| q.get("key"))
                .or_else(|| q.get("question"))
                .and_then(Value::as_str)
                .map(str::to_owned)
                .unwrap_or_else(|| index.to_string()),
            question: text(q, "question"),
            multiple: q["multiSelect"] == true,
            secret: q["isSecret"] == true,
            options: array(q, "options")
                .iter()
                .take(16)
                .map(|option| QuestionOption {
                    label: text(option, "label"),
                    description: text(option, "description"),
                })
                .collect(),
        })
        .collect()
}

pub fn approvals(rows: &[Value], provider: Provider) -> Vec<ApprovalRequest> {
    rows.iter()
        .take(30)
        .filter(|row| !row["id"].is_null())
        .map(|row| {
            let wire_id = row["id"].to_string();
            let id = row["id"]
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| wire_id.clone());
            let params = if provider == Provider::Codex {
                &row["params"]
            } else if row["needsInput"] == true {
                &row["input"]
            } else {
                row
            };
            let kind = if provider == Provider::Codex {
                match text(row, "method").as_str() {
                    "item/commandExecution/requestApproval" => ApprovalKind::Command,
                    "item/fileChange/requestApproval" => ApprovalKind::FileChange,
                    "item/tool/requestUserInput" | "tool/requestUserInput" => {
                        ApprovalKind::Questions
                    }
                    _ => ApprovalKind::Unsupported,
                }
            } else if row["needsInput"] == true {
                ApprovalKind::Questions
            } else if row["supported"] != false
                && row["tool"].is_string()
                && row["input"].is_object()
            {
                ApprovalKind::Command
            } else {
                ApprovalKind::Unsupported
            };
            let supported = kind != ApprovalKind::Unsupported && row["supported"] != false;
            let offered = array(params, "availableDecisions");
            let allows = |choice: &str| {
                offered.is_empty() || offered.iter().any(|v| v.as_str() == Some(choice))
            };
            let qs = questions(params);
            let detail = if provider == Provider::Codex {
                match kind {
                    ApprovalKind::Command => [
                        text(params, "command"),
                        text(params, "cwd"),
                        text(params, "reason"),
                    ]
                    .into_iter()
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join("\n"),
                    ApprovalKind::FileChange => {
                        serde_json::to_string_pretty(params).unwrap_or_default()
                    }
                    _ => text(params, "message"),
                }
            } else {
                format!(
                    "{}\n{}",
                    text(row, "tool"),
                    serde_json::to_string_pretty(&row["input"]).unwrap_or_default()
                )
            };
            let (detail, truncated) = clipped(&detail);
            let supported = supported && !truncated && array(params, "questions").len() <= 8;
            ApprovalRequest {
                id,
                wire_id,
                kind,
                title: if provider == Provider::Codex {
                    text(row, "method")
                } else {
                    text(row, "tool")
                },
                detail,
                supported,
                can_accept: supported
                    && allows("accept")
                    && (kind != ApprovalKind::Questions || !qs.is_empty()),
                can_decline: supported && kind != ApprovalKind::Questions && allows("decline"),
                questions: qs,
                fingerprint: fingerprint(row),
            }
        })
        .collect()
}

pub fn finish_snapshot(
    mut snapshot: SessionSnapshot,
    meta: &Value,
    gateway_identity: &str,
) -> SessionSnapshot {
    let account = meta
        .get("draftAccountIdentity")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if account.is_empty() || gateway_identity.is_empty() {
        snapshot.account_identity.clear();
        snapshot.capabilities = CapabilitySet::default();
        snapshot.approvals.clear();
        snapshot.notice =
            "Account identity is unavailable. Refresh or continue on the computer".into();
    } else {
        snapshot.account_identity = fingerprint(&(gateway_identity, account, &snapshot.session));
    }
    snapshot.control_token = fingerprint(&json!({
        "session":snapshot.session,"account":snapshot.account_identity,
        "connected":snapshot.connected,"running":snapshot.running,"status":snapshot.status,
        "caps":snapshot.capabilities,"requests":snapshot.approvals,
        "model":snapshot.model,"effort":snapshot.effort,
        "runtime":meta.get("runtime").or_else(||meta.get("access").and_then(|v|v.get("runtime"))),
        "provider":meta.get("provider"),"cwd":snapshot.cwd,
        "turn":meta.get("activeTurnId").or_else(||meta.get("turnId")),
        "tail":snapshot.history.messages.last().map(|row| &row.id),
        "lastUser":snapshot.history.messages.iter().rev().find(|row| row.role == "user").map(|row| &row.id),
    }));
    snapshot
}

pub async fn snapshot(transport: &Transport, session: &SessionRef) -> Result<SessionSnapshot> {
    match session.provider {
        Provider::Codex => codex::snapshot(transport, session).await,
        Provider::Claude => claude::snapshot(transport, session).await,
        Provider::Deepseek => deepseek::snapshot(transport, session).await,
    }
}

pub async fn history(
    transport: &Transport,
    session: &SessionRef,
    before: &str,
) -> Result<HistoryPage> {
    if before.len() > 16_384 {
        return Err(BridgeError::Invalid("History cursor is too large".into()));
    }
    match session.provider {
        Provider::Codex => codex::history(transport, session, Some(before)).await,
        Provider::Claude => claude::history(transport, session, before).await,
        Provider::Deepseek => deepseek::history(transport, session, before).await,
    }
}

pub async fn sessions(
    transport: &Transport,
    computer: &str,
    provider: Provider,
    query: &str,
    offset: u32,
) -> Result<SessionPage> {
    match provider {
        Provider::Codex => codex::sessions(transport, computer, query, offset).await,
        Provider::Claude => claude::sessions(transport, computer, query, offset).await,
        Provider::Deepseek => deepseek::sessions(transport, computer, query, offset).await,
    }
}

pub fn route(session: &SessionRef, action: &str) -> (String, Vec<(&'static str, String)>) {
    if session.provider == Provider::Codex {
        (
            format!("/api/sessions/{}/{}", session.id, action),
            vec![("host", session.environment.clone())],
        )
    } else {
        (
            format!(
                "/api/desktop-sessions/{}/{}",
                session.provider.slug(),
                action
            ),
            vec![("sessionId", session.id.clone())],
        )
    }
}

pub async fn catalog(transport: &Transport, session: &SessionRef) -> Result<Vec<ModelOption>> {
    let (path, mut query) = route(session, "catalog");
    query.push((
        if session.provider == Provider::Codex {
            "kind"
        } else {
            "section"
        },
        "models".into(),
    ));
    let value = transport.get(&path, &query).await?;
    Ok(array(&value, "models")
        .iter()
        .filter(|v| v["selectable"] != false)
        .filter_map(|row| {
            let id = row
                .get("id")
                .or_else(|| row.get("model"))
                .and_then(Value::as_str)?
                .to_owned();
            let name = row
                .get("name")
                .or_else(|| row.get("displayName"))
                .or_else(|| row.get("label"))
                .and_then(Value::as_str)
                .unwrap_or(&id)
                .to_owned();
            let efforts = array(row, "efforts")
                .iter()
                .filter_map(|item| {
                    item.as_str()
                        .or_else(|| item.get("id").and_then(Value::as_str))
                })
                .map(str::to_owned)
                .collect();
            Some(ModelOption {
                id,
                name,
                efforts,
                default_effort: text(row, "defaultEffort"),
            })
        })
        .collect())
}

pub async fn projects(
    transport: &Transport,
    provider: Provider,
    environment: &str,
) -> Result<Vec<ProjectOption>> {
    let (path, query) = if provider == Provider::Codex {
        (
            "/api/projects".to_owned(),
            if environment.starts_with("wsl:") {
                vec![("entry", environment.to_owned())]
            } else {
                vec![]
            },
        )
    } else {
        (
            format!("/api/desktop-sessions/{}/projects", provider.slug()),
            vec![],
        )
    };
    let value = transport.get(&path, &query).await?;
    Ok(array(&value, "projects")
        .iter()
        .filter_map(|row| {
            let key = row.get("key").and_then(Value::as_str)?.to_owned();
            Some(ProjectOption {
                key,
                name: row
                    .get("name")
                    .or_else(|| row.get("label"))
                    .and_then(Value::as_str)
                    .unwrap_or("Project")
                    .into(),
                cwd: text(row, "cwd"),
                environment: if environment.starts_with("wsl:") {
                    environment.into()
                } else {
                    row.get("host")
                        .and_then(Value::as_str)
                        .unwrap_or("local")
                        .into()
                },
                requires_message: value["createRequiresMessage"] == true
                    || row["createRequiresMessage"] == true,
                provider,
            })
        })
        .collect())
}
