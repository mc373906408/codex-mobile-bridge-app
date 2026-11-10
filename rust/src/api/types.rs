use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};

pub use super::cloud_types::*;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Codex,
    Claude,
    Deepseek,
    Zcode,
}

impl Provider {
    pub(crate) fn slug(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
            Self::Deepseek => "deepseek",
            Self::Zcode => "zcode",
        }
    }
}

#[frb]
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
pub struct SessionRef {
    pub computer_id: String,
    pub provider: Provider,
    pub environment: String,
    pub id: String,
    /// Empty is the default family entry. Omit it to preserve v3 draft fingerprints.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    #[frb(default = "")]
    pub entry: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ConnectionInput {
    pub base_url: String,
    pub pairing_token: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct AuthStatus {
    pub authenticated: bool,
    pub computer_name: String,
    pub platform: String,
    pub passwordless: bool,
    pub notifications: bool,
    pub transport: String,
}

#[frb]
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ClientInfo {
    pub provider: Provider,
    pub enabled: bool,
    pub connected: bool,
    pub readable: bool,
    pub reason: String,
    #[serde(default)]
    #[frb(default = "")]
    pub entry: String,
    #[serde(default)]
    #[frb(default = "")]
    pub name: String,
    #[serde(default)]
    #[frb(default = "{}")]
    pub metadata: String,
}

#[frb]
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SessionSummary {
    pub session: SessionRef,
    pub title: String,
    pub cwd: String,
    pub updated_at: String,
    pub status: String,
    pub backend: String,
    #[serde(default)]
    #[frb(default = "")]
    pub environment_label: String,
    #[serde(default)]
    #[frb(default = false)]
    pub pinned: bool,
    #[serde(default)]
    #[frb(default = "{}")]
    pub metadata: String,
}

#[frb]
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SessionPage {
    pub sessions: Vec<SessionSummary>,
    pub next_offset: Option<u32>,
    pub notice: String,
    #[serde(default)]
    #[frb(default = "const []")]
    pub environment_issues: Vec<EnvironmentIssue>,
    #[serde(default)]
    #[frb(default = "const []")]
    pub available_sources: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct EnvironmentIssue {
    pub environment: String,
    pub label: String,
    pub reason: String,
    pub loading: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct CapabilitySet {
    pub send: bool,
    pub steer: bool,
    pub stop: bool,
    pub approve: bool,
    pub resume: bool,
    pub models: bool,
    pub attachments: bool,
    pub arbitrary_files: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Attachment {
    pub id: String,
    pub name: String,
    pub image: bool,
    pub source: String,
}

#[frb]
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ChatMessage {
    pub id: String,
    pub role: String,
    pub title: String,
    pub text: String,
    pub output: String,
    pub truncated: bool,
    pub attachments: Vec<Attachment>,
    #[serde(default)]
    #[frb(default = "{}")]
    pub metadata: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct QuestionOption {
    pub label: String,
    pub description: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ApprovalQuestion {
    pub id: String,
    pub question: String,
    pub options: Vec<QuestionOption>,
    pub multiple: bool,
    pub secret: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum ApprovalKind {
    Command,
    FileChange,
    Questions,
    Unsupported,
    Structured,
}

#[frb]
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ApprovalRequest {
    pub id: String,
    pub wire_id: String,
    pub kind: ApprovalKind,
    pub title: String,
    pub detail: String,
    pub supported: bool,
    pub can_accept: bool,
    pub can_decline: bool,
    pub questions: Vec<ApprovalQuestion>,
    pub fingerprint: String,
    #[serde(default)]
    #[frb(default = "{}")]
    pub metadata: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct QuestionAnswer {
    pub question_id: String,
    pub values: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct HistoryPage {
    pub messages: Vec<ChatMessage>,
    pub before: Option<String>,
    pub has_more: bool,
    pub epoch: String,
    pub reset: bool,
}

#[frb]
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SessionSnapshot {
    pub session: SessionRef,
    pub title: String,
    pub cwd: String,
    pub connected: bool,
    pub running: bool,
    pub status: String,
    pub model: String,
    pub effort: String,
    pub capabilities: CapabilitySet,
    pub approvals: Vec<ApprovalRequest>,
    pub history: HistoryPage,
    pub control_token: String,
    pub account_identity: String,
    pub sequence: i64,
    pub notice: String,
    #[serde(default)]
    #[frb(default = "{}")]
    pub metadata: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum OutcomeKind {
    Accepted,
    NotSubmitted,
    Unknown,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct OperationOutcome {
    pub id: String,
    pub kind: OutcomeKind,
    pub message: String,
    pub created_session: Option<SessionRef>,
}

#[frb]
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Draft {
    pub text: String,
    pub attachments: Vec<Attachment>,
    pub revision: u32,
    #[serde(default)]
    #[frb(default = "{}")]
    pub options: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PendingOperation {
    pub id: String,
    pub action: String,
    pub created_at: i64,
    pub message: String,
}

#[frb]
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PendingCreation {
    pub operation: PendingOperation,
    pub account_identity: String,
    pub provider: Provider,
    #[serde(default)]
    #[frb(default = "")]
    pub entry: String,
    pub environment: String,
    pub project_key: String,
}

#[frb]
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct UiPreferences {
    pub theme: String,
    pub locale: String,
    pub read_inbox: Vec<String>,
    #[serde(default)]
    #[frb(default = "{}")]
    pub presentation: String,
}

impl Default for UiPreferences {
    fn default() -> Self {
        Self {
            theme: "system".into(),
            locale: "zh".into(),
            read_inbox: vec![],
            presentation: "{}".into(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ModelOption {
    pub id: String,
    pub name: String,
    pub efforts: Vec<String>,
    pub default_effort: String,
}

#[frb]
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ProjectOption {
    pub key: String,
    pub name: String,
    pub cwd: String,
    pub environment: String,
    pub requires_message: bool,
    pub provider: Provider,
    #[serde(default)]
    #[frb(default = "")]
    pub entry: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct InboxEntry {
    pub id: String,
    pub title: String,
    pub body: String,
    pub session: Option<SessionRef>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct NotificationEvent {
    pub id: String,
    pub kind: String,
    pub created_at: f64,
    pub session: Option<SessionRef>,
    #[serde(default)]
    pub notification_id: Option<String>,
    #[serde(default)]
    pub expires_at: Option<i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct NotificationBatch {
    pub enabled: bool,
    pub scope: String,
    pub events: Vec<NotificationEvent>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct GatewayEvent {
    pub subscription_id: String,
    pub snapshot: Option<SessionSnapshot>,
    pub authentication_required: bool,
    pub message: String,
}
