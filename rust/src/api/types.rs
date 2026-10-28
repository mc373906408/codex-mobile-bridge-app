use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Codex,
    Claude,
    Deepseek,
}

impl Provider {
    pub(crate) fn slug(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
            Self::Deepseek => "deepseek",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Computer {
    pub id: String,
    pub name: String,
    pub base_url: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
pub struct SessionRef {
    pub computer_id: String,
    pub provider: Provider,
    pub environment: String,
    pub id: String,
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

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ClientInfo {
    pub provider: Provider,
    pub enabled: bool,
    pub connected: bool,
    pub readable: bool,
    pub reason: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SessionSummary {
    pub session: SessionRef,
    pub title: String,
    pub cwd: String,
    pub updated_at: String,
    pub status: String,
    pub backend: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SessionPage {
    pub sessions: Vec<SessionSummary>,
    pub next_offset: Option<u32>,
    pub notice: String,
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

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ChatMessage {
    pub id: String,
    pub role: String,
    pub title: String,
    pub text: String,
    pub output: String,
    pub truncated: bool,
    pub attachments: Vec<Attachment>,
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
}

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

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Draft {
    pub text: String,
    pub attachments: Vec<Attachment>,
    pub revision: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PendingOperation {
    pub id: String,
    pub action: String,
    pub created_at: i64,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PendingCreation {
    pub operation: PendingOperation,
    pub provider: Provider,
    pub environment: String,
    pub project_key: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct UiPreferences {
    pub theme: String,
    pub locale: String,
    pub read_inbox: Vec<String>,
}

impl Default for UiPreferences {
    fn default() -> Self {
        Self {
            theme: "system".into(),
            locale: "zh".into(),
            read_inbox: vec![],
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

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ProjectOption {
    pub key: String,
    pub name: String,
    pub cwd: String,
    pub environment: String,
    pub requires_message: bool,
    pub provider: Provider,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct InboxEntry {
    pub id: String,
    pub title: String,
    pub body: String,
    pub session: Option<SessionRef>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct GatewayEvent {
    pub subscription_id: String,
    pub snapshot: Option<SessionSnapshot>,
    pub authentication_required: bool,
    pub message: String,
}
