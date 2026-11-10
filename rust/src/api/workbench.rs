use serde::{Deserialize, Serialize};

/// Closed business resources. Callers cannot supply a URL, host, entry or IPC method.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum SessionResource {
    Files,
    FileInfo,
    FilePreview,
    GitStatus,
    GitDiff,
    GitHistory,
    GitCommit,
    GitHistoryDiff,
    GitBranches,
    Terminal,
    SideChats,
    Subagents,
    Catalog,
    Permissions,
    Notifications,
    Organization,
    DeletePreview,
    MessageDetail,
    MessageManagement,
    Tasks,
    CliNetwork,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum SessionCommand {
    Rename,
    Pin,
    Archive,
    Delete,
    Organization,
    Send,
    CancelQueued,
    Settings,
    Permissions,
    Compact,
    Respond,
    MessageAction,
    MessageManagement,
    GoalEdit,
    GoalStatus,
    GoalCancel,
    Goal,
    Git,
    Terminal,
    SideChat,
    Notifications,
    StopTask,
    EditMessage,
    Fork,
    CliNetwork,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum GatewayResource {
    Clients,
    Entries,
    Projects,
    CreationModels,
    Accounts,
    Account,
    CliConnections,
    CliAccess,
    NetworkAdaptation,
    FileTransfer,
    NotificationDefaults,
    NotificationCommon,
    Ntfy,
    Bark,
    Pushplus,
    Webhook,
    WslEnvironments,
    WslAccounts,
    PendingOperations,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub enum GatewayCommand {
    Client,
    ReconnectClaude,
    ScanEntries,
    BrowseProjects,
    RegisterProject,
    TrustProject,
    AccountDetails,
    SwitchAccount,
    CliConnections,
    CliAccess,
    NetworkAdaptation,
    FileTransfer,
    NotificationDefaults,
    NotificationCommon,
    Ntfy,
    Bark,
    Pushplus,
    Webhook,
    WebhookEndpoints,
    TestNtfy,
    TestBark,
    TestPushplus,
    TestWebhook,
    SshRetry,
    InitializeCodex,
    AccountReminders,
    ResetDynamic,
    DesktopUpdate,
    WslAccounts,
    WebhookUrl,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct BusinessReply {
    pub outcome: super::types::OperationOutcome,
    pub data: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct GatewayState {
    pub identity: String,
    pub data: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct DownloadChunk {
    pub data: Vec<u8>,
    pub offset: i64,
    pub total: i64,
    pub etag: String,
    pub content_type: String,
}
