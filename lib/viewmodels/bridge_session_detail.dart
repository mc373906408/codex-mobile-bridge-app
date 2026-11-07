part of 'bridge_view_model.dart';

extension BridgeSessionDetail on BridgeViewModel {
  Future<void> openSession(SessionRef session) async {
    if (busy ||
        !foreground ||
        !authenticated ||
        session.computerId != computer?.id) {
      return;
    }
    final generation = ++_selectionGeneration;
    await flushDraft();
    if (_draftFailed) {
      fresh = false;
      _notify();
      return;
    }
    await _stopWatch();
    if (_disposed || generation != _selectionGeneration) return;
    selected = session;
    _clearSnapshotNotice();
    snapshot = null;
    messages = [];
    pending = [];
    attachments = [];
    draftText = '';
    _draftAccount = '';
    _draftReady = false;
    _draftRevision = 0;
    _draftFailed = false;
    fresh = false;
    loadingHistory = true;
    error = null;
    hasMoreHistory = false;
    _historyEpoch = '';
    _notify();
    try {
      final value = await repository.snapshot(session);
      if (!_current(generation, session) || !foreground) return;
      await _applySnapshot(value, generation);
      if (!_current(generation, session) || !foreground) return;
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
                  _inboxTimer?.cancel();
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
    } catch (value) {
      if (_current(generation, session)) error = value;
    } finally {
      if (_current(generation, session)) {
        loadingHistory = false;
        _notify();
      }
    }
  }

  bool _current(int generation, SessionRef session) =>
      !_disposed && generation == _selectionGeneration && selected == session;

  Future<void> _applySnapshot(SessionSnapshot value, int generation) async {
    if (!_current(generation, value.session) || !foreground) return;
    final previousError = _watchErrorRevision;
    final update = ++_snapshotGeneration;
    ++_historyRevision;
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
    messages = preserve
        ? [...messages.take(overlap), ...incoming]
        : [...incoming];
    if (messages.length > 500) {
      messages = messages.sublist(messages.length - 500);
      _before = value.history.before;
      hasMoreHistory = value.history.hasMore;
    }
    if (!preserve) {
      _before = value.history.before;
      hasMoreHistory = value.history.hasMore;
    }
    _historyEpoch = value.history.epoch;
    snapshot = value;
    fresh = true;
    if (value.notice.isNotEmpty) {
      notice = value.notice;
      _snapshotNotice = value.notice;
    } else {
      _clearSnapshotNotice();
    }
    if (!value.capabilities.steer) steer = false;
    if (accountChanged && _draftReady) {
      // Persist the old scope before discarding its editor, never migrate across accounts.
      final oldDraft = Draft(
        text: draftText,
        attachments: [...attachments],
        revision: _draftRevision,
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
      attachments = restored.attachments;
      _draftRevision = restored.revision;
      _draftReady = true;
      _draftFailed = false;
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
    _clearRecoveredReadError(previousError);
    if (_watchErrorRevision == previousError) _watchErrorRevision = null;
    _notify();
  }

  Future<void> loadOlder() async {
    final session = selected;
    final cursor = _before;
    if (session == null ||
        cursor == null ||
        !hasMoreHistory ||
        loadingHistory ||
        !foreground) {
      return;
    }
    final generation = _selectionGeneration, revision = _historyRevision;
    loadingHistory = true;
    _notify();
    try {
      final page = await repository.history(session, cursor);
      if (!_current(generation, session) || revision != _historyRevision) {
        return;
      }
      if (page.reset || page.epoch != _historyEpoch) {
        notice = 'History changed; refresh the latest view';
        return;
      }
      final known = messages.map((message) => message.id).toSet();
      messages = [
        ...page.messages.where((message) => !known.contains(message.id)),
        ...messages,
      ];
      _before = page.before;
      hasMoreHistory = page.hasMore;
      if (messages.length > 500) {
        messages = messages.take(500).toList();
        hasMoreHistory = false;
        notice =
            'Memory window reached. Refresh to return to the latest messages';
      }
    } catch (value) {
      if (_current(generation, session)) error = value;
    } finally {
      if (_current(generation, session)) {
        loadingHistory = false;
        _notify();
      }
    }
  }
}
