use std::sync::Arc;
use std::time::Duration;

use rustls_platform_verifier::ConfigVerifierExt;
use tokio_tungstenite::{
    Connector,
    tungstenite::{
        Error,
        handshake::client::{Request, Response},
        protocol::WebSocketConfig,
    },
};

use super::Socket;
use crate::error::{BridgeError, Result};

fn platform_connector() -> Result<Connector> {
    // Native-root file probing misses Android/iOS trust; use the same OS verifier as HTTPS.
    let config = rustls::ClientConfig::with_platform_verifier().map_err(|_| BridgeError::Tls)?;
    Ok(Connector::Rustls(Arc::new(config)))
}

pub(super) async fn connect(
    request: Request,
    config: WebSocketConfig,
) -> Result<(Socket, Response)> {
    connect_with_connector(request, config, platform_connector()?).await
}

async fn connect_with_connector(
    request: Request,
    config: WebSocketConfig,
    connector: Connector,
) -> Result<(Socket, Response)> {
    tokio::time::timeout(
        Duration::from_secs(15),
        tokio_tungstenite::connect_async_tls_with_config(
            request,
            Some(config),
            false,
            Some(connector),
        ),
    )
    .await
    .map_err(|_| BridgeError::Network)?
    .map_err(connection_error)
}

fn connection_error(error: Error) -> BridgeError {
    match error {
        Error::Tls(_) => BridgeError::Tls,
        Error::Io(error)
            if error
                .get_ref()
                .and_then(|source| source.downcast_ref::<rustls::Error>())
                .is_some_and(|source| matches!(source, rustls::Error::InvalidCertificate(_))) =>
        {
            BridgeError::Tls
        }
        Error::Http(response) if response.status().is_redirection() => BridgeError::Redirect,
        _ => BridgeError::Network,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use futures_util::{SinkExt, StreamExt};
    use rustls::pki_types::PrivatePkcs8KeyDer;
    use tokio::net::TcpListener;
    use tokio::task::JoinHandle;
    use tokio_rustls::TlsAcceptor;
    use tokio_tungstenite::tungstenite::{
        Message, client::IntoClientRequest, handshake::server::Response as ServerResponse,
    };

    use super::*;

    struct Fixture {
        url: String,
        connector: Connector,
        upgrades: Arc<AtomicUsize>,
        task: JoinHandle<bool>,
    }

    async fn fixture(hostname: &str, expired: bool) -> Fixture {
        let mut params = rcgen::CertificateParams::new(vec![hostname.into()]).unwrap();
        if expired {
            params.not_before = rcgen::date_time_ymd(2000, 1, 1);
            params.not_after = rcgen::date_time_ymd(2001, 1, 1);
        }
        let key = rcgen::KeyPair::generate().unwrap();
        let certificate = params.self_signed(&key).unwrap();
        let config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(
                vec![certificate.der().clone()],
                PrivatePkcs8KeyDer::from(key.serialize_der()).into(),
            )
            .unwrap();
        let mut roots = rustls::RootCertStore::empty();
        roots.add(certificate.der().clone()).unwrap();
        let connector = Connector::Rustls(Arc::new(
            rustls::ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth(),
        ));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!(
            "wss://localhost:{}/v1/ws/mobile",
            listener.local_addr().unwrap().port()
        );
        let upgrades = Arc::new(AtomicUsize::new(0));
        let observed = upgrades.clone();
        let task = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let Ok(stream) = TlsAcceptor::from(Arc::new(config)).accept(stream).await else {
                return false;
            };
            // Tungstenite fixes this callback's error type to an unboxed HTTP response.
            #[allow(clippy::result_large_err)]
            let on_upgrade = move |request: &Request, mut response: ServerResponse| {
                observed.fetch_add(1, Ordering::SeqCst);
                assert_eq!(request.uri().path(), "/v1/ws/mobile");
                assert_eq!(request.headers()["Authorization"], "Bearer synthetic-token");
                assert_eq!(request.headers()["X-Bridge-Binding"], "synthetic-binding");
                assert_eq!(
                    request.headers()["Sec-WebSocket-Protocol"],
                    "bridge-relay-v1"
                );
                response
                    .headers_mut()
                    .insert("Sec-WebSocket-Protocol", "bridge-relay-v1".parse().unwrap());
                Ok(response)
            };
            let mut socket = tokio_tungstenite::accept_hdr_async(stream, on_upgrade)
                .await
                .unwrap();
            socket
                .send(Message::Binary(vec![1, 2, 3].into()))
                .await
                .unwrap();
            socket.close(None).await.unwrap();
            true
        });
        Fixture {
            url,
            connector,
            upgrades,
            task,
        }
    }

    fn request(url: &str) -> Request {
        let mut request = url.into_client_request().unwrap();
        request
            .headers_mut()
            .insert("Authorization", "Bearer synthetic-token".parse().unwrap());
        request
            .headers_mut()
            .insert("X-Bridge-Binding", "synthetic-binding".parse().unwrap());
        request
            .headers_mut()
            .insert("Sec-WebSocket-Protocol", "bridge-relay-v1".parse().unwrap());
        request
    }

    async fn completed(task: JoinHandle<bool>) -> bool {
        tokio::time::timeout(Duration::from_secs(5), task)
            .await
            .unwrap()
            .unwrap()
    }

    #[test]
    fn encrypted_websockets_use_an_explicit_platform_connector() {
        assert!(matches!(
            platform_connector().unwrap(),
            Connector::Rustls(_)
        ));
    }

    #[tokio::test]
    async fn a_trusted_websocket_certificate_completes_the_upgrade() {
        let server = fixture("localhost", false).await;
        let (mut socket, response) = connect_with_connector(
            request(&server.url),
            WebSocketConfig::default(),
            server.connector,
        )
        .await
        .unwrap();
        assert_eq!(
            response.headers()["Sec-WebSocket-Protocol"],
            "bridge-relay-v1"
        );
        assert_eq!(
            socket.next().await.unwrap().unwrap(),
            Message::Binary(vec![1, 2, 3].into())
        );
        assert!(completed(server.task).await);
        assert_eq!(server.upgrades.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn custom_tls_keeps_the_websocket_message_size_limit() {
        let server = fixture("localhost", false).await;
        let (mut socket, _) = connect_with_connector(
            request(&server.url),
            WebSocketConfig::default().max_message_size(Some(2)),
            server.connector,
        )
        .await
        .unwrap();
        assert!(matches!(socket.next().await, Some(Err(Error::Capacity(_)))));
        assert!(completed(server.task).await);
    }

    #[tokio::test]
    async fn platform_trust_rejects_a_self_signed_certificate_before_sending_credentials() {
        let server = fixture("localhost", false).await;
        let result = connect(request(&server.url), WebSocketConfig::default()).await;
        assert!(matches!(result, Err(BridgeError::Tls)), "{result:?}");
        assert!(!completed(server.task).await);
        assert_eq!(server.upgrades.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn a_trusted_certificate_cannot_bypass_websocket_hostname_verification() {
        let server = fixture("other.example.test", false).await;
        let result = connect_with_connector(
            request(&server.url),
            WebSocketConfig::default(),
            server.connector,
        )
        .await;
        assert!(matches!(result, Err(BridgeError::Tls)), "{result:?}");
        assert!(!completed(server.task).await);
        assert_eq!(server.upgrades.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn a_trusted_certificate_cannot_bypass_websocket_expiry_verification() {
        let server = fixture("localhost", true).await;
        let result = connect_with_connector(
            request(&server.url),
            WebSocketConfig::default(),
            server.connector,
        )
        .await;
        assert!(matches!(result, Err(BridgeError::Tls)), "{result:?}");
        assert!(!completed(server.task).await);
        assert_eq!(server.upgrades.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn websocket_redirects_never_forward_credentials_to_another_origin() {
        use wiremock::{
            Mock, MockServer, ResponseTemplate,
            matchers::{method, path},
        };

        let source = MockServer::start().await;
        let target = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/v1/ws/mobile"))
            .respond_with(
                ResponseTemplate::new(302)
                    .insert_header("Location", format!("{}/v1/ws/mobile", target.uri())),
            )
            .expect(1)
            .mount(&source)
            .await;
        let url = source.uri().replacen("http://", "ws://", 1) + "/v1/ws/mobile";
        assert!(matches!(
            connect(request(&url), WebSocketConfig::default()).await,
            Err(BridgeError::Redirect)
        ));
        assert!(target.received_requests().await.unwrap().is_empty());
    }

    #[test]
    fn websocket_errors_do_not_expose_private_response_bodies() {
        let response = http::Response::builder()
            .status(500)
            .body(Some(b"synthetic-private-response".to_vec()))
            .unwrap();
        let error = connection_error(Error::Http(Box::new(response)));
        assert!(matches!(error, BridgeError::Network));
        assert!(!error.to_string().contains("synthetic-private-response"));
    }
}
