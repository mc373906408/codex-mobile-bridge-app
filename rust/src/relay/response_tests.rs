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
            direct: false,
            p2p_available: false,
            runtime: None,
            links: None,
            authority: None,
        },
        Channel {
            socket: server,
            cipher: ControlCipher::new(second).unwrap(),
            binding,
            channel,
            direct: false,
            p2p_available: false,
            runtime: None,
            links: None,
            authority: None,
        },
    )
}

#[tokio::test]
async fn active_binding_missing_local_preview_proof_uses_authorize_and_recovers_it() {
    exchange_pairing_proof(Authorization::Existing, true).await;
}

#[tokio::test]
async fn scan_challenge_requires_an_encrypted_ack_and_never_opens_business_access() {
    let token = "ab".repeat(16);
    exchange_pairing_proof(Authorization::Pair(None), false).await;
    exchange_pairing_proof(Authorization::Pair(Some(&token)), false).await;
    exchange_pairing_proof(Authorization::Pair(Some(&token)), true).await;
}

async fn exchange_pairing_proof(authorization: Authorization<'_>, scan_verified: bool) {
    let (_, mut saved) = super::tests::secrets();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    saved.connection.origin = format!("http://{address}");
    saved.control_private = b64(&[7; 32]);
    saved.control_public = b64(&cloud_crypto::public_key(&[7; 32]).unwrap());
    saved.preview_private = b64(&[10; 32]);
    saved.preview_public = b64(&cloud_crypto::public_key(&[10; 32]).unwrap());
    saved.connection.desktop_public_key = b64(&cloud_crypto::public_key(&[9; 32]).unwrap());
    saved.desktop_preview_public.clear();
    saved.pairing_code.clear();
    let original = saved.clone();
    let secret_store = RwLock::new(saved.clone());
    let pairing = matches!(authorization, Authorization::Pair(_));
    let expected_token = match authorization {
        Authorization::Pair(token) => token.map(str::to_owned),
        Authorization::Existing => None,
    };
    let requires_scan = expected_token.is_some();

    let desktop = tokio::spawn(async move {
        let (tcp, _) = listener.accept().await.unwrap();
        let mut socket = tokio_tungstenite::accept_async(MaybeTlsStream::Plain(tcp))
            .await
            .unwrap();
        let binding = id(&original.connection.binding_id).unwrap();
        let gateway = id(&original.connection.gateway_id).unwrap();
        let channel = Uuid::new_v4();
        let desktop_private = cloud_crypto::key(&b64(&[9; 32])).unwrap();
        let mobile_public = cloud_crypto::key(&original.control_public).unwrap();
        let desktop_public = cloud_crypto::public_key(&desktop_private).unwrap();
        let prologue = cloud_crypto::control_prologue(
            &original.connection.origin,
            gateway,
            binding,
            channel,
            &desktop_public,
            &mobile_public,
        )
        .unwrap();
        let mut handshake =
            cloud_crypto::handshake(&desktop_private, &mobile_public, &prologue, false).unwrap();

        let open = Frame {
            kind: 1,
            binding,
            channel,
            payload: desktop_public.to_vec(),
        }
        .encode()
        .unwrap();
        socket.send(Message::Binary(open.into())).await.unwrap();
        let Some(Ok(Message::Binary(first))) = socket.next().await else {
            panic!("mobile did not send its Noise handshake");
        };
        let first = Frame::decode(&first).unwrap();
        cloud_crypto::handshake_read(&mut handshake, &first.payload).unwrap();
        let response = cloud_crypto::handshake_write(&mut handshake).unwrap();
        let response = Frame {
            kind: 2,
            binding,
            channel,
            payload: response,
        }
        .encode()
        .unwrap();
        socket.send(Message::Binary(response.into())).await.unwrap();
        let mut cipher = ControlCipher::new(handshake).unwrap();

        async fn send_control(
            socket: &mut WebSocketStream<MaybeTlsStream<TcpStream>>,
            cipher: &mut ControlCipher,
            binding: Uuid,
            channel: Uuid,
            value: Value,
        ) {
            let mut plaintext = vec![0];
            plaintext.extend(serde_json::to_vec(&value).unwrap());
            let frame = Frame {
                kind: 2,
                binding,
                channel,
                payload: cipher.encrypt(&plaintext).unwrap(),
            }
            .encode()
            .unwrap();
            socket.send(Message::Binary(frame.into())).await.unwrap();
        }

        async fn receive_control(
            socket: &mut WebSocketStream<MaybeTlsStream<TcpStream>>,
            cipher: &mut ControlCipher,
        ) -> Value {
            let Some(Ok(Message::Binary(data))) = socket.next().await else {
                panic!("mobile closed before the authorization request");
            };
            let frame = Frame::decode(&data).unwrap();
            let plaintext = cipher.decrypt(&frame.payload).unwrap();
            assert_eq!(plaintext.first(), Some(&0));
            serde_json::from_slice(&plaintext[1..]).unwrap()
        }

        send_control(
            &mut socket,
            &mut cipher,
            binding,
            channel,
            json!({"kind":"ready"}),
        )
        .await;
        assert_eq!(
            receive_control(&mut socket, &mut cipher).await["kind"],
            "key_confirm"
        );
        send_control(
            &mut socket,
            &mut cipher,
            binding,
            channel,
            json!({"kind":"key_confirmed"}),
        )
        .await;
        let request = receive_control(&mut socket, &mut cipher).await;
        assert_eq!(request["kind"], if pairing { "pair" } else { "authorize" });
        assert_eq!(request["preview_public_key"], original.preview_public);
        assert_eq!(request["scan_token"].as_str(), expected_token.as_deref());
        let preview = cloud_crypto::public_key(&[12; 32]).unwrap();
        let response = if pairing {
            let safety_code = cloud_crypto::pairing_safety_code(
                &original.connection.origin,
                gateway,
                binding,
                &desktop_private,
                &mobile_public,
                &desktop_public,
                &mobile_public,
                &preview,
                &cloud_crypto::key(&original.preview_public).unwrap(),
            )
            .unwrap();
            json!({"kind":"pair_pending","desktop_preview_public_key":b64(&preview),"safety_code":safety_code,"scan_verified":scan_verified})
        } else {
            json!({"kind":"authorized","desktop_preview_public_key":b64(&preview),"p2p":false})
        };
        send_control(&mut socket, &mut cipher, binding, channel, response).await;
    });

    let tcp = tokio::net::TcpStream::connect(address).await.unwrap();
    let (socket, _) = tokio_tungstenite::client_async(
        format!("ws://{address}/v1/ws/mobile"),
        MaybeTlsStream::Plain(tcp),
    )
    .await
    .unwrap();
    let result = authenticate_channel(&saved, socket, authorization, Some(&secret_store)).await;
    desktop.await.unwrap();
    if requires_scan && !scan_verified {
        assert!(result.is_err());
        assert!(secret_store.read().unwrap().pairing_code.is_empty());
        return;
    }
    assert_eq!(result.unwrap().is_none(), pairing);

    let recovered = secret_store.read().unwrap().clone();
    assert_eq!(
        recovered.desktop_preview_public,
        b64(&cloud_crypto::public_key(&[12; 32]).unwrap())
    );
    assert_eq!(
        Relay::new(
            &recovered.connection,
            &serde_json::to_string(&recovered).unwrap()
        )
        .unwrap()
        .saved_safety_code()
        .unwrap(),
        recovered.pairing_code
    );
}

#[tokio::test]
async fn encrypted_transport_preserves_future_methods_paths_and_bodies() {
    for method in [
        Method::POST,
        Method::PUT,
        Method::PATCH,
        Method::DELETE,
        Method::HEAD,
        Method::OPTIONS,
    ] {
        let (client, mut desktop) = channels().await;
        let (_, mut saved) = super::tests::secrets();
        saved.control_private = b64(&[9; 32]);
        saved.control_public = b64(&cloud_crypto::public_key(&[9; 32]).unwrap());
        saved.connection.desktop_public_key = b64(&cloud_crypto::public_key(&[8; 32]).unwrap());
        saved.preview_public = b64(&cloud_crypto::public_key(&[10; 32]).unwrap());
        saved.connection.binding_id = client.binding.to_string();
        let relay = Relay::new(&saved.connection, &serde_json::to_string(&saved).unwrap()).unwrap();
        let active = session::Session::start(client, relay.status.clone());
        relay.session.lock().await.active = Some(active.clone());
        let payload = if method == Method::HEAD {
            Vec::new()
        } else {
            b"{\"value\":\"once\"}".to_vec()
        };
        let expected_method = method.clone();
        let expected_body = payload.clone();
        let responder = tokio::spawn(async move {
            let request = desktop.control(5).await.unwrap();
            assert_eq!(request["method"], expected_method.as_str());
            assert_eq!(request["path"], "/api/a-future-feature?entry=separate");
            assert_eq!(request["length"], expected_body.len());
            let stream = request["stream_id"].as_u64().unwrap();
            desktop
                .send(json!({"kind":"credit","stream_id":stream,"count":4}))
                .await
                .unwrap();
            if !expected_body.is_empty() {
                let raw = desktop.receive(5).await.unwrap();
                assert_eq!(raw[0], 1);
                assert_eq!(&raw[9..], expected_body);
            }
            assert_eq!(desktop.control(5).await.unwrap()["kind"], "request_end");
            let length = if expected_method == Method::HEAD {
                "32"
            } else {
                "0"
            };
            desktop
                .send(
                    json!({"kind":"response_start","stream_id":stream,"status":200,
                "headers":{"Content-Length":length}}),
                )
                .await
                .unwrap();
            assert_eq!(desktop.control(5).await.unwrap()["kind"], "credit");
            desktop
                .send(json!({"kind":"response_end","stream_id":stream}))
                .await
                .unwrap();
            assert_eq!(desktop.control(5).await.unwrap()["kind"], "response_ack");
        });
        let response = relay
            .request(
                method,
                "/api/a-future-feature?entry=separate",
                Some(payload),
                "application/json",
            )
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        assert!(response.bytes().await.unwrap().is_empty());
        responder.await.unwrap();
        active.closed.cancel();
    }
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
