use serde_json::{Value, json};

use super::codex::parse_sessions;

const SESSION_ID: &str = "11111111-1111-4111-8111-111111111111";
const SSH_READING: &str = "正在后台读取 SSH 主机；本机会话可正常使用。";

fn row(host: &str) -> Value {
    json!({"id": SESSION_ID, "host": host, "title": "Chat", "hostLabel": "Build server"})
}

#[test]
fn session_list_keeps_host_routing_and_detailed_partial_failure() {
    let value = json!({
        "sessions": [row("local"), row("ssh:lab")],
        "unavailableHosts": [{"host": "ssh:offline", "label": "Offline server", "error": "SSH connection refused"}]
    });
    let page = parse_sessions(&value, "desktop-a", 0).unwrap();
    assert_eq!(page.sessions.len(), 2);
    assert_eq!(page.sessions[0].session.environment, "local");
    assert_eq!(page.sessions[1].session.environment, "ssh:lab");
    assert_eq!(page.sessions[1].session.computer_id, "desktop-a");
    assert_eq!(page.sessions[1].environment_label, "Build server");
    assert!(page.notice.is_empty());
    let issue = &page.environment_issues[0];
    assert_eq!(issue.environment, "ssh:offline");
    assert_eq!(issue.label, "Offline server");
    assert_eq!(issue.reason, "SSH connection refused");
    assert!(!issue.loading);
}

#[test]
fn session_list_distinguishes_background_ssh_read_from_failure() {
    let value = json!({
        "sessions": [row("local")],
        "unavailableHosts": [{"host": "ssh:lab", "error": SSH_READING}]
    });
    let page = parse_sessions(&value, "desktop-a", 0).unwrap();
    assert!(page.environment_issues[0].loading);
    assert_eq!(page.environment_issues[0].reason, SSH_READING);
}

#[test]
fn session_list_never_substitutes_local_for_unknown_host() {
    for host in [Value::Null, json!(""), json!(" "), json!(5)] {
        let value = json!({"sessions": [{"id": SESSION_ID, "host": host}]});
        assert!(parse_sessions(&value, "desktop-a", 0).is_err());
    }
}

#[test]
fn session_list_rejects_malformed_diagnostics_instead_of_hiding_them() {
    for issues in [
        json!({}),
        json!([{"host": "ssh:lab"}]),
        json!([{"error": "Read failed"}]),
        json!([{"host": "", "error": "Read failed"}]),
    ] {
        let value = json!({"sessions": [row("local")], "unavailableHosts": issues});
        assert!(parse_sessions(&value, "desktop-a", 0).is_err());
    }
}

#[test]
fn session_list_without_diagnostics_remains_compatible() {
    let value = json!({"sessions": [row("local")]});
    assert!(
        parse_sessions(&value, "desktop-a", 0)
            .unwrap()
            .environment_issues
            .is_empty()
    );
}
