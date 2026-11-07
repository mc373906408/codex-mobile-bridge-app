use serde_json::Value;

use crate::api::types::EnvironmentIssue;
use crate::error::{BridgeError, Result};

const SSH_READING: &str = "正在后台读取 SSH 主机；本机会话可正常使用。";

pub(super) fn parse(value: &Value) -> Result<Vec<EnvironmentIssue>> {
    let Some(raw) = value.get("unavailableHosts") else {
        return Ok(vec![]);
    };
    raw.as_array()
        .ok_or_else(|| BridgeError::Protocol("invalid environment diagnostics".into()))?
        .iter()
        .map(issue)
        .collect()
}

fn issue(value: &Value) -> Result<EnvironmentIssue> {
    let environment = required_text(value, "host")?;
    let reason = required_text(value, "error")?;
    Ok(EnvironmentIssue {
        environment: environment.into(),
        label: value["label"].as_str().unwrap_or_default().into(),
        reason: reason.into(),
        loading: reason == SSH_READING,
    })
}

fn required_text<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value[key]
        .as_str()
        .filter(|text| !text.trim().is_empty())
        .ok_or_else(|| BridgeError::Protocol(format!("missing environment diagnostic {key}")))
}
