use std::{sync::Arc, time::Duration};

use serde_json::{Value, json};
use wiremock::{
    Mock, MockServer, ResponseTemplate,
    matchers::{body_partial_json, header, method, path, query_param},
};

use crate::{adapters, api::types::*, engine::Engine, error::BridgeError, transport::Transport};

const SID: &str = "11111111-1111-4111-8111-111111111111";

fn timeline() -> Value {
    json!({"epoch":"timeline-a","sequence":7,"rows":[{"key":"row-1","role":"assistant","text":"Synthetic answer"}],"before":"cursor-1","hasMore":true,
        "meta":{"id":SID,"host":"local","title":"Synthetic session","cwd":"/synthetic/project","connected":true,"status":"idle","model":"model-a","effort":"high",
        "draftAccountIdentity":"account-a","access":{"canSend":true,"canInterrupt":true,"canApprove":true,"canReconnect":true,"canChangeModel":true},"requests":[]}})
}

fn desktop(provider: Provider) -> Value {
    json!({"connected":true,"capabilities":{"send":true,"stop":true,"steer":true,"models":true,"attachments":true},
        "draftAccountIdentity":"account-a","session":{"id":"opaque/session:not-a-uuid","title":"Synthetic desktop session","cwd":"/synthetic/project","host":"ssh:lab","status":"idle","model":"model-a","requests":[],
        "backend":if provider==Provider::Claude {"cli"} else {"deepseek"},"connectionState":"ready"},
        "messages":[{"id":"message-a","role":"assistant","text":"Synthetic desktop answer"}],"history":{"before":"cursor-d","hasMore":true}})
}

async fn auth(server: &MockServer, transport: &str) {
    Mock::given(method("GET")).and(path("/api/auth"))
        .respond_with(ResponseTemplate::new(200).insert_header("Set-Cookie","codex_mobile_session_rotated=synthetic-cookie; Path=/; HttpOnly; SameSite=Strict")
        .set_body_json(json!({"authenticated":true,"csrf":"synthetic-csrf","cookieName":"codex_mobile_session_rotated","draftIdentity":"gateway-a","transport":transport,"computer":{"name":"Test computer","platform":"Windows"}})))
        .mount(server).await;
}

async fn setup(provider: Provider) -> (MockServer, tempfile::TempDir, Arc<Engine>, SessionRef) {
    let server = MockServer::start().await;
    auth(&server, "poll").await;
    let directory = tempfile::tempdir().unwrap();
    let engine = Arc::new(
        Engine::new(
            Computer {
                id: "pc-a".into(),
                name: "Synthetic".into(),
                base_url: server.uri(),
                connection_type: crate::api::types::ConnectionType::Direct,
                relay: None,
            },
            directory.path().join("state.sqlite").to_str().unwrap(),
            "Android",
            None,
        )
        .unwrap(),
    );
    engine.transport.authenticate().await.unwrap();
    let session = SessionRef {
        computer_id: "pc-a".into(),
        provider,
        environment: if provider == Provider::Codex {
            "local"
        } else {
            "ssh:lab"
        }
        .into(),
        id: if provider == Provider::Codex {
            SID
        } else {
            "opaque/session:not-a-uuid"
        }
        .into(),
    };
    (server, directory, engine, session)
}

async fn mount_snapshot(server: &MockServer, provider: Provider) {
    let endpoint = if provider == Provider::Codex {
        format!("/api/sessions/{SID}/timeline")
    } else {
        format!("/api/desktop-sessions/{}/detail", provider.slug())
    };
    let value = if provider == Provider::Codex {
        timeline()
    } else {
        desktop(provider)
    };
    Mock::given(method("GET"))
        .and(path(endpoint))
        .respond_with(ResponseTemplate::new(200).set_body_json(value))
        .mount(server)
        .await;
}

#[tokio::test]
async fn authentication_dynamic_cookie_origin_csrf_content_length_and_mobile_ua() {
    let (server, _dir, engine, session) = setup(Provider::Codex).await;
    mount_snapshot(&server, Provider::Codex).await;
    let current = engine.snapshot(&session).await.unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    Mock::given(method("POST"))
        .and(path(format!("/api/sessions/{SID}/send")))
        .and(header("Origin", server.uri()))
        .and(header("X-CSRF-Token", "synthetic-csrf"))
        .and(header(
            "Cookie",
            "codex_mobile_session_rotated=synthetic-cookie",
        ))
        .and(query_param("host", "local"))
        .and(body_partial_json(
            json!({"id":id,"text":"Hello","mode":"send"}),
        ))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({"status":"accepted","id":id})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let result = engine
        .send(
            &session,
            &current.control_token,
            &id,
            "Hello".into(),
            vec![],
            false,
        )
        .await
        .unwrap();
    assert_eq!(result.kind, OutcomeKind::Accepted);
    let requests = server.received_requests().await.unwrap();
    let request = requests.iter().find(|r| r.method == "POST").unwrap();
    assert_eq!(
        request
            .headers
            .get("content-length")
            .unwrap()
            .to_str()
            .unwrap(),
        request.body.len().to_string()
    );
    assert!(!request.headers.contains_key("transfer-encoding"));
    assert!(
        request
            .headers
            .get("user-agent")
            .unwrap()
            .to_str()
            .unwrap()
            .contains("BridgeMobile/0.1.0-Android")
    );
}

#[tokio::test]
async fn unknown_200_and_repeated_operation_do_not_replay() {
    let (server, _dir, engine, session) = setup(Provider::Codex).await;
    mount_snapshot(&server, Provider::Codex).await;
    let current = engine.snapshot(&session).await.unwrap();
    Mock::given(method("POST"))
        .and(path(format!("/api/sessions/{SID}/send")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"status":"unknown"})))
        .expect(1)
        .mount(&server)
        .await;
    let id = uuid::Uuid::new_v4().to_string();
    for _ in 0..2 {
        assert_eq!(
            engine
                .send(
                    &session,
                    &current.control_token,
                    &id,
                    "Synthetic".into(),
                    vec![],
                    false
                )
                .await
                .unwrap()
                .kind,
            OutcomeKind::Unknown
        );
    }
    assert!(
        engine
            .send(
                &session,
                &current.control_token,
                &uuid::Uuid::new_v4().to_string(),
                "Synthetic".into(),
                vec![],
                false
            )
            .await
            .is_err()
    );
}

#[tokio::test]
async fn explicit_not_submitted_is_distinct_from_ambiguous_failure() {
    let (server, _dir, engine, session) = setup(Provider::Codex).await;
    mount_snapshot(&server, Provider::Codex).await;
    let current = engine.snapshot(&session).await.unwrap();
    Mock::given(method("POST"))
        .and(path(format!("/api/sessions/{SID}/send")))
        .respond_with(
            ResponseTemplate::new(400)
                .set_body_json(json!({"code":"send_not_submitted","error":"Wrong mode"})),
        )
        .expect(2)
        .mount(&server)
        .await;
    for _ in 0..2 {
        let result = engine
            .send(
                &session,
                &current.control_token,
                &uuid::Uuid::new_v4().to_string(),
                "Synthetic".into(),
                vec![],
                false,
            )
            .await
            .unwrap();
        assert_eq!(result.kind, OutcomeKind::NotSubmitted);
    }
}

#[tokio::test]
async fn server_failure_remains_unknown() {
    let (server, _dir, engine, session) = setup(Provider::Codex).await;
    mount_snapshot(&server, Provider::Codex).await;
    let current = engine.snapshot(&session).await.unwrap();
    Mock::given(method("POST"))
        .and(path(format!("/api/sessions/{SID}/send")))
        .respond_with(
            ResponseTemplate::new(500).set_body_json(json!({"error":"Synthetic failure"})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let outcome = engine
        .send(
            &session,
            &current.control_token,
            &uuid::Uuid::new_v4().to_string(),
            "Synthetic".into(),
            vec![],
            false,
        )
        .await
        .unwrap();
    assert_eq!(outcome.kind, OutcomeKind::Unknown);
}

#[tokio::test]
async fn claude_and_deepseek_preserve_opaque_ids_and_host_scope() {
    for provider in [Provider::Claude, Provider::Deepseek] {
        let (server, _dir, engine, session) = setup(provider).await;
        mount_snapshot(&server, provider).await;
        let current = engine.snapshot(&session).await.unwrap();
        assert!(current.capabilities.send);
        assert_eq!(current.session.environment, "ssh:lab");
        let id = uuid::Uuid::new_v4().to_string();
        Mock::given(method("POST"))
            .and(path(format!(
                "/api/desktop-sessions/{}/send",
                provider.slug()
            )))
            .and(query_param("sessionId", "opaque/session:not-a-uuid"))
            .and(body_partial_json(
                json!({"sessionId":"opaque/session:not-a-uuid","id":id}),
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"status":"accepted"})))
            .expect(1)
            .mount(&server)
            .await;
        assert_eq!(
            engine
                .send(
                    &session,
                    &current.control_token,
                    &id,
                    "Test".into(),
                    vec![],
                    false
                )
                .await
                .unwrap()
                .kind,
            OutcomeKind::Accepted
        );
        let mut wrong = session.clone();
        wrong.computer_id = "other-pc".into();
        assert!(engine.snapshot(&wrong).await.is_err());
    }
}

#[tokio::test]
async fn historical_metadata_never_becomes_control_state() {
    let (server, _dir, engine, session) = setup(Provider::Codex).await;
    let mut value = timeline();
    value["meta"]["connected"] = json!(false);
    value["meta"]["requests"] = json!([{"id":"stale","method":"item/commandExecution/requestApproval","supported":true,"params":{"command":"historical command"}}]);
    Mock::given(method("GET"))
        .and(path(format!("/api/sessions/{SID}/timeline")))
        .respond_with(ResponseTemplate::new(200).set_body_json(value))
        .mount(&server)
        .await;
    let current = engine.snapshot(&session).await.unwrap();
    assert!(current.approvals.is_empty());
    assert!(!current.capabilities.send);
    assert!(!current.connected);
    let page = adapters::history(&engine.transport, &session, "older")
        .await
        .unwrap();
    assert_eq!(page.messages.len(), 1);
}

#[tokio::test]
async fn stale_control_token_prevents_any_write() {
    let (server, _dir, engine, session) = setup(Provider::Codex).await;
    mount_snapshot(&server, Provider::Codex).await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(500))
        .expect(0)
        .mount(&server)
        .await;
    assert!(
        engine
            .send(
                &session,
                "old-token",
                &uuid::Uuid::new_v4().to_string(),
                "Test".into(),
                vec![],
                false
            )
            .await
            .is_err()
    );
    let current = engine.snapshot(&session).await.unwrap();
    assert!(
        engine
            .respond(
                &session,
                &current.control_token,
                &uuid::Uuid::new_v4().to_string(),
                "expired",
                true,
                vec![]
            )
            .await
            .is_err()
    );
}

#[tokio::test]
async fn cross_origin_redirect_is_not_followed_or_given_credentials() {
    let (server, _dir, engine, _session) = setup(Provider::Codex).await;
    let receiver = MockServer::start().await;
    Mock::given(method("GET"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
        .expect(0)
        .mount(&receiver)
        .await;
    Mock::given(method("GET"))
        .and(path("/api/redirect"))
        .respond_with(
            ResponseTemplate::new(302)
                .insert_header("Location", format!("{}/api/stolen", receiver.uri())),
        )
        .expect(1)
        .mount(&server)
        .await;
    assert!(matches!(
        engine.transport.get("/api/redirect", &[]).await,
        Err(BridgeError::Redirect)
    ));
    let credentials = engine.transport.export_credentials().unwrap().unwrap();
    assert!(Transport::new(&receiver.uri(), "Android", Some(&credentials)).is_err());
}

#[tokio::test]
async fn pairing_expiry_and_revocation_clear_authority() {
    let server = MockServer::start().await;
    let transport = Transport::new(&server.uri(), "iOS", None).unwrap();
    Mock::given(method("POST"))
        .and(path("/api/pair"))
        .respond_with(
            ResponseTemplate::new(403)
                .set_body_json(json!({"error":"Pairing expired or consumed"})),
        )
        .expect(1)
        .mount(&server)
        .await;
    assert!(transport.pair("t".repeat(43)).await.is_err());
    assert!(transport.export_credentials().unwrap().is_none());
    auth(&server, "sse").await;
    transport.authenticate().await.unwrap();
    Mock::given(method("GET"))
        .and(path("/api/revoked"))
        .respond_with(ResponseTemplate::new(401).set_body_json(json!({"code":"unauthenticated"})))
        .mount(&server)
        .await;
    assert!(matches!(
        transport.get("/api/revoked", &[]).await,
        Err(BridgeError::Unauthenticated)
    ));
    assert!(!transport.status().authenticated);
    assert!(transport.export_credentials().unwrap().is_none());
}

#[tokio::test]
async fn background_cancels_reads_without_stopping_the_remote_task() {
    let (server, _dir, engine, session) = setup(Provider::Codex).await;
    mount_snapshot(&server, Provider::Codex).await;
    Mock::given(method("GET"))
        .and(path(format!("/api/sessions/{SID}/poll")))
        .respond_with(
            ResponseTemplate::new(200)
                .set_delay(Duration::from_secs(10))
                .set_body_json(json!({"state":null})),
        )
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(500))
        .expect(0)
        .mount(&server)
        .await;
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let other = engine.clone();
    let task = tokio::spawn(async move {
        other
            .watch(session, "subscription-a".into(), move |event| {
                tx.send(event).is_ok()
            })
            .await
    });
    let event = tokio::time::timeout(Duration::from_secs(2), rx.recv())
        .await
        .unwrap()
        .unwrap();
    assert!(event.snapshot.is_some());
    engine.pause();
    tokio::time::timeout(Duration::from_secs(1), task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn sse_logout_stops_the_subscription() {
    let server = MockServer::start().await;
    auth(&server, "sse").await;
    let dir = tempfile::tempdir().unwrap();
    let engine = Arc::new(
        Engine::new(
            Computer {
                id: "pc-a".into(),
                name: "Test".into(),
                base_url: server.uri(),
                connection_type: crate::api::types::ConnectionType::Direct,
                relay: None,
            },
            dir.path().join("db.sqlite").to_str().unwrap(),
            "Android",
            None,
        )
        .unwrap(),
    );
    engine.transport.authenticate().await.unwrap();
    mount_snapshot(&server, Provider::Codex).await;
    Mock::given(method("GET"))
        .and(path(format!("/api/sessions/{SID}/events")))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_raw("event: logout\ndata: {}\n\n", "text/event-stream"),
        )
        .expect(1)
        .mount(&server)
        .await;
    let session = SessionRef {
        computer_id: "pc-a".into(),
        provider: Provider::Codex,
        environment: "local".into(),
        id: SID.into(),
    };
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let other = engine.clone();
    let task = tokio::spawn(async move {
        other
            .watch(session, "sse-a".into(), move |event| tx.send(event).is_ok())
            .await
    });
    let mut logged_out = false;
    while let Some(event) = tokio::time::timeout(Duration::from_secs(2), rx.recv())
        .await
        .unwrap()
    {
        logged_out |= event.authentication_required;
    }
    task.await.unwrap().unwrap();
    assert!(logged_out);
    assert!(engine.transport.export_credentials().unwrap().is_none());
}

#[test]
fn account_changes_invalidate_control_fingerprints() {
    let session = SessionRef {
        computer_id: "pc-a".into(),
        provider: Provider::Codex,
        environment: "local".into(),
        id: SID.into(),
    };
    let first = adapters::codex::parse_snapshot(&timeline(), &session, "gateway-a").unwrap();
    let mut value = timeline();
    value["meta"]["draftAccountIdentity"] = json!("account-b");
    let second = adapters::codex::parse_snapshot(&value, &session, "gateway-a").unwrap();
    assert_ne!(first.control_token, second.control_token);
    assert_ne!(first.account_identity, second.account_identity);
}

#[test]
fn missing_account_identity_is_read_only_and_new_turns_invalidate_control() {
    let session = SessionRef {
        computer_id: "pc-a".into(),
        provider: Provider::Codex,
        environment: "local".into(),
        id: SID.into(),
    };
    let original = adapters::codex::parse_snapshot(&timeline(), &session, "gateway-a").unwrap();
    let mut value = timeline();
    value["rows"][0]["key"] = json!("next-turn-row");
    let next = adapters::codex::parse_snapshot(&value, &session, "gateway-a").unwrap();
    assert_ne!(original.control_token, next.control_token);
    value["meta"]["draftAccountIdentity"] = json!("");
    let unknown = adapters::codex::parse_snapshot(&value, &session, "gateway-a").unwrap();
    assert!(unknown.account_identity.is_empty());
    assert_eq!(unknown.capabilities, CapabilitySet::default());
    assert!(!unknown.history.messages.is_empty());
}

#[test]
fn desktop_question_inputs_and_unsupported_requests_are_not_guessed() {
    let requests = adapters::approvals(
        &[
            json!({"id":"ask-a","tool":"AskUserQuestion","needsInput":true,"input":{"questions":[
                {"question":"Which option?","options":[{"label":"A","description":"First"}],"multiSelect":false}
            ]}}),
            json!({"id":"unknown","unrecognizedKind":true}),
            json!({"id":"large","tool":"Shell","input":{"command":"x".repeat(40_000)}}),
        ],
        Provider::Claude,
    );
    assert_eq!(requests[0].kind, ApprovalKind::Questions);
    assert_eq!(requests[0].questions[0].id, "Which option?");
    assert!(requests[0].can_accept);
    assert!(!requests[1].supported);
    assert!(!requests[2].supported);
}

#[tokio::test]
async fn desktop_baseline_methods_follow_the_known_backend_contract() {
    let (server, _dir, engine, session) = setup(Provider::Claude).await;
    let mut value = desktop(Provider::Claude);
    value["session"]["backend"] = json!("cowork");
    value["session"]["status"] = json!("active");
    value["capabilities"]
        .as_object_mut()
        .unwrap()
        .remove("send");
    value["capabilities"]
        .as_object_mut()
        .unwrap()
        .remove("stop");
    Mock::given(method("GET"))
        .and(path("/api/desktop-sessions/claude/detail"))
        .respond_with(ResponseTemplate::new(200).set_body_json(value))
        .mount(&server)
        .await;
    let snapshot = engine.snapshot(&session).await.unwrap();
    assert!(snapshot.capabilities.send);
    assert!(snapshot.capabilities.stop);
    assert!(snapshot.capabilities.approve);
}

#[tokio::test]
async fn approval_answers_preserve_numeric_ids_and_native_payloads() {
    let (server, _dir, engine, session) = setup(Provider::Codex).await;
    let mut value = timeline();
    value["meta"]["requests"] = json!([{"id":42,"method":"item/tool/requestUserInput",
        "params":{"questions":[{"id":"q1","question":"Choose","options":[{"label":"A"}]}]}}]);
    Mock::given(method("GET"))
        .and(path(format!("/api/sessions/{SID}/timeline")))
        .respond_with(ResponseTemplate::new(200).set_body_json(value))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path(format!("/api/sessions/{SID}/respond")))
        .and(body_partial_json(
            json!({"requestId":42,"response":{"answers":{"q1":["A"]}}}),
        ))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"ok":true})))
        .expect(1)
        .mount(&server)
        .await;
    let current = engine.snapshot(&session).await.unwrap();
    let result = engine
        .respond(
            &session,
            &current.control_token,
            &uuid::Uuid::new_v4().to_string(),
            "42",
            true,
            vec![QuestionAnswer {
                question_id: "q1".into(),
                values: vec!["A".into()],
            }],
        )
        .await
        .unwrap();
    assert_eq!(result.kind, OutcomeKind::Accepted);
}

#[tokio::test]
async fn reused_subscription_id_can_still_be_cancelled_after_old_cleanup() {
    let (server, _dir, engine, session) = setup(Provider::Codex).await;
    mount_snapshot(&server, Provider::Codex).await;
    Mock::given(method("GET"))
        .and(path(format!("/api/sessions/{SID}/poll")))
        .respond_with(
            ResponseTemplate::new(200)
                .set_delay(Duration::from_secs(20))
                .set_body_json(json!({"state":null})),
        )
        .mount(&server)
        .await;
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let first_engine = engine.clone();
    let first_session = session.clone();
    let first_tx = tx.clone();
    let first = tokio::spawn(async move {
        first_engine
            .watch(first_session, "reused".into(), move |event| {
                first_tx.send(event).is_ok()
            })
            .await
    });
    tokio::time::timeout(Duration::from_secs(2), rx.recv())
        .await
        .unwrap()
        .unwrap();
    let second_engine = engine.clone();
    let second = tokio::spawn(async move {
        second_engine
            .watch(session, "reused".into(), move |event| {
                tx.send(event).is_ok()
            })
            .await
    });
    tokio::time::timeout(Duration::from_secs(2), rx.recv())
        .await
        .unwrap()
        .unwrap();
    first.await.unwrap().unwrap();
    engine.cancel("reused");
    tokio::time::timeout(Duration::from_secs(1), second)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn interrupted_write_leaves_a_durable_unknown_without_replay() {
    let (server, directory, engine, session) = setup(Provider::Codex).await;
    mount_snapshot(&server, Provider::Codex).await;
    Mock::given(method("POST"))
        .and(path(format!("/api/sessions/{SID}/send")))
        .respond_with(
            ResponseTemplate::new(200)
                .set_delay(Duration::from_secs(20))
                .set_body_json(json!({"status":"accepted"})),
        )
        .expect(1)
        .mount(&server)
        .await;
    let current = engine.snapshot(&session).await.unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    let (other, target, token, operation) = (
        engine.clone(),
        session.clone(),
        current.control_token.clone(),
        id.clone(),
    );
    let task = tokio::spawn(async move {
        other
            .send(&target, &token, &operation, "Test".into(), vec![], false)
            .await
    });
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if server
                .received_requests()
                .await
                .unwrap()
                .iter()
                .any(|r| r.method == "POST")
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());
    let reopened = Engine::new(
        engine.computer.clone(),
        directory.path().join("state.sqlite").to_str().unwrap(),
        "Android",
        None,
    )
    .unwrap();
    reopened.transport.authenticate().await.unwrap();
    let result = reopened
        .send(
            &session,
            &current.control_token,
            &id,
            "Test".into(),
            vec![],
            false,
        )
        .await
        .unwrap();
    assert_eq!(result.kind, OutcomeKind::Unknown);
    assert_eq!(
        reopened
            .store
            .pending(
                &crate::persistence::Store::scope(&session, &current.account_identity).unwrap()
            )
            .unwrap()
            .len(),
        1
    );
}

#[tokio::test]
async fn stale_unauthorized_read_does_not_revoke_a_newer_login() {
    let server = MockServer::start().await;
    auth(&server, "poll").await;
    let transport = Arc::new(Transport::new(&server.uri(), "Android", None).unwrap());
    transport.authenticate().await.unwrap();
    Mock::given(method("GET"))
        .and(path("/api/stale"))
        .respond_with(ResponseTemplate::new(401).set_delay(Duration::from_millis(250)))
        .mount(&server)
        .await;
    let other = transport.clone();
    let read = tokio::spawn(async move { other.get("/api/stale", &[]).await });
    tokio::time::timeout(Duration::from_secs(2), async {
        while !server
            .received_requests()
            .await
            .unwrap()
            .iter()
            .any(|r| r.url.path() == "/api/stale")
        {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    transport.authenticate().await.unwrap();
    assert!(matches!(
        read.await.unwrap(),
        Err(BridgeError::Unauthenticated)
    ));
    assert!(transport.status().authenticated);
    assert!(transport.export_credentials().unwrap().is_some());
}

#[tokio::test]
async fn untrusted_tls_certificate_is_rejected_before_http() {
    use tokio_rustls::{TlsAcceptor, rustls};
    let certificate = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
    let key = rustls::pki_types::PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der());
    let config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![certificate.cert.der().clone()], key.into())
        .unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        TlsAcceptor::from(Arc::new(config))
            .accept(stream)
            .await
            .is_err()
    });
    let transport = Transport::new(&format!("https://localhost:{port}"), "Android", None).unwrap();
    assert!(transport.authenticate().await.is_err());
    assert!(
        tokio::time::timeout(Duration::from_secs(5), server)
            .await
            .unwrap()
            .unwrap()
    );
    assert!(!transport.status().authenticated);
}

#[tokio::test]
async fn ambiguous_creation_is_visible_and_review_is_scoped_to_its_computer() {
    let (server, _dir, engine, _) = setup(Provider::Codex).await;
    Mock::given(method("GET"))
        .and(path("/api/projects"))
        .respond_with(ResponseTemplate::new(200).set_body_json(
            json!({"projects":[{"key":"project-a","name":"Project","host":"local"}]}),
        ))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/api/sessions"))
        .respond_with(ResponseTemplate::new(500).set_body_json(json!({"error":"Unknown"})))
        .expect(1)
        .mount(&server)
        .await;
    let project = ProjectOption {
        key: "project-a".into(),
        name: "Project".into(),
        cwd: "/test".into(),
        environment: "local".into(),
        requires_message: false,
        provider: Provider::Codex,
    };
    let id = uuid::Uuid::new_v4().to_string();
    let result = engine
        .create(project.clone(), "A new chat".into(), "".into(), &id)
        .await
        .unwrap();
    assert_eq!(result.kind, OutcomeKind::Unknown);
    assert_eq!(
        engine.store.pending_creations("pc-a").unwrap()[0].project_key,
        "project-a"
    );
    engine
        .store
        .review_creation("another-pc", &id, true)
        .unwrap();
    assert_eq!(engine.store.pending_creations("pc-a").unwrap().len(), 1);
    engine.store.review_creation("pc-a", &id, true).unwrap();
    assert!(engine.store.pending_creations("pc-a").unwrap().is_empty());
    assert_eq!(
        engine
            .create(project, "A new chat".into(), "".into(), &id)
            .await
            .unwrap()
            .kind,
        OutcomeKind::Unknown
    );
}
