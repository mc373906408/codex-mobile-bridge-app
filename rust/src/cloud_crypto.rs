use anyhow::{Result, bail, ensure};
#[cfg(test)]
use base64::{Engine, engine::general_purpose::STANDARD};
use snow::{Builder, HandshakeState, TransportState};
use uuid::Uuid;

pub const MAX_CHUNK: usize = 32_768;
const CONTROL: &str = "Noise_KK_25519_ChaChaPoly_BLAKE2s";
#[cfg(test)]
use bridge_preview::{Envelope, decrypt_preview, preview_prologue};
pub use bridge_preview::{exact_origin, key};

fn origin_bytes(origin: &str) -> Result<Vec<u8>> {
    exact_origin(origin)?;
    let mut bytes = (origin.len() as u16).to_be_bytes().to_vec();
    bytes.extend_from_slice(origin.as_bytes());
    Ok(bytes)
}

pub fn new_keypair() -> Result<snow::Keypair> {
    Ok(Builder::new(CONTROL.parse()?).generate_keypair()?)
}

pub fn public_key(private: &[u8]) -> Result<[u8; 32]> {
    use snow::resolvers::{CryptoResolver, DefaultResolver};
    ensure!(private.len() == 32, "invalid private key size");
    let mut dh = DefaultResolver
        .resolve_dh(&snow::params::DHChoice::Curve25519)
        .ok_or_else(|| anyhow::anyhow!("X25519 unavailable"))?;
    dh.set(private);
    Ok(dh.pubkey().try_into()?)
}

pub fn control_prologue(
    origin: &str,
    gateway: Uuid,
    binding: Uuid,
    channel: Uuid,
    desktop: &[u8; 32],
    mobile: &[u8; 32],
) -> Result<Vec<u8>> {
    let mut out = b"bridge/control/v1\0".to_vec();
    out.extend(origin_bytes(origin)?);
    for id in [gateway, binding, channel] {
        out.extend_from_slice(id.as_bytes());
    }
    out.extend_from_slice(desktop);
    out.extend_from_slice(mobile);
    Ok(out)
}

pub fn handshake(
    private: &[u8],
    remote: &[u8],
    prologue: &[u8],
    initiator: bool,
) -> Result<HandshakeState> {
    let builder = Builder::new(CONTROL.parse()?)
        .local_private_key(private)?
        .remote_public_key(remote)?
        .prologue(prologue)?;
    Ok(if initiator {
        builder.build_initiator()?
    } else {
        builder.build_responder()?
    })
}

pub fn handshake_read(state: &mut HandshakeState, message: &[u8]) -> Result<()> {
    ensure!(message.len() <= MAX_CHUNK + 16, "handshake too large");
    let mut out = vec![0; MAX_CHUNK];
    ensure!(
        state.read_message(message, &mut out)? == 0,
        "early application data forbidden"
    );
    Ok(())
}

pub fn handshake_write(state: &mut HandshakeState) -> Result<Vec<u8>> {
    let mut out = vec![0; MAX_CHUNK + 16];
    let size = state.write_message(&[], &mut out)?;
    out.truncate(size);
    Ok(out)
}

pub struct ControlCipher {
    state: TransportState,
    failed: bool,
}
impl ControlCipher {
    pub fn new(state: HandshakeState) -> Result<Self> {
        ensure!(state.is_handshake_finished(), "handshake incomplete");
        Ok(Self {
            state: state.into_transport_mode()?,
            failed: false,
        })
    }
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>> {
        if self.failed || plaintext.len() > MAX_CHUNK {
            self.failed = true;
            bail!("channel closed or chunk too large");
        }
        let mut out = vec![0; plaintext.len() + 16];
        match self.state.write_message(plaintext, &mut out) {
            Ok(size) => {
                out.truncate(size);
                Ok(out)
            }
            Err(_) => {
                self.failed = true;
                bail!("record authentication failed")
            }
        }
    }
    pub fn decrypt(&mut self, ciphertext: &[u8]) -> Result<Vec<u8>> {
        if self.failed || !(16..=MAX_CHUNK + 16).contains(&ciphertext.len()) {
            self.failed = true;
            bail!("channel closed or invalid record size");
        }
        let mut out = vec![0; ciphertext.len()];
        match self.state.read_message(ciphertext, &mut out) {
            Ok(size) => {
                out.truncate(size);
                Ok(out)
            }
            Err(_) => {
                self.failed = true;
                bail!("record authentication failed")
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct Frame {
    pub kind: u8,
    pub binding: Uuid,
    pub channel: Uuid,
    pub payload: Vec<u8>,
}
impl Frame {
    pub fn encode(&self) -> Result<Vec<u8>> {
        ensure!(
            match self.kind {
                1 => self.payload.len() == 32,
                2 => (16..=MAX_CHUNK + 16).contains(&self.payload.len()),
                3 => self.payload.is_empty(),
                _ => false,
            },
            "invalid relay frame"
        );
        let mut out = vec![1, self.kind];
        out.extend_from_slice(self.binding.as_bytes());
        out.extend_from_slice(self.channel.as_bytes());
        out.extend_from_slice(&self.payload);
        Ok(out)
    }
    pub fn decode(raw: &[u8]) -> Result<Self> {
        ensure!(raw.len() >= 34 && raw[0] == 1, "invalid relay version");
        let frame = Self {
            kind: raw[1],
            binding: Uuid::from_slice(&raw[2..18])?,
            channel: Uuid::from_slice(&raw[18..34])?,
            payload: raw[34..].to_vec(),
        };
        frame.encode()?;
        Ok(frame)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn python_vectors_and_authenticated_boundaries() -> Result<()> {
        let v: serde_json::Value =
            serde_json::from_str(include_str!("../tests/cloud_vectors.json"))?;
        let field =
            |name: &str| -> Result<Vec<u8>> { Ok(STANDARD.decode(v[name].as_str().unwrap())?) };
        let desktop = field("desktop_private")?;
        let mobile = field("mobile_private")?;
        let dp: [u8; 32] = field("desktop_public")?.try_into().unwrap();
        let mp: [u8; 32] = field("mobile_public")?.try_into().unwrap();
        let origin = v["origin"].as_str().unwrap();
        let id = |name: &str| Uuid::parse_str(v[name].as_str().unwrap()).unwrap();
        let p = control_prologue(
            origin,
            id("gateway_id"),
            id("binding_id"),
            id("channel_id"),
            &dp,
            &mp,
        )?;
        assert_eq!(p, field("control_prologue")?);
        let ephemeral = field("mobile_ephemeral")?;
        let mut hs = Builder::new(CONTROL.parse()?)
            .local_private_key(&mobile)?
            .remote_public_key(&dp)?
            .prologue(&p)?
            .fixed_ephemeral_key_for_testing_only(&ephemeral)
            .build_initiator()?;
        assert_eq!(handshake_write(&mut hs)?, field("kk_first")?);
        handshake_read(&mut hs, &field("kk_second")?)?;
        let mut cipher = ControlCipher::new(hs)?;
        assert_eq!(
            cipher.decrypt(&field("desktop_record")?)?,
            b"{\"kind\":\"ready\"}"
        );
        assert_eq!(
            cipher.encrypt(b"{\"kind\":\"key_confirm\"}")?,
            field("mobile_record")?
        );
        assert!(cipher.decrypt(&field("desktop_record")?).is_err());
        assert!(cipher.encrypt(b"after failure").is_err());
        let mut wrong = p.clone();
        wrong[0] ^= 1;
        let mut hs = handshake(&desktop, &mp, &wrong, false)?;
        assert!(handshake_read(&mut hs, &field("kk_first")?).is_err());
        let e: Envelope = serde_json::from_value(v["envelope"].clone())?;
        assert_eq!(preview_prologue(origin, &e)?, field("preview_prologue")?);
        assert_eq!(
            decrypt_preview(
                origin,
                &field("mobile_preview_private")?,
                &field("desktop_preview_public")?,
                &e,
                e.expires_at - 1
            )?,
            field("preview_plaintext")?
        );
        let mut substituted = e.clone();
        substituted.binding_id = Uuid::new_v4();
        assert!(
            decrypt_preview(
                origin,
                &field("mobile_preview_private")?,
                &field("desktop_preview_public")?,
                &substituted,
                e.expires_at - 1
            )
            .is_err()
        );
        assert!(
            decrypt_preview(
                origin,
                &field("mobile_preview_private")?,
                &field("desktop_preview_public")?,
                &e,
                e.expires_at
            )
            .is_err()
        );
        Ok(())
    }
}
