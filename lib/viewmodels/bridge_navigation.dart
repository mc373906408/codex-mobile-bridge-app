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
    final generation = ++_selectionGeneration;
    final watch = _takeWatch();
    await Future.wait([flushDraft(), _stopWatch(watch)]);
    if (_disposed || generation != _selectionGeneration) return;
    if (_draftFailed) {
      fresh = false;
      _notify();
      return;
    }
    _clearRecoveredReadError(_watchErrorRevision);
    _watchErrorRevision = null;
    _clearSnapshotNotice();
    selected = null;
    snapshot = null;
    _chatPreview = null;
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

  _SessionWatch _takeWatch() {
    final watch = (
      subscription: _watch,
      id: _subscriptionId,
      computerId: _subscriptionComputer,
    );
    _watch = null;
    _subscriptionId = null;
    _subscriptionComputer = null;
    return watch;
  }

  Future<void> _stopWatch([_SessionWatch? target]) async {
    final watch = target ?? _takeWatch();
    await Future.wait([
      if (watch.id != null && watch.computerId != null)
        repository.cancelWatch(watch.computerId!, watch.id!),
      if (watch.subscription != null) watch.subscription!.cancel(),
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
