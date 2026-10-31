//! Preview-only crypto. This library has no account, control, or network APIs.
use anyhow::{Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use snow::Builder;
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

pub const MAX_PREVIEW: usize = 1024;
const MAX_INPUT: usize = 4096;
const PREVIEW: &str = "Noise_K_25519_ChaChaPoly_BLAKE2s";

pub fn exact_origin(value: &str) -> Result<url::Url> {
    let url = url::Url::parse(value)?;
    ensure!(
        value.is_ascii()
            && value.len() <= 2048
            && url.scheme() == "https"
            && url.host_str().is_some()
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none()
            && url.path() == "/"
            && url.as_str().strip_suffix('/') == Some(value),
        "exact canonical HTTPS origin required"
    );
    Ok(url)
}

pub fn key(encoded: &str) -> Result<[u8; 32]> {
    let key: [u8; 32] = STANDARD
        .decode(encoded)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("invalid key size"))?;
    ensure!(key != [0; 32], "invalid X25519 key");
    Ok(key)
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub v: u8,
    pub notification_id: Uuid,
    pub binding_id: Uuid,
    pub expires_at: i64,
    pub ciphertext: String,
}

pub fn preview_prologue(origin: &str, envelope: &Envelope) -> Result<Vec<u8>> {
    exact_origin(origin)?;
    ensure!(envelope.v == 1, "unsupported preview protocol");
    let mut out = b"bridge/preview/v1\0".to_vec();
    out.extend_from_slice(&(origin.len() as u16).to_be_bytes());
    out.extend_from_slice(origin.as_bytes());
    out.extend_from_slice(envelope.notification_id.as_bytes());
    out.extend_from_slice(envelope.binding_id.as_bytes());
    out.extend_from_slice(&envelope.expires_at.to_be_bytes());
    Ok(out)
}

pub fn decrypt_preview(
    origin: &str,
    private: &[u8],
    desktop: &[u8],
    envelope: &Envelope,
    now: i64,
) -> Result<Vec<u8>> {
    ensure!(
        now >= 0 && envelope.expires_at > now && envelope.expires_at <= now.saturating_add(3600),
        "expired preview"
    );
    let raw = STANDARD.decode(&envelope.ciphertext)?;
    ensure!(
        (48..=MAX_PREVIEW + 48).contains(&raw.len()),
        "invalid preview size"
    );
    let prologue = preview_prologue(origin, envelope)?;
    let mut state = Builder::new(PREVIEW.parse()?)
        .local_private_key(private)?
        .remote_public_key(desktop)?
        .prologue(&prologue)?
        .build_responder()?;
    let mut out = vec![0; MAX_PREVIEW];
    let size = state.read_message(&raw, &mut out)?;
    ensure!(
        state.is_handshake_finished(),
        "preview handshake incomplete"
    );
    out.truncate(size);
    Ok(out)
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PreviewCredentials {
    pub origin: String,
    pub binding_id: String,
    pub gateway_id: String,
    pub private_key: String,
    pub desktop_public_key: String,
}

impl Drop for PreviewCredentials {
    fn drop(&mut self) {
        self.private_key.zeroize();
    }
}

pub fn decrypt(credentials: &str, envelope: &str, now: i64) -> Result<String> {
    ensure!(
        credentials.len() <= MAX_INPUT && envelope.len() <= MAX_INPUT,
        "input too large"
    );
    let credentials: PreviewCredentials = serde_json::from_str(credentials)?;
    let envelope: Envelope = serde_json::from_str(envelope)?;
    let binding = Uuid::parse_str(&credentials.binding_id)?;
    ensure!(
        binding.to_string() == credentials.binding_id
            && envelope.binding_id == binding
            && Uuid::parse_str(&credentials.gateway_id)?.to_string() == credentials.gateway_id,
        "cross-binding preview"
    );
    let private = Zeroizing::new(key(&credentials.private_key)?);
    let desktop = key(&credentials.desktop_public_key)?;
    let plaintext = Zeroizing::new(decrypt_preview(
        &credentials.origin,
        private.as_ref(),
        &desktop,
        &envelope,
        now,
    )?);
    let mut value: serde_json::Value = serde_json::from_slice(&plaintext)?;
    ensure!(
        value.is_object()
            && value["gateway_id"] == credentials.gateway_id
            && value["binding_id"] == credentials.binding_id
            && value["notification_id"] == envelope.notification_id.to_string(),
        "invalid preview identity"
    );
    ensure!(
        value["title"]
            .as_str()
            .is_some_and(|s| !s.is_empty() && s.chars().count() <= 200)
            && value["body"]
                .as_str()
                .is_some_and(|s| s.chars().count() <= 600)
            && value["event_id"] == format!("cloud:{}", envelope.notification_id)
            && value["scope"].as_str().is_some_and(|s| s.len() == 64
                && s.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))),
        "invalid preview text or route"
    );
    value["origin"] = credentials.origin.clone().into();
    value["expires_at"] = envelope.expires_at.into();
    Ok(serde_json::to_string(&value)?)
}

/// Returns an owned UTF-8 JSON buffer, or null for a generic notification.
///
/// # Safety
/// Inputs must point to readable buffers of their declared lengths. `output_len`
/// must be writable. The result must be freed exactly once with its returned length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bridge_preview_decrypt(
    credentials: *const u8,
    credentials_len: usize,
    envelope: *const u8,
    envelope_len: usize,
    now: i64,
    output_len: *mut usize,
) -> *mut u8 {
    if output_len.is_null() {
        return std::ptr::null_mut();
    }
    unsafe { *output_len = 0 };
    if credentials.is_null()
        || envelope.is_null()
        || !(1..=MAX_INPUT).contains(&credentials_len)
        || !(1..=MAX_INPUT).contains(&envelope_len)
    {
        return std::ptr::null_mut();
    }
    let result = std::panic::catch_unwind(|| -> Result<Box<[u8]>> {
        let credentials = std::str::from_utf8(unsafe {
            std::slice::from_raw_parts(credentials, credentials_len)
        })?;
        let envelope =
            std::str::from_utf8(unsafe { std::slice::from_raw_parts(envelope, envelope_len) })?;
        Ok(decrypt(credentials, envelope, now)?
            .into_bytes()
            .into_boxed_slice())
    });
    match result {
        Ok(Ok(output)) => {
            unsafe { *output_len = output.len() };
            Box::into_raw(output).cast()
        }
        _ => std::ptr::null_mut(),
    }
}

/// Erases and releases a successful decrypt result.
///
/// # Safety
/// `buffer` and `length` must be the unchanged pair returned by
/// `bridge_preview_decrypt`, and must not have been freed before.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bridge_preview_free(buffer: *mut u8, length: usize) {
    if buffer.is_null() {
        return;
    }
    let mut output = unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(buffer, length)) };
    output.zeroize();
}

#[cfg(target_os = "android")]
mod android {
    use jni::{
        EnvUnowned, Outcome, jni_mangle,
        objects::{JObject, JString},
    };
    use zeroize::Zeroizing;

    #[jni_mangle("dev.waken.bridge_mobile.CloudPreview")]
    pub fn decrypt<'caller>(
        mut env: EnvUnowned<'caller>,
        _this: JObject<'caller>,
        credentials: JString<'caller>,
        envelope: JString<'caller>,
        now: i64,
    ) -> JString<'caller> {
        match env
            .with_env(|env| -> jni::errors::Result<_> {
                let credentials_chars = credentials.mutf8_chars(env)?;
                let envelope_chars = envelope.mutf8_chars(env)?;
                if credentials_chars.as_bytes().len() > super::MAX_INPUT
                    || envelope_chars.as_bytes().len() > super::MAX_INPUT
                {
                    return Ok(JString::null());
                }
                let credentials = Zeroizing::new(credentials_chars.to_string());
                let envelope = envelope_chars.to_string();
                match super::decrypt(&credentials, &envelope, now) {
                    Ok(output) => JString::from_str(env, Zeroizing::new(output).as_str()),
                    Err(_) => Ok(JString::null()),
                }
            })
            .into_outcome()
        {
            Outcome::Ok(value) => value,
            _ => JString::null(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn unchanged_python_vector_and_scope_tampering() -> Result<()> {
        let v: serde_json::Value =
            serde_json::from_str(include_str!("../../rust/tests/cloud_vectors.json"))?;
        let e: Envelope = serde_json::from_value(v["envelope"].clone())?;
        let field =
            |name: &str| -> Result<Vec<u8>> { Ok(STANDARD.decode(v[name].as_str().unwrap())?) };
        assert_eq!(
            preview_prologue(v["origin"].as_str().unwrap(), &e)?,
            field("preview_prologue")?
        );
        let open = |e: &Envelope, now| {
            decrypt_preview(
                v["origin"].as_str().unwrap(),
                &field("mobile_preview_private").unwrap(),
                &field("desktop_preview_public").unwrap(),
                e,
                now,
            )
        };
        assert_eq!(open(&e, e.expires_at - 1)?, field("preview_plaintext")?);
        assert!(open(&e, e.expires_at).is_err());
        assert!(open(&e, e.expires_at - 3601).is_err());
        let mut altered = e.clone();
        altered.notification_id = Uuid::nil();
        assert!(open(&altered, e.expires_at - 1).is_err());
        assert!(exact_origin("https://RELAY.test").is_err());
        assert!(exact_origin("https://relay.test:443").is_err());
        Ok(())
    }

    fn fixture_with_route(route: Option<(&str, &str)>) -> Result<(String, Envelope)> {
        let v: serde_json::Value =
            serde_json::from_str(include_str!("../../rust/tests/cloud_vectors.json"))?;
        let mut e: Envelope = serde_json::from_value(v["envelope"].clone())?;
        let desktop = key(v["desktop_preview_private"].as_str().unwrap())?;
        let mobile = key(v["mobile_preview_public"].as_str().unwrap())?;
        let prologue = preview_prologue(v["origin"].as_str().unwrap(), &e)?;
        let mut sender = Builder::new(PREVIEW.parse()?)
            .local_private_key(&desktop)?
            .remote_public_key(&mobile)?
            .prologue(&prologue)?
            .build_initiator()?;
        let event_id = format!("cloud:{}", e.notification_id);
        let scope = "a".repeat(64);
        let (scope, event_id) = route.unwrap_or((&scope, &event_id));
        let plaintext =
            serde_json::to_vec(&json!({"title":"Bridge", "body":"Private test preview",
            "event_id":event_id, "scope":scope, "gateway_id":v["gateway_id"],
            "binding_id":e.binding_id, "notification_id":e.notification_id}))?;
        let mut out = vec![0; MAX_PREVIEW + 48];
        let size = sender.write_message(&plaintext, &mut out)?;
        e.ciphertext = STANDARD.encode(&out[..size]);
        let credentials = serde_json::to_string(&PreviewCredentials {
            origin: v["origin"].as_str().unwrap().into(),
            binding_id: e.binding_id.to_string(),
            gateway_id: v["gateway_id"].as_str().unwrap().into(),
            private_key: v["mobile_preview_private"].as_str().unwrap().into(),
            desktop_public_key: v["desktop_preview_public"].as_str().unwrap().into(),
        })?;
        Ok((credentials, e))
    }

    fn fixture() -> Result<(String, Envelope)> {
        fixture_with_route(None)
    }

    #[test]
    fn python_production_form_vector_uses_real_native_decrypt() -> Result<()> {
        let v: serde_json::Value =
            serde_json::from_str(include_str!("../../rust/tests/cloud_preview.json"))?;
        let actual: serde_json::Value = serde_json::from_str(&decrypt(
            &v["credentials"].to_string(),
            &v["envelope"].to_string(),
            v["now"].as_i64().unwrap(),
        )?)?;
        assert_eq!(actual, v["expected"]);
        Ok(())
    }

    #[test]
    fn authenticated_arbitrary_routes_are_rejected_by_native_decrypt() -> Result<()> {
        for (scope, event) in [
            ("test-scope".to_owned(), "execute:task".to_owned()),
            ("a".repeat(64), "test-event".to_owned()),
            (
                "A".repeat(64),
                "cloud:00000000-0000-4000-8000-000000000004".to_owned(),
            ),
        ] {
            let (credentials, envelope) = fixture_with_route(Some((&scope, &event)))?;
            assert!(
                decrypt(
                    &credentials,
                    &serde_json::to_string(&envelope)?,
                    envelope.expires_at - 1
                )
                .is_err()
            );
        }
        Ok(())
    }

    #[test]
    fn native_identity_validation_and_generic_fallback() -> Result<()> {
        let (credentials, e) = fixture()?;
        let raw = serde_json::to_string(&e)?;
        let value: serde_json::Value =
            serde_json::from_str(&decrypt(&credentials, &raw, e.expires_at - 1)?)?;
        assert_eq!(value["origin"], "https://relay.example.test");
        assert!(decrypt(&credentials, &raw, e.expires_at).is_err());
        assert!(decrypt(&"x".repeat(4097), &raw, e.expires_at - 1).is_err());
        let mut changed: serde_json::Value = serde_json::from_str(&credentials)?;
        changed["binding_id"] = Uuid::nil().to_string().into();
        assert!(decrypt(&changed.to_string(), &raw, e.expires_at - 1).is_err());
        changed["control_private"] = "not allowed in a preview keychain".into();
        assert!(decrypt(&changed.to_string(), &raw, e.expires_at - 1).is_err());
        Ok(())
    }

    #[test]
    fn c_abi_returns_bounded_owned_buffer_and_null_on_failure() -> Result<()> {
        let (credentials, e) = fixture()?;
        let raw = serde_json::to_string(&e)?;
        let mut len = 0;
        let output = unsafe {
            bridge_preview_decrypt(
                credentials.as_ptr(),
                credentials.len(),
                raw.as_ptr(),
                raw.len(),
                e.expires_at - 1,
                &mut len,
            )
        };
        assert!(!output.is_null() && len <= 4096);
        let value: serde_json::Value =
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(output, len) })?;
        assert_eq!(value["notification_id"], e.notification_id.to_string());
        unsafe { bridge_preview_free(output, len) };
        let output = unsafe {
            bridge_preview_decrypt(
                std::ptr::null(),
                0,
                raw.as_ptr(),
                raw.len(),
                e.expires_at,
                &mut len,
            )
        };
        assert!(output.is_null() && len == 0);
        Ok(())
    }
}
