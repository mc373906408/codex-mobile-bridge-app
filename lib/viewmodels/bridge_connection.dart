part of 'bridge_view_model.dart';

extension BridgeConnection on BridgeViewModel {
  Future<void> _observeConnection(Computer target) async {
    await _connectionWatch?.cancel();
    _connectionWatch = null;
    if (target.relay == null || !foreground || _disposed) return;
    var interrupted = false;
    _connectionWatch = repository
        .connectionStates(target)
        .listen(
          (state) {
            if (_disposed || computer != target || !foreground) return;
            relayState = state;
            if (state != 'connected') fresh = false;
            if (const {
              'reconnecting',
              'gateway_offline',
              'capacity',
              'unavailable',
            }.contains(state)) {
              interrupted = true;
            }
            if (const {
              'login_required',
              'entitlement_required',
              'access_denied',
              'protocol_upgrade_required',
              'certificate',
            }.contains(state)) {
              auth = null;
              _inboxTimer?.cancel();
              unawaited(_stopWatch());
              error = 'Relay connection: $state';
              _connectionReadErrorRevision = _errorRevision;
            } else if (state == 'connected' &&
                interrupted &&
                !loading &&
                !busy) {
              interrupted = false;
              unawaited(_restoreRelayRead(target));
            }
            _notify();
          },
          onError: (Object value) {
            if (!_disposed && computer == target && foreground) {
              relayState = 'reconnecting';
              _notify();
            }
          },
        );
  }

  Future<void> _restoreRelayRead(Computer target) async {
    final generation = _connectionGeneration;
    final currentSession = selected;
    try {
      final status = await repository.connect(target);
      if (_disposed ||
          !foreground ||
          generation != _connectionGeneration ||
          computer != target) {
        return;
      }
      auth = status;
      if (!status.authenticated) return;
      await _loadConnected(generation);
      if (generation == _connectionGeneration &&
          foreground &&
          currentSession == selected &&
          currentSession != null) {
        await openSession(currentSession);
      }
    } catch (value) {
      if (generation == _connectionGeneration) {
        error = value;
        _connectionReadErrorRevision = _errorRevision;
        _notify();
      }
    }
  }

  Future<void> cloudAccessChanged(
    Computer value,
    bool allowed, {
    bool transientFailure = false,
  }) async {
    if (_disposed || computer?.id != value.id || value.relay == null) {
      return;
    }
    if (allowed) {
      if (_cloudRecoveryComputer != value ||
          _recoveringCloud ||
          busy ||
          loading ||
          !foreground ||
          _returningHome) {
        return;
      }
      if (authenticated) {
        _cloudRecoveryComputer = null;
        return;
      }
      final generation = _connectionGeneration;
      final selection = _selectionGeneration;
      final session = selected;
      bool current() =>
          !_disposed &&
          foreground &&
          !_returningHome &&
          computer == value &&
          _cloudRecoveryComputer == value &&
          generation == _connectionGeneration &&
          selection == _selectionGeneration;
      _recoveringCloud = true;
      loading = true;
      _notify();
      try {
        final status = await repository.connect(value);
        await _observeConnection(value);
        if (!current()) return;
        auth = status;
        if (!status.authenticated) return;
        await _loadConnected(generation);
        if (!current()) return;
        _cloudRecoveryComputer = null;
        if (session != null) await openSession(session);
      } catch (failure) {
        if (current() &&
            (error == null || _connectionReadErrorRevision == _errorRevision)) {
          error = failure;
          _connectionReadErrorRevision = _errorRevision;
        }
      } finally {
        _recoveringCloud = false;
        if (generation == _connectionGeneration) loading = false;
        _notify();
      }
      return;
    }
    _cloudRecoveryComputer =
        transientFailure && (authenticated || _cloudRecoveryComputer == value)
        ? value
        : null;
    fresh = false;
    auth = null;
    loading = false;
    ++_connectionGeneration;
    ++_selectionGeneration;
    ++_listGeneration;
    _inboxTimer?.cancel();
    _searchTimer?.cancel();
    _notify();
    await _stopWatch();
  }

  Future<T> cloudOperation<T>(
    String origin,
    Future<T> Function() work, {
    bool changesAccount = false,
  }) async {
    if (_disposed || !initialized || busy || loading || !foreground) {
      throw StateError(
        'Wait until the app is ready before changing cloud state',
      );
    }
    busy = true;
    final affected = changesAccount && computer?.relay?.origin == origin;
    final previousAuth = auth;
    if (affected) {
      _returningHome = true;
      fresh = false;
      auth = null;
      ++_connectionGeneration;
      ++_selectionGeneration;
      ++_listGeneration;
      _inboxTimer?.cancel();
      _searchTimer?.cancel();
    }
    _notify();
    try {
      if (affected) {
        try {
          await Future.wait([flushDraft(), _stopWatch()]);
          if (_draftFailed) {
            throw StateError(
              'Save the current draft before changing cloud accounts',
            );
          }
        } catch (_) {
          // No account mutation happened: keep the unsaved editor, but not live controls.
          if (!_disposed) auth = previousAuth;
          rethrow;
        }
        if (!_disposed) _clearConnectionState();
      }
      if (_disposed || !foreground) {
        throw StateError('Keep the app in the foreground for this operation');
      }
      return await work();
    } finally {
      _returningHome = false;
      busy = false;
      _notify();
    }
  }
}
