use super::*;

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
    use_changes: bool,
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
        let mut use_changes = true;
        loop {
            let step = WatchStep {
                session: subscription.session,
                id: subscription.id,
                use_changes,
            };
            let error = match self.read_watch_step(step, emit).await {
                Ok(supported) => {
                    use_changes = supported;
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
            let delay = BACKOFF_BASE_MILLISECONDS * (1u64 << failures.min(MAX_BACKOFF_SHIFT));
            tokio::time::sleep(Duration::from_millis(delay)).await;
        }
    }

    async fn read_watch_step(
        &self,
        step: WatchStep<'_>,
        emit: &mut (impl FnMut(GatewayEvent) -> bool + Send),
    ) -> Result<bool> {
        let current = self.snapshot(step.session).await?;
        let sequence = current.sequence;
        let epoch = current.history.epoch.clone();
        let start = current.history.before.clone();
        let running = current.running;
        if !emit(GatewayEvent {
            subscription_id: step.id.into(),
            snapshot: Some(current),
            authentication_required: false,
            message: String::new(),
        }) {
            return Err(BridgeError::Cancelled);
        }
        if step.session.provider == Provider::Codex {
            if !step.use_changes || epoch.is_empty() {
                // Older gateways still have bounded timeline pages. Never
                // fall back to the full-history /events or /poll payloads.
                tokio::time::sleep(Duration::from_secs(IDLE_DESKTOP_POLL_SECONDS)).await;
                return Ok(false);
            }
            let (path, mut query) = adapters::route(step.session, "changes");
            query.push(("after", sequence.to_string()));
            query.push(("epoch", epoch));
            if let Some(start) = start {
                query.push(("start", start));
            }
            let started = tokio::time::Instant::now();
            let supported = match self.transport.get(&path, &query).await {
                Ok(_) => true,
                Err(BridgeError::Http {
                    status: 404 | 405 | 501,
                    ..
                }) => false,
                Err(error) => return Err(error),
            };
            // /changes normally waits on the server. Bound the refresh rate
            // even if a gateway repeatedly returns reset or an unchanged page.
            let minimum = if supported {
                Duration::from_millis(250)
            } else {
                Duration::from_secs(IDLE_DESKTOP_POLL_SECONDS)
            };
            tokio::time::sleep(minimum.saturating_sub(started.elapsed())).await;
            // Deltas are invalidations only. The next iteration re-reads a
            // bounded snapshot and verifies its session/host/account authority.
            return Ok(supported);
        }
        let seconds = if running {
            ACTIVE_DESKTOP_POLL_SECONDS
        } else {
            IDLE_DESKTOP_POLL_SECONDS
        };
        tokio::time::sleep(Duration::from_secs(seconds)).await;
        Ok(step.use_changes)
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
