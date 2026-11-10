use super::*;
use crate::api::workbench::*;
use crate::security::validate_entry;

fn object(raw: &str) -> Result<Value> {
    if raw.len() > 512_000 {
        return Err(BridgeError::TooLarge);
    }
    let value: Value = serde_json::from_str(raw)?;
    if !value.is_object() {
        return Err(BridgeError::Invalid("Expected business parameters".into()));
    }
    Ok(value)
}

fn parameters(raw: &str) -> Result<Vec<(String, String)>> {
    let value = object(raw)?;
    let allowed = [
        "path",
        "hidden",
        "search",
        "offset",
        "limit",
        "revision",
        "ref",
        "section",
        "mode",
        "id",
        "after",
        "waitMs",
        "key",
        "version",
        "kind",
        "q",
        "refresh",
        "view",
        "environment",
        "projectKey",
        "project",
    ];
    let mut result = vec![];
    for (key, value) in value.as_object().unwrap() {
        if !allowed.contains(&key.as_str()) {
            return Err(BridgeError::Invalid(
                "Unsupported resource parameter".into(),
            ));
        }
        let values = value
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or(std::slice::from_ref(value));
        for value in values {
            if !value.is_string() && !value.is_boolean() && !value.is_number() {
                return Err(BridgeError::Invalid("Invalid resource parameter".into()));
            }
            result.push((
                key.clone(),
                value
                    .as_str()
                    .map(str::to_owned)
                    .unwrap_or_else(|| value.to_string()),
            ));
        }
    }
    Ok(result)
}

impl SessionResource {
    fn path(self) -> &'static str {
        match self {
            Self::Files => "workspace",
            Self::FileInfo => "workspace/info",
            Self::FilePreview => "workspace/preview",
            Self::GitStatus => "workspace/git-status",
            Self::GitDiff => "workspace/git-diff",
            Self::GitHistory => "workspace/git-history",
            Self::GitCommit => "workspace/git-commit",
            Self::GitHistoryDiff => "workspace/git-history-diff",
            Self::GitBranches => "workspace/git-branches",
            Self::Terminal => "terminal",
            Self::SideChats => "side-chat",
            Self::Subagents => "subagents",
            Self::Catalog => "catalog",
            Self::Permissions => "permissions",
            Self::Notifications => "notifications",
            Self::Organization => "organization",
            Self::DeletePreview => "delete",
            Self::MessageDetail => "detail",
            Self::MessageManagement => "message-management",
            Self::Tasks => "tasks",
            Self::CliNetwork => "cli-network",
        }
    }
}

impl SessionCommand {
    fn path(self) -> &'static str {
        match self {
            Self::Rename => "rename",
            Self::Pin => "pin",
            Self::Archive => "archive",
            Self::Delete => "delete",
            Self::Organization => "organization",
            Self::Send => "send",
            Self::CancelQueued => "queue",
            Self::Settings => "settings",
            Self::Permissions => "permissions",
            Self::Compact => "compact",
            Self::Respond => "respond",
            Self::MessageAction => "message-action",
            Self::MessageManagement => "message-management",
            Self::GoalEdit => "goal/edit",
            Self::GoalStatus => "goal/status",
            Self::GoalCancel => "goal/cancel",
            Self::Goal => "goal",
            Self::Git => "workspace/git-action",
            Self::Terminal => "terminal",
            Self::SideChat => "side-chat",
            Self::Notifications => "notifications",
            Self::StopTask => "stop-task",
            Self::EditMessage => "edit-message",
            Self::Fork => "fork",
            Self::CliNetwork => "cli-network",
        }
    }
    fn controls_turn(self) -> bool {
        matches!(
            self,
            Self::Send
                | Self::Settings
                | Self::Permissions
                | Self::Compact
                | Self::Respond
                | Self::MessageAction
                | Self::GoalEdit
                | Self::GoalStatus
                | Self::GoalCancel
                | Self::Goal
                | Self::StopTask
                | Self::EditMessage
                | Self::Fork
        )
    }
}

impl Engine {
    pub(crate) async fn upload_workspace(
        &self,
        session: &SessionRef,
        account: &str,
        id: &str,
        path: &str,
        bytes: Vec<u8>,
    ) -> Result<BusinessReply> {
        let _guard = self.writes.lock().await;
        let current = self.snapshot(session).await?;
        if current.account_identity != account
            || account.is_empty()
            || path.is_empty()
            || bytes.len() > MAX_FILE
        {
            return Err(BridgeError::Invalid(
                "Invalid upload scope, path or size".into(),
            ));
        }
        let scope = Store::scope(session, account)?;
        let body = json!({"path":path,"sha256":crate::security::sha256_hex(&bytes)});
        if let Some(outcome) = self.store.begin(id, &scope, "workspace/upload", &body)? {
            return Ok(BusinessReply {
                outcome,
                data: "{}".into(),
            });
        }
        let (url, mut query) = adapters::route(session, "workspace/upload");
        query.push(("path", path.into()));
        let result = match self
            .transport
            .request(
                Method::POST,
                &url,
                &query,
                Some(bytes),
                "application/octet-stream",
            )
            .await
        {
            Ok(response) => Transport::decode(response).await,
            Err(error) => Err(error),
        };
        let (outcome, data) = match result {
            Ok(value) if value["path"].is_string() || value["ok"] == true => (
                OperationOutcome {
                    id: id.into(),
                    kind: OutcomeKind::Accepted,
                    message: String::new(),
                    created_session: None,
                },
                value.to_string(),
            ),
            Ok(value) => (
                unknown(id, "Upload result needs review; it will not be replayed"),
                value.to_string(),
            ),
            Err(error) => (unknown(id, &error.to_string()), "{}".into()),
        };
        self.store.finish(&outcome)?;
        Ok(BusinessReply { outcome, data })
    }
    pub(crate) async fn gateway_resource(
        &self,
        provider: Provider,
        entry: &str,
        resource: GatewayResource,
        raw: &str,
    ) -> Result<GatewayState> {
        validate_entry(provider, entry)?;
        if !self.transport.authenticate_if_needed().await?.authenticated {
            return Err(BridgeError::Unauthenticated);
        }
        let bound = account_resource(resource);
        let identity = self.gateway_identity(provider, entry, bound).await?;
        if resource == GatewayResource::PendingOperations {
            let session = SessionRef {
                computer_id: self.computer.id.clone(),
                provider,
                entry: entry.into(),
                environment: "local".into(),
                id: "management".into(),
            };
            return Ok(GatewayState {
                identity,
                data: json!({"operations": self.store.pending_management(&session, &self.transport.identity())?}).to_string(),
            });
        }
        let path = gateway_read_path(provider, resource);
        let mut query_body = object(raw)?;
        let host = query_body.as_object_mut().unwrap().remove("host");
        let mut params = parameters(&query_body.to_string())?;
        if matches!(
            resource,
            GatewayResource::WslEnvironments | GatewayResource::WslAccounts
        ) {
            if !params.is_empty()
                || host.is_some()
                || !matches!(provider, Provider::Codex | Provider::Claude)
            {
                return Err(BridgeError::Invalid("Invalid WSL account query".into()));
            }
            params.push(("provider".into(), provider.slug().into()));
            if resource == GatewayResource::WslAccounts {
                if !entry.starts_with("wsl:") && !entry.starts_with("wsl-claude:") {
                    return Err(BridgeError::Invalid(
                        "Select a registered WSL environment".into(),
                    ));
                }
                params.push(("entry".into(), entry.into()));
            }
        }
        if let Some(host) = host {
            if !matches!(
                resource,
                GatewayResource::Projects | GatewayResource::CreationModels
            ) || !host.is_string()
            {
                return Err(BridgeError::Invalid("Invalid project host".into()));
            }
            params.push(("host".into(), host.as_str().unwrap().into()));
        }
        if !entry.is_empty()
            && matches!(
                resource,
                GatewayResource::Accounts
                    | GatewayResource::Account
                    | GatewayResource::Projects
                    | GatewayResource::CreationModels
            )
        {
            params.push(("entry".into(), entry.into()));
        }
        let query: Vec<_> = params
            .iter()
            .map(|(k, v)| (k.as_str(), v.clone()))
            .collect();
        let mut value = self.transport.get(&path, &query).await?;
        if resource == GatewayResource::Projects {
            adapters::add_independent_projects(&mut value, provider);
        }
        let data = value.to_string();
        if identity != self.gateway_identity(provider, entry, bound).await? {
            return Err(BridgeError::Cancelled);
        }
        Ok(GatewayState { identity, data })
    }

    pub(crate) async fn gateway_identity(
        &self,
        provider: Provider,
        entry: &str,
        account_bound: bool,
    ) -> Result<String> {
        validate_entry(provider, entry)?;
        let transport = self.transport.identity();
        if !entry.is_empty() {
            let clients = self.transport.get("/api/clients", &[]).await?;
            let known = array(&clients, "clients").iter().any(|row| {
                row["id"] == entry
                    || array(row, "entries")
                        .iter()
                        .any(|child| child["id"] == entry)
            });
            if !known {
                return Err(BridgeError::Invalid(
                    "The selected client instance is unavailable".into(),
                ));
            }
        }
        if !account_bound {
            return Ok(transport);
        }
        let wsl = entry.starts_with("wsl:") || entry.starts_with("wsl-claude:");
        let path = if wsl {
            "/api/wsl-accounts".into()
        } else {
            gateway_read_path(provider, GatewayResource::Accounts)
        };
        let query = if wsl {
            vec![
                ("provider", provider.slug().into()),
                ("entry", entry.into()),
            ]
        } else if entry.is_empty() {
            vec![]
        } else {
            vec![("entry", entry.into())]
        };
        let accounts = self.transport.get(&path, &query).await?;
        let revision = accounts["managementRevision"]
            .as_str()
            .or_else(|| accounts["modelCatalogIdentity"].as_str())
            .or_else(|| {
                if wsl {
                    accounts["identity"]
                        .as_str()
                        .or_else(|| (accounts["available"] == false).then_some("unavailable"))
                } else {
                    None
                }
            })
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                BridgeError::Invalid(
                    "The gateway cannot verify the current coding account/configuration".into(),
                )
            })?;
        if transport != self.transport.identity() {
            return Err(BridgeError::Cancelled);
        }
        Ok(crate::security::sha256_hex(
            json!([
                "management-v1",
                transport,
                provider,
                entry,
                accounts["activeId"],
                accounts["activeIds"],
                revision
            ])
            .to_string()
            .as_bytes(),
        ))
    }

    pub(crate) async fn gateway_command(
        &self,
        provider: Provider,
        entry: &str,
        identity: &str,
        id: &str,
        command: GatewayCommand,
        raw: &str,
    ) -> Result<BusinessReply> {
        let _guard = self.writes.lock().await;
        validate_entry(provider, entry)?;
        if !self.transport.authenticate().await?.authenticated
            || identity.is_empty()
            || self
                .gateway_identity(provider, entry, account_command(command))
                .await?
                != identity
        {
            return Err(BridgeError::Unauthenticated);
        }
        let mut body = object(raw)?;
        if body.get("entry").is_some()
            || body.get("host").is_some()
                && !matches!(
                    command,
                    GatewayCommand::BrowseProjects
                        | GatewayCommand::RegisterProject
                        | GatewayCommand::SshRetry
                )
        {
            return Err(BridgeError::Invalid("Identity cannot be overridden".into()));
        }
        if command == GatewayCommand::Client && body != json!({"action":"scan-wsl"}) {
            body["provider"] = json!(if entry.is_empty() {
                provider.slug()
            } else {
                entry
            });
        }
        if command == GatewayCommand::ScanEntries {
            body = json!({"action":"scan"});
        }
        if command == GatewayCommand::WslAccounts {
            if !entry.starts_with("wsl:") && !entry.starts_with("wsl-claude:") {
                return Err(BridgeError::Invalid(
                    "Select a registered WSL environment".into(),
                ));
            }
            if body.get("provider").is_some() {
                return Err(BridgeError::Invalid("Identity cannot be overridden".into()));
            }
            body["provider"] = json!(provider.slug());
            body["entry"] = json!(entry);
        }
        if provider != Provider::Codex
            && matches!(
                command,
                GatewayCommand::AccountDetails | GatewayCommand::SwitchAccount
            )
        {
            body["action"] = json!(if command == GatewayCommand::AccountDetails {
                "details"
            } else {
                "switch"
            });
        }
        let path = gateway_write_path(provider, command);
        let query = if entry.is_empty()
            || !matches!(
                command,
                GatewayCommand::AccountDetails
                    | GatewayCommand::SwitchAccount
                    | GatewayCommand::InitializeCodex
                    | GatewayCommand::AccountReminders
                    | GatewayCommand::ResetDynamic
                    | GatewayCommand::DesktopUpdate
                    | GatewayCommand::SshRetry
                    | GatewayCommand::BrowseProjects
                    | GatewayCommand::RegisterProject
                    | GatewayCommand::TrustProject
                    | GatewayCommand::ReconnectClaude
            ) {
            vec![]
        } else {
            vec![("entry", entry.into())]
        };
        let scope = Store::scope(
            &SessionRef {
                computer_id: self.computer.id.clone(),
                provider,
                environment: "local".into(),
                id: "management".into(),
                entry: entry.into(),
            },
            identity,
        )?;
        let result = self
            .business_write(
                &scope,
                id,
                &format!("gateway/{command:?}"),
                &path,
                &query,
                body,
            )
            .await?;
        if !matches!(
            command,
            GatewayCommand::SwitchAccount | GatewayCommand::WslAccounts
        ) && identity
            != self
                .gateway_identity(provider, entry, account_command(command))
                .await?
        {
            return Err(BridgeError::Invalid("Account changed after submission; the saved result must be reviewed before continuing".into()));
        }
        Ok(result)
    }

    pub(crate) async fn download_chunk(
        &self,
        session: &SessionRef,
        account: &str,
        path: &str,
        archive: bool,
        offset: i64,
        etag: &str,
    ) -> Result<DownloadChunk> {
        let current = self.snapshot(session).await?;
        if current.account_identity != account
            || account.is_empty()
            || !(0..=i64::MAX - 4_194_304).contains(&offset)
            || offset > 0 && etag.is_empty()
        {
            return Err(BridgeError::Invalid(
                "Download scope or cursor changed".into(),
            ));
        }
        let (url, mut query) = adapters::route(session, "workspace/download");
        query.extend([("path", path.into()), ("explicit", "1".into())]);
        if archive {
            query.push(("archive", "1".into()));
        }
        let response = self
            .transport
            .request_with_range(
                Method::GET,
                &url,
                &query,
                None,
                "",
                Some((offset as u64, offset as u64 + 4_194_303, etag)),
            )
            .await?;
        let status = response.status().as_u16();
        if !response.status().is_success() {
            Transport::decode(response).await?;
            return Err(BridgeError::Protocol("Download failed".into()));
        }
        let header = |name: &str| {
            response
                .headers()
                .get(name)
                .and_then(|v| v.to_str().ok())
                .unwrap_or_default()
                .to_owned()
        };
        let tag = header("etag");
        let content_type = header("content-type");
        if !etag.is_empty() && (etag != tag || status != 206) {
            return Err(BridgeError::Invalid(
                "The file changed; restart this download".into(),
            ));
        }
        let (start, end, total) = if status == 206 {
            parse_content_range(&header("content-range"))?
        } else if status == 200 && offset == 0 {
            let length = response
                .content_length()
                .ok_or_else(|| BridgeError::Protocol("Missing file length".into()))?
                as i64;
            (0, length - 1, length)
        } else {
            return Err(BridgeError::Protocol("Invalid download response".into()));
        };
        if start != offset || total < 0 || end >= total || end < start - 1 {
            return Err(BridgeError::Protocol("Download range changed".into()));
        }
        let data = Transport::bounded_bytes(response, 4_194_304).await?;
        if data.len() as i64 != end - start + 1 || total > end + 1 && tag.is_empty() {
            return Err(BridgeError::Protocol("Incomplete download range".into()));
        }
        if self.snapshot(session).await?.account_identity != account {
            return Err(BridgeError::Cancelled);
        }
        Ok(DownloadChunk {
            data,
            offset,
            total,
            etag: tag,
            content_type,
        })
    }

    pub(crate) async fn sessions_for_entry(
        &self,
        provider: Provider,
        entry: &str,
        search: &str,
        offset: u32,
        source: &str,
        archived: bool,
    ) -> Result<SessionPage> {
        validate_entry(provider, entry)?;
        if entry.is_empty() && source == "all" && !archived {
            return adapters::sessions(
                &self.transport,
                &self.computer.id,
                provider,
                search,
                offset,
            )
            .await;
        }
        self.require_entry(provider, entry).await?;
        let mut query = vec![(
            "entry",
            if entry.is_empty() {
                "desktop".into()
            } else {
                entry.into()
            },
        )];
        if provider == Provider::Codex {
            query.extend([
                ("q", search.into()),
                ("offset", offset.to_string()),
                ("source", source.into()),
                ("archived", archived.to_string()),
            ]);
            let value = self.transport.get("/api/sessions", &query).await?;
            let mut page = adapters::codex::parse_sessions(&value, &self.computer.id, offset)?;
            for row in &mut page.sessions {
                row.session.entry = entry.into();
            }
            return Ok(page);
        }
        if entry.is_empty() {
            query.clear();
        }
        let mut value = self
            .transport
            .get(
                &format!("/api/desktop-sessions/{}/list", provider.slug()),
                &query,
            )
            .await?;
        value["availableSources"] = json!(
            array(&value, "sessions")
                .iter()
                .filter_map(|row| row["runtime"].as_str().or(row["backend"].as_str()))
                .collect::<std::collections::BTreeSet<_>>()
        );
        if source != "all"
            && let Some(rows) = value["sessions"].as_array_mut()
        {
            rows.retain(|row| row["runtime"].as_str().or(row["backend"].as_str()) == Some(source));
        }
        adapters::parse_desktop_sessions(
            &value,
            &self.computer.id,
            provider,
            entry,
            search,
            offset,
            archived,
        )
    }

    async fn require_entry(&self, provider: Provider, entry: &str) -> Result<()> {
        validate_entry(provider, entry)?;
        if !self.transport.authenticate_if_needed().await?.authenticated {
            return Err(BridgeError::Unauthenticated);
        }
        if !self
            .clients()
            .await?
            .iter()
            .any(|v| v.provider == provider && v.entry == entry && v.enabled)
        {
            return Err(BridgeError::Invalid(
                "The selected client instance is unavailable".into(),
            ));
        }
        Ok(())
    }

    pub(crate) async fn projects_for_entry(
        &self,
        provider: Provider,
        entry: &str,
        environment: &str,
    ) -> Result<Vec<ProjectOption>> {
        if entry.is_empty() {
            return adapters::projects(&self.transport, provider, environment).await;
        }
        self.require_entry(provider, entry).await?;
        let path = if provider == Provider::Codex {
            "/api/projects".into()
        } else {
            format!("/api/desktop-sessions/{}/projects", provider.slug())
        };
        let mut value = self
            .transport
            .get(&path, &[("entry", entry.into())])
            .await?;
        adapters::add_independent_projects(&mut value, provider);
        Ok(array(&value, "projects")
            .iter()
            .filter_map(|row| {
                Some(ProjectOption {
                    key: row["key"].as_str()?.into(),
                    name: row["name"]
                        .as_str()
                        .or_else(|| row["label"].as_str())
                        .unwrap_or("Project")
                        .into(),
                    cwd: text(row, "cwd"),
                    environment: row["host"].as_str().unwrap_or(environment).into(),
                    requires_message: row["createRequiresMessage"] == true
                        || value["createRequiresMessage"] == true,
                    provider,
                    entry: entry.into(),
                })
            })
            .collect())
    }

    pub(crate) async fn session_resource(
        &self,
        session: &SessionRef,
        resource: SessionResource,
        raw: &str,
    ) -> Result<String> {
        validate_session(session, &self.computer.id)?;
        self.require_entry(session.provider, &session.entry).await?;
        let action =
            if session.provider != Provider::Codex && resource == SessionResource::Permissions {
                "access"
            } else {
                resource.path()
            };
        let (path, base) = adapters::route(session, action);
        let mut values: Vec<(String, String)> =
            base.into_iter().map(|(k, v)| (k.into(), v)).collect();
        let mut extra = parameters(raw)?;
        if session.provider != Provider::Codex && resource == SessionResource::Catalog {
            for (key, _) in &mut extra {
                if key == "kind" {
                    *key = "section".into();
                }
            }
        }
        values.extend(extra);
        let query: Vec<_> = values
            .iter()
            .map(|(k, v)| (k.as_str(), v.clone()))
            .collect();
        Ok(self.transport.get(&path, &query).await?.to_string())
    }

    pub(crate) async fn session_command(
        &self,
        session: &SessionRef,
        account: &str,
        token: &str,
        id: &str,
        command: SessionCommand,
        raw: &str,
    ) -> Result<BusinessReply> {
        let _guard = self.writes.lock().await;
        let current = self.snapshot(session).await?;
        if account.is_empty()
            || current.account_identity != account
            || command.controls_turn() && (token.is_empty() || current.control_token != token)
        {
            return Err(BridgeError::Invalid(
                "Session state or account changed. Refresh before trying again".into(),
            ));
        }
        let mut body = object(raw)?;
        for key in [
            "host",
            "entry",
            "sessionId",
            "resolvedImages",
            "resolvedFiles",
            "resolvedReferences",
        ] {
            if body.get(key).is_some() {
                return Err(BridgeError::Invalid(
                    "Identity and resolved resources cannot be overridden".into(),
                ));
            }
        }
        if command == SessionCommand::Send
            && (!current.capabilities.send
                || body["mode"] == "steer" && !current.capabilities.steer)
        {
            return Err(BridgeError::Invalid("Send is unavailable".into()));
        }
        if command == SessionCommand::Respond && !current.capabilities.approve {
            return Err(BridgeError::Invalid("Approval is unavailable".into()));
        }
        if command == SessionCommand::Respond {
            let expected = body
                .as_object_mut()
                .unwrap()
                .remove("expectedRequestFingerprint")
                .and_then(|v| v.as_str().map(str::to_owned))
                .unwrap_or_default();
            let request = current
                .approvals
                .iter()
                .find(|request| {
                    serde_json::from_str::<Value>(&request.wire_id)
                        .ok()
                        .as_ref()
                        == Some(&body["requestId"])
                })
                .ok_or_else(|| {
                    BridgeError::Invalid("Approval expired; refresh before responding".into())
                })?;
            if !request.supported || expected.is_empty() || request.fingerprint != expected {
                return Err(BridgeError::Invalid(
                    "Approval changed; read the current request".into(),
                ));
            }
        }
        if command == SessionCommand::Send {
            let metadata: Value = serde_json::from_str(&current.metadata)?;
            let state = if metadata["session"].is_object() {
                &metadata["session"]
            } else {
                &metadata
            };
            let caps = if metadata["capabilities"].is_object() {
                &metadata["capabilities"]
            } else {
                &state["capabilities"]
            };
            if body["mode"] == "queue" && caps["queue"] == false
                || body["workMode"] == "plan" && caps["plan"] == false
                || body["workMode"] == "goal" && caps["goal"] == false
                || array(&body, "attachments").len() + array(&body, "references").len() > 10
                || body["workMode"] == "goal"
                    && ["attachments", "references", "skills"]
                        .iter()
                        .any(|k| !array(&body, k).is_empty())
            {
                return Err(BridgeError::Invalid(
                    "Send options are unavailable for this session".into(),
                ));
            }
            if session.provider != Provider::Codex
                && let Some(skills) = body.as_object_mut().unwrap().remove("skills")
            {
                body["plugins"] = skills;
            }
        }
        if matches!(
            command,
            SessionCommand::Send
                | SessionCommand::Archive
                | SessionCommand::Delete
                | SessionCommand::Compact
                | SessionCommand::GoalEdit
                | SessionCommand::GoalStatus
                | SessionCommand::GoalCancel
                | SessionCommand::MessageAction
        ) {
            body["id"] = json!(id);
        }
        if session.provider != Provider::Codex
            && !matches!(
                command,
                SessionCommand::Terminal | SessionCommand::Git | SessionCommand::Notifications
            )
        {
            body["sessionId"] = json!(session.id);
            body["id"] = json!(id);
        }
        let action =
            if session.provider != Provider::Codex && command == SessionCommand::Permissions {
                "access"
            } else {
                command.path()
            };
        let (path, mut query) = adapters::route(session, action);
        if command == SessionCommand::SideChat {
            query.push(("view", "native".into()));
        }
        if command == SessionCommand::Terminal
            && !matches!(body["action"].as_str(), Some("start" | "stop"))
        {
            query.push(("mode", "pty".into()));
        }
        let scope = Store::scope(session, account)?;
        // An unconfirmed terminal input blocks more input, but must not prevent
        // explicit stop/close. The original input is never replayed.
        let record_action = if command == SessionCommand::Terminal {
            format!("terminal/{}", body["action"].as_str().unwrap_or("unknown"))
        } else if command == SessionCommand::Git {
            format!(
                "workspace/git-action/{}",
                body["action"].as_str().unwrap_or("unknown")
            )
        } else {
            command.path().into()
        };
        self.business_write(&scope, id, &record_action, &path, &query, body)
            .await
    }

    async fn business_write(
        &self,
        scope: &str,
        id: &str,
        action: &str,
        path: &str,
        query: &[(&str, String)],
        body: Value,
    ) -> Result<BusinessReply> {
        if let Some(outcome) =
            self.store
                .begin_authorized(id, scope, action, &body, &self.transport.identity())?
        {
            return Ok(BusinessReply {
                outcome,
                data: "{}".into(),
            });
        }
        let result = self.transport.post(path, query, &body).await;
        let (outcome, data) = match result {
            Ok(value) => {
                let accepted = acknowledged(action, &value);
                (
                    OperationOutcome {
                        id: id.into(),
                        kind: if accepted {
                            OutcomeKind::Accepted
                        } else {
                            OutcomeKind::Unknown
                        },
                        message: if accepted {
                            String::new()
                        } else {
                            "The result needs review; the request will not be replayed".into()
                        },
                        created_session: None,
                    },
                    value.to_string(),
                )
            }
            Err(error) => (unknown(id, &error.to_string()), "{}".into()),
        };
        self.store.finish(&outcome)?;
        Ok(BusinessReply { outcome, data })
    }
}

fn account_resource(resource: GatewayResource) -> bool {
    matches!(
        resource,
        GatewayResource::Accounts
            | GatewayResource::Account
            | GatewayResource::Projects
            | GatewayResource::CreationModels
            | GatewayResource::WslAccounts
    )
}

fn account_command(command: GatewayCommand) -> bool {
    matches!(
        command,
        GatewayCommand::AccountDetails
            | GatewayCommand::SwitchAccount
            | GatewayCommand::BrowseProjects
            | GatewayCommand::RegisterProject
            | GatewayCommand::TrustProject
            | GatewayCommand::AccountReminders
            | GatewayCommand::ResetDynamic
            | GatewayCommand::DesktopUpdate
            | GatewayCommand::InitializeCodex
            | GatewayCommand::SshRetry
            | GatewayCommand::WslAccounts
    )
}

fn acknowledged(action: &str, value: &Value) -> bool {
    if value.get("error").is_some()
        || matches!(
            value["status"].as_str(),
            Some("unknown" | "blocked" | "failed")
        )
    {
        return false;
    }
    if action == "respond" && value["status"] == "submitted" {
        return true;
    }
    if value["ok"] == true
        || value["confirmed"] == true
        || value["applied"] == true
        || value["accepted"] == true
        || matches!(
            value["status"].as_str(),
            Some("accepted" | "ready" | "confirmed" | "skipped" | "queued")
        )
        || matches!(
            value["outcome"].as_str(),
            Some("success" | "conflict" | "merge-pending")
        )
    {
        return true;
    }
    if action.starts_with("gateway/") {
        return match action {
            "gateway/Client" | "gateway/ReconnectClaude" => value["clients"].is_array(),
            "gateway/ScanEntries" => value["entries"].is_array(),
            "gateway/BrowseProjects" => {
                value["entries"].is_array() || value["directories"].is_array()
            }
            "gateway/RegisterProject" => value["project"].is_object(),
            "gateway/TrustProject" => {
                value["trusted"].is_boolean() || value["required"].is_boolean()
            }
            "gateway/AccountDetails" => {
                value["accounts"].is_array() || value["account"].is_object()
            }
            "gateway/SwitchAccount" => value["switched"] == true || value["accounts"].is_array(),
            "gateway/InitializeCodex"
            | "gateway/SshRetry"
            | "gateway/AccountReminders"
            | "gateway/ResetDynamic"
            | "gateway/DesktopUpdate" => value["accounts"].is_array(),
            "gateway/WslAccounts" => {
                value["accounts"].is_array()
                    || value["models"].is_array()
                    || value["sources"].is_array()
            }
            "gateway/CliConnections" => {
                value["connections"].is_array() || value["results"].is_array()
            }
            "gateway/WebhookUrl" => value["webhookUrl"].is_string(),
            "gateway/NetworkAdaptation" | "gateway/Ntfy" => value["enabled"].is_boolean(),
            "gateway/FileTransfer" => value["clickDownloadMiB"].is_number(),
            "gateway/Bark" => value["barkEnabled"].is_boolean(),
            "gateway/Pushplus" => value["pushplusEnabled"].is_boolean(),
            "gateway/Webhook" | "gateway/WebhookEndpoints" => {
                value["webhookEnabled"].is_boolean() || value["webhookEndpoints"].is_array()
            }
            "gateway/NotificationCommon" => value["includeTitle"].is_boolean(),
            "gateway/NotificationDefaults" => {
                value["requests"].is_boolean() && value["completion"].is_boolean()
            }
            _ => false,
        };
    }
    if action.starts_with("terminal/") {
        return value["id"].is_string()
            || value["matches"].is_array()
            || value["candidates"].is_array();
    }
    if action.starts_with("workspace/git-action/") {
        return value["version"].is_string();
    }
    match action {
        "rename" => value["title"].is_string(),
        "pin" => value["pinned"].is_boolean(),
        "archive" => value["archived"].is_boolean(),
        "organization" => value["available"].is_boolean(),
        "notifications" => value["requests"].is_string() && value["completion"].is_string(),
        "workspace/git-action" => value["version"].is_string(),
        "terminal" => {
            value["id"].is_string() || value["terminal"].is_object() || value["matches"].is_array()
        }
        "side-chat" => value["id"].is_string() || value["side"].is_object(),
        "message-management" => value["version"].is_string() && value["queue"].is_array(),
        _ => false,
    }
}

fn parse_content_range(value: &str) -> Result<(i64, i64, i64)> {
    let fail = || BridgeError::Protocol("Invalid content range".into());
    let (range, total) = value
        .strip_prefix("bytes ")
        .and_then(|v| v.split_once('/'))
        .ok_or_else(fail)?;
    let (start, end) = range.split_once('-').ok_or_else(fail)?;
    Ok((
        start.parse().map_err(|_| fail())?,
        end.parse().map_err(|_| fail())?,
        total.parse().map_err(|_| fail())?,
    ))
}

fn gateway_read_path(provider: Provider, resource: GatewayResource) -> String {
    use GatewayResource::*;
    match resource {
        Clients => "/api/clients".into(),
        Entries => "/api/codex/entries".into(),
        WslEnvironments => "/api/wsl-accounts/environments".into(),
        WslAccounts => "/api/wsl-accounts".into(),
        PendingOperations => unreachable!("local operation history"),
        Projects | CreationModels | Accounts | Account if provider != Provider::Codex => format!(
            "/api/desktop-sessions/{}/{}",
            provider.slug(),
            match resource {
                Projects => "projects",
                CreationModels => "create-models",
                Accounts => "accounts",
                _ => "account",
            }
        ),
        Projects => "/api/projects".into(),
        CreationModels => "/api/projects/models".into(),
        Accounts => "/api/accounts".into(),
        Account => "/api/account".into(),
        CliConnections => "/api/cli-connections".into(),
        CliAccess => "/api/cli-access".into(),
        NetworkAdaptation => "/api/network-adaptation".into(),
        FileTransfer => "/api/file-transfer".into(),
        NotificationDefaults => "/api/notifications/defaults".into(),
        NotificationCommon => "/api/notifications/channels/common".into(),
        Ntfy => "/api/notifications/channels/ntfy".into(),
        Bark => "/api/notifications/channels/bark".into(),
        Pushplus => "/api/notifications/channels/pushplus".into(),
        Webhook => "/api/notifications/channels/webhook".into(),
    }
}

fn gateway_write_path(provider: Provider, command: GatewayCommand) -> String {
    use GatewayCommand::*;
    match command {
        Client => "/api/clients".into(),
        ReconnectClaude => "/api/clients/claude/reconnect".into(),
        ScanEntries => "/api/codex/entries".into(),
        BrowseProjects | RegisterProject | TrustProject if provider != Provider::Codex => format!(
            "/api/desktop-sessions/{}/projects/{}",
            provider.slug(),
            match command {
                BrowseProjects => "browse",
                RegisterProject => "register",
                _ => "trust",
            }
        ),
        BrowseProjects => "/api/projects/browse".into(),
        RegisterProject => "/api/projects".into(),
        TrustProject => "/api/projects/trust".into(),
        AccountDetails | SwitchAccount if provider != Provider::Codex => {
            format!("/api/desktop-sessions/{}/accounts", provider.slug())
        }
        AccountDetails => "/api/accounts/details".into(),
        SwitchAccount => "/api/accounts/switch".into(),
        SshRetry => "/api/accounts/ssh-retry".into(),
        InitializeCodex => "/api/accounts/desktop-runtime".into(),
        AccountReminders => "/api/accounts/reminders".into(),
        ResetDynamic => "/api/accounts/reset-dynamic".into(),
        DesktopUpdate => "/api/accounts/desktop-update".into(),
        WslAccounts => "/api/wsl-accounts".into(),
        WebhookUrl => "/api/notifications/channels/webhook/url".into(),
        CliConnections => gateway_read_path(provider, GatewayResource::CliConnections),
        CliAccess => gateway_read_path(provider, GatewayResource::CliAccess),
        NetworkAdaptation => gateway_read_path(provider, GatewayResource::NetworkAdaptation),
        FileTransfer => gateway_read_path(provider, GatewayResource::FileTransfer),
        NotificationDefaults => gateway_read_path(provider, GatewayResource::NotificationDefaults),
        NotificationCommon => gateway_read_path(provider, GatewayResource::NotificationCommon),
        Ntfy => gateway_read_path(provider, GatewayResource::Ntfy),
        Bark => gateway_read_path(provider, GatewayResource::Bark),
        Pushplus => gateway_read_path(provider, GatewayResource::Pushplus),
        Webhook => gateway_read_path(provider, GatewayResource::Webhook),
        WebhookEndpoints => "/api/notifications/channels/webhook/endpoints".into(),
        TestNtfy => "/api/notifications/channels/ntfy/test".into(),
        TestBark => "/api/notifications/channels/bark/test".into(),
        TestPushplus => "/api/notifications/channels/pushplus/test".into(),
        TestWebhook => "/api/notifications/channels/webhook/test".into(),
    }
}
