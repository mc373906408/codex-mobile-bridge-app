use super::*;

const MAX_FILENAME_BYTES: usize = 255;
const WEBP_FORMAT_OFFSET: usize = 8;
const WEBP_FORMAT_TAG: &[u8] = b"WEBP";

struct UploadInput<'a> {
    id: &'a str,
    name: String,
    bytes: Vec<u8>,
}

impl Engine {
    pub async fn upload(
        &self,
        session: &SessionRef,
        token: &str,
        id: &str,
        name: String,
        bytes: Vec<u8>,
    ) -> Result<Attachment> {
        let _guard = self.writes.lock().await;
        let current = self.preflight(session, token).await?;
        let input = UploadInput { id, name, bytes };
        let attachment = prepare_attachment(&current, &input)?;
        let scope = Store::scope(session, &current.account_identity)?;
        let body = json!({"name":input.name,"sha256":crate::security::sha256_hex(&input.bytes)});
        if let Some(existing) = self.store.begin(id, &scope, "upload", &body)? {
            return finish_attachment(existing, attachment);
        }
        let result = self.request_upload(session, input).await;
        let outcome = upload_outcome(id, result);
        self.store.finish(&outcome)?;
        finish_attachment(outcome, attachment)
    }

    async fn request_upload(&self, session: &SessionRef, input: UploadInput<'_>) -> Result<Value> {
        let (path, mut query) = adapters::route(session, "uploads");
        query.push(("id", input.id.into()));
        query.push(("name", input.name));
        let response = self
            .transport
            .request(
                Method::POST,
                &path,
                &query,
                Some(input.bytes),
                "application/octet-stream",
            )
            .await?;
        Transport::decode(response).await
    }

    pub async fn image(&self, session: &SessionRef, attachment: &Attachment) -> Result<Vec<u8>> {
        validate_session(session, &self.computer.id)?;
        let (path, query) =
            if attachment.source == "upload" && uuid::Uuid::parse_str(&attachment.id).is_ok() {
                let (path, mut query) =
                    adapters::route(session, &format!("uploads/{}/preview", attachment.id));
                query.push(("variant", "original".into()));
                (path, query)
            } else if session.provider == Provider::Codex
                && attachment.source == "desktop"
                && attachment.id.len() == 64
                && attachment.id.bytes().all(|b| b.is_ascii_hexdigit())
            {
                adapters::route(session, &format!("desktop-images/{}", attachment.id))
            } else {
                return Err(BridgeError::Invalid("Unsupported image reference".into()));
            };
        let response = self
            .transport
            .request(Method::GET, &path, &query, None, "")
            .await?;
        if !response.status().is_success() {
            Transport::decode(response).await?;
            return Err(BridgeError::Invalid("Image is unavailable".into()));
        }
        let mime = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default();
        if !["image/png", "image/jpeg", "image/gif", "image/webp"]
            .iter()
            .any(|allowed| mime.split(';').next() == Some(*allowed))
        {
            return Err(BridgeError::Invalid(
                "Only raster images are rendered".into(),
            ));
        }
        Transport::bounded_bytes(response, MAX_FILE).await
    }
}

fn raster_image(bytes: &[u8]) -> bool {
    bytes.starts_with(b"\x89PNG\r\n\x1a\n")
        || bytes.starts_with(b"\xff\xd8\xff")
        || bytes.starts_with(b"GIF8")
        || bytes.starts_with(b"RIFF")
            && bytes.get(WEBP_FORMAT_OFFSET..WEBP_FORMAT_OFFSET + WEBP_FORMAT_TAG.len())
                == Some(WEBP_FORMAT_TAG)
}

fn prepare_attachment(current: &SessionSnapshot, input: &UploadInput<'_>) -> Result<Attachment> {
    if !current.capabilities.attachments
        || input.bytes.is_empty()
        || input.bytes.len() > MAX_FILE
        || input.name.is_empty()
        || input.name.len() > MAX_FILENAME_BYTES
        || input.name.chars().any(char::is_control)
    {
        return Err(BridgeError::Invalid(
            "Attachment is unsupported or exceeds 20 MiB".into(),
        ));
    }
    uuid::Uuid::parse_str(input.id)
        .map_err(|_| BridgeError::Invalid("Invalid upload ID".into()))?;
    let image = raster_image(&input.bytes);
    if !image && !current.capabilities.arbitrary_files {
        return Err(BridgeError::Invalid(
            "This client accepts image attachments only".into(),
        ));
    }
    Ok(Attachment {
        id: input.id.into(),
        name: input.name.clone(),
        image,
        source: "upload".into(),
    })
}

fn upload_outcome(id: &str, result: Result<Value>) -> OperationOutcome {
    match result {
        Ok(value) if value["id"].as_str() == Some(id) => OperationOutcome {
            id: id.into(),
            kind: OutcomeKind::Accepted,
            message: "Attachment stored by the gateway".into(),
            created_session: None,
        },
        Ok(_) => unknown(id, "Upload was not acknowledged; check it on the computer"),
        Err(error) => unknown(id, &error.to_string()),
    }
}

fn finish_attachment(outcome: OperationOutcome, attachment: Attachment) -> Result<Attachment> {
    if outcome.kind == OutcomeKind::Accepted {
        return Ok(attachment);
    }
    Err(BridgeError::Invalid(outcome.message))
}
