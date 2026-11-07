part of 'bridge_view_model.dart';

extension BridgeNavigation on BridgeViewModel {
  Future<void> backToComputers() async {
    if (_disposed || busy || !foreground || computer == null) return;
    busy = true;
    _returningHome = true;
    fresh = false;
    loading = false;
    loadingHistory = false;
    error = null;
    ++_connectionGeneration;
    ++_selectionGeneration;
    ++_listGeneration;
    _inboxTimer?.cancel();
    _searchTimer?.cancel();
    _notify();
    try {
      await Future.wait([flushDraft(), _stopWatch()]);
      if (_disposed || _draftFailed) return;
      _clearConnectionState();
    } catch (value) {
      error = value;
    } finally {
      _returningHome = false;
      busy = false;
      _notify();
    }
  }

  void _clearConnectionState() {
    unawaited(_connectionWatch?.cancel());
    _connectionWatch = null;
    _cloudRecoveryComputer = null;
    _snapshotNotice = null;
    // Invalidate reads started before or during draft persistence.
    ++_connectionGeneration;
    ++_selectionGeneration;
    ++_listGeneration;
    _pendingNotification = null;
    _draftTimer?.cancel();
    _searchTimer?.cancel();
    _inboxTimer?.cancel();
    computer = null;
    selected = null;
    snapshot = null;
    auth = null;
    clients = [];
    sessions = [];
    environmentIssues = const [];
    messages = [];
    pending = [];
    pendingCreations = [];
    inbox = [];
    draftText = '';
    attachments = [];
    _draftReady = false;
    _draftFailed = false;
    _draftAccount = '';
    _draftRevision = 0;
    nextOffset = null;
    hasMoreHistory = false;
    _before = null;
    _historyEpoch = '';
    query = '';
    notice = null;
    error = null;
    fresh = false;
    loading = false;
    loadingHistory = false;
  }

  Future<void> backToSessions() async {
    if (busy) return;
    ++_selectionGeneration;
    await flushDraft();
    if (_draftFailed) {
      fresh = false;
      _notify();
      return;
    }
    await _stopWatch();
    _clearRecoveredReadError(_watchErrorRevision);
    _watchErrorRevision = null;
    _clearSnapshotNotice();
    selected = null;
    snapshot = null;
    fresh = false;
    _draftReady = false;
    messages = [];
    pending = [];
    _notify();
  }

  void _clearSnapshotNotice() {
    if (_snapshotNotice != null && notice == _snapshotNotice) notice = null;
    _snapshotNotice = null;
  }

  Future<void> _stopWatch() async {
    final id = _subscriptionId, pc = _subscriptionComputer;
    final watch = _watch;
    _watch = null;
    _subscriptionId = null;
    _subscriptionComputer = null;
    await Future.wait([
      if (id != null && pc != null) repository.cancelWatch(pc, id),
      if (watch != null) watch.cancel(),
    ]);
  }

  Future<void> setForeground(bool value) async {
    if (foreground == value) return;
    foreground = value;
    final lifecycle = ++_lifecycleGeneration;
    final generation = ++_connectionGeneration;
    ++_listGeneration;
    ++_selectionGeneration;
    if (!value) {
      await _connectionWatch?.cancel();
      _connectionWatch = null;
      fresh = false;
      loading = false;
      loadingHistory = false;
      _inboxTimer?.cancel();
      _notify();
      await Future.wait([flushDraft(), _stopWatch(), repository.pause()]);
      return;
    }
    final target = computer, session = selected;
    // Refresh foreground controls even when no gateway needs reconnecting.
    _notify();
    if (target == null || _returningHome) return;
    try {
      await _observeConnection(target);
      final status = await repository.connect(target);
      if (_disposed ||
          lifecycle != _lifecycleGeneration ||
          generation != _connectionGeneration ||
          !foreground) {
        return;
      }
      auth = status;
      if (!authenticated) {
        fresh = false;
        _notify();
        return;
      }
      await _loadConnected(generation);
      if (_disposed ||
          lifecycle != _lifecycleGeneration ||
          generation != _connectionGeneration ||
          !foreground) {
        return;
      }
      if (session != null && !busy) await openSession(session);
      await _resolveNotification();
    } catch (value) {
      if (generation == _connectionGeneration) {
        fresh = false;
        error = value;
        _connectionReadErrorRevision = _errorRevision;
        _notify();
      }
    }
  }
}
