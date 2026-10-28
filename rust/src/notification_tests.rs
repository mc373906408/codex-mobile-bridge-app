use std::{sync::Arc, time::Duration};

use serde_json::{Value, json};
use wiremock::{
    Mock, MockServer, ResponseTemplate,
    matchers::{method, path, query_param},
};

use crate::{api::types::*, engine::Engine, error::BridgeError};

const SID: &str = "11111111-1111-4111-8111-111111111111";

async fn setup() -> (MockServer, tempfile::TempDir, Arc<Engine>) {
    let server = MockServer::start().await;
    let directory = tempfile::tempdir().unwrap();
    let engine = Arc::new(
        Engine::new(
            Computer {
                id: "pc-a".into(),
                name: "Synthetic".into(),
                base_url: server.uri(),
            },
            directory.path().join("state.sqlite").to_str().unwrap(),
            "Android",
            None,
        )
        .unwrap(),
    );
    (server, directory, engine)
}

async fn auth(server: &MockServer, identity: &str, enabled: bool) {
    Mock::given(method("GET"))
        .and(path("/api/auth"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "authenticated": true, "csrf": "synthetic-csrf", "draftIdentity": identity,
            "notifications": enabled, "passwordless": true, "transport": "poll",
        })))
        .mount(server)
        .await;
}

fn event(id: &str) -> Value {
    json!({"id": id, "kind": "completion", "createdAt": 100.0,
        "threadId": SID, "host": "local", "title": "Private conversation title",
        "body": "Private conversation content"})
}

async fn events(server: &MockServer, value: Value) {
    Mock::given(method("GET"))
        .and(path("/api/mobile/events"))
        .and(query_param("after", "0"))
        .respond_with(ResponseTemplate::new(200).set_body_json(value))
        .mount(server)
        .await;
}

#[tokio::test]
async fn notification_reads_authenticate_and_preserve_inbox_identity_without_content() {
    let (server, _directory, engine) = setup().await;
    auth(&server, "account-a", true).await;
    events(
        &server,
        json!({"streamId": "stream-a", "events": [event("a")]}),
    )
    .await;
    let batch = engine.notification_events().await.unwrap();
    assert!(batch.enabled);
    assert_eq!(batch.scope.len(), 64);
    assert_eq!(batch.events[0].id, engine.inbox().await.unwrap()[0].id);
    assert_eq!(batch.events[0].session.as_ref().unwrap().id, SID);
    assert!(
        !serde_json::to_string(&batch)
            .unwrap()
            .contains("Private conversation")
    );
    assert!(
        server
            .received_requests()
            .await
            .unwrap()
            .iter()
            .all(|request| request.method == "GET")
    );
}

#[tokio::test]
async fn disabled_gateway_notifications_do_not_read_the_optional_endpoint() {
    let (server, _directory, engine) = setup().await;
    auth(&server, "account-a", false).await;
    let batch = engine.notification_events().await.unwrap();
    assert!(!batch.enabled);
    assert!(batch.events.is_empty());
    assert_eq!(server.received_requests().await.unwrap().len(), 1);
}

#[tokio::test]
async fn unauthenticated_notification_reads_never_fetch_events() {
    let (server, _directory, engine) = setup().await;
    Mock::given(path("/api/auth"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"authenticated": false})))
        .mount(&server)
        .await;
    assert!(matches!(
        engine.notification_events().await,
        Err(BridgeError::Unauthenticated)
    ));
    assert_eq!(server.received_requests().await.unwrap().len(), 1);
}

#[tokio::test]
async fn notification_scope_changes_with_both_account_and_stream() {
    let (server, _directory, engine) = setup().await;
    auth(&server, "account-a", true).await;
    events(
        &server,
        json!({"streamId": "stream-a", "events": [event("a")]}),
    )
    .await;
    let first = engine.notification_events().await.unwrap();
    server.reset().await;
    auth(&server, "account-b", true).await;
    events(
        &server,
        json!({"streamId": "stream-a", "events": [event("a")]}),
    )
    .await;
    engine.transport.authenticate().await.unwrap();
    let second = engine.notification_events().await.unwrap();
    assert_ne!(first.scope, second.scope);
    assert_ne!(first.events[0].id, second.events[0].id);
    server.reset().await;
    events(
        &server,
        json!({"streamId": "stream-b", "events": [event("a")]}),
    )
    .await;
    let third = engine.notification_events().await.unwrap();
    assert_ne!(second.scope, third.scope);
    assert_ne!(second.events[0].id, third.events[0].id);
}

#[tokio::test]
async fn malformed_notification_events_are_filtered_and_routes_remain_scoped() {
    let (server, _directory, engine) = setup().await;
    auth(&server, "account-a", true).await;
    let mut unknown = event("unknown");
    unknown["kind"] = json!("command");
    let mut missing_time = event("bad-time");
    missing_time["createdAt"] = json!(-1);
    let mut bad_route = event("bad-route");
    bad_route["threadId"] = json!("../../elsewhere");
    let mut claude = event("claude");
    claude["host"] = json!("desktop:claude");
    claude["threadId"] = json!("opaque/session:not-a-uuid");
    claude["kind"] = json!("request");
    let mut deepseek = claude.clone();
    deepseek["id"] = json!("deepseek");
    deepseek["host"] = json!("desktop:deepseek");
    events(&server, json!({"streamId": "stream-a", "events": [unknown, missing_time, bad_route, claude, deepseek]})).await;
    let batch = engine.notification_events().await.unwrap();
    assert_eq!(batch.events.len(), 3);
    assert_eq!(
        batch.events[0].session.as_ref().unwrap().provider,
        Provider::Deepseek
    );
    assert_eq!(
        batch.events[1].session.as_ref().unwrap().provider,
        Provider::Claude
    );
    assert_eq!(
        batch.events[1].session.as_ref().unwrap().environment,
        "local"
    );
    assert!(batch.events[2].session.is_none());
}

#[tokio::test]
async fn notification_response_requires_a_stream_and_event_array() {
    for value in [
        json!({"events": []}),
        json!({"streamId": ""}),
        json!({"streamId": "a", "events": {}}),
    ] {
        let (server, _directory, engine) = setup().await;
        auth(&server, "account-a", true).await;
        events(&server, value).await;
        assert!(matches!(
            engine.notification_events().await,
            Err(BridgeError::Protocol(_))
        ));
    }
}

#[tokio::test]
async fn repeated_background_polls_do_not_reset_live_authentication_epoch() {
    let (server, _directory, engine) = setup().await;
    auth(&server, "account-a", true).await;
    events(&server, json!({"streamId": "stream-a", "events": []})).await;
    engine.transport.authenticate().await.unwrap();
    let epoch = engine.transport.authentication_epoch();
    engine.pause();
    engine.notification_events().await.unwrap();
    engine.notification_events().await.unwrap();
    assert_eq!(engine.transport.authentication_epoch(), epoch);
    let requests = server.received_requests().await.unwrap();
    assert_eq!(
        requests
            .iter()
            .filter(|request| request.url.path() == "/api/auth")
            .count(),
        1
    );
}

#[tokio::test]
async fn notification_response_from_a_revoked_epoch_is_discarded() {
    let (server, _directory, engine) = setup().await;
    auth(&server, "account-a", true).await;
    Mock::given(path("/api/mobile/events"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_delay(Duration::from_millis(100))
                .set_body_json(json!({"streamId": "stream-a", "events": [event("a")]})),
        )
        .mount(&server)
        .await;
    let reader = engine.clone();
    let poll = tokio::spawn(async move { reader.notification_events().await });
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if server
                .received_requests()
                .await
                .unwrap()
                .iter()
                .any(|request| request.url.path() == "/api/mobile/events")
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    engine.transport.invalidate();
    assert!(poll.await.unwrap().is_err());
}

#[tokio::test]
async fn notification_payload_is_bounded_to_the_latest_two_hundred_events() {
    let (server, _directory, engine) = setup().await;
    auth(&server, "account-a", true).await;
    let values: Vec<_> = (0..250).map(|id| event(&id.to_string())).collect();
    events(&server, json!({"streamId": "stream-a", "events": values})).await;
    assert_eq!(
        engine.notification_events().await.unwrap().events.len(),
        200
    );
}
