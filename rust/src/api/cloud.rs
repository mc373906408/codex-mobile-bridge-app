//! Account operations have no mobile redemption or purchase entry point.
use super::types::*;

#[flutter_rust_bridge::frb(sync)]
pub fn cloud_origin(origin: String) -> anyhow::Result<String> {
    crate::cloud_crypto::exact_origin(&origin)?;
    Ok(origin)
}

pub fn cloud_credential_state(
    credentials: String,
    origin: String,
    account_id: String,
) -> anyhow::Result<CloudCredentialState> {
    Ok(crate::relay::credential_state(
        &credentials,
        &origin,
        &account_id,
    )?)
}

pub fn cloud_binding_credentials(binding: String, account: String) -> anyhow::Result<String> {
    Ok(crate::relay::updated_binding_credentials(
        &binding, &account,
    )?)
}

pub fn cloud_signed_out_credentials(
    credentials: String,
    origin: String,
    account_id: String,
) -> anyhow::Result<String> {
    Ok(crate::relay::signed_out_credentials(
        &credentials,
        &origin,
        &account_id,
    )?)
}

pub async fn cloud_logout(
    credentials: String,
    origin: String,
    account_id: String,
) -> anyhow::Result<()> {
    Ok(crate::relay::account_logout(&credentials, &origin, &account_id).await?)
}

pub fn relay_invitation_origin(value: String) -> anyhow::Result<String> {
    Ok(crate::relay::invitation_origin(&value)?)
}
pub async fn cloud_capabilities(origin: String) -> anyhow::Result<CloudCapabilities> {
    Ok(crate::relay::capabilities(&origin).await?)
}
pub async fn cloud_login(
    origin: String,
    login: String,
    password: String,
    saved: Option<String>,
) -> anyhow::Result<CloudLogin> {
    Ok(crate::relay::login(origin, login, password, saved).await?)
}
pub async fn cloud_refresh(
    credentials: String,
    origin: String,
    account_id: String,
) -> anyhow::Result<String> {
    Ok(crate::relay::refresh(credentials, origin, account_id).await?)
}
pub async fn cloud_entitlement(
    credentials: String,
    origin: String,
    account_id: String,
) -> anyhow::Result<CloudEntitlement> {
    Ok(crate::relay::entitlement(&credentials, &origin, &account_id).await?)
}
pub async fn join_relay(
    invitation: String,
    credentials: String,
    name: String,
) -> anyhow::Result<RelayEnrollment> {
    Ok(crate::relay::enroll(&invitation, &credentials, name).await?)
}
