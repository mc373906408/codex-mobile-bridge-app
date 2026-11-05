import 'dart:async';

import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/src/rust/api/types.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:bridge_mobile/viewmodels/cloud_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';
import 'support/fake_repository.dart';

void main() {
  late FakeCloudRepository repository;
  late BridgeViewModel bridge;
  late CloudViewModel cloud;
  setUp(() async {
    repository = FakeCloudRepository();
    bridge = BridgeViewModel(repository);
    await bridge.initialize();
    cloud = CloudViewModel(accounts: repository.cloudAccounts, bridge: bridge);
  });
  tearDown(() {
    cloud.dispose();
    bridge.dispose();
  });

  test('new installs use the official exact origin without connecting or enrolling', () async {
    await Future.wait([cloud.initialize(), cloud.initialize()]);
    expect(cloud.origin, officialCloudOrigin);
    expect(cloud.origin, endsWith(':8787'));
    expect(cloud.signedIn, false);
    expect(cloud.serviceStatus, CloudServiceStatus.signedOut);
    expect(repository.api.capabilityOrigins, [officialCloudOrigin]);
    expect(repository.api.entitlements, 0);
    expect(repository.api.loginOrigins, isEmpty);
    expect(repository.connects, 0);
    expect(repository.vault.writes, isEmpty);
  });

  test(
    'existing single-account server and credentials are preserved',
    () async {
      final account = await repository.cloudAccounts.signIn(
        selfhostOrigin,
        'user',
        'password',
      );
      final key = repository.cloudAccounts.credentialKey(account);
      final raw = repository.vault.values[key];
      await cloud.initialize();
      expect(cloud.origin, selfhostOrigin);
      expect(cloud.account?.scope, account.scope);
      expect(cloud.serviceStatus, CloudServiceStatus.unknown);
      expect(repository.api.entitlements, 0);
      await cloud.refresh();
      expect(cloud.serviceStatus, CloudServiceStatus.selfHosted);
      expect(cloud.expiresAt, isNull);
      expect(repository.vault.values[key], raw);
      expect(bridge.computers, [computerA, computerB]);
      expect(repository.removedComputerIds, isEmpty);
    },
  );

  test('explicit HTTP selection retains its scheme and keeps HTTPS credentials separate', () async {
    await cloud.initialize();
    expect(
      cloud.canonicalInput(' http://relay.example:8787/ '),
      'http://relay.example:8787',
    );
    expect(await cloud.switchServer('http://relay.example:8787'), true);
    expect(cloud.origin, 'http://relay.example:8787');
    expect(await cloud.signIn('user', 'password'), true);
    final plain = cloud.account!;
    final secure = await repository.cloudAccounts.signIn(
      'https://relay.example:8787',
      'user',
      'password',
    );
    expect(plain.scope, isNot(secure.scope));
    expect(
      repository.cloudAccounts.credentialKey(plain),
      isNot(repository.cloudAccounts.credentialKey(secure)),
    );
    expect(repository.api.loginOrigins, [
      'http://relay.example:8787',
      'https://relay.example:8787',
    ]);

    expect(repository.connects, 0);
  });

  test(
    'qualification is explicitly queried and failures preserve display cache',
    () async {
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      await cloud.initialize();
      expect(repository.api.entitlements, 0);
      await cloud.refresh();
      expect(cloud.serviceStatus, CloudServiceStatus.active);
      expect(cloud.expiresAt, DateTime.utc(2030, 1, 2, 3, 4));
      repository.api.onEntitlement = (_) async => const CloudEntitlement(
        active: false,
        required_: true,
        expiresAt: '2020-01-02T03:04:00Z',
      );
      await cloud.refresh();
      expect(cloud.serviceStatus, CloudServiceStatus.unavailable);
      repository.api.onEntitlement = (_) async => throw StateError('offline');
      await cloud.refresh();
      expect(cloud.serviceStatus, CloudServiceStatus.unavailable);
      expect(cloud.entitlement, isNotNull);
      expect(cloud.entitlementError, isNotNull);
      expect(cloud.signedIn, true);
      repository.api.onEntitlement = (_) async => activeEntitlement;
      await cloud.refresh();
      expect(cloud.serviceStatus, CloudServiceStatus.active);
    },
  );

  test(
    'capability failure cannot be interpreted as active or expired service',
    () async {
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      await cloud.initialize();
      repository.api.onCapabilities = (_) async => throw StateError('offline');
      await cloud.refresh();
      expect(cloud.capabilities, isNotNull);
      expect(cloud.capabilityError, isNotNull);
      expect(cloud.serviceStatus, CloudServiceStatus.active);
    },
  );

  test(
    'login success is retained when entitlement fails, without auto pairing',
    () async {
      await cloud.initialize();
      repository.api.onEntitlement = (_) async => throw StateError('offline');
      expect(await cloud.signIn('user@example.com', 'password'), true);
      expect(cloud.signedIn, true);
      expect(cloud.serviceStatus, CloudServiceStatus.unknown);

      expect(repository.connects, 0);
    },
  );

  test('concurrent refreshes share one request and stale server results are ignored', () async {
    await cloud.initialize();
    final old = Completer<CloudCapabilities>();
    final started = Completer<void>();
    repository.api.onCapabilities = (origin) {
      if (origin == officialCloudOrigin) {
        started.complete();
        return old.future;
      }
      return Future.value(selfhostCapabilities);
    };
    final first = cloud.refresh();
    final second = cloud.refresh();
    await started.future;
    expect(repository.api.capabilityOrigins.length, 2);
    expect(await cloud.switchServer(' $selfhostOrigin/ '), true);
    expect(cloud.origin, selfhostOrigin);
    expect(cloud.capabilities?.mode, 'selfhost');
    old.complete(hostedCapabilities);
    await Future.wait([first, second]);
    expect(cloud.origin, selfhostOrigin);
    expect(cloud.capabilities?.mode, 'selfhost');
    expect(cloud.loading, false);
  });

  test(
    'server changes require sign-out and never choose other saved credentials',
    () async {
      final old = await repository.cloudAccounts.signIn(
        selfhostOrigin,
        'user',
        'password',
      );
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      await cloud.initialize();
      expect(cloud.origin, officialCloudOrigin);
      expect(await cloud.switchServer(selfhostOrigin), false);
      expect(repository.api.logoutOrigins, isEmpty);
      expect(await cloud.signOut(), true);
      expect(await cloud.switchServer(selfhostOrigin), true);
      expect(cloud.account, isNull);
      expect(
        await repository.cloudAccounts.enabled(old.origin, old.accountId),
        true,
      );
      final reloaded = CloudViewModel(
        accounts: repository.cloudAccounts,
        bridge: bridge,
      );
      await reloaded.initialize();
      expect(reloaded.origin, selfhostOrigin);
      expect(reloaded.account, isNull);
      reloaded.dispose();
      expect(repository.removedComputerIds, isEmpty);
    },
  );

  test(
    'only input whitespace and a single root slash are normalized',
    () async {
      await cloud.initialize();
      expect(
        cloud.canonicalInput('  $officialCloudOrigin/  '),
        officialCloudOrigin,
      );
      for (final value in [
        'ftp://private.example',
        'http://private.example:80',
        '$selfhostOrigin/path',
        '$selfhostOrigin//',
        '$selfhostOrigin/?a=1',
        '$selfhostOrigin/#fragment',
        'https://PRIVATE.example',
        'https://private.example:443',
        'https://user@private.example',
      ]) {
        expect(() => cloud.canonicalInput(value), throwsStateError);
      }
      expect(repository.api.capabilityOrigins, [officialCloudOrigin]);
    },
  );

  test(
    'offline logout clears cloud authentication but preserves computer data',
    () async {
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      final computer = cloudComputer();
      await repository.saveComputer(computer);
      await cloud.initialize();
      await bridge.selectComputer(computer);
      expect(bridge.authenticated, true);
      repository.api.onLogout = (_) async => throw StateError('offline');
      expect(await cloud.signOut(), false);
      expect(cloud.signedIn, false);
      expect(bridge.authenticated, false);
      expect(bridge.computer, isNull);
      expect(
        cloud.operationError.toString(),
        contains('Server logout could not be confirmed'),
      );
      expect(repository.savedComputers, contains(computer));
      expect(repository.removedComputerIds, isEmpty);
    },
  );

  test(
    'account rotation preserves the current cloud chat draft and clears auth',
    () async {
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      final computer = cloudComputer(id: computerA.id);
      await repository.saveComputer(computer);
      await cloud.initialize();
      await bridge.selectComputer(computer);
      await bridge.openSession(sessionA);
      bridge.editDraft('Keep the cloud draft');
      await cloud.signOut();
      expect(
        (await repository.draft(sessionA, 'account-a')).text,
        'Keep the cloud draft',
      );
      expect(bridge.authenticated, false);
      expect(bridge.selected, isNull);
    },
  );

  test(
    'cloud changes do not interrupt an unrelated local direct chat',
    () async {
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      await cloud.initialize();
      await bridge.selectComputer(computerA);
      await bridge.openSession(sessionA);
      bridge.editDraft('Local draft');
      expect(await cloud.signOut(), true);
      expect(bridge.computer, computerA);
      expect(bridge.authenticated, true);
      expect(bridge.selected, sessionA);
      expect(bridge.draftText, 'Local draft');
    },
  );

  test(
    'failed draft persistence keeps the editor and prevents account mutation',
    () async {
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      final computer = cloudComputer(id: computerA.id);
      await repository.saveComputer(computer);
      await cloud.initialize();
      await bridge.selectComputer(computer);
      await bridge.openSession(sessionA);
      bridge.editDraft('Unsaved cloud draft');
      repository.onSaveDraft = (_, _, _) async => throw StateError(
        'Local state could not be saved. Check the computer before retrying',
      );
      expect(await cloud.signOut(), false);
      expect(cloud.signedIn, true);
      expect(bridge.computer, computer);
      expect(bridge.selected, sessionA);
      expect(bridge.draftText, 'Unsaved cloud draft');
      expect(bridge.draftEditable, true);
      expect(bridge.fresh, false);
      expect(repository.api.logoutOrigins, isEmpty);
      expect(repository.disabledScopes, isEmpty);
    },
  );

  test('failed local disabling is visible, without leaving a stale authenticated view', () async {
    await repository.cloudAccounts.signIn(
      officialCloudOrigin,
      'user@example.com',
      'password',
    );
    final computer = cloudComputer();
    await repository.saveComputer(computer);
    await cloud.initialize();
    await bridge.selectComputer(computer);
    repository.vault.failWrite = (key) => key == 'bridge.cloud.accounts.v1';
    expect(await cloud.signOut(), false);
    expect(cloud.signedIn, true);
    expect(cloud.operationError, isNotNull);
    expect(bridge.authenticated, false);
    expect(repository.api.logoutOrigins, isEmpty);
  });

  test(
    'busy and background states block mutations without later replay',
    () async {
      await cloud.initialize();
      bridge.busy = true;
      expect(await cloud.signIn('user@example.com', 'password'), false);
      expect(await cloud.switchServer(selfhostOrigin), false);
      bridge.busy = false;
      await bridge.setForeground(false);
      cloud.setForeground(false);
      expect(await cloud.signIn('user@example.com', 'password'), false);
      expect(await cloud.switchServer(selfhostOrigin), false);
      await bridge.setForeground(true);
      cloud.setForeground(true);
      await cloud.refresh();
      expect(repository.api.loginOrigins, isEmpty);
      expect(cloud.origin, officialCloudOrigin);
    },
  );

  test(
    'corrupt server selection fails closed and can be reread after repair',
    () async {
      repository.vault.values['bridge.cloud.selection.v1'] = '{bad JSON';
      await cloud.initialize();
      expect(cloud.storageError, isNotNull);
      expect(cloud.account, isNull);
      expect(cloud.canManage, false);
      expect(repository.api.capabilityOrigins, isEmpty);
      repository.vault.values.remove('bridge.cloud.selection.v1');
      await cloud.refresh();
      expect(cloud.storageError, isNull);
      expect(cloud.canManage, true);
      expect(cloud.origin, officialCloudOrigin);
    },
  );

  test(
    'a different server computer never reads or forwards credentials',
    () async {
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      await cloud.initialize();
      repository.vault.reads.clear();
      await expectLater(
        repository.cloudAccounts.prepareDiscovered(
          cloud.account!,
          CloudDiscoveredDevice(
            gateway: cloudGateway(selfhostOrigin),
            bindingId: 'binding',
            status: CloudDeviceStatus.pending,
            accessRevision: 0,
          ),
          'Phone',
        ),
        throwsStateError,
      );

      expect(repository.vault.reads, isEmpty);
      expect(cloud.origin, officialCloudOrigin);
    },
  );
}
