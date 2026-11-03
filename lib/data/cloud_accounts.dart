import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../src/rust/api/cloud.dart' as native;
import '../src/rust/api/types.dart';

class CloudAccountRef {
  const CloudAccountRef({
    required this.origin,
    required this.accountId,
    required this.login,
    required this.enabled,
  });
  final String origin;
  final String accountId;
  final String login;
  final bool enabled;

  String get scope => '$origin\u0000$accountId';
  CloudAccountRef withEnabled(bool value) => CloudAccountRef(
    origin: origin,
    accountId: accountId,
    login: login,
    enabled: value,
  );
  Map<String, Object> toJson() => {
    'origin': origin,
    'accountId': accountId,
    'login': login,
    'enabled': enabled,
  };
}

abstract interface class CloudVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureCloudVault implements CloudVault {
  SecureCloudVault(this.storage);
  final FlutterSecureStorage storage;
  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
}

abstract interface class CloudApi {
  String canonicalOrigin(String origin);
  Future<CloudCapabilities> capabilities(String origin);
  Future<CloudLogin> login(
    String origin,
    String login,
    String password,
    String? saved,
  );
  Future<CloudCredentialState> credentialState(
    String raw,
    String origin,
    String accountId,
  );
  Future<String> refresh(String raw, String origin, String accountId);
  Future<String> signedOut(String raw, String origin, String accountId);
  Future<void> logout(String raw, String origin, String accountId);
  Future<CloudEntitlement> entitlement(
    String raw,
    String origin,
    String accountId,
  );
  Future<List<CloudGateway>> gateways(
    String raw,
    String origin,
    String accountId,
  );
  Future<List<CloudDiscoveredDevice>> devices(
    String raw,
    String origin,
    String accountId,
  );
  Future<void> cancelDeviceReads();
  Future<RelayEnrollment> prepareDiscovered(
    CloudDiscoveredDevice device,
    String raw,
    String deviceName,
  );
  Future<RelayEnrollment> preparePairing(
    CloudGateway gateway,
    String raw,
    String name,
    String deviceName,
  );
}

class NativeCloudApi implements CloudApi {
  int _directoryEpoch = 0;
  final Set<native.CloudDiscoveryClient> _directoryClients = {};
  @override
  String canonicalOrigin(String origin) => native.cloudOrigin(origin: origin);
  @override
  Future<CloudCapabilities> capabilities(String origin) =>
      native.cloudCapabilities(origin: origin);
  @override
  Future<CloudLogin> login(
    String origin,
    String login,
    String password,
    String? saved,
  ) => native.cloudLogin(
    origin: origin,
    login: login,
    password: password,
    saved: saved,
  );
  @override
  Future<CloudCredentialState> credentialState(
    String raw,
    String origin,
    String accountId,
  ) => native.cloudCredentialState(
    credentials: raw,
    origin: origin,
    accountId: accountId,
  );
  @override
  Future<String> refresh(String raw, String origin, String accountId) => native
      .cloudRefresh(credentials: raw, origin: origin, accountId: accountId);
  @override
  Future<String> signedOut(String raw, String origin, String accountId) =>
      native.cloudSignedOutCredentials(
        credentials: raw,
        origin: origin,
        accountId: accountId,
      );
  @override
  Future<void> logout(String raw, String origin, String accountId) => native
      .cloudLogout(credentials: raw, origin: origin, accountId: accountId);
  @override
  Future<CloudEntitlement> entitlement(
    String raw,
    String origin,
    String accountId,
  ) => native.cloudEntitlement(
    credentials: raw,
    origin: origin,
    accountId: accountId,
  );
  @override
  Future<List<CloudGateway>> gateways(
    String raw,
    String origin,
    String accountId,
  ) => native.cloudGateways(
    credentials: raw,
    origin: origin,
    accountId: accountId,
  );
  @override
  Future<List<CloudDiscoveredDevice>> devices(
    String raw,
    String origin,
    String accountId,
  ) async {
    final epoch = _directoryEpoch;
    final client = await native.CloudDiscoveryClient.open(
      credentials: raw,
      origin: origin,
      accountId: accountId,
    );
    if (epoch != _directoryEpoch) {
      client.dispose();
      throw StateError('Operation cancelled');
    }
    _directoryClients.add(client);
    try {
      return await client.devices();
    } finally {
      _directoryClients.remove(client);
      client.dispose();
    }
  }

  @override
  Future<void> cancelDeviceReads() async {
    _directoryEpoch++;
    await Future.wait(
      _directoryClients.toList().map((client) => client.cancel()),
    );
  }

  @override
  Future<RelayEnrollment> prepareDiscovered(
    CloudDiscoveredDevice device,
    String raw,
    String deviceName,
  ) => native.prepareRelayDiscovery(
    device: device,
    credentials: raw,
    deviceName: deviceName,
  );
  @override
  Future<RelayEnrollment> preparePairing(
    CloudGateway gateway,
    String raw,
    String name,
    String deviceName,
  ) => native.prepareRelayPairing(
    gateway: gateway,
    credentials: raw,
    name: name,
    deviceName: deviceName,
  );
}

class PreparedRelay {
  const PreparedRelay(
    this.computer,
    this.mobileControlPublicKey,
    this.mobilePreviewPublicKey,
  );
  final Computer computer;
  final String mobileControlPublicKey;
  final String mobilePreviewPublicKey;
}

abstract interface class CloudRepository {
  CloudAccountManager get cloudAccounts;
  Future<PreparedRelay> prepareRelay(
    CloudAccountRef account,
    CloudGateway gateway,
    String name,
    String deviceName,
  );
  Future<RelayPairingState> requestRelay(Computer computer);
  Future<RelayPairingState> relayPairingState(Computer computer);
  Future<void> cancelRelay(Computer computer);
  Future<AuthStatus> confirmRelay(Computer computer);
  Future<Computer?> ensureDiscovered(
    CloudAccountRef account,
    CloudDiscoveredDevice device, {
    required bool Function() current,
  });
  Future<void> suspendRelay(Computer computer);
  Future<void> resumeRelay(Computer computer, bool allowed);
  Future<void> cancelDiscovery();
  Future<String> savedRelaySafetyCode(Computer computer);
}

/// Account writes and token rotation are serialized; directory GETs use scoped leases.
class CloudAccountManager {
  CloudAccountManager({
    required this.vault,
    required this.api,
    this.onDisabled,
    this.onCredentialsChanged,
  });
  final CloudVault vault;
  final CloudApi api;
  final Future<void> Function(CloudAccountRef)? onDisabled;
  final Future<void> Function(CloudAccountRef, String)? onCredentialsChanged;
  static const _indexKey = 'bridge.cloud.accounts.v1';
  Future<void> _tail = Future<void>.value();
  final Map<String, int> _epochs = {};
  int _directoryEpoch = 0;

  Future<T> _run<T>(Future<T> Function() work) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    try {
      return await work();
    } finally {
      done.complete();
    }
  }

  String canonicalOrigin(String origin) => api.canonicalOrigin(origin);
  Future<CloudCapabilities> capabilities(String origin) =>
      api.capabilities(canonicalOrigin(origin));

  String credentialKey(CloudAccountRef account) =>
      'bridge.cloud.credentials.v1.${base64Url.encode(utf8.encode(account.scope)).replaceAll('=', '')}';

  Future<List<CloudAccountRef>> _refs() async {
    final raw = await vault.read(_indexKey);
    if (raw == null) return [];
    if (raw.length > 65536) {
      throw StateError('Cloud account storage is invalid');
    }
    final value = jsonDecode(raw);
    if (value is! List || value.length > 32) {
      throw StateError('Cloud account storage is invalid');
    }
    final result = <CloudAccountRef>[];
    final scopes = <String>{};
    for (final item in value) {
      if (item is! Map ||
          item.length != 4 ||
          item['origin'] is! String ||
          item['accountId'] is! String ||
          item['login'] is! String ||
          item['enabled'] is! bool) {
        throw StateError('Cloud account storage is invalid');
      }
      final account = CloudAccountRef(
        origin: canonicalOrigin(item['origin'] as String),
        accountId: item['accountId'] as String,
        login: item['login'] as String,
        enabled: item['enabled'] as bool,
      );
      if (!RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ).hasMatch(account.accountId) ||
          account.login.isEmpty ||
          account.login.length > 320 ||
          !scopes.add(account.scope)) {
        throw StateError('Cloud account storage is invalid');
      }
      result.add(account);
    }
    return result;
  }

  Future<void> _saveRefs(List<CloudAccountRef> accounts) => vault.write(
    _indexKey,
    jsonEncode(accounts.map((value) => value.toJson()).toList()),
  );

  Future<List<CloudAccountRef>> accounts() => _run(_refs);

  Future<bool> enabled(String origin, String accountId) => _run(
    () async => (await _refs()).any(
      (value) =>
          value.origin == origin &&
          value.accountId == accountId &&
          value.enabled,
    ),
  );

  Future<CloudAccountRef> _current(CloudAccountRef requested) async {
    canonicalOrigin(requested.origin);
    final account = (await _refs())
        .where((value) => value.scope == requested.scope)
        .firstOrNull;
    if (account == null ||
        !account.enabled ||
        account.login != requested.login) {
      throw StateError('Sign in to this cloud server again');
    }
    return account;
  }

  Future<void> _disable(
    CloudAccountRef account,
    List<CloudAccountRef> accounts,
  ) async {
    _epochs[account.scope] = (_epochs[account.scope] ?? 0) + 1;
    await _saveRefs(
      accounts
          .map(
            (value) =>
                value.scope == account.scope ? value.withEnabled(false) : value,
          )
          .toList(),
    );
    await onDisabled?.call(account);
  }

  Future<CloudAccountRef> signIn(
    String origin,
    String login,
    String password,
  ) => _run(() async {
    origin = canonicalOrigin(origin);
    final refs = await _refs();
    final prior = refs
        .where(
          (value) =>
              value.origin == origin &&
              value.login.toLowerCase() == login.toLowerCase(),
        )
        .firstOrNull;
    final saved = prior == null ? null : await vault.read(credentialKey(prior));
    // Enrollment rotates an installation token. Close all old clients first;
    // a lost login response must not leave them appearing authenticated.
    if (prior != null) await _disable(prior, refs);
    final result = await api.login(origin, login, password, saved);
    final account = CloudAccountRef(
      origin: origin,
      accountId: result.accountId,
      login: result.login,
      enabled: false,
    );
    final state = await api.credentialState(
      result.credentials,
      origin,
      result.accountId,
    );
    if (state.login != result.login || state.consumedCredentials != null) {
      throw StateError('Cloud login response is invalid');
    }
    await vault.write(credentialKey(account), result.credentials);
    final current = (await _refs())
        .where((value) => value.scope != account.scope)
        .toList();
    if (current.length >= 32) throw StateError('Too many cloud accounts');
    await _saveRefs([...current, account]);
    await onCredentialsChanged?.call(account, result.credentials);
    final enabled = account.withEnabled(true);
    await _saveRefs([...current, enabled]);
    return enabled;
  });

  Future<String> _credentials(CloudAccountRef account) async {
    final raw = await vault.read(credentialKey(account));
    if (raw == null) throw StateError('Sign in to this cloud server again');
    final state = await api.credentialState(
      raw,
      account.origin,
      account.accountId,
    );
    if (state.login != account.login) {
      throw StateError('Cloud credential identity changed');
    }
    final consumed = state.consumedCredentials;
    if (consumed == null) return raw;
    // Persist the spent refresh token BEFORE sending it. A lost response
    // requires explicit login, never an automatic second rotation attempt.
    await vault.write(credentialKey(account), consumed);
    final refreshed = await api.refresh(raw, account.origin, account.accountId);
    await vault.write(credentialKey(account), refreshed);
    return refreshed;
  }

  Future<CloudEntitlement> entitlement(CloudAccountRef account) =>
      _run(() async {
        final current = await _current(account);
        return api.entitlement(
          await _credentials(current),
          current.origin,
          current.accountId,
        );
      });

  Future<List<CloudGateway>> gateways(CloudAccountRef account) =>
      _run(() async {
        final current = await _current(account);
        final result = await api.gateways(
          await _credentials(current),
          current.origin,
          current.accountId,
        );
        if (result.any((item) => item.origin != current.origin)) {
          throw StateError('Cloud computer list belongs to another server');
        }
        return result;
      });

  Future<List<CloudDiscoveredDevice>> devices(CloudAccountRef account) async {
    final epoch = _directoryEpoch;
    final lease = await _run(() async {
      final current = await _current(account);
      return (
        account: current,
        credentials: await _credentials(current),
        epoch: _epochs[current.scope] ?? 0,
      );
    });
    if (epoch != _directoryEpoch) throw StateError('Operation cancelled');
    // A slow directory read must not hold up local logout or account replacement.
    final result = await api.devices(
      lease.credentials,
      lease.account.origin,
      lease.account.accountId,
    );
    await _run(() async {
      await _current(lease.account);
      if ((_epochs[lease.account.scope] ?? 0) != lease.epoch) {
        throw StateError('Cloud credential identity changed');
      }
    });
    if (result.any((item) => item.gateway.origin != lease.account.origin)) {
      throw StateError('Cloud computer list belongs to another server');
    }
    return result;
  }

  Future<void> cancelDeviceReads() {
    _directoryEpoch++;
    return api.cancelDeviceReads();
  }

  Future<RelayEnrollment> prepareDiscovered(
    CloudAccountRef account,
    CloudDiscoveredDevice device,
    String deviceName,
  ) => _run(() async {
    if (device.gateway.origin != account.origin) {
      throw StateError('The computer belongs to a different cloud server');
    }
    final current = await _current(account);
    final credentials = await _credentials(current);
    final result = await api.prepareDiscovered(device, credentials, deviceName);
    final connection = result.computer.relay;
    if (connection == null ||
        connection.origin != current.origin ||
        connection.accountId != current.accountId ||
        connection.gatewayId != device.gateway.id ||
        connection.bindingId != device.bindingId ||
        connection.desktopPublicKey != device.gateway.controlPublicKey ||
        result.accountCredentials != credentials) {
      throw StateError('Cloud discovery response is invalid');
    }
    return result;
  });

  Future<RelayEnrollment> preparePairing(
    CloudAccountRef account,
    CloudGateway gateway,
    String name,
    String deviceName,
  ) => _run(() async {
    if (gateway.origin != account.origin) {
      throw StateError('The computer belongs to a different cloud server');
    }
    final current = await _current(account);
    final credentials = await _credentials(current);
    final result = await api.preparePairing(
      gateway,
      credentials,
      name,
      deviceName,
    );
    final connection = result.computer.relay;
    if (connection == null ||
        connection.origin != current.origin ||
        connection.accountId != current.accountId ||
        connection.gatewayId != gateway.id ||
        connection.desktopPublicKey != gateway.controlPublicKey) {
      throw StateError('Cloud pairing response is invalid');
    }
    if (result.accountCredentials != credentials) {
      throw StateError('Cloud pairing changed account credentials');
    }
    return result;
  });

  Future<void> signOut(CloudAccountRef account) => _run(() async {
    final refs = await _refs();
    final current = refs
        .where((value) => value.scope == account.scope)
        .firstOrNull;
    if (current == null) return;
    final raw = await vault.read(credentialKey(current));
    await _disable(current, refs);
    if (raw == null) return;
    final scrubbed = await api.signedOut(
      raw,
      current.origin,
      current.accountId,
    );
    await vault.write(credentialKey(current), scrubbed);
    await api.logout(raw, current.origin, current.accountId);
  });
}
