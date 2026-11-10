use std::net::Ipv4Addr;

use sha2::{Digest, Sha256};
use url::{Host, Url};

use crate::api::types::{ConnectionInput, Provider, SessionRef};
use crate::error::{BridgeError, Result};

#[derive(Clone, Debug)]
pub struct GatewayAddress {
    pub base: String,
    pub origin: String,
}

impl GatewayAddress {
    pub fn parse(input: &str) -> Result<(Self, Option<String>)> {
        let input = input.trim();
        let invalid = || BridgeError::Address("use an HTTP or HTTPS origin".into());
        if input.len() > 2048 || input.chars().any(|c| c.is_control() || c == '\\') {
            return Err(invalid());
        }
        let url = Url::parse(input).map_err(|_| invalid())?;
        if !url.username().is_empty() || url.password().is_some() || url.query().is_some() {
            return Err(invalid());
        }
        let authority = input
            .split_once("://")
            .ok_or_else(invalid)?
            .1
            .split(['/', '?', '#'])
            .next()
            .unwrap_or_default();
        if authority.contains('@') || authority.ends_with(":0") {
            return Err(invalid());
        }
        if let Host::Ipv4(ip) = url.host().ok_or_else(invalid)? {
            let original = authority.split(':').next().unwrap_or_default();
            if original.parse::<Ipv4Addr>().ok() != Some(ip) || original != ip.to_string() {
                return Err(invalid());
            }
        }
        if !matches!(url.scheme(), "http" | "https") {
            return Err(invalid());
        }
        // Inspect the original path too: URL parsers normalize dot segments.
        let after_authority = &input[input.find("://").unwrap() + 3 + authority.len()..];
        let raw_path = after_authority.split(['?', '#']).next().unwrap_or_default();
        let path = raw_path.trim_end_matches('/');
        let relay = path.strip_prefix("/d/").is_some_and(|id| {
            id.len() == 32
                && id
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        });
        if (!path.is_empty() && !relay) || raw_path.ends_with("//") {
            return Err(invalid());
        }
        let token = match url.fragment() {
            None | Some("") => None,
            Some(fragment) => {
                let value = fragment.strip_prefix("pair=").ok_or_else(invalid)?;
                if value.len() != 43
                    || !value
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
                {
                    return Err(invalid());
                }
                Some(value.to_owned())
            }
        };
        let origin = url.origin().ascii_serialization();
        Ok((
            Self {
                base: format!("{origin}{path}"),
                origin,
            },
            token,
        ))
    }

    pub fn endpoint(&self, path: &str, query: &[(&str, String)]) -> Result<Url> {
        if !path.starts_with("/api/") || path.contains(['?', '#', '%', '\\']) || path.contains("..")
        {
            return Err(BridgeError::Invalid("Invalid API path".into()));
        }
        let mut url = Url::parse(&format!("{}{path}", self.base))
            .map_err(|_| BridgeError::Invalid("Invalid API path".into()))?;
        if !query.is_empty() {
            url.query_pairs_mut()
                .extend_pairs(query.iter().map(|(key, value)| (*key, value.as_str())));
        }
        Ok(url)
    }
}

pub fn parse_connection(value: String) -> Result<ConnectionInput> {
    let (address, pairing_token) = GatewayAddress::parse(&value)?;
    Ok(ConnectionInput {
        base_url: address.base,
        pairing_token,
    })
}

pub fn validate_session(session: &SessionRef, computer_id: &str) -> Result<()> {
    validate_entry(session.provider, &session.entry)?;
    if session.computer_id != computer_id
        || session.id.is_empty()
        || session.id.len() > 512
        || session.environment.is_empty()
        || session.environment.len() > 256
        || session
            .id
            .chars()
            .chain(session.environment.chars())
            .any(char::is_control)
    {
        return Err(BridgeError::Invalid("Invalid session identity".into()));
    }
    if session.provider == Provider::Codex {
        let id = uuid::Uuid::parse_str(&session.id)
            .map_err(|_| BridgeError::Invalid("Invalid Codex session ID".into()))?;
        if id.to_string() != session.id {
            return Err(BridgeError::Invalid(
                "Codex session ID must be canonical".into(),
            ));
        }
    }
    Ok(())
}

pub(crate) fn validate_entry(provider: Provider, entry: &str) -> Result<()> {
    if entry.is_empty() {
        return Ok(());
    }
    let valid_family = entry.starts_with(&format!("{}:", provider.slug()))
        || provider == Provider::Codex && entry.starts_with("wsl:")
        || provider == Provider::Claude && entry.starts_with("wsl-claude:");
    if !valid_family
        || entry.len() > 256
        || entry
            .chars()
            .any(|c| c.is_control() || matches!(c, '/' | '\\' | '?' | '#'))
    {
        return Err(BridgeError::Invalid("Invalid client instance".into()));
    }
    Ok(())
}

pub fn fingerprint(value: &impl serde::Serialize) -> String {
    let bytes = serde_json::to_vec(value).expect("serializable protocol value");
    sha256_hex(&bytes)
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_encoding_retains_standard_lowercase_vectors() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(fingerprint(&"abc"), sha256_hex(br#""abc""#));
    }

    #[test]
    fn strict_addresses_and_pairing() {
        for value in [
            "http://10.0.0.1:8080",
            "http://127.0.0.1",
            "http://[::1]:8080",
            "http://example.com",
            "http://100.64.0.1",
            "http://[fd00::1]",
            "http://203.0.113.10:8787",
            "https://example.test",
            "https://example.test/d/0123456789abcdef0123456789abcdef/",
        ] {
            assert!(GatewayAddress::parse(value).is_ok(), "{value}");
        }
        for value in [
            "ftp://example.com",
            "http://127.1",
            "http://0177.0.0.1",
            "http://2130706433",
            "http://0x7f000001",
            "https://user:pass@example.com",
            "https://x.test/a/../",
            "https://x.test/?token=secret",
            "https://x.test//",
            "http://10.0.0.1:0",
            "https://x.test/#pair=bad",
            "https://x.test/%2e%2e/",
        ] {
            assert!(GatewayAddress::parse(value).is_err(), "{value}");
        }
        let (address, token) =
            GatewayAddress::parse(&format!("https://x.test/#pair={}", "x".repeat(43))).unwrap();
        assert_eq!(token.unwrap().len(), 43);
        assert_eq!(address.base, "https://x.test");
        assert!(
            !address
                .endpoint("/api/pair", &[])
                .unwrap()
                .as_str()
                .contains('#')
        );
    }

    #[test]
    fn http_and_https_are_explicit_distinct_origins() {
        let plain = GatewayAddress::parse("http://gateway.example:8787")
            .unwrap()
            .0;
        let secure = GatewayAddress::parse("https://gateway.example:8787")
            .unwrap()
            .0;
        assert_ne!(plain.origin, secure.origin);
        assert_eq!(plain.endpoint("/api/auth", &[]).unwrap().scheme(), "http");
        assert_eq!(secure.endpoint("/api/auth", &[]).unwrap().scheme(), "https");
    }

    #[test]
    fn desktop_identifiers_are_opaque_and_queries_are_encoded() {
        let session = SessionRef {
            entry: String::new(),
            computer_id: "a".into(),
            provider: Provider::Claude,
            environment: "ssh:work".into(),
            id: "cowork/session?x=1&y=2".into(),
        };
        validate_session(&session, "a").unwrap();
        assert!(validate_session(&session, "b").is_err());
        let address = GatewayAddress::parse("https://x.test").unwrap().0;
        let url = address
            .endpoint(
                "/api/desktop-sessions/claude/detail",
                &[("sessionId", session.id)],
            )
            .unwrap();
        assert_eq!(url.query_pairs().count(), 1);
    }
}
