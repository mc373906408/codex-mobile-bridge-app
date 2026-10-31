part of 'bridge_repository.dart';

mixin _NativeConnections on _NativeBridgeState {
  @override
  Future<native.BridgeClient> _open(Computer computer) async {
    if (_closed ||
        _removing.contains(computer.id) ||
        _blocked.contains(computer.id)) {
      throw StateError('Connection is closed');
    }
    if (_clients[computer.id] case final client?) return client;
    if (_opening[computer.id] case final opening?) return opening;
    final opening = _openOnce(computer);
    _opening[computer.id] = opening;
    try {
      return await opening;
    } finally {
      if (identical(_opening[computer.id], opening)) {
        _opening.remove(computer.id);
      }
    }
  }

  Future<native.BridgeClient> _openOnce(Computer computer) async {
    final generation = _clientGenerations[computer.id] ?? 0;
    final relay = computer.relay;
    if (relay != null &&
        !await cloudAccounts.enabled(relay.origin, relay.accountId)) {
      throw StateError('Sign in to this cloud server again');
    }
    final credentials = await _secure.read(key: _credentialKey(computer.id));
    final client = await native.BridgeClient.open(
      computer: computer,
      databasePath: _databasePath,
      platform: Platform.isIOS ? 'iOS' : 'Android',
      credentials: credentials,
    );
    if (_closed ||
        _removing.contains(computer.id) ||
        _blocked.contains(computer.id) ||
        generation != (_clientGenerations[computer.id] ?? 0)) {
      await client.pause();
      throw StateError('Connection is closed');
    }
    _clients[computer.id] = client;
    _saved[computer.id] = credentials;
    return client;
  }

  @override
  Future<void> _saveCredentials(String id) {
    final previous = _credentialWrites[id] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      final client = _clients[id];
      if (client == null || _removing.contains(id) || _blocked.contains(id)) {
        return;
      }
      // Read inside the queue, never persist a credential snapshot captured before a logout.
      final value = await client.credentials();
      if (_saved[id] == value) return;
      if (value == null) {
        await _secure.delete(key: _credentialKey(id));
      } else {
        await _secure.write(key: _credentialKey(id), value: value);
      }
      _saved[id] = value;
      _storageWarning = null;
    });
    _credentialWrites[id] = next;
    return next;
  }

  @override
  Future<T> _call<T>(
    String id,
    Future<T> Function(native.BridgeClient) work,
  ) async {
    if (_closed || _removing.contains(id) || _blocked.contains(id)) {
      throw StateError('Connection is closed');
    }
    T result;
    try {
      result = await work(_client(id));
    } catch (_) {
      try {
        await _saveCredentials(id);
      } catch (_) {
        _storageWarning = 'Secure credential storage is unavailable';
      }
      rethrow;
    }
    try {
      await _saveCredentials(id);
    } catch (_) {
      _storageWarning = 'Secure credential storage is unavailable; sign in again after restarting';
      // Do not turn an acknowledged submission into a retryable storage error.
      if (result is! OperationOutcome) rethrow;
    }
    return result;
  }

  @override
  Future<AuthStatus> connect(Computer computer) async {
    await _open(computer);
    final status = await _call(computer.id, (client) => client.authenticate());
    if (status.authenticated && computer.relay != null) {
      await _previewStorage.save(
        computer.id,
        await _client(computer.id).previewCredentials(),
      );
    }
    return status;
  }

  @override
  Future<void> removeComputer(Computer computer) async {
    final id = computer.id;
    _removing.add(id);
    try {
      try {
        await _opening[id];
      } catch (_) {
        /* A cancelled opening must not recreate credentials. */
      }
      final client = _clients[id];
      if (client != null) {
        await client.pause();
        try {
          await client.logout();
        } catch (_) {
          /* Local removal still succeeds offline. */
        }
      }
      try {
        await _credentialWrites[id];
      } catch (_) {
        /* Deletion is still attempted. */
      }
      await _secure.delete(key: _credentialKey(id));
      if (computer.relay != null) await _previewStorage.remove(id);
      await _database.removeComputer(id: id);
      _clients.remove(id);
      _saved.remove(id);
      _credentialWrites.remove(id);
      _blocked.remove(id);
    } finally {
      _removing.remove(id);
    }
  }
}
