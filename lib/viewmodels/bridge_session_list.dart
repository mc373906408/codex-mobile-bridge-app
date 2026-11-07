part of 'bridge_view_model.dart';

extension BridgeSessionList on BridgeViewModel {
  Future<void> selectProvider(Provider value) async {
    if (busy || provider == value) return;
    await backToSessions();
    if (_draftFailed || !foreground) return;
    provider = value;
    query = '';
    nextOffset = null;
    sessions = [];
    environmentIssues = const [];
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
    final previousError = _sessionListErrorRevision;
    loading = true;
    _notify();
    try {
      final page = await repository.sessions(
        target,
        selectedProvider,
        query,
        more ? nextOffset! : 0,
      );
      if (_disposed ||
          generation != _listGeneration ||
          connection != _connectionGeneration ||
          provider != selectedProvider) {
        return;
      }
      sessions = more
          ? {
              for (final value in [...sessions, ...page.sessions])
                value.session: value,
            }.values.toList()
          : page.sessions;
      nextOffset = page.nextOffset;
      notice = page.notice.isEmpty ? null : page.notice;
      environmentIssues = List.unmodifiable(page.environmentIssues);
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
}
