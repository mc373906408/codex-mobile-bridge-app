use super::*;

const SSE_FAILURES_BEFORE_POLLING: u32 = 3;
const MAX_BACKOFF_SHIFT: u32 = 5;
const BACKOFF_BASE_MILLISECONDS: u64 = 500;
const ACTIVE_DESKTOP_POLL_SECONDS: u64 = 1;
const IDLE_DESKTOP_POLL_SECONDS: u64 = 3;

struct Subscription<'a> {
    session: &'a SessionRef,
    id: &'a str,
}

struct WatchStep<'a> {
    session: &'a SessionRef,
    id: &'a str,
    use_sse: bool,
}

struct SseEvent<'a> {
    session: &'a SessionRef,
    id: &'a str,
    kind: &'a str,
    epoch: u64,
}

impl Engine {
    pub async fn watch(
        &self,
        session: SessionRef,
        id: String,
        mut emit: impl FnMut(GatewayEvent) -> bool + Send,
    ) -> Result<()> {
        validate_session(&session, &self.computer.id)?;
        let token = self.register_subscription(&id);
        let subscription = Subscription {
            session: &session,
            id: &id,
        };
        tokio::select! {
            _ = token.cancelled() => {},
            _ = self.watch_loop(&subscription, &mut emit) => {},
        }
        self.unregister_subscription(&id, &token);
        Ok(())
    }

    fn register_subscription(&self, id: &str) -> Arc<CancellationToken> {
        let token = Arc::new(CancellationToken::new());
        let previous = self
            .subscriptions
            .lock()
            .unwrap()
            .insert(id.into(), token.clone());
        if let Some(previous) = previous {
            previous.cancel();
        }
        token
    }

    fn unregister_subscription(&self, id: &str, token: &Arc<CancellationToken>) {
        let mut subscriptions = self.subscriptions.lock().unwrap();
        // Cancelling an old stream must not remove its replacement with the same ID.
        if subscriptions
            .get(id)
            .is_some_and(|active| Arc::ptr_eq(active, token))
        {
            subscriptions.remove(id);
        }
    }

    async fn watch_loop(
        &self,
        subscription: &Subscription<'_>,
        emit: &mut (impl FnMut(GatewayEvent) -> bool + Send),
    ) {
        let mut failures = 0u32;
        let mut use_sse = subscription.session.provider == Provider::Codex
            && self.transport.status().transport == "sse";
        loop {
            let step = WatchStep {
                session: subscription.session,
                id: subscription.id,
                use_sse,
            };
            let error = match self.read_watch_step(step, emit).await {
                Ok(()) => {
                    failures = 0;
                    continue;
                }
                Err(error) => error,
            };
            if matches!(error, BridgeError::Cancelled)
                || !report_watch_error(subscription, &error, emit)
            {
                break;
            }
            failures = failures.saturating_add(1);
            if failures >= SSE_FAILURES_BEFORE_POLLING {
                use_sse = false;
            }
            let delay = BACKOFF_BASE_MILLISECONDS * (1u64 << failures.min(MAX_BACKOFF_SHIFT));
            tokio::time::sleep(Duration::from_millis(delay)).await;
        }
    }

    async fn read_watch_step(
        &self,
        step: WatchStep<'_>,
        emit: &mut (impl FnMut(GatewayEvent) -> bool + Send),
    ) -> Result<()> {
        let current = self.snapshot(step.session).await?;
        let sequence = current.sequence;
        let running = current.running;
        if !emit(GatewayEvent {
            subscription_id: step.id.into(),
            snapshot: Some(current),
            authentication_required: false,
            message: String::new(),
        }) {
            return Err(BridgeError::Cancelled);
        }
        if step.use_sse {
            return self
                .sse(
                    &Subscription {
                        session: step.session,
                        id: step.id,
                    },
                    emit,
                )
                .await;
        }
        if step.session.provider == Provider::Codex {
            let (path, mut query) = adapters::route(step.session, "poll");
            query.push(("after", sequence.to_string()));
            self.transport.get(&path, &query).await?;
            return Ok(());
        }
        let seconds = if running {
            ACTIVE_DESKTOP_POLL_SECONDS
        } else {
            IDLE_DESKTOP_POLL_SECONDS
        };
        tokio::time::sleep(Duration::from_secs(seconds)).await;
        Ok(())
    }

    async fn sse(
        &self,
        subscription: &Subscription<'_>,
        emit: &mut (impl FnMut(GatewayEvent) -> bool + Send),
    ) -> Result<()> {
        let (path, query) = adapters::route(subscription.session, "events");
        let epoch = self.transport.authentication_epoch();
        let response = self
            .transport
            .request(Method::GET, &path, &query, None, "")
            .await?;
        if !response.status().is_success() {
            Transport::decode(response).await?;
            return Err(BridgeError::Network);
        }
        if !response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default()
            .starts_with("text/event-stream")
        {
            return Err(BridgeError::Protocol("expected an event stream".into()));
        }
        let mut stream = response.bytes_stream();
        let mut decoder = SseDecoder::default();
        while let Some(chunk) = stream.next().await {
            for kind in decoder.feed(&chunk?)? {
                let event = SseEvent {
                    session: subscription.session,
                    id: subscription.id,
                    kind: &kind,
                    epoch,
                };
                self.handle_sse_event(event, emit).await?;
            }
        }
        Err(BridgeError::Network)
    }

    async fn handle_sse_event(
        &self,
        event: SseEvent<'_>,
        emit: &mut (impl FnMut(GatewayEvent) -> bool + Send),
    ) -> Result<()> {
        match event.kind {
            "logout" => {
                self.transport.invalidate_epoch(Some(event.epoch));
                return Err(BridgeError::Unauthenticated);
            }
            "state" => {
                // The event invalidates the snapshot; timeline page keys remain stable.
                let snapshot = self.snapshot(event.session).await?;
                if !emit(GatewayEvent {
                    subscription_id: event.id.into(),
                    snapshot: Some(snapshot),
                    authentication_required: false,
                    message: String::new(),
                }) {
                    return Err(BridgeError::Cancelled);
                }
            }
            _ => {}
        }
        Ok(())
    }
}

fn report_watch_error(
    subscription: &Subscription<'_>,
    error: &BridgeError,
    emit: &mut (impl FnMut(GatewayEvent) -> bool + Send),
) -> bool {
    let authentication_required = matches!(error, BridgeError::Unauthenticated);
    emit(GatewayEvent {
        subscription_id: subscription.id.into(),
        snapshot: None,
        authentication_required,
        message: error.to_string(),
    }) && !authentication_required
}
