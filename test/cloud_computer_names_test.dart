import 'dart:async';

import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:bridge_mobile/viewmodels/cloud_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';

CloudDiscoveredDevice device(
  String id, {
  String name = 'Desktop',
  String key = 'desktop-key',
  bool online = true,
  CloudDeviceStatus status = CloudDeviceStatus.active,
  int revision = 1,
}) => CloudDiscoveredDevice(
  bindingId: id,
  gateway: CloudGateway(
    origin: officialCloudOrigin,
    id: 'gateway-$id',
    name: name,
    controlPublicKey: key,
    online: online,
  ),
  status: status,
  accessRevision: revision,
);

AuthStatus named(String name) => AuthStatus(
  authenticated: true,
  computerName: name,
  platform: 'test',
  passwordless: false,
  notifications: false,
  transport: 'poll',
);

Future<void> settleNames() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeCloudRepository repository;
  late BridgeViewModel bridge;
  late CloudViewModel cloud;

  setUp(() async {
    repository = FakeCloudRepository()
      ..savedComputers = []
      ..pairingStatus = 'active';
    bridge = BridgeViewModel(repository);
    await bridge.initialize();
    await repository.cloudAccounts.signIn(
      officialCloudOrigin,
      'user@example.com',
      'password',
    );
    cloud = CloudViewModel(accounts: repository.cloudAccounts, bridge: bridge);
  });

  tearDown(() {
    cloud.dispose();
    bridge.dispose();
  });

  test('two legacy Desktop cards use their own authenticated system names and survive restart', () async {
    repository.api.onDevices = (_, _) async => [
      device('mac'),
      device('windows'),
    ];
    repository.onConnect = (computer) async =>
        named(computer.id == 'mac' ? 'Studio-Mac.local' : 'OFFICE-PC');
    await cloud.initialize();
    await settleNames();
    final computers = [...bridge.computers];
    expect(computers.map((c) => c.name), ['Desktop', 'Desktop']);
    expect(computers.map(bridge.computerName), [
      'Studio-Mac.local',
      'OFFICE-PC',
    ]);
    expect(repository.connects, 2);
    expect(bridge.computer, isNull);
    expect(repository.sends + repository.creates + repository.stops, 0);
    await cloud.syncDevices();
    await settleNames();
    expect(repository.connects, 2);
    expect(repository.savedComputers, computers);
    expect(repository.api.discoveryPreparations, 2);

    final restarted = BridgeViewModel(repository);
    await restarted.initialize();
    expect(restarted.computers.map(restarted.computerName), [
      'Studio-Mac.local',
      'OFFICE-PC',
    ]);
    restarted.dispose();
  });

  test('directory name changes update old objects while local aliases stay authoritative', () async {
    var name = 'Desktop';
    repository.api.onDevices = (_, _) async => [device('mac', name: name)];
    repository.onConnect = (_) async => named('Studio-Mac.local');
    await cloud.initialize();
    await settleNames();
    final original = bridge.computers.single;
    bridge.computer = original;
    bridge.draftText = 'Keep the unfinished draft';
    final generation = bridge.connectionGeneration;
    name = 'Renamed-Mac';
    await cloud.syncDevices();
    expect(bridge.computerName(original), name);
    expect(bridge.computer, same(original));
    expect(bridge.connectionGeneration, generation);
    expect(bridge.draftText, 'Keep the unfinished draft');
    await bridge.renameComputer(original, 'My office');
    name = 'Another remote name';
    await cloud.syncDevices();
    expect(bridge.computerName(original), 'My office');
    expect(original.name, 'Desktop');
    expect(repository.connects, 1);
  });

  test(
    'pending, denied and offline devices never cause authenticated name reads',
    () async {
      repository.api.onDevices = (_, _) async => [
        device('pending', status: CloudDeviceStatus.pending),
        device('disabled', status: CloudDeviceStatus.disabled),
        device('offline', online: false),
      ];
      await cloud.initialize();
      await settleNames();
      expect(repository.connects, 0);
    },
  );

  test(
    'a failed optional lookup keeps directory access and draft intact',
    () async {
      repository.api.onDevices = (_, _) async => [device('mac')];
      repository.onConnect = (_) async => throw StateError('Network error');
      bridge.draftText = 'Keep this draft';
      await cloud.initialize();
      await settleNames();
      expect(cloud.discoveryError, isNull);
      expect(cloud.canConnect(bridge.computers.single), isTrue);
      expect(bridge.computerName(bridge.computers.single), 'Desktop');
      expect(bridge.draftText, 'Keep this draft');
    },
  );

  for (final change in ['logout', 'revoked', 'key-changed', 'background']) {
    test('late system name is discarded after $change', () async {
      final reply = Completer<AuthStatus>();
      var current = device('mac');
      repository.api.onDevices = (_, _) async => [current];
      repository.onConnect = (_) => reply.future;
      await cloud.initialize();
      final original = bridge.computers.single;
      await cloud.syncDevices();
      expect(repository.connects, 1);
      switch (change) {
        case 'logout':
          await cloud.signOut();
        case 'revoked':
          current = device(
            'mac',
            status: CloudDeviceStatus.revoked,
            revision: 2,
          );
          await cloud.syncDevices();
        case 'key-changed':
          current = device('mac', key: 'different-key', revision: 2);
          await cloud.syncDevices();
        case 'background':
          cloud.setForeground(false);
      }
      reply.complete(named('Must not be cached'));
      await settleNames();
      expect(bridge.computerName(original), 'Desktop');
      expect(bridge.presentation['discoveredComputerNames'], isNull);
    });
  }

  test('a manual alias entered during lookup wins over the response', () async {
    final reply = Completer<AuthStatus>();
    repository.api.onDevices = (_, _) async => [device('mac')];
    repository.onConnect = (_) => reply.future;
    await cloud.initialize();
    final original = bridge.computers.single;
    await bridge.renameComputer(original, 'Personal Mac');
    reply.complete(named('Actual-Mac.local'));
    await settleNames();
    expect(bridge.computerName(original), 'Personal Mac');
  });

  test('automatic names remain scoped to account and desktop key', () async {
    final first = cloudComputer();
    bridge.rememberDiscoveredComputerName(first, 'Actual host');
    final otherAccount = cloudComputer(accountId: alternateCloudAccountId);
    expect(bridge.computerName(first), 'Actual host');
    expect(bridge.computerName(otherAccount), otherAccount.name);
    bridge.rememberDiscoveredComputerName(first, '\n');
    bridge.rememberDiscoveredComputerName(first, 'invalid\nname');
    expect(bridge.computerName(first), 'Actual host');
  });
}
