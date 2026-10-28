use super::desktop;
use crate::{api::types::*, error::Result, transport::Transport};

pub async fn sessions(
    transport: &Transport,
    computer: &str,
    query: &str,
    offset: u32,
) -> Result<SessionPage> {
    desktop::sessions(transport, computer, Provider::Deepseek, query, offset).await
}

pub async fn snapshot(transport: &Transport, session: &SessionRef) -> Result<SessionSnapshot> {
    let value = desktop::detail(transport, session, None).await?;
    desktop::parse_snapshot(&value, session, &transport.identity(), false)
}

pub async fn history(
    transport: &Transport,
    session: &SessionRef,
    before: &str,
) -> Result<HistoryPage> {
    desktop::parse_history(&desktop::detail(transport, session, Some(before)).await?)
}
