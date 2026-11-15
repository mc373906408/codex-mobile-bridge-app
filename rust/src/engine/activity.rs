use super::*;

impl Engine {
    pub(super) async fn session_activity(
        &self,
        provider: Provider,
        entry: &str,
        raw: &str,
    ) -> Result<Value> {
        if raw.len() > 512_000 {
            return Err(BridgeError::TooLarge);
        }
        let body: Value = serde_json::from_str(raw)?;
        let hosts = body["hosts"]
            .as_object()
            .filter(|hosts| hosts.len() <= 20)
            .ok_or_else(|| BridgeError::Invalid("Invalid session activity query".into()))?;
        if body.as_object().is_none_or(|body| body.len() != 1) {
            return Err(BridgeError::Invalid(
                "Invalid session activity query".into(),
            ));
        }
        for (host, ids) in hosts {
            let ids = ids
                .as_array()
                .filter(|ids| ids.len() <= 500)
                .ok_or_else(|| BridgeError::Invalid("Invalid session activity query".into()))?;
            for id in ids {
                validate_session(
                    &SessionRef {
                        computer_id: self.computer.id.clone(),
                        provider,
                        entry: entry.into(),
                        environment: host.clone(),
                        id: id
                            .as_str()
                            .ok_or_else(|| BridgeError::Invalid("Invalid session ID".into()))?
                            .into(),
                    },
                    &self.computer.id,
                )?;
            }
        }
        let value = if provider == Provider::Codex {
            // This POST is the Web client's passive batch read. It neither
            // activates a chat nor enters the mutation/unknown-write journal.
            self.transport.post("/api/activity", &[], &body).await?
        } else {
            let query = if entry.is_empty() {
                vec![]
            } else {
                vec![("entry", entry.to_owned())]
            };
            self.transport
                .get(
                    &format!("/api/desktop-sessions/{}/list", provider.slug()),
                    &query,
                )
                .await?
        };
        let rows = value["sessions"]
            .as_array()
            .ok_or_else(|| BridgeError::Protocol("Missing session activity".into()))?;
        let rows: Vec<_> = rows
            .iter()
            .filter_map(|row| {
                let host = row["host"].as_str().unwrap_or("local");
                let id = row["id"].as_str()?;
                if !hosts.get(host)?.as_array()?.iter().any(|value| value == id) {
                    return None;
                }
                Some(json!({
                    "host": host, "id": id,
                    "connected": if provider == Provider::Codex {row["connected"] == true} else {value["connected"] != false},
                    "status": text(row, "status"),
                    "turnId": row["turnId"], "turnStatus": row["turnStatus"],
                    "awaiting": !array(row, "requests").is_empty(),
                }))
            })
            .collect();
        Ok(json!({"sessions": rows}))
    }
}
