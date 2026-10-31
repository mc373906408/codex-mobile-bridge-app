use super::*;

const MAX_TITLE_CHARACTERS: usize = 120;
const MAX_MESSAGE_CHARACTERS: usize = 100_000;

struct CreationInput<'a> {
    project: &'a ProjectOption,
    title: &'a str,
    message: &'a str,
    id: &'a str,
}

impl Engine {
    pub async fn create(
        &self,
        project: ProjectOption,
        title: String,
        message: String,
        id: &str,
    ) -> Result<OperationOutcome> {
        let _guard = self.writes.lock().await;
        let input = CreationInput {
            project: &project,
            title: &title,
            message: &message,
            id,
        };
        validate_creation(&input)?;
        self.validate_creation_project(&input).await?;
        let session = SessionRef {
            computer_id: self.computer.id.clone(),
            provider: project.provider,
            environment: project.environment.clone(),
            id: format!("create:{}", project.key),
        };
        let scope = Store::scope(&session, &self.transport.identity())?;
        let body = creation_body(&input);
        if let Some(existing) = self.store.begin(id, &scope, "create", &body)? {
            return Ok(existing);
        }
        let (path, query) = creation_route(&project);
        let result = self.transport.post(&path, &query, &body).await;
        let outcome = self.creation_outcome(&input, result);
        self.store.finish(&outcome)?;
        Ok(outcome)
    }

    async fn validate_creation_project(&self, input: &CreationInput<'_>) -> Result<()> {
        if !self.transport.authenticate().await?.authenticated {
            return Err(BridgeError::Unauthenticated);
        }
        let project = input.project;
        let projects =
            adapters::projects(&self.transport, project.provider, &project.environment).await?;
        let offered = projects
            .into_iter()
            .find(|offered| {
                offered.key == project.key && offered.environment == project.environment
            })
            .ok_or_else(|| BridgeError::Invalid("The project is no longer available".into()))?;
        if offered.requires_message && input.message.trim().is_empty() {
            return Err(BridgeError::Invalid(
                "This client requires an opening message".into(),
            ));
        }
        Ok(())
    }

    fn creation_outcome(
        &self,
        input: &CreationInput<'_>,
        result: Result<Value>,
    ) -> OperationOutcome {
        let project = input.project;
        let outcome = classify(
            input.id,
            project.provider,
            "create",
            result
                .as_ref()
                .map(Clone::clone)
                .map_err(|_| BridgeError::Network),
        );
        let Ok(value) = result else { return outcome };
        let id = if project.provider == Provider::Codex {
            value["id"].as_str()
        } else {
            value["sessionId"]
                .as_str()
                .or_else(|| value["session"]["id"].as_str())
        };
        let Some(id) = id.filter(|id| *id != input.id) else {
            return outcome;
        };
        let created = SessionRef {
            computer_id: self.computer.id.clone(),
            provider: project.provider,
            environment: value["host"]
                .as_str()
                .unwrap_or(&project.environment)
                .into(),
            id: id.into(),
        };
        if validate_session(&created, &self.computer.id).is_err()
            || !(outcome.kind == OutcomeKind::Accepted
                || project.provider == Provider::Codex && value.get("opened").is_some())
        {
            return outcome;
        }
        OperationOutcome {
            kind: OutcomeKind::Accepted,
            message: "Chat created; continuing is a separate explicit action".into(),
            created_session: Some(created),
            ..outcome
        }
    }
}

fn validate_creation(input: &CreationInput<'_>) -> Result<()> {
    if input.title.chars().count() > MAX_TITLE_CHARACTERS
        || input.title.trim().is_empty()
        || input.message.chars().count() > MAX_MESSAGE_CHARACTERS
    {
        return Err(BridgeError::Invalid(
            "Invalid new-chat title or message".into(),
        ));
    }
    Ok(())
}

fn creation_body(input: &CreationInput<'_>) -> Value {
    if input.project.provider == Provider::Codex {
        return json!({"id":input.id,"project":input.project.key,"title":input.title});
    }
    json!({"id":input.id,"projectKey":input.project.key,"title":input.title,"text":input.message})
}

fn creation_route(project: &ProjectOption) -> (String, Vec<(&'static str, String)>) {
    if project.provider != Provider::Codex {
        return (
            format!("/api/desktop-sessions/{}/create", project.provider.slug()),
            vec![],
        );
    }
    let query = if project.environment.starts_with("wsl:") {
        vec![("entry", project.environment.clone())]
    } else {
        vec![]
    };
    ("/api/sessions".into(), query)
}
