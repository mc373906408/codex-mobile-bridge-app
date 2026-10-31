use std::sync::Arc;

use flutter_rust_bridge::frb;

use super::types::*;
use crate::frb_generated::StreamSink;
use crate::{adapters, engine::Engine, persistence::Store, security};

#[frb(opaque)]
pub struct LocalDatabase {
    store: Arc<Store>,
}

impl LocalDatabase {
    pub async fn open(path: String) -> anyhow::Result<Self> {
        Ok(Self {
            store: Arc::new(Store::open(&path)?),
        })
    }

    pub async fn computers(&self) -> anyhow::Result<Vec<Computer>> {
        Ok(self.store.computers()?)
    }
    pub async fn preferences(&self) -> anyhow::Result<UiPreferences> {
        Ok(self.store.preferences()?)
    }
    pub async fn save_preferences(&self, value: UiPreferences) -> anyhow::Result<()> {
        Ok(self.store.save_preferences(&value)?)
    }
    pub async fn pending_creations(
        &self,
        computer: String,
    ) -> anyhow::Result<Vec<PendingCreation>> {
        Ok(self.store.pending_creations(&computer)?)
    }
    pub async fn review_creation(
        &self,
        computer: String,
        id: String,
        confirmed: bool,
    ) -> anyhow::Result<()> {
        Ok(self.store.review_creation(&computer, &id, confirmed)?)
    }
    pub async fn save_computer(&self, computer: Computer) -> anyhow::Result<()> {
        Ok(self.store.save_computer(&computer)?)
    }
    pub async fn remove_computer(&self, id: String) -> anyhow::Result<()> {
        Ok(self.store.remove_computer(&id)?)
    }

    pub async fn draft(&self, session: SessionRef, account: String) -> anyhow::Result<Draft> {
        Ok(self.store.draft(&Store::scope(&session, &account)?)?)
    }

    pub async fn save_draft(
        &self,
        session: SessionRef,
        account: String,
        draft: Draft,
    ) -> anyhow::Result<()> {
        Ok(self
            .store
            .save_draft(&Store::scope(&session, &account)?, &draft)?)
    }

    pub async fn pending(
        &self,
        session: SessionRef,
        account: String,
    ) -> anyhow::Result<Vec<PendingOperation>> {
        Ok(self.store.pending(&Store::scope(&session, &account)?)?)
    }

    pub async fn mark_reviewed(
        &self,
        session: SessionRef,
        account: String,
        id: String,
        confirmed: bool,
    ) -> anyhow::Result<()> {
        Ok(self
            .store
            .mark_reviewed(&Store::scope(&session, &account)?, &id, confirmed)?)
    }
}

#[frb(opaque)]
pub struct BridgeClient {
    engine: Arc<Engine>,
}

impl BridgeClient {
    pub async fn open(
        computer: Computer,
        database_path: String,
        platform: String,
        credentials: Option<String>,
    ) -> anyhow::Result<Self> {
        Ok(Self {
            engine: Arc::new(Engine::new(
                computer,
                &database_path,
                &platform,
                credentials.as_deref(),
            )?),
        })
    }

    pub async fn authenticate(&self) -> anyhow::Result<AuthStatus> {
        Ok(self.engine.transport.authenticate().await?)
    }
    pub async fn login(&self, username: String, password: String) -> anyhow::Result<AuthStatus> {
        Ok(self.engine.transport.login(username, password).await?)
    }
    pub async fn pair(&self, token: String) -> anyhow::Result<AuthStatus> {
        Ok(self.engine.transport.pair(token).await?)
    }
    pub async fn credentials(&self) -> anyhow::Result<Option<String>> {
        Ok(self.engine.transport.export_credentials()?)
    }
    pub async fn confirm_relay(&self, invitation: String) -> anyhow::Result<AuthStatus> {
        self.engine.transport.relay()?.confirm(&invitation).await?;
        Ok(self.engine.transport.authenticate().await?)
    }
    pub async fn preview_credentials(&self) -> anyhow::Result<String> {
        Ok(self.engine.transport.relay()?.preview_credentials()?)
    }
    pub async fn register_cloud_push(
        &self,
        platform: String,
        app_id: String,
        token: String,
        enabled: bool,
        consent: bool,
    ) -> anyhow::Result<()> {
        Ok(self
            .engine
            .transport
            .relay()?
            .endpoint(platform, app_id, token, enabled, consent)
            .await?)
    }
    pub async fn acknowledge_cloud_push(&self, ids: Vec<String>) -> anyhow::Result<()> {
        Ok(self.engine.transport.relay()?.acknowledge(ids).await?)
    }
    pub async fn logout(&self) -> anyhow::Result<()> {
        self.engine.pause();
        Ok(self.engine.transport.logout().await?)
    }
    pub async fn clients(&self) -> anyhow::Result<Vec<ClientInfo>> {
        Ok(self.engine.clients().await?)
    }

    pub async fn sessions(
        &self,
        provider: Provider,
        query: String,
        offset: u32,
    ) -> anyhow::Result<SessionPage> {
        Ok(adapters::sessions(
            &self.engine.transport,
            &self.engine.computer.id,
            provider,
            &query,
            offset,
        )
        .await?)
    }
    pub async fn snapshot(&self, session: SessionRef) -> anyhow::Result<SessionSnapshot> {
        Ok(self.engine.snapshot(&session).await?)
    }
    pub async fn history(
        &self,
        session: SessionRef,
        before: String,
    ) -> anyhow::Result<HistoryPage> {
        security::validate_session(&session, &self.engine.computer.id)?;
        Ok(adapters::history(&self.engine.transport, &session, &before).await?)
    }

    pub async fn send(
        &self,
        session: SessionRef,
        token: String,
        id: String,
        text: String,
        attachments: Vec<String>,
        steer: bool,
    ) -> anyhow::Result<OperationOutcome> {
        Ok(self
            .engine
            .send(&session, &token, &id, text, attachments, steer)
            .await?)
    }
    pub async fn stop(
        &self,
        session: SessionRef,
        token: String,
        id: String,
    ) -> anyhow::Result<OperationOutcome> {
        Ok(self.engine.stop(&session, &token, &id).await?)
    }
    pub async fn resume(
        &self,
        session: SessionRef,
        token: String,
        id: String,
    ) -> anyhow::Result<OperationOutcome> {
        Ok(self.engine.resume(&session, &token, &id).await?)
    }
    pub async fn respond(
        &self,
        session: SessionRef,
        token: String,
        id: String,
        request_id: String,
        accept: bool,
        answers: Vec<QuestionAnswer>,
    ) -> anyhow::Result<OperationOutcome> {
        Ok(self
            .engine
            .respond(&session, &token, &id, &request_id, accept, answers)
            .await?)
    }
    pub async fn models(&self, session: SessionRef) -> anyhow::Result<Vec<ModelOption>> {
        security::validate_session(&session, &self.engine.computer.id)?;
        Ok(adapters::catalog(&self.engine.transport, &session).await?)
    }
    pub async fn settings(
        &self,
        session: SessionRef,
        token: String,
        id: String,
        model: String,
        effort: String,
    ) -> anyhow::Result<OperationOutcome> {
        Ok(self
            .engine
            .settings(&session, &token, &id, model, effort)
            .await?)
    }
    pub async fn projects(
        &self,
        provider: Provider,
        environment: String,
    ) -> anyhow::Result<Vec<ProjectOption>> {
        Ok(adapters::projects(&self.engine.transport, provider, &environment).await?)
    }
    pub async fn create(
        &self,
        project: ProjectOption,
        title: String,
        text: String,
        id: String,
    ) -> anyhow::Result<OperationOutcome> {
        Ok(self.engine.create(project, title, text, &id).await?)
    }
    pub async fn upload(
        &self,
        session: SessionRef,
        token: String,
        id: String,
        name: String,
        bytes: Vec<u8>,
    ) -> anyhow::Result<Attachment> {
        Ok(self
            .engine
            .upload(&session, &token, &id, name, bytes)
            .await?)
    }
    pub async fn image(
        &self,
        session: SessionRef,
        attachment: Attachment,
    ) -> anyhow::Result<Vec<u8>> {
        Ok(self.engine.image(&session, &attachment).await?)
    }
    pub async fn inbox(&self) -> anyhow::Result<Vec<InboxEntry>> {
        Ok(self.engine.inbox().await?)
    }

    pub async fn notification_events(&self) -> anyhow::Result<NotificationBatch> {
        Ok(self.engine.notification_events().await?)
    }

    pub async fn watch_session(
        &self,
        session: SessionRef,
        subscription_id: String,
        sink: StreamSink<GatewayEvent>,
    ) -> anyhow::Result<()> {
        Ok(self
            .engine
            .watch(session, subscription_id, move |event| {
                sink.add(event).is_ok()
            })
            .await?)
    }
    pub async fn cancel_watch(&self, subscription_id: String) {
        self.engine.cancel(&subscription_id);
    }
    pub async fn pause(&self) {
        self.engine.pause();
    }
}

#[frb(sync)]
pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

pub fn parse_connection(value: String) -> anyhow::Result<ConnectionInput> {
    Ok(security::parse_connection(value)?)
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
