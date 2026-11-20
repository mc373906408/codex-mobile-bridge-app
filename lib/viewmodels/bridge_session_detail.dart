part of 'bridge_view_model.dart';

extension BridgeSessionDetail on BridgeViewModel {
  Future<void> openSession(SessionRef session, {bool activate = false}) async {
    if (busy ||
        !foreground ||
        !authenticated ||
        session.computerId != computer?.id) {
      return;
    }
    final generation = ++_selectionGeneration;
    final scope = _listSnapshotScope(session);
    final prefetch = _listSnapshotReads[scope];
    final watch = _takeWatch();
    await Future.wait([flushDraft(), _stopWatch(watch)]);
    if (_disposed ||
        generation != _selectionGeneration ||
        !foreground ||
        !authenticated) {
      return;
    }
    if (_draftFailed) {
      fresh = false;
      _notify();
      return;
    }
    selected = session;
    _clearSnapshotNotice();
    snapshot = null;
    _chatPreview = relayRecovering ? null : _chatPreviews.read(session);
    messages = [];
    pending = [];
    attachments = [];
    draftText = '';
    draftOptions = {};
    _draftAccount = '';
    _draftReady = false;
    _draftRevision = 0;
    _draftFailed = false;
    fresh = false;
    loadingHistory = true;
    error = null;
    hasMoreHistory = false;
    _before = null;
    _historyEpoch = '';
    _notify();
    try {
      SessionSnapshot? value;
      if (prefetch != null && _currentListSnapshotScope(scope)) {
        try {
          final preloaded = await prefetch;
          if (_currentListSnapshotScope(scope) &&
              preloaded.session == session &&
              preloaded.accountIdentity.isNotEmpty) {
            value = preloaded;
          }
        } catch (_) {}
        if (!_current(generation, session) || !foreground || !authenticated) {
          return;
        }
      }
      value ??= await repository.snapshot(session);
      if (!_current(generation, session) || !foreground || !authenticated) {
        return;
      }
      if (value.session != session) {
        throw StateError(
          'Session state or account changed. Refresh before trying again',
        );
      }
      await _applySnapshot(value, generation);
      if (!_current(generation, session) || !foreground || !authenticated) {
        return;
      }
      final id = repository.newId();
      _subscriptionId = id;
      _subscriptionComputer = session.computerId;
      _watch = repository
          .watch(session, id)
          .listen(
            (event) {
              if (!_current(generation, session) ||
                  event.subscriptionId != id ||
                  !foreground) {
                return;
              }
              if (event.snapshot case final value?) {
                unawaited(
                  _applySnapshot(value, generation).catchError((Object value) {
                    if (_current(generation, session)) {
                      fresh = false;
                      reportError(value);
                    }
                  }),
                );
              } else {
                fresh = false;
                error = event.message;
                _watchErrorRevision = _errorRevision;
                if (event.authenticationRequired) {
                  auth = null;
                }
                _notify();
              }
            },
            onError: (Object value) {
              if (_current(generation, session)) {
                fresh = false;
                error = value;
                _watchErrorRevision = _errorRevision;
                _notify();
              }
            },
            onDone: () {
              if (_current(generation, session) && _subscriptionId == id) {
                fresh = false;
                _notify();
              }
            },
          );
      if (activate && _current(generation, session)) {
        loadingHistory = false;
        await connectSession();
      }
    } catch (value) {
      if (_current(generation, session)) {
        if (snapshot == null) _discardChatPreviews();
        error = value;
      }
    } finally {
      if (_current(generation, session)) {
        loadingHistory = false;
        _notify();
      }
    }
  }

  bool _current(int generation, SessionRef session) =>
      !_disposed && generation == _selectionGeneration && selected == session;

  void _observeSessionIdentity(SessionSnapshot value) {
    _readAccounts[sessionKey(value.session)] = value.accountIdentity;
    _rememberListMessageTime(value);
    _chatPreviews.discardMismatch(value);
    if (_chatPreview case final preview?) {
      if (preview.session == value.session && !preview.matches(value)) {
        _chatPreview = null;
      }
    }
  }

  Future<void> _applySnapshot(SessionSnapshot value, int generation) async {
    if (!_current(generation, value.session) || !foreground || !authenticated) {
      return;
    }
    final previousError = _watchErrorRevision;
    final update = ++_snapshotGeneration;
    final accountChanged = _draftAccount != value.accountIdentity;
    final incoming = value.history.messages;
    final overlap = incoming.isEmpty
        ? -1
        : messages.indexWhere((message) => message.id == incoming.first.id);
    final preserve =
        !accountChanged &&
        !value.history.reset &&
        _historyEpoch == value.history.epoch &&
        overlap > 0;
    if (!preserve &&
        (accountChanged ||
            value.history.reset ||
            _historyEpoch != value.history.epoch ||
            messages.firstOrNull?.id != incoming.firstOrNull?.id ||
            _before != value.history.before ||
            hasMoreHistory != value.history.hasMore)) {
      ++_historyRevision;
    }
    messages = preserve
        ? [...messages.take(overlap), ...incoming]
        : [...incoming];
    if (!preserve) {
      _before = value.history.before;
      hasMoreHistory = value.history.hasMore;
    }
    final previous = snapshot;
    if (value.history.reset ||
        (previous != null &&
            (previous.accountIdentity != value.accountIdentity ||
                previous.history.epoch != value.history.epoch))) {
      _resetAttachmentScope();
    }
    _historyEpoch = value.history.epoch;
    snapshot = value;
    final imageScope = attachmentReadScope;
    if (previous == null && imageScope != null) {
      _attachmentImages.discardOtherScopes(imageScope);
    }
    _observeSessionIdentity(value);
    _chatPreview = null;
    if (!relayRecovering) {
      final row = sessions
          .where((row) => row.session == value.session)
          .firstOrNull;
      _chatPreviews.remember(
        value,
        listRevision: row == null ? null : sessionListRevision(row),
      );
    }
    fresh = true;
    if (value.notice.isNotEmpty) {
      notice = value.notice;
      _snapshotNotice = value.notice;
    } else {
      _clearSnapshotNotice();
    }
    if (accountChanged && _draftReady) {
      // Persist the old scope before discarding its editor, never migrate across accounts.
      final oldDraft = Draft(
        text: draftText,
        attachments: [...attachments],
        revision: _draftRevision,
        options: jsonEncode(draftOptions),
      );
      final oldAccount = _draftAccount;
      unawaited(
        repository.saveDraft(value.session, oldAccount, oldDraft).catchError((
          Object value,
        ) {
          reportError(value);
        }),
      );
    }
    if (accountChanged || value.accountIdentity.isEmpty) {
      _draftTimer?.cancel();
      _draftReady = false;
      _draftAccount = value.accountIdentity;
      draftText = '';
      draftOptions = {};
      attachments = [];
      _draftRevision = 0;
      pending = [];
      _notify();
    }
    if (value.accountIdentity.isEmpty) {
      _clearRecoveredReadError(previousError);
      if (_watchErrorRevision == previousError) _watchErrorRevision = null;
      _notify();
      return;
    }
    if (!_draftReady) {
      final restored = await repository.draft(
        value.session,
        value.accountIdentity,
      );
      if (!_current(generation, value.session) ||
          update != _snapshotGeneration ||
          _draftAccount != value.accountIdentity) {
        return;
      }
      draftText = restored.text;
      draftOptions = Map<String, dynamic>.from(
        jsonDecode(restored.options) as Map,
      );
      attachments = restored.attachments;
      _draftRevision = restored.revision;
      _draftReady = true;
      _draftFailed = false;
    }
    if (!value.capabilities.steer && steer) {
      draftOptions = {...draftOptions, 'mode': 'send'};
    }
    final unresolved = await repository.pending(
      value.session,
      value.accountIdentity,
    );
    if (!_current(generation, value.session) ||
        update != _snapshotGeneration ||
        _draftAccount != value.accountIdentity) {
      return;
    }
    pending = unresolved;
    _prefetchModelCatalog(value);
    _clearRecoveredReadError(previousError);
    if (_watchErrorRevision == previousError) _watchErrorRevision = null;
    _notify();
  }

  bool get _canReadHistory => foreground && authenticated && !relayRecovering;

  bool get canLoadOlder =>
      _canReadHistory &&
      snapshot != null &&
      selected != null &&
      _before != null &&
      hasMoreHistory &&
      !loadingHistory;

  Future<void> loadOlder() async {
    if (!canLoadOlder) return;
    final session = selected!, cursor = _before!;
    final generation = _selectionGeneration, revision = _historyRevision;
    bool current() =>
        _current(generation, session) &&
        revision == _historyRevision &&
        _canReadHistory;
    loadingHistory = true;
    _notify();
    try {
      final page = await repository.history(session, cursor);
      if (!current()) return;
      if (page.reset || page.epoch != _historyEpoch) {
        _before = null;
        hasMoreHistory = false;
        notice = 'History changed; refresh the latest view';
        return;
      }
      final known = messages.map((message) => message.id).toSet();
      messages = [
        ...page.messages.where((message) => !known.contains(message.id)),
        ...messages,
      ];
      hasMoreHistory =
          page.hasMore && page.before != null && page.before != cursor;
      _before = hasMoreHistory ? page.before : null;
    } catch (value) {
      if (current()) error = value;
    } finally {
      if (_current(generation, session)) {
        loadingHistory = false;
        _notify();
      }
    }
  }
}
