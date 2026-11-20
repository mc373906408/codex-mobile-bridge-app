part of 'bridge_view_model.dart';

extension BridgeSessionList on BridgeViewModel {
  DateTime? lastMessageTime(SessionSummary row) {
    if (!authenticated || row.session.computerId != computer?.id) return null;
    final known = _listMessageTimes[row.session];
    return known?.$1 == sessionListRevision(row) ? known?.$2 : null;
  }

  void _rememberListMessageTime(SessionSnapshot snapshot) {
    final session = snapshot.session;
    final row = sessions.where((row) => row.session == session).firstOrNull;
    _listMessageTimes.remove(session);
    if (row == null || snapshot.accountIdentity.isEmpty) return;
    if (lastSnapshotMessageTime(snapshot) case final time?) {
      _listMessageTimes[session] = (sessionListRevision(row), time);
      if (_listMessageTimes.length > 500) {
        _listMessageTimes.remove(_listMessageTimes.keys.first);
      }
    }
  }

  Future<void> openListedSession(SessionSummary row) async {
    final generation = _selectionGeneration + 1;
    await openSession(row.session, activate: true);
    final current = snapshot;
    if (!_current(generation, row.session) ||
        !foreground ||
        !authenticated ||
        !fresh ||
        current == null ||
        current.session != row.session ||
        current.accountIdentity.isEmpty ||
        !sessions.any(
          (candidate) =>
              candidate.session == row.session &&
              sessionListRevision(candidate) == sessionListRevision(row),
        )) {
      return;
    }
    _rememberReadMarker(row, current.accountIdentity);
  }

  Future<void> prefetchListedSessions(List<SessionSummary> rows) async {
    if (_disposed ||
        !foreground ||
        !authenticated ||
        relayRecovering ||
        _prefetching ||
        selected != null ||
        busy ||
        loading ||
        archived ||
        query.isNotEmpty) {
      return;
    }
    final batch = (
      _connectionGeneration,
      _listGeneration,
      _chatPreviewGeneration,
    );
    if (_prefetchBatch != batch) {
      _prefetchBatch = batch;
      _prefetchAttempts.clear();
      _unreadPrefetches = 0;
    }
    if (_prefetchAttempts.length >= 8) return;
    final listed = sessions.toSet();
    SessionSummary? candidate;
    var priority = 3;
    for (final row in rows) {
      if (_prefetchAttempts.contains(row.session) || !listed.contains(row)) {
        continue;
      }
      final rank = _prefetchPriority(row);
      if (rank >= priority ||
          (rank == 2 && _unreadPrefetches >= 4) ||
          _chatPreviews.read(row.session)?.listRevision ==
              sessionListRevision(row)) {
        continue;
      }
      candidate = row;
      priority = rank;
      if (rank == 0) break;
    }
    if (candidate == null) return;
    final session = candidate.session;
    final scope = _listSnapshotScope(session);
    if (!_currentListSnapshotScope(scope)) return;
    _prefetchAttempts.add(session);
    if (priority == 2) ++_unreadPrefetches;
    final selection = _selectionGeneration;
    _prefetching = true;
    try {
      final value = await _readListSnapshot(scope);
      if (!_currentListSnapshotScope(scope) ||
          _selectionGeneration != selection ||
          value.session != session ||
          !sessions.contains(candidate)) {
        return;
      }
      _chatPreviews.remember(
        value,
        listRevision: sessionListRevision(candidate),
      );
      _rememberListMessageTime(value);
    } catch (_) {
      return;
    } finally {
      _prefetching = false;
      _notify();
    }
  }

  int _prefetchPriority(SessionSummary row) {
    final session = row.session;
    final status = _sessionActivity(session);
    final activityKnown =
        _activityContext ==
            (_connectionGeneration, session.provider, session.entry) &&
        _activity.rows.containsKey(
          activityKey(session.environment, session.id),
        );
    if (status == SessionActivityKind.running ||
        !activityKnown &&
            const {'active', 'running', 'inProgress'}.contains(row.status)) {
      return 0;
    }
    if (const {
      SessionActivityKind.completed,
      SessionActivityKind.failed,
      SessionActivityKind.interrupted,
    }.contains(status)) {
      return 1;
    }
    final marker = _readMarkerAccount(row);
    final verified = _readAccounts[sessionKey(session)];
    return marker == null || (verified != null && marker != verified) ? 2 : 3;
  }

  _ListSnapshotScope _listSnapshotScope(SessionRef session) => (
    connection: _connectionGeneration,
    list: _listGeneration,
    preview: _chatPreviewGeneration,
    session: session,
  );

  bool _currentListSnapshotScope(_ListSnapshotScope scope) =>
      !_disposed &&
      foreground &&
      authenticated &&
      !relayRecovering &&
      computer?.id == scope.session.computerId &&
      scope == _listSnapshotScope(scope.session);

  Future<SessionSnapshot> _readListSnapshot(_ListSnapshotScope scope) =>
      _listSnapshotReads.putIfAbsent(scope, () {
        return Future.sync(() => repository.snapshot(scope.session))
            .whenComplete(() {
              _listSnapshotReads.remove(scope);
            });
      });

  Future<void> selectProvider(Provider value) async {
    if (busy || provider == value && entry.isEmpty) return;
    await backToSessions();
    if (_draftFailed || !foreground) return;
    provider = value;
    source = 'all';
    availableSources = const [];
    entry = '';
    query = '';
    nextOffset = null;
    sessions = [];
    environmentIssues = const [];
    await refreshSessions();
  }

  Future<void> selectClient(ClientInfo client) async {
    if (busy || provider == client.provider && entry == client.entry) return;
    await backToSessions();
    if (_draftFailed || !foreground) return;
    provider = client.provider;
    source = 'all';
    availableSources = const [];
    entry = client.entry;
    query = '';
    sessions = [];
    nextOffset = null;
    await refreshSessions();
  }

  Future<void> filterSessions({
    String? source,
    bool? archived,
    bool? groupByProject,
  }) async {
    if (groupByProject != null) {
      setPresentation('groupByProject', groupByProject);
    }
    if (source != null) this.source = source;
    if (archived != null) this.archived = archived;
    await refreshSessions();
  }

  void search(String value) {
    query = value;
    ++_listGeneration;
    _searchTimer?.cancel();
    _searchTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(refreshSessions()),
    );
  }

  Future<void> refreshSessions({bool more = false}) async {
    final target = computer;
    if (target == null || !authenticated || !foreground) return;
    if (more && nextOffset == null) return;
    final generation = ++_listGeneration;
    final connection = _connectionGeneration;
    final selectedProvider = provider;
    final selectedEntry = entry;
    final previousError = _sessionListErrorRevision;
    _readAccounts.clear();
    loading = true;
    _notify();
    try {
      final page = await repository.sessionsForEntry(
        target,
        selectedProvider,
        selectedEntry,
        query,
        more ? nextOffset! : 0,
        source,
        archived,
        groupByProject: groupByProject,
      );
      if (_disposed ||
          generation != _listGeneration ||
          connection != _connectionGeneration ||
          provider != selectedProvider ||
          entry != selectedEntry) {
        return;
      }
      sessions = more
          ? {
              for (final value in [...sessions, ...page.sessions])
                value.session: value,
            }.values.toList()
          : page.sessions;
      nextOffset = page.nextOffset;
      availableSources = List.unmodifiable(page.availableSources);
      notice = page.notice.isEmpty ? null : page.notice;
      environmentIssues = List.unmodifiable(page.environmentIssues);
      unawaited(_verifyReadSessions(generation, connection));
      _clearRecoveredReadError(previousError);
      _sessionListErrorRevision = null;
    } catch (value) {
      if (generation == _listGeneration) {
        error = value;
        _sessionListErrorRevision = _errorRevision;
      }
    } finally {
      if (generation == _listGeneration) {
        loading = false;
        _notify();
        unawaited(refreshSessionActivity());
      }
    }
  }

  Future<void> _verifyReadSessions(int generation, int connection) async {
    final rows = sessions
        .where((row) => _readMarkerAccount(row) != null)
        .iterator;
    final previewGeneration = _chatPreviewGeneration;
    bool current() =>
        !_disposed &&
        foreground &&
        authenticated &&
        !relayRecovering &&
        generation == _listGeneration &&
        connection == _connectionGeneration &&
        previewGeneration == _chatPreviewGeneration;
    // Only persisted read markers need verification. Bounded passive reads keep
    // one slow environment from blocking the list or creating a request burst.
    Future<void> worker() async {
      while (current() && rows.moveNext()) {
        final row = rows.current;
        final snapshotGeneration = _snapshotGeneration;
        try {
          final verified = await _readListSnapshot(
            _listSnapshotScope(row.session),
          );
          if (!current()) return;
          if (verified.session != row.session ||
              (row.session == selected &&
                  snapshotGeneration != _snapshotGeneration)) {
            continue;
          }
          _observeSessionIdentity(verified);
          _notify();
        } catch (_) {
          // An unverifiable account is conservatively unread.
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
  }
}
