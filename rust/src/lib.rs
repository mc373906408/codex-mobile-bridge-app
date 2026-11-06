mod adapters;
#[cfg(target_os = "android")]
mod android_tls;
pub mod api;
mod cloud_crypto;
mod engine;
mod error;
mod events;
mod frb_generated;
mod persistence;
mod relay;
mod security;
mod transport;

pub(crate) fn crypto_provider() {
    // EasyTier enables ring while Bridge uses aws-lc; select explicitly before TLS.
    static INIT: std::sync::Once = std::sync::Once::new();
    INIT.call_once(|| {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    });
}

#[cfg(test)]
mod notification_tests;
#[cfg(test)]
mod tests;
