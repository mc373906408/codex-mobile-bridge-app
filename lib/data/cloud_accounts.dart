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
  Future<String> invitationOrigin(String invitation);
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
  Future<RelayEnrollment> join(String invitation, String raw, String name);
}

class NativeCloudApi implements CloudApi {
  @override
  String canonicalOrigin(String origin) => native.cloudOrigin(origin: origin);
  @override
  Future<String> invitationOrigin(String invitation) =>
      native.relayInvitationOrigin(value: invitation);
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
  Future<RelayEnrollment> join(String invitation, String raw, String name) =>
      native.joinRelay(invitation: invitation, credentials: raw, name: name);
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
    String invitation,
    String name,
  );
  Future<AuthStatus> confirmRelay(Computer computer, String invitation);
}

/// The queue includes durable writes and network calls, not just token lookup.
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

  Future<RelayEnrollment> join(
    CloudAccountRef account,
    String invitation,
    String name,
  ) => _run(() async {
    // The QR cannot select a credential store or change the server selection.
    if (await api.invitationOrigin(invitation) != account.origin) {
      throw StateError('The QR belongs to a different cloud server');
    }
    final current = await _current(account);
    final credentials = await _credentials(current);
    final result = await api.join(invitation, credentials, name);
    final connection = result.computer.relay;
    if (connection == null ||
        connection.origin != current.origin ||
        connection.accountId != current.accountId) {
      throw StateError('Cloud pairing response is invalid');
    }
    await vault.write(credentialKey(current), result.accountCredentials);
    if (result.accountCredentials != credentials) {
      await onCredentialsChanged?.call(current, result.accountCredentials);
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
