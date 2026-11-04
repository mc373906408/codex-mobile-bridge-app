part of 'bridge_repository.dart';

mixin _NativeCloud on _NativeBridgeState {
  Future<List<Computer>> _accountBindings(CloudAccountRef account) async =>
      (await computers())
          .where(
            (value) =>
                value.relay?.origin == account.origin &&
                value.relay?.accountId == account.accountId,
          )
          .toList();

  Future<void> _suspendCloudBinding(Computer computer) async {
    final id = computer.id;
    _blocked.add(id);
    _cloudAllowed.remove(id);
    _clientGenerations[id] = (_clientGenerations[id] ?? 0) + 1;
    // An opening may be waiting for the account queue that invoked this hook.
    // Invalidate its generation rather than deadlocking on that same queue.
    _opening.remove(id);
    final client = _clients.remove(id);
    await client?.pause();
    try {
      await _credentialWrites[id];
    } catch (_) {
      /* The rotation replaces this value. */
    }
    _saved.remove(id);
    _credentialWrites.remove(id);
  }

  @override
  Future<void> _disableCloudAccount(CloudAccountRef account) async {
    final bindings = await _accountBindings(account);
    Object? failure;
    StackTrace? trace;
    try {
      // Every cached/opening client is fenced before any native storage failure can stop cleanup.
      await Future.wait(bindings.map(_suspendCloudBinding));
    } catch (error, stack) {
      failure = error;
      trace = stack;
    }
    try {
      await Future.wait(
        bindings.map((computer) => _previewStorage.remove(computer.id)),
      );
    } catch (error, stack) {
      failure ??= error;
      trace ??= stack;
    }
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }

  @override
  Future<void> _rotateCloudBindings(
    CloudAccountRef account,
    String credentials,
  ) async {
    final bindings = await _accountBindings(account);
    await Future.wait(bindings.map(_suspendCloudBinding));
    for (final computer in bindings) {
      final raw = await _secure.read(key: _credentialKey(computer.id));
      if (raw == null) {
        throw StateError('Saved cloud binding credentials are unavailable');
      }
      final updated = await cloud_native.cloudBindingCredentials(
        binding: raw,
        account: credentials,
      );
      await _secure.write(key: _credentialKey(computer.id), value: updated);
    }
    for (final computer in bindings) {
      _blocked.remove(computer.id);
    }
  }

  @override
  Future<RelayPairingState> relayPairingState(Computer computer) async {
    final relay = computer.relay;
    if (relay == null ||
        !await cloudAccounts.enabled(relay.origin, relay.accountId)) {
      throw StateError('Sign in to this cloud server again');
    }
    final generation = _clientGenerations[computer.id] ?? 0;
    // Only the proof/status API may use a blocked client. Business calls remain blocked.
    final client = await _open(computer, verificationOnly: true);
    final state = await client.relayPairingState();
    if (_closed ||
        generation != (_clientGenerations[computer.id] ?? 0) ||
        !identical(_clients[computer.id], client) ||
        !await cloudAccounts.enabled(relay.origin, relay.accountId)) {
      throw StateError('Operation cancelled');
    }
    await _saveCredentials(computer.id, verificationOnly: true);
    return state;
  }

  @override
  Future<Computer?> ensureDiscovered(
    CloudAccountRef account,
    CloudDiscoveredDevice device, {
    required bool Function() current,
  }) async {
    if (!current() || _closed) return null;
    final saved = await computers();
    if (!current()) return null;
    final existing = saved
        .where(
          (computer) =>
              computer.relay?.origin == account.origin &&
              computer.relay?.accountId == account.accountId &&
              computer.relay?.bindingId == device.bindingId,
        )
        .firstOrNull;
    if (existing != null) {
      if (existing.relay?.gatewayId != device.gateway.id ||
          existing.relay?.desktopPublicKey != device.gateway.controlPublicKey) {
        throw StateError(
          'Cloud device identity changed. Existing keys are kept',
        );
      }
      return existing;
    }
    if (device.status == CloudDeviceStatus.revoked) return null;
    if (saved.any((computer) => computer.id == device.bindingId)) {
      throw StateError('Cloud discovery response is invalid');
    }
    final result = await cloudAccounts.prepareDiscovered(
      account,
      device,
      Platform.isIOS
          ? 'iPhone'
          : Platform.isAndroid
          ? 'Android phone'
          : 'Phone',
    );
    if (!current() || _closed) return null;
    final computer = result.computer;
    await _secure.write(
      key: _credentialKey(computer.id),
      value: result.bindingCredentials,
    );
    if (!current() || _closed) {
      await _secure.delete(key: _credentialKey(computer.id));
      return null;
    }
    await saveComputer(computer);
    if (!current() || _closed) {
      await _database.removeComputer(id: computer.id);
      await _secure.delete(key: _credentialKey(computer.id));
      return null;
    }
    return computer;
  }

  @override
  Future<void> suspendRelay(Computer computer) async {
    await _suspendCloudBinding(computer);
    await _previewStorage.remove(computer.id);
  }

  @override
  Future<void> resumeRelay(Computer computer, bool allowed) async {
    final relay = computer.relay;
    final generation = _clientGenerations[computer.id] ?? 0;
    if (relay == null ||
        _closed ||
        !await cloudAccounts.enabled(relay.origin, relay.accountId)) {
      return;
    }
    if (generation != (_clientGenerations[computer.id] ?? 0)) return;
    if (allowed) {
      _blocked.remove(computer.id);
      final client = await _open(computer);
      if (_closed ||
          _blocked.contains(computer.id) ||
          generation != (_clientGenerations[computer.id] ?? 0) ||
          !identical(_clients[computer.id], client)) {
        return;
      }
      _cloudAllowed.add(computer.id);
      await _savePreview(computer, client);
    } else {
      _blocked.add(computer.id);
      if (_cloudAllowed.remove(computer.id)) {
        await _previewStorage.remove(computer.id);
      }
    }
  }

  @override
  Future<void> _savePreview(
    Computer computer,
    native.BridgeClient client,
  ) async {
    final generation = _clientGenerations[computer.id] ?? 0;
    try {
      await _previewStorage.save(
        computer.id,
        await client.previewCredentials(),
      );
      if (_closed ||
          _blocked.contains(computer.id) ||
          generation != (_clientGenerations[computer.id] ?? 0)) {
        await _previewStorage.remove(computer.id);
        return;
      }
      _previewFailures.remove(computer.id);
    } catch (_) {
      _previewFailures.add(computer.id);
    }
  }

  @override
  Future<bool> cloudAccountEnabled(Computer computer) async {
    final relay = computer.relay;
    return !_closed &&
        !_removing.contains(computer.id) &&
        relay != null &&
        await cloudAccounts.enabled(relay.origin, relay.accountId);
  }

  @override
  Future<void> cancelDiscovery() async {
    await Future.wait([
      cloudAccounts.cancelDeviceReads(),
      ..._clients.values.toList().map(
        (client) => client.cancelRelayDiscovery(),
      ),
    ]);
  }

  @override
  Future<String> savedRelaySafetyCode(Computer computer) async {
    final connection = computer.relay;
    final credentials = await _secure.read(key: _credentialKey(computer.id));
    if (connection == null || credentials == null) return '';
    return cloud_native.cloudRelaySafetyCode(
      connection: connection,
      credentials: credentials,
    );
  }

  @override
  Future<bool> cloudEnabled(Computer computer) async {
    final relay = computer.relay;
    return !_closed &&
        !_blocked.contains(computer.id) &&
        !_removing.contains(computer.id) &&
        _cloudAllowed.contains(computer.id) &&
        !_previewFailures.contains(computer.id) &&
        relay != null &&
        await cloudAccounts.enabled(relay.origin, relay.accountId);
  }

  @override
  Future<void> registerCloudPush(
    Computer computer,
    CloudPushState state,
  ) async {
    if (!state.enabled || !state.consent) {
      if (!await cloudAccountEnabled(computer)) {
        throw StateError('Cloud account is disabled');
      }
      final raw = await _secure.read(key: _credentialKey(computer.id));
      if (raw == null) {
        throw StateError('Saved cloud binding credentials are unavailable');
      }
      // Reducing notification authority never opens a business connection.
      await cloud_native.cloudWithdrawPush(
        connection: computer.relay!,
        credentials: raw,
      );
      return;
    }
    if (!await cloudEnabled(computer)) {
      throw StateError('Cloud account is disabled');
    }
    await _open(computer);
    await _call(
      computer.id,
      (client) => client.registerCloudPush(
        platform: state.platform,
        appId: state.appId,
        token: state.enabled ? state.token : '',
        enabled: state.enabled,
        consent: state.consent,
      ),
    );
  }

  @override
  Future<void> acknowledgeCloudPush(Computer computer, List<String> ids) async {
    if (!await cloudEnabled(computer)) {
      throw StateError('Cloud account is disabled');
    }
    await _open(computer);
    await _call(computer.id, (client) => client.acknowledgeCloudPush(ids: ids));
  }
}
