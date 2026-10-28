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
        let db = Connection::open(path)?;
        db.busy_timeout(Duration::from_secs(5))?;
        let version: i64 = db.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if version > 2 {
            return Err(BridgeError::Invalid(
                "Local database needs a newer application".into(),
            ));
        }
        db.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=FULL;
             PRAGMA foreign_keys=ON;
             CREATE TABLE IF NOT EXISTS computers (
               id TEXT PRIMARY KEY, name TEXT NOT NULL, base_url TEXT NOT NULL UNIQUE);
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
             PRAGMA user_version=2;",
        )?;
        Ok(Self { db: Mutex::new(db) })
    }

    pub fn computers(&self) -> Result<Vec<Computer>> {
        let db = self.db.lock().unwrap();
        let mut statement =
            db.prepare("SELECT id,name,base_url FROM computers ORDER BY name,id")?;
        Ok(statement
            .query_map([], |row| {
                Ok(Computer {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    base_url: row.get(2)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?)
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
        let (address, token) = GatewayAddress::parse(&computer.base_url)?;
        if token.is_some()
            || address.base != computer.base_url
            || computer.id.is_empty()
            || computer.name.trim().is_empty()
            || computer.name.len() > 200
        {
            return Err(BridgeError::Invalid(
                "Invalid computer configuration".into(),
            ));
        }
        let db = self.db.lock().unwrap();
        let old: Option<String> = db
            .query_row(
                "SELECT base_url FROM computers WHERE id=?1",
                [&computer.id],
                |row| row.get(0),
            )
            .optional()?;
        if old.as_ref().is_some_and(|base| base != &computer.base_url) {
            return Err(BridgeError::Invalid(
                "A different address requires a separate connection and login".into(),
            ));
        }
        db.execute("INSERT INTO computers VALUES (?1,?2,?3) ON CONFLICT(id) DO UPDATE SET name=excluded.name", params![computer.id, computer.name, address.base])?;
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
        let row: Option<(String, String, u32)> = db
            .query_row(
                "SELECT text,attachments,revision FROM drafts WHERE scope=?1",
                [scope],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;
        match row {
            Some((text, attachments, revision)) => Ok(Draft {
                text,
                attachments: serde_json::from_str(&attachments)?,
                revision,
            }),
            None => Ok(Draft {
                text: String::new(),
                attachments: vec![],
                revision: 0,
            }),
        }
    }

    pub fn save_draft(&self, scope: &str, draft: &Draft) -> Result<()> {
        if draft.text.chars().count() > 100_000 || draft.attachments.len() > 8 {
            return Err(BridgeError::Invalid(
                "Draft exceeds the gateway limit".into(),
            ));
        }
        self.db.lock().unwrap().execute(
            "INSERT INTO drafts VALUES (?1,?2,?3,?4) ON CONFLICT(scope) DO UPDATE
             SET text=excluded.text,attachments=excluded.attachments,revision=excluded.revision
             WHERE excluded.revision>=drafts.revision",
            params![
                scope,
                draft.text,
                serde_json::to_string(&draft.attachments)?,
                draft.revision
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

    pub fn pending_creations(&self, computer: &str) -> Result<Vec<PendingCreation>> {
        let db = self.db.lock().unwrap();
        let mut statement = db.prepare(
            "SELECT id,action,created_at,message,scope FROM operations
             WHERE json_extract(scope,'$[0].computer_id')=?1 AND action='create' AND status='unknown'
             ORDER BY created_at",
        )?;
        let rows = statement.query_map([computer], |row| {
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
            let (session, _): (SessionRef, String) = serde_json::from_str(&scope)?;
            Ok(PendingCreation {
                operation,
                provider: session.provider,
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

    pub fn review_creation(&self, computer: &str, id: &str, confirmed: bool) -> Result<()> {
        if !confirmed {
            return Err(BridgeError::Invalid(
                "Check the new chat on the computer first".into(),
            ));
        }
        self.db.lock().unwrap().execute(
            "UPDATE operations SET status='reviewed' WHERE id=?1 AND action='create'
             AND json_extract(scope,'$[0].computer_id')=?2 AND status='unknown'",
            params![id, computer],
        )?;
        Ok(())
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
    fn durable_intent_is_never_replayed_and_drafts_are_isolated() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        let session = SessionRef {
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
