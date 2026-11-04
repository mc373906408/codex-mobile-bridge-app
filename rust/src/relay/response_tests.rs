use super::*;
use tokio::io::AsyncWriteExt;
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
    let (mut client, mut server) = channels().await;
    // The desktop already has its initial response credit; only later credit
    // writes fail, while authenticated response bytes remain readable.
    client
        .send(json!({"kind":"credit","count":4}))
        .await
        .unwrap();
    assert_eq!(
        server.control(5).await.unwrap(),
        json!({"kind":"credit","count":4})
    );
    server.send_data(b"\x01first ").await.unwrap();
    server.send_data(b"\x01second").await.unwrap();
    if complete {
        server.send(json!({"kind":"response_end"})).await.unwrap();
    } else {
        // A clean WebSocket close is still not an authenticated response_end.
        server.socket.send(Message::Close(None)).await.unwrap();
    }
    match client.socket.get_mut() {
        MaybeTlsStream::Plain(tcp) => tcp.shutdown().await.unwrap(),
        _ => unreachable!(),
    }
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
