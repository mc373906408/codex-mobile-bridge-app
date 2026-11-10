part of 'bridge_view_model.dart';

extension BridgeSessionList on BridgeViewModel {
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

  Future<void> filterSessions({String? source, bool? archived}) async {
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
      }
    }
  }

  Future<void> _verifyReadSessions(int generation, int connection) async {
    final markers = presentation['readSessions'] as Map? ?? {};
    final rows = sessions.where((row) {
      final marker = markers[sessionKey(row.session)];
      return marker is Map &&
          marker['account'] is String &&
          marker['account'] != '' &&
          marker['updated'] == row.updatedAt;
    }).iterator;
    bool current() =>
        !_disposed &&
        foreground &&
        authenticated &&
        generation == _listGeneration &&
        connection == _connectionGeneration;
    // Only persisted read markers need verification. Bounded passive reads keep
    // one slow environment from blocking the list or creating a request burst.
    Future<void> worker() async {
      while (current() && rows.moveNext()) {
        final row = rows.current;
        try {
          final verified = await repository.snapshot(row.session);
          if (!current()) return;
          _readAccounts[sessionKey(row.session)] = verified.accountIdentity;
          _notify();
        } catch (_) {
          // An unverifiable account is conservatively unread.
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
  }
}
