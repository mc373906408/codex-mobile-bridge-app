//! Opt-in real Go/Python/EasyTier/Rust fixture; never uses the user's accounts.
use super::*;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "requires the isolated cross-language P2P fixture"]
async fn real_p2p_fixture_survives_cloud_loss_and_obeys_revocation() {
    let path = std::env::var("BRIDGE_P2P_FIXTURE").expect("fixture path required");
    let fixture: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    let origin = fixture["origin"].as_str().unwrap();
    assert!(origin.starts_with("http://127.0.0.1:"));
    let client = reqwest::Client::new();
    let account = login(origin.into(), "relogin-user".into(), "synthetic-relogin-password-123".into(), None).await.unwrap();
    let discovered = devices(&account.credentials, origin, &account.account_id).await.unwrap().remove(0);
    let enrollment = prepare_discovery(discovered.clone(), &account.credentials, "P2P fixture".into()).unwrap();
    let relay = Relay::new(enrollment.computer.relay.as_ref().unwrap(), &enrollment.binding_credentials).unwrap();
    let proof = relay.pairing_state().await.unwrap();
    let approved: Value = client.post(format!("{}/approve", fixture["control"].as_str().unwrap()))
        .json(&json!({"binding":discovered.binding_id,"revision":discovered.access_revision,"code":proof.safety_code}))
        .send().await.unwrap().json().await.unwrap();
    assert_eq!(approved["confirmed"], true);
    assert_eq!(relay.pairing_state().await.unwrap().status, "active");
    for _ in 0..80 {
        relay.request(Method::GET, "/api/clients", None, "").await.unwrap().bytes().await.unwrap();
        if relay.transport_status().path == "p2p" { break; }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert_eq!(relay.transport_status().path, "p2p", "no real direct path established");
    let before = relay.transport_status();
    for _ in 0..20 { relay.request(Method::GET, "/api/clients", None, "").await.unwrap().bytes().await.unwrap(); }
    let after = relay.transport_status();
    assert!(after.p2p_received > before.p2p_received && after.p2p_sent > before.p2p_sent);
    assert_eq!(after.relay_received, before.relay_received);
    client.post(format!("{origin}/.test/network")).json(&json!({"offline":true})).send().await.unwrap();
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert_eq!(relay.transport_status().path, "p2p");
    relay.request(Method::GET, "/api/clients", None, "").await.unwrap().bytes().await.unwrap();
    client.post(format!("{origin}/.test/network")).json(&json!({"offline":false})).send().await.unwrap();
    client.post(format!("{origin}/.test/revoke")).json(&json!({"binding":discovered.binding_id})).send().await.unwrap();
    for _ in 0..60 {
        if !relay.links.direct().is_some() { break; }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(relay.links.direct().is_none(), "revocation did not close the direct path");
    assert!(relay.request(Method::GET, "/api/clients", None, "").await.is_err());
    println!("P2P fixture: direct bytes={}, relay bypass, cloud loss and revocation passed", after.p2p_received);
    relay.revoke().await;
}
