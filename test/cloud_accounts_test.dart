import 'dart:convert';

import 'package:bridge_mobile/data/cloud_accounts.dart';
import 'package:bridge_mobile/data/bridge_types.dart';
import 'package:flutter_test/flutter_test.dart';

const accountId = '00000000-0000-4000-8000-000000000001';

class Vault implements CloudVault {
  final values = <String, String>{};
  final log = <String>[];
  bool failConsumedWrite = false;
  @override
  Future<String?> read(String key) async {
    log.add('read:$key');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failConsumedWrite && value.contains('"request_id"')) {
      throw StateError('storage unavailable');
    }
    log.add('write:$key');
    values[key] = value;
  }
}

class Api implements CloudApi {
  final log = <String>[];
  final savedLogins = <String?>[];
  bool failRefresh = false, failLogout = false;
  int rotations = 0, joins = 0;
  final refreshAttempts = <String>[];
  final pairingAttempts = <String?>[];
  void Function()? beforeRefresh, beforeLogout;

  String credentials(
    String origin, {
    bool expired = false,
    String refresh = 'refresh',
  }) => jsonEncode({
    'origin': origin,
    'account': accountId,
    'login': 'user',
    'expired': expired,
    'refresh': refresh,
    'device': 'device-token',
  });
  @override
  String canonicalOrigin(String origin) {
    if (!RegExp(r'^https://[a-z0-9.-]+(?::[1-9][0-9]*)?$').hasMatch(origin) ||
        origin.endsWith(':443')) {
      throw StateError('invalid origin');
    }
    return origin;
  }

  @override
  Future<CloudCapabilities> capabilities(String origin) async =>
      CloudCapabilities(
        mode: 'selfhost',
        login: 'username',
        registration: false,
        entitlementRequired: false,
        umeng: false,
        apns: false,
        umengAppId: '',
        apnsAppId: '',
      );
  @override
  Future<CloudLogin> login(
    String origin,
    String login,
    String password,
    String? saved,
  ) async {
    log.add('login:$origin');
    savedLogins.add(saved);
    return CloudLogin(
      accountId: accountId,
      login: 'user',
      credentials: credentials(origin),
    );
  }

  @override
  Future<CloudCredentialState> credentialState(
    String raw,
    String origin,
    String accountId,
  ) async {
    final value = jsonDecode(raw) as Map<String, dynamic>;
    if (value['origin'] != origin || value['account'] != accountId) {
      throw StateError('cross-account credentials');
    }
    String? consumed;
    if (value['expired'] == true) {
      if (value['refresh'] == '') throw StateError('refresh was already spent');
      consumed = jsonEncode({
        ...value,
        'request_id': value['request_id'] ?? 'stable-test-attempt',
      });
    }
    return CloudCredentialState(
      origin: origin,
      accountId: accountId,
      login: 'user',
      consumedCredentials: consumed,
    );
  }

  @override
  Future<String> refresh(String raw, String origin, String accountId) async {
    rotations++;
    final value = jsonDecode(raw) as Map<String, dynamic>;
    if (value['request_id'] == null || value['refresh'] == '') {
      throw StateError('refresh attempt was not persisted');
    }
    refreshAttempts.add(value['request_id'] as String);
    log.add('refresh:$origin');
    beforeRefresh?.call();
    if (failRefresh) throw StateError('lost response');
    return credentials(origin, refresh: 'next-refresh');
  }

  @override
  Future<String> signedOut(String raw, String origin, String accountId) async =>
      credentials(origin, expired: true, refresh: '');

  @override
  Future<CloudDiscoveredDevice> requestPairing(
    String raw,
    CloudAccountRef account,
    CloudGateway gateway,
    String? replace,
  ) async {
    pairingAttempts.add(replace);
    return CloudDiscoveredDevice(
      gateway: gateway,
      bindingId: 'pending',
      status: CloudDeviceStatus.pending,
      accessRevision: 0,
      accessAllowed: false,
    );
  }

  @override
  Future<void> logout(String raw, String origin, String accountId) async {
    beforeLogout?.call();
    log.add('logout:$origin');
    if (failLogout) throw StateError('offline');
  }

  @override
  Future<CloudEntitlement> entitlement(
    String raw,
    String origin,
    String accountId,
  ) async {
    log.add('entitlement:$origin');
    return const CloudEntitlement(
      active: true,
      required_: false,
      expiresAt: null,
    );
  }

  @override
  Future<List<CloudDiscoveredDevice>> devices(
    String raw,
    String origin,
    String accountId,
  ) async => [];
  @override
  Future<void> cancelDeviceReads() async {}
  @override
  Future<RelayEnrollment> prepareDiscovered(
    CloudDiscoveredDevice device,
    String raw,
    String deviceName,
  ) async {
    joins++;
    return RelayEnrollment(
      computer: Computer(
        id: device.bindingId,
        name: device.gateway.name,
        baseUrl: device.gateway.origin,
        connectionType: ConnectionType.relay,
        relay: RelayConnection(
          origin: device.gateway.origin,
          accountId: accountId,
          gatewayId: device.gateway.id,
          bindingId: device.bindingId,
          desktopPublicKey: device.gateway.controlPublicKey,
        ),
      ),
      accountCredentials: raw,
      bindingCredentials: 'opaque-binding',
      mobileControlPublicKey: 'control-public',
      mobilePreviewPublicKey: 'preview-public',
    );
  }
}

void main() {
  late Vault vault;
  late Api api;
  late CloudAccountManager manager;
  setUp(() {
    vault = Vault();
    api = Api();
    manager = CloudAccountManager(vault: vault, api: api);
  });

  test(
    'same login on different exact origins never shares saved credentials',
    () async {
      final official = await manager.signIn(
        'https://official.test',
        'user',
        'password',
      );
      final selfhost = await manager.signIn(
        'https://selfhost.test',
        'user',
        'password',
      );
      expect(
        manager.credentialKey(official),
        isNot(manager.credentialKey(selfhost)),
      );
      expect(api.savedLogins, [null, null]);
      expect((await manager.accounts()).length, 2);
      expect(
        () => manager.canonicalOrigin('https://OFFICIAL.test'),
        throwsStateError,
      );
      expect(
        () => manager.canonicalOrigin('https://official.test/'),
        throwsStateError,
      );
    },
  );

  test('refresh attempt is durable before network and concurrent callers rotate once', () async {
    final account = await manager.signIn(
      'https://official.test',
      'user',
      'password',
    );
    vault.values[manager.credentialKey(account)] = api.credentials(
      account.origin,
      expired: true,
    );
    api.beforeRefresh = () => expect(
      jsonDecode(vault.values[manager.credentialKey(account)]!)['request_id'],
      'stable-test-attempt',
    );
    await Future.wait([
      manager.entitlement(account),
      manager.entitlement(account),
    ]);
    expect(api.rotations, 1);
  });

  test(
    'a replacement request keeps the account and unrelated bindings active',
    () async {
      var fenced = 0;
      manager = CloudAccountManager(
        vault: vault,
        api: api,
        onDisabled: (_) async {
          fenced++;
        },
      );
      final account = await manager.signIn(
        'https://official.test',
        'user',
        'password',
      );
      final key = manager.credentialKey(account);
      final credentials = vault.values[key];
      final pending = await manager.requestPairing(
        account,
        CloudGateway(
          id: 'one-computer',
          name: 'Desktop',
          origin: account.origin,
          controlPublicKey: 'public-key',
          online: true,
        ),
        replace: 'old-binding',
      );
      expect(pending.status, CloudDeviceStatus.pending);
      expect(api.pairingAttempts, ['old-binding']);
      expect(fenced, 0);
      expect((await manager.accounts()).single.enabled, true);
      expect(vault.values[key], credentials);
    },
  );

  test(
    'a new manager restores the same rotation after a lost refresh response',
    () async {
      final account = await manager.signIn(
        'https://official.test',
        'user',
        'password',
      );
      vault.values[manager.credentialKey(account)] = api.credentials(
        account.origin,
        expired: true,
      );
      api.failRefresh = true;
      await expectLater(manager.entitlement(account), throwsStateError);
      api.failRefresh = false;
      manager = CloudAccountManager(vault: vault, api: api);
      await manager.entitlement(account);
      expect(api.rotations, 2);
      expect(api.refreshAttempts, [
        'stable-test-attempt',
        'stable-test-attempt',
      ]);
      expect(
        jsonDecode(vault.values[manager.credentialKey(account)]!)['refresh'],
        'next-refresh',
      );
    },
  );

  test(
    'failed durable consumed-token write prevents all refresh networking',
    () async {
      final account = await manager.signIn(
        'https://official.test',
        'user',
        'password',
      );
      vault.values[manager.credentialKey(account)] = api.credentials(
        account.origin,
        expired: true,
      );
      vault.failConsumedWrite = true;
      await expectLater(manager.entitlement(account), throwsStateError);
      expect(api.rotations, 0);
    },
  );

  test(
    'a computer from a different origin is rejected before any credential read',
    () async {
      final account = await manager.signIn(
        'https://official.test',
        'user',
        'password',
      );
      vault.log.clear();
      await expectLater(
        manager.prepareDiscovered(
          account,
          CloudDiscoveredDevice(
            gateway: CloudGateway(
              origin: 'https://selfhost.test',
              id: 'gateway',
              name: 'computer',
              controlPublicKey: 'public',
              online: true,
            ),
            bindingId: 'binding',
            status: CloudDeviceStatus.pending,
            accessRevision: 0,
          ),
          'phone',
        ),
        throwsStateError,
      );
      expect(vault.log, isEmpty);
      expect(api.joins, 0);
    },
  );

  test(
    'offline logout disables the account and preview before cloud networking',
    () async {
      var disabled = false;
      manager = CloudAccountManager(
        vault: vault,
        api: api,
        onDisabled: (_) async {
          disabled = true;
        },
      );
      final account = await manager.signIn(
        'https://official.test',
        'user',
        'password',
      );
      api.failLogout = true;
      api.beforeLogout = () {
        expect(disabled, isTrue);
        expect(
          jsonDecode(vault.values[manager.credentialKey(account)]!)['refresh'],
          '',
        );
        expect(
          (jsonDecode(
            vault.values['bridge.cloud.accounts.v1']!,
          ) as List).single['enabled'],
          false,
        );
      };
      await expectLater(manager.signOut(account), throwsStateError);
      expect(await manager.enabled(account.origin, account.accountId), false);
    },
  );

  test(
    're-login suspends old bindings before rotating an installation',
    () async {
      final order = <String>[];
      manager = CloudAccountManager(
        vault: vault,
        api: api,
        onDisabled: (_) async {
          order.add('disabled');
        },
        onCredentialsChanged: (_, _) async {
          order.add('updated');
        },
      );
      await manager.signIn('https://official.test', 'user', 'password');
      order.clear();
      await manager.signIn('https://official.test', 'USER', 'password');
      expect(order, ['disabled', 'updated']);
      expect(api.savedLogins.last, isNotNull);
    },
  );

  test('partial binding-token persistence leaves account disabled', () async {
    manager = CloudAccountManager(
      vault: vault,
      api: api,
      onCredentialsChanged: (_, _) async {
        throw StateError('vault failed');
      },
    );
    await expectLater(
      manager.signIn('https://official.test', 'user', 'password'),
      throwsStateError,
    );
    expect((await manager.accounts()).single.enabled, false);
  });
}
