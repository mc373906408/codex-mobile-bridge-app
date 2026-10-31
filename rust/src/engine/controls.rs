use super::*;

const MAX_ANSWER_CHARACTERS: usize = 20_000;

impl Engine {
    pub async fn send(
        &self,
        session: &SessionRef,
        token: &str,
        id: &str,
        message: String,
        attachments: Vec<String>,
        steer: bool,
    ) -> Result<OperationOutcome> {
        let _guard = self.writes.lock().await;
        let current = self.preflight(session, token).await?;
        if !current.capabilities.send
            || steer && !current.capabilities.steer
            || current.running && !steer
        {
            return Err(BridgeError::Invalid(
                "This session cannot use the selected send mode".into(),
            ));
        }
        if (message.trim().is_empty() && attachments.is_empty())
            || message.chars().count() > 100_000
            || attachments.len() > 8
        {
            return Err(BridgeError::Invalid("Message is empty or too large".into()));
        }
        if !attachments.is_empty() && !current.capabilities.attachments {
            return Err(BridgeError::Invalid("Attachments are not supported".into()));
        }
        for attachment in &attachments {
            uuid::Uuid::parse_str(attachment)
                .map_err(|_| BridgeError::Invalid("Invalid attachment ID".into()))?;
        }
        let body = json!({"text":message,"attachments":attachments,"mode":if steer {"steer"} else {"send"},"id":id});
        self.mutate(session, &current, "send", id, body).await
    }

    pub async fn stop(
        &self,
        session: &SessionRef,
        token: &str,
        id: &str,
    ) -> Result<OperationOutcome> {
        let _guard = self.writes.lock().await;
        let current = self.preflight(session, token).await?;
        if !current.capabilities.stop {
            return Err(BridgeError::Invalid(
                "There is no confirmed running task to stop".into(),
            ));
        }
        self.mutate(session, &current, "stop", id, json!({})).await
    }

    pub async fn resume(
        &self,
        session: &SessionRef,
        token: &str,
        id: &str,
    ) -> Result<OperationOutcome> {
        let _guard = self.writes.lock().await;
        let current = self.preflight(session, token).await?;
        if !current.capabilities.resume {
            return Err(BridgeError::Invalid("Resume is not available".into()));
        }
        self.mutate(
            session,
            &current,
            if session.provider == Provider::Codex {
                "reconnect"
            } else {
                "resume"
            },
            id,
            json!({"activate":true}),
        )
        .await
    }

    pub async fn respond(
        &self,
        session: &SessionRef,
        token: &str,
        id: &str,
        request_id: &str,
        accept: bool,
        answers: Vec<QuestionAnswer>,
    ) -> Result<OperationOutcome> {
        let _guard = self.writes.lock().await;
        let current = self.preflight(session, token).await?;
        let approval = current
            .approvals
            .iter()
            .find(|request| request.id == request_id)
            .ok_or_else(|| {
                BridgeError::Invalid("This approval has expired or was already handled".into())
            })?;
        if !current.capabilities.approve
            || !approval.supported
            || (accept && !approval.can_accept)
            || (!accept && !approval.can_decline)
        {
            return Err(BridgeError::Invalid(
                "Handle this request on the computer".into(),
            ));
        }
        let answer_map = question_answers(approval, session.provider, &answers)?;
        let decision = if accept { "accept" } else { "decline" };
        let wire_id: Value = serde_json::from_str(&approval.wire_id)?;
        let body = if session.provider == Provider::Codex {
            json!({"requestId":wire_id,"response":if approval.kind==ApprovalKind::Questions {json!({"answers":answer_map})} else {json!({"decision":decision})}})
        } else {
            json!({"requestId":wire_id,"decision":decision,"answers":answer_map})
        };
        self.mutate(session, &current, "respond", id, body).await
    }

    pub async fn settings(
        &self,
        session: &SessionRef,
        token: &str,
        id: &str,
        model: String,
        effort: String,
    ) -> Result<OperationOutcome> {
        let _guard = self.writes.lock().await;
        let current = self.preflight(session, token).await?;
        if !current.capabilities.models {
            return Err(BridgeError::Invalid(
                "Model settings are not available".into(),
            ));
        }
        let models = adapters::catalog(&self.transport, session).await?;
        let offered = models
            .iter()
            .find(|option| option.id == model)
            .ok_or_else(|| BridgeError::Invalid("Select an advertised model".into()))?;
        if !offered.efforts.is_empty() && !offered.efforts.contains(&effort) {
            return Err(BridgeError::Invalid(
                "Select an advertised reasoning effort".into(),
            ));
        }
        let mut body = json!({"model":model});
        if !offered.efforts.is_empty() {
            body["effort"] = json!(effort);
        }
        self.mutate(session, &current, "settings", id, body).await
    }
}

fn question_answers(
    approval: &ApprovalRequest,
    provider: Provider,
    answers: &[QuestionAnswer],
) -> Result<serde_json::Map<String, Value>> {
    let mut result = serde_json::Map::new();
    if approval.kind != ApprovalKind::Questions {
        return Ok(result);
    }
    if answers.len() != approval.questions.len() {
        return Err(BridgeError::Invalid("Answer every question".into()));
    }
    for question in &approval.questions {
        let answer = answers
            .iter()
            .find(|answer| answer.question_id == question.id)
            .ok_or_else(|| BridgeError::Invalid("Missing answer".into()))?;
        if answer.values.is_empty()
            || answer.values.iter().any(|value| {
                value.trim().is_empty() || value.chars().count() > MAX_ANSWER_CHARACTERS
            })
        {
            return Err(BridgeError::Invalid("Invalid answer".into()));
        }
        let value = if provider == Provider::Codex {
            json!(answer.values)
        } else {
            json!({"answers":answer.values})
        };
        result.insert(question.id.clone(), value);
    }
    Ok(result)
}
