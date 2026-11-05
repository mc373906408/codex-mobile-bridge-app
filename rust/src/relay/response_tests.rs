use super::*;
use tokio::net::TcpListener;

async fn channels() -> (Channel, Channel) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let accepted = tokio::spawn(async move {
        let (tcp, _) = listener.accept().await.unwrap();
        tokio_tungstenite::accept_async(MaybeTlsStream::Plain(tcp))
            .await
            .unwrap()
    });
    let (client, _) = tokio_tungstenite::connect_async(format!("ws://{address}"))
        .await
        .unwrap();
    let server = accepted.await.unwrap();
    let desktop = [8; 32];
    let mobile = [9; 32];
    let mut first = cloud_crypto::handshake(
        &mobile,
        &cloud_crypto::public_key(&desktop).unwrap(),
        b"synthetic-response",
        true,
    )
    .unwrap();
    let mut second = cloud_crypto::handshake(
        &desktop,
        &cloud_crypto::public_key(&mobile).unwrap(),
        b"synthetic-response",
        false,
    )
    .unwrap();
    cloud_crypto::handshake_read(
        &mut second,
        &cloud_crypto::handshake_write(&mut first).unwrap(),
    )
    .unwrap();
    cloud_crypto::handshake_read(
        &mut first,
        &cloud_crypto::handshake_write(&mut second).unwrap(),
    )
    .unwrap();
    let binding = Uuid::new_v4();
    let channel = Uuid::new_v4();
    (
        Channel {
            socket: client,
            cipher: ControlCipher::new(first).unwrap(),
            binding,
            channel,
        },
        Channel {
            socket: server,
            cipher: ControlCipher::new(second).unwrap(),
            binding,
            channel,
        },
    )
}

async fn response_after_credit_write_failure(complete: bool) -> (Vec<u8>, bool) {
    let (client, mut server) = channels().await;
    let active = session::Session::start(client, tokio::sync::watch::channel(String::new()).0);
    let client = active.open(false).await.unwrap();
    client
        .send(json!({"kind":"credit","count":4}))
        .await
        .unwrap();
    assert_eq!(
        server.control(5).await.unwrap(),
        json!({"kind":"credit","count":4,"stream_id":1})
    );
    for body in [b"first ".as_slice(), b"second".as_slice()] {
        let mut raw = vec![1];
        raw.extend(1u64.to_be_bytes());
        raw.extend(body);
        server.send_data(&raw).await.unwrap();
    }
    if complete {
        server
            .send(json!({"kind":"response_end","stream_id":1}))
            .await
            .unwrap();
    } else {
        // A clean WebSocket close is still not an authenticated response_end.
        server.socket.send(Message::Close(None)).await.unwrap();
    }
    let _ = server.socket.close(None).await;
    let (tx, mut rx) = tokio::sync::mpsc::channel(4);
    let receiving = tokio::spawn(receive_response_body(client, tx, false));
    let mut bytes = Vec::new();
    let mut failed = false;
    while let Some(item) = tokio::time::timeout(Duration::from_secs(5), rx.recv())
        .await
        .unwrap()
    {
        match item {
            Ok(part) => bytes.extend(part),
            Err(_) => failed = true,
        }
    }
    receiving.await.unwrap();
    active.closed.cancel();
    (bytes, failed)
}

#[tokio::test]
async fn complete_authenticated_response_survives_late_credit_write_failure() {
    let (body, failed) = response_after_credit_write_failure(true).await;
    assert_eq!(body, b"first second");
    assert!(
        !failed,
        "complete authenticated response was mistaken for a network failure"
    );
}

#[tokio::test]
async fn incomplete_response_still_fails_when_credit_write_also_fails() {
    let (_, failed) = response_after_credit_write_failure(false).await;
    assert!(failed, "missing response_end was accepted as success");
}

#[tokio::test]
async fn a_cancelled_stream_does_not_close_another_stream_or_the_session() {
    let (client, mut desktop) = channels().await;
    let active = session::Session::start(client, tokio::sync::watch::channel(String::new()).0);
    let mut first = active.open(false).await.unwrap();
    let second = active.open(false).await.unwrap();
    first.send(json!({"kind":"request_end"})).await.unwrap();
    assert_eq!(desktop.control(5).await.unwrap()["stream_id"], 1);
    drop(second);
    desktop
        .send(json!({"kind":"response_end","stream_id":1}))
        .await
        .unwrap();
    assert_eq!(first.control(5).await.unwrap()["kind"], "response_end");
    first.finish().await;
    assert!(!active.closed.is_cancelled());
    let third = active.open(false).await.unwrap();
    third.send(json!({"kind":"request_end"})).await.unwrap();
    for _ in 0..4 {
        if desktop.control(5).await.unwrap()["stream_id"] == 3 {
            active.closed.cancel();
            return;
        }
    }
    panic!("new stream did not reuse the session");
}

#[tokio::test]
async fn background_quiescence_cancels_reads_and_drains_a_submitted_write() {
    let (client, mut desktop) = channels().await;
    let active = session::Session::start(client, tokio::sync::watch::channel(String::new()).0);
    let mut write = active.open(true).await.unwrap();
    write.send(json!({"kind":"request_end"})).await.unwrap();
    desktop.control(5).await.unwrap();
    active.quiesce.cancel();
    assert!(active.open(false).await.is_err());
    desktop
        .send(json!({"kind":"response_end","stream_id":1}))
        .await
        .unwrap();
    assert_eq!(write.control(5).await.unwrap()["kind"], "response_end");
    write.finish().await;
    drop(write);
    tokio::time::timeout(Duration::from_secs(3), active.closed.cancelled())
        .await
        .unwrap();
}
