use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension, params};

use crate::api::types::*;
use crate::error::{BridgeError, Result};
use crate::security::{GatewayAddress, fingerprint};

pub struct Store {
    db: Mutex<Connection>,
}

impl Store {
    pub fn open(path: &str) -> Result<Self> {
        let mut db = Connection::open(path)?;
        db.busy_timeout(Duration::from_secs(5))?;
        db.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=FULL;
             PRAGMA foreign_keys=ON;",
        )?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let version: i64 = tx.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        let empty: bool = tx.query_row(
            "SELECT NOT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%')",
            [],
            |row| row.get(0),
        )?;
        if !(matches!(version, 3..=5) || version == 0 && empty) {
            return Err(BridgeError::Invalid(
                "Unsupported local database schema; initialize fresh app storage".into(),
            ));
        }
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS computers (
               id TEXT PRIMARY KEY, name TEXT NOT NULL, base_url TEXT NOT NULL,
               connection_type TEXT NOT NULL CHECK(connection_type IN ('direct','relay')),
               relay TEXT,
               CHECK((connection_type='direct' AND relay IS NULL) OR
                     (connection_type='relay' AND relay IS NOT NULL AND json_valid(relay))));
             CREATE UNIQUE INDEX IF NOT EXISTS direct_address ON computers(base_url)
               WHERE connection_type='direct';
             CREATE UNIQUE INDEX IF NOT EXISTS relay_binding ON computers(
               json_extract(relay,'$.origin'),json_extract(relay,'$.account_id'),
               json_extract(relay,'$.binding_id')) WHERE connection_type='relay';
             CREATE TABLE IF NOT EXISTS drafts (
               scope TEXT PRIMARY KEY, text TEXT NOT NULL, attachments TEXT NOT NULL,
               revision INTEGER NOT NULL);
             CREATE TABLE IF NOT EXISTS operations (
               id TEXT PRIMARY KEY, scope TEXT NOT NULL, action TEXT NOT NULL,
               fingerprint TEXT NOT NULL, status TEXT NOT NULL,
               created_at INTEGER NOT NULL, message TEXT NOT NULL, result TEXT);
             CREATE UNIQUE INDEX IF NOT EXISTS one_unresolved_operation
               ON operations(scope, action) WHERE status = 'unknown';
             CREATE TABLE IF NOT EXISTS preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS operation_authority (
               id TEXT PRIMARY KEY REFERENCES operations(id) ON DELETE CASCADE,
               gateway_identity TEXT NOT NULL);
             ",
        )?;
        if version < 4 {
            tx.execute_batch("ALTER TABLE drafts ADD COLUMN options TEXT NOT NULL DEFAULT '{}';")?;
        }
        tx.execute_batch("PRAGMA user_version=5;")?;
        tx.commit()?;
        Ok(Self { db: Mutex::new(db) })
    }

    pub fn computers(&self) -> Result<Vec<Computer>> {
        let db = self.db.lock().unwrap();
        let mut statement = db.prepare(
            "SELECT id,name,base_url,connection_type,relay FROM computers ORDER BY name,id",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            })?
            .map(|row| {
                let (id, name, base_url, kind, relay) = row?;
                let connection_type = match kind.as_str() {
                    "direct" => ConnectionType::Direct,
                    "relay" => ConnectionType::Relay,
                    _ => return Err(BridgeError::Invalid("Invalid saved connection type".into())),
                };
                let computer = Computer {
                    id,
                    name,
                    base_url,
                    connection_type,
                    relay: relay.as_deref().map(serde_json::from_str).transpose()?,
                };
                validate_computer(&computer)?;
                Ok(computer)
            })
            .collect()
    }

    pub fn preferences(&self) -> Result<UiPreferences> {
        let value: Option<String> = self
            .db
            .lock()
            .unwrap()
            .query_row("SELECT value FROM preferences WHERE key='ui'", [], |row| {
                row.get(0)
            })
            .optional()?;
        Ok(match value {
            Some(value) => serde_json::from_str(&value)?,
            None => UiPreferences::default(),
        })
    }

    pub fn save_preferences(&self, value: &UiPreferences) -> Result<()> {
        if !["system", "light", "dark"].contains(&value.theme.as_str())
            || !["zh", "en"].contains(&value.locale.as_str())
            || value.read_inbox.len() > 1000
            || value.read_inbox.iter().any(|id| id.len() > 256)
        {
            return Err(BridgeError::Invalid("Invalid display preferences".into()));
        }
        self.db.lock().unwrap().execute(
            "INSERT INTO preferences VALUES ('ui',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [serde_json::to_string(value)?],
        )?;
        Ok(())
    }

    pub fn save_computer(&self, computer: &Computer) -> Result<()> {
        validate_computer(computer)?;
        let kind = match computer.connection_type {
            ConnectionType::Direct => "direct",
            ConnectionType::Relay => "relay",
        };
        let relay = computer
            .relay
            .as_ref()
            .map(serde_json::to_string)
            .transpose()?;
        let db = self.db.lock().unwrap();
        let old: Option<(String, String, Option<String>)> = db
            .query_row(
                "SELECT base_url,connection_type,relay FROM computers WHERE id=?1",
                [&computer.id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;
        if old.as_ref().is_some_and(|(base, old_kind, old_relay)| {
            base != &computer.base_url || old_kind != kind || old_relay != &relay
        }) {
            return Err(BridgeError::Invalid(
                "A different server, account or binding requires a separate connection and login"
                    .into(),
            ));
        }
        db.execute(
            "INSERT INTO computers(id,name,base_url,connection_type,relay) VALUES (?1,?2,?3,?4,?5)
             ON CONFLICT(id) DO UPDATE SET name=excluded.name",
            params![computer.id, computer.name, computer.base_url, kind, relay],
        )?;
        Ok(())
    }

    pub fn remove_computer(&self, id: &str) -> Result<()> {
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        // Scopes are structured JSON, not a prefix match on untrusted IDs.
        for table in ["drafts", "operations"] {
            tx.execute(
                &format!("DELETE FROM {table} WHERE json_extract(scope,'$[0].computer_id')=?1"),
                [id],
            )?;
        }
        tx.execute("DELETE FROM computers WHERE id=?1", [id])?;
        tx.commit()?;
        Ok(())
    }

    pub fn scope(session: &SessionRef, account: &str) -> Result<String> {
        if account.is_empty() {
            return Err(BridgeError::Invalid(
                "Account identity has not been verified".into(),
            ));
        }
        Ok(serde_json::to_string(&(session, account))?)
    }

    pub fn draft(&self, scope: &str) -> Result<Draft> {
        let db = self.db.lock().unwrap();
        let row: Option<(String, String, u32, String)> = db
            .query_row(
                "SELECT text,attachments,revision,options FROM drafts WHERE scope=?1",
                [scope],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;
        match row {
            Some((text, attachments, revision, options)) => Ok(Draft {
                options,
                text,
                attachments: serde_json::from_str(&attachments)?,
                revision,
            }),
            None => Ok(Draft {
                options: "{}".into(),
                text: String::new(),
                attachments: vec![],
                revision: 0,
            }),
        }
    }

    pub fn save_draft(&self, scope: &str, draft: &Draft) -> Result<()> {
        let options: serde_json::Value = serde_json::from_str(&draft.options)?;
        if !options.is_object()
            || draft.options.len() > 512_000
            || draft.text.chars().count() > 100_000
            || draft.attachments.len() > 10
        {
            return Err(BridgeError::Invalid(
                "Draft exceeds the gateway limit".into(),
            ));
        }
        self.db.lock().unwrap().execute(
            "INSERT INTO drafts (scope,text,attachments,revision,options) VALUES (?1,?2,?3,?4,?5) ON CONFLICT(scope) DO UPDATE
             SET text=excluded.text,attachments=excluded.attachments,revision=excluded.revision,options=excluded.options
             WHERE excluded.revision>=drafts.revision",
            params![
                scope,
                draft.text,
                serde_json::to_string(&draft.attachments)?,
                draft.revision,
                draft.options
            ],
        )?;
        Ok(())
    }

    pub fn begin(
        &self,
        id: &str,
        scope: &str,
        action: &str,
        body: &serde_json::Value,
    ) -> Result<Option<OperationOutcome>> {
        self.begin_authorized(id, scope, action, body, "")
    }

    pub fn begin_authorized(
        &self,
        id: &str,
        scope: &str,
        action: &str,
        body: &serde_json::Value,
        gateway: &str,
    ) -> Result<Option<OperationOutcome>> {
        uuid::Uuid::parse_str(id)
            .map_err(|_| BridgeError::Invalid("Invalid operation ID".into()))?;
        let digest = fingerprint(&(scope, action, body));
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let existing: Option<(String, Option<String>)> = tx
            .query_row(
                "SELECT fingerprint,result FROM operations WHERE id=?1",
                [id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        if let Some((old, result)) = existing {
            if old != digest {
                return Err(BridgeError::Invalid(
                    "Operation ID was already used for different content".into(),
                ));
            }
            return Ok(Some(match result {
                Some(json) => serde_json::from_str(&json)?,
                None => unknown(id, "Previous submission is unresolved; it was not replayed"),
            }));
        }
        let pending: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM operations WHERE scope=?1 AND action=?2 AND status='unknown')", params![scope,action], |row| row.get(0))?;
        if pending {
            return Err(BridgeError::Invalid(
                "Check the previous unresolved operation on the computer before submitting again"
                    .into(),
            ));
        }
        let at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        tx.execute(
            "INSERT INTO operations VALUES (?1,?2,?3,?4,'unknown',?5,?6,NULL)",
            params![
                id,
                scope,
                action,
                digest,
                at,
                "Submission may have reached the computer"
            ],
        )?;
        if !gateway.is_empty() {
            tx.execute(
                "INSERT INTO operation_authority(id,gateway_identity) VALUES (?1,?2)",
                params![id, gateway],
            )?;
        }
        tx.commit()?;
        Ok(None)
    }

    pub fn finish(&self, outcome: &OperationOutcome) -> Result<()> {
        let state = match outcome.kind {
            OutcomeKind::Accepted => "accepted",
            OutcomeKind::NotSubmitted => "not_submitted",
            OutcomeKind::Unknown => "unknown",
        };
        self.db.lock().unwrap().execute(
            "UPDATE operations SET status=?1,message=?2,result=?3 WHERE id=?4",
            params![
                state,
                outcome.message,
                serde_json::to_string(outcome)?,
                outcome.id
            ],
        )?;
        Ok(())
    }

    pub fn pending(&self, scope: &str) -> Result<Vec<PendingOperation>> {
        let db = self.db.lock().unwrap();
        let mut statement = db.prepare("SELECT id,action,created_at,message FROM operations WHERE scope=?1 AND status='unknown' ORDER BY created_at")?;
        Ok(statement
            .query_map([scope], |row| {
                Ok(PendingOperation {
                    id: row.get(0)?,
                    action: row.get(1)?,
                    created_at: row.get(2)?,
                    message: row.get(3)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?)
    }

    pub fn mark_reviewed(&self, scope: &str, id: &str, confirmed: bool) -> Result<()> {
        if !confirmed {
            return Err(BridgeError::Invalid(
                "Explicit confirmation of a desktop check is required".into(),
            ));
        }
        self.db.lock().unwrap().execute(
            "UPDATE operations SET status='reviewed' WHERE scope=?1 AND id=?2 AND status='unknown'",
            params![scope, id],
        )?;
        Ok(())
    }

    pub fn pending_management(
        &self,
        session: &SessionRef,
        gateway: &str,
    ) -> Result<Vec<serde_json::Value>> {
        let db = self.db.lock().unwrap();
        let mut statement = db.prepare("SELECT id,action,created_at,message,json_extract(scope,'$[1]') FROM operations WHERE json_extract(scope,'$[0]')=?1 AND status='unknown' AND (EXISTS(SELECT 1 FROM operation_authority a WHERE a.id=operations.id AND a.gateway_identity=?2) OR json_extract(scope,'$[1]')=?2) ORDER BY created_at")?;
        Ok(statement.query_map(params![serde_json::to_string(session)?,gateway], |row| {
            Ok(serde_json::json!({"id": row.get::<_, String>(0)?, "action": row.get::<_, String>(1)?, "createdAt": row.get::<_, i64>(2)?, "message": row.get::<_, String>(3)?, "identity": row.get::<_, String>(4)?}))
        })?.collect::<std::result::Result<Vec<_>, _>>()?)
    }

    pub fn pending_creations(&self, computer: &str, account: &str) -> Result<Vec<PendingCreation>> {
        if account.is_empty() {
            return Err(BridgeError::Unauthenticated);
        }
        self.creation_records(computer, account)
    }

    fn creation_records(&self, computer: &str, account: &str) -> Result<Vec<PendingCreation>> {
        let db = self.db.lock().unwrap();
        let mut statement = db.prepare(
            "SELECT id,action,created_at,message,scope FROM operations
             WHERE json_extract(scope,'$[0].computer_id')=?1 AND (json_extract(scope,'$[1]')=?2 OR EXISTS(SELECT 1 FROM operation_authority a WHERE a.id=operations.id AND a.gateway_identity=?2))
             AND action='create' AND status='unknown'
             ORDER BY created_at",
        )?;
        let rows = statement.query_map(params![computer, account], |row| {
            Ok((
                PendingOperation {
                    id: row.get(0)?,
                    action: row.get(1)?,
                    created_at: row.get(2)?,
                    message: row.get(3)?,
                },
                row.get::<_, String>(4)?,
            ))
        })?;
        rows.map(|row| {
            let (operation, scope) = row?;
            let (session, authority): (SessionRef, String) = serde_json::from_str(&scope)?;
            Ok(PendingCreation {
                operation,
                account_identity: authority,
                provider: session.provider,
                entry: session.entry,
                environment: session.environment,
                project_key: session
                    .id
                    .strip_prefix("create:")
                    .unwrap_or(&session.id)
                    .to_owned(),
            })
        })
        .collect()
    }

    pub fn review_creation(
        &self,
        computer: &str,
        account: &str,
        id: &str,
        confirmed: bool,
    ) -> Result<()> {
        if account.is_empty() {
            return Err(BridgeError::Unauthenticated);
        }
        if !confirmed {
            return Err(BridgeError::Invalid(
                "Check the new chat on the computer first".into(),
            ));
        }
        self.db.lock().unwrap().execute(
            "UPDATE operations SET status='reviewed' WHERE id=?1 AND action='create'
             AND json_extract(scope,'$[0].computer_id')=?2 AND json_extract(scope,'$[1]')=?3 AND status='unknown'",
            params![id, computer, account],
        )?;
        Ok(())
    }
}

fn validate_computer(computer: &Computer) -> Result<()> {
    let (address, token) = GatewayAddress::parse(&computer.base_url)?;
    if token.is_some()
        || address.base != computer.base_url
        || computer.id.is_empty()
        || computer.id.len() > 200
        || computer.name.trim().is_empty()
        || computer.name.len() > 200
    {
        return Err(BridgeError::Invalid(
            "Invalid computer configuration".into(),
        ));
    }
    match (&computer.connection_type, &computer.relay) {
        (ConnectionType::Direct, None) => Ok(()),
        (ConnectionType::Relay, Some(relay)) if relay.origin == computer.base_url => {
            crate::cloud_crypto::exact_origin(&relay.origin)
                .and_then(|_| crate::cloud_crypto::key(&relay.desktop_public_key))
                .map_err(|_| {
                    BridgeError::Invalid("Invalid encrypted relay configuration".into())
                })?;
            for value in [&relay.account_id, &relay.gateway_id, &relay.binding_id] {
                uuid::Uuid::parse_str(value)
                    .map_err(|_| BridgeError::Invalid("Invalid encrypted relay identity".into()))?;
            }
            Ok(())
        }
        _ => Err(BridgeError::Invalid("Invalid connection type".into())),
    }
}

pub fn unknown(id: &str, message: &str) -> OperationOutcome {
    OperationOutcome {
        id: id.into(),
        kind: OutcomeKind::Unknown,
        message: message.into(),
        created_session: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn unsupported_databases_are_rejected_without_rewriting_saved_connections() {
        for version in [0, 1, 2, 6] {
            let file = tempfile::NamedTempFile::new().unwrap();
            let db = Connection::open(file.path()).unwrap();
            db.execute_batch(
                "CREATE TABLE computers(id TEXT PRIMARY KEY,name TEXT NOT NULL,base_url TEXT NOT NULL UNIQUE);
                 INSERT INTO computers VALUES ('old','Existing','https://desktop.test');",
            ).unwrap();
            db.pragma_update(None, "user_version", version).unwrap();
            assert!(Store::open(file.path().to_str().unwrap()).is_err());
            assert_eq!(
                db.query_row("SELECT name FROM computers WHERE id='old'", [], |row| {
                    row.get::<_, String>(0)
                })
                .unwrap(),
                "Existing"
            );
            assert_eq!(
                db.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))
                    .unwrap(),
                version
            );
        }
        assert!(
            serde_json::from_value::<Computer>(json!({
                "id":"legacy", "name":"Legacy", "base_url":"https://desktop.test"
            }))
            .is_err()
        );
    }

    #[test]
    fn relay_gateways_share_origin_but_cannot_replace_account_or_pinned_identity() {
        use base64::Engine as _;
        let file = tempfile::NamedTempFile::new().unwrap();
        let store = Store::open(file.path().to_str().unwrap()).unwrap();
        let mut first = Computer {
            id: "relay-a".into(),
            name: "Desktop A".into(),
            base_url: "https://relay.test".into(),
            connection_type: ConnectionType::Relay,
            relay: Some(RelayConnection {
                origin: "https://relay.test".into(),
                account_id: uuid::Uuid::new_v4().to_string(),
                gateway_id: uuid::Uuid::new_v4().to_string(),
                binding_id: uuid::Uuid::new_v4().to_string(),
                desktop_public_key: base64::engine::general_purpose::STANDARD.encode([7; 32]),
            }),
        };
        store.save_computer(&first).unwrap();
        let mut second = first.clone();
        second.id = "relay-b".into();
        second.relay.as_mut().unwrap().binding_id = uuid::Uuid::new_v4().to_string();
        second.relay.as_mut().unwrap().gateway_id = uuid::Uuid::new_v4().to_string();
        store.save_computer(&second).unwrap();
        assert_eq!(store.computers().unwrap().len(), 2);
        first.relay.as_mut().unwrap().account_id = uuid::Uuid::new_v4().to_string();
        assert!(store.save_computer(&first).is_err());
        second.connection_type = ConnectionType::Direct;
        assert!(store.save_computer(&second).is_err());
        second.connection_type = ConnectionType::Relay;
        second.relay.as_mut().unwrap().origin = "https://another.test".into();
        assert!(store.save_computer(&second).is_err());
        drop(store);
        assert_eq!(
            Store::open(file.path().to_str().unwrap())
                .unwrap()
                .computers()
                .unwrap()
                .len(),
            2
        );
    }

    #[test]
    fn v3_upgrade_preserves_default_scope_drafts_connections_and_unknown_writes() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let session = SessionRef {
            computer_id: "pc1".into(),
            provider: Provider::Claude,
            entry: String::new(),
            environment: "ssh:dev".into(),
            id: "same-session".into(),
        };
        let scope = Store::scope(&session, "account1").unwrap();
        let old_session = json!({"computer_id":"pc1","provider":"Claude","environment":"ssh:dev","id":"same-session"});
        // The default instance must keep the pre-entry JSON representation.
        let serialized = serde_json::to_value(&session).unwrap();
        assert!(serialized.get("entry").is_none());
        assert_eq!(serialized["computer_id"], old_session["computer_id"]);
        let id = uuid::Uuid::new_v4().to_string();
        {
            let store = Store::open(file.path().to_str().unwrap()).unwrap();
            store
                .save_computer(&Computer {
                    id: "pc1".into(),
                    name: "Existing".into(),
                    base_url: "https://desktop.test".into(),
                    connection_type: ConnectionType::Direct,
                    relay: None,
                })
                .unwrap();
            store
                .save_draft(
                    &scope,
                    &Draft {
                        text: "旧草稿".into(),
                        attachments: vec![],
                        revision: 17,
                        options: "{}".into(),
                    },
                )
                .unwrap();
            store
                .begin(&id, &scope, "send", &json!({"text":"pending"}))
                .unwrap();
        }
        {
            let old = Connection::open(file.path()).unwrap();
            old.execute_batch("ALTER TABLE drafts DROP COLUMN options; PRAGMA user_version=3;")
                .unwrap();
        }
        for _ in 0..2 {
            let store = Store::open(file.path().to_str().unwrap()).unwrap();
            let draft = store.draft(&scope).unwrap();
            assert_eq!(draft.text, "旧草稿");
            assert_eq!(draft.revision, 17);
            assert_eq!(draft.options, "{}");
            assert_eq!(store.computers().unwrap()[0].name, "Existing");
            assert_eq!(store.pending(&scope).unwrap()[0].id, id);
            assert_eq!(
                store
                    .begin(&id, &scope, "send", &json!({"text":"pending"}))
                    .unwrap()
                    .unwrap()
                    .kind,
                OutcomeKind::Unknown
            );
        }
    }

    #[test]
    fn same_session_is_isolated_by_instance_environment_and_account() {
        let store = Store::open(":memory:").unwrap();
        let base = SessionRef {
            computer_id: "pc".into(),
            provider: Provider::Zcode,
            entry: String::new(),
            environment: "local".into(),
            id: "same".into(),
        };
        let scope = Store::scope(&base, "account1").unwrap();
        let draft = Draft {
            text: "private".into(),
            attachments: vec![],
            revision: 1,
            options: json!({"skills":["s"],"mode":"queue","references":[{"path":"x"}]}).to_string(),
        };
        store.save_draft(&scope, &draft).unwrap();
        for changed in [
            SessionRef {
                entry: "zcode:other".into(),
                ..base.clone()
            },
            SessionRef {
                environment: "ssh:lab".into(),
                ..base.clone()
            },
        ] {
            assert_ne!(Store::scope(&changed, "account1").unwrap(), scope);
            assert!(
                store
                    .draft(&Store::scope(&changed, "account1").unwrap())
                    .unwrap()
                    .text
                    .is_empty()
            );
        }
        assert!(
            store
                .draft(&Store::scope(&base, "account2").unwrap())
                .unwrap()
                .text
                .is_empty()
        );
        assert_eq!(store.draft(&scope).unwrap().options, draft.options);
    }

    #[test]
    fn management_review_retains_old_revisions_without_crossing_instances() {
        let store = Store::open(":memory:").unwrap();
        let session = SessionRef {
            computer_id: "pc".into(),
            provider: Provider::Claude,
            entry: "claude:one".into(),
            environment: "local".into(),
            id: "management".into(),
        };
        let id = uuid::Uuid::new_v4().to_string();
        let scope = Store::scope(&session, "old-account-revision").unwrap();
        store
            .begin_authorized(
                &id,
                &scope,
                "gateway/SwitchAccount",
                &json!({"id":"two"}),
                "gateway-a",
            )
            .unwrap();
        let rows = store.pending_management(&session, "gateway-a").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["identity"], "old-account-revision");
        assert!(
            store
                .pending_management(&session, "gateway-b")
                .unwrap()
                .is_empty()
        );
        assert!(
            store
                .pending_management(
                    &SessionRef {
                        entry: "claude:two".into(),
                        ..session.clone()
                    },
                    "gateway-a"
                )
                .unwrap()
                .is_empty()
        );
        store.mark_reviewed(&scope, &id, true).unwrap();
        assert!(
            store
                .pending_management(&session, "gateway-a")
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn pending_creation_retains_coding_revision_only_for_its_gateway_account() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let session = SessionRef {
            computer_id: "pc".into(),
            provider: Provider::Codex,
            entry: "codex:one".into(),
            environment: "ssh:dev".into(),
            id: "create:project".into(),
        };
        let id = uuid::Uuid::new_v4().to_string();
        let scope = Store::scope(&session, "old-coding-revision").unwrap();
        {
            let store = Store::open(file.path().to_str().unwrap()).unwrap();
            store
                .begin_authorized(
                    &id,
                    &scope,
                    "create",
                    &json!({"project":"project"}),
                    "gateway-a",
                )
                .unwrap();
        }
        let store = Store::open(file.path().to_str().unwrap()).unwrap();
        let rows = store.pending_creations("pc", "gateway-a").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].account_identity, "old-coding-revision");
        assert_eq!(rows[0].project_key, "project");
        assert!(
            store
                .pending_creations("pc", "gateway-b")
                .unwrap()
                .is_empty()
        );
        assert!(
            store
                .pending_creations("other-pc", "gateway-a")
                .unwrap()
                .is_empty()
        );
        store
            .review_creation("pc", &rows[0].account_identity, &id, true)
            .unwrap();
        assert!(
            store
                .pending_creations("pc", "gateway-a")
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn durable_intent_is_never_replayed_and_drafts_are_isolated() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        let session = SessionRef {
            entry: String::new(),
            computer_id: "pc1".into(),
            provider: Provider::Claude,
            environment: "ssh:dev".into(),
            id: "opaque-id".into(),
        };
        let scope = Store::scope(&session, "account1").unwrap();
        {
            let store = Store::open(file.path().to_str().unwrap()).unwrap();
            store
                .save_draft(
                    &scope,
                    &Draft {
                        options: "{}".into(),
                        text: "private draft".into(),
                        attachments: vec![],
                        revision: 2,
                    },
                )
                .unwrap();
            store
                .save_draft(
                    &scope,
                    &Draft {
                        options: "{}".into(),
                        text: "late old draft".into(),
                        attachments: vec![],
                        revision: 1,
                    },
                )
                .unwrap();
            assert!(
                store
                    .begin(&id, &scope, "send", &json!({"text":"hello"}))
                    .unwrap()
                    .is_none()
            );
        }
        let store = Store::open(file.path().to_str().unwrap()).unwrap();
        assert_eq!(
            store
                .begin(&id, &scope, "send", &json!({"text":"hello"}))
                .unwrap()
                .unwrap()
                .kind,
            OutcomeKind::Unknown
        );
        assert!(
            store
                .begin(&id, &scope, "send", &json!({"text":"changed"}))
                .is_err()
        );
        assert!(
            store
                .begin(
                    &uuid::Uuid::new_v4().to_string(),
                    &scope,
                    "send",
                    &json!({})
                )
                .is_err()
        );
        assert!(
            store
                .begin(
                    &uuid::Uuid::new_v4().to_string(),
                    &scope,
                    "stop",
                    &json!({})
                )
                .unwrap()
                .is_none()
        );
        assert_eq!(store.draft(&scope).unwrap().text, "private draft");
        assert!(
            store
                .draft(&Store::scope(&session, "account2").unwrap())
                .unwrap()
                .text
                .is_empty()
        );
        assert!(store.mark_reviewed(&scope, &id, false).is_err());
    }
}
