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
  Future<PreparedRelay> prepareRelay(
    CloudAccountRef account,
    String invitation,
    String name,
  ) async {
    final result = await cloudAccounts.join(account, invitation, name);
    final computer = result.computer;
    // A pending pairing's identity and secrets are durable before proof or approval.
    await _secure.write(
      key: _credentialKey(computer.id),
      value: result.bindingCredentials,
    );
    await saveComputer(computer);
    return PreparedRelay(
      computer,
      result.mobileControlPublicKey,
      result.mobilePreviewPublicKey,
    );
  }

  @override
  Future<AuthStatus> confirmRelay(Computer computer, String invitation) async {
    await _open(computer);
    final status = await _call(
      computer.id,
      (client) => client.confirmRelay(invitation: invitation),
    );
    if (status.authenticated) {
      await _previewStorage.save(
        computer.id,
        await _client(computer.id).previewCredentials(),
      );
    }
    return status;
  }

  @override
  Future<bool> cloudEnabled(Computer computer) async {
    final relay = computer.relay;
    return !_closed &&
        !_blocked.contains(computer.id) &&
        !_removing.contains(computer.id) &&
        relay != null &&
        await cloudAccounts.enabled(relay.origin, relay.accountId);
  }

  @override
  Future<void> registerCloudPush(
    Computer computer,
    CloudPushState state,
  ) async {
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
