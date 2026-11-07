import 'dart:async';

import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/data/bridge_types.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:bridge_mobile/viewmodels/cloud_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';
import 'support/fake_repository.dart';

CloudDiscoveredDevice discovered({
  String binding = '00000000-0000-4000-8000-000000000101',
  String gateway = '00000000-0000-4000-8000-000000000201',
  String origin = officialCloudOrigin,
  String name = 'Account desktop',
  String key = 'desktop-key',
  CloudDeviceStatus status = CloudDeviceStatus.pending,
  int revision = 0,
  bool online = true,
}) => CloudDiscoveredDevice(
  gateway: CloudGateway(
    origin: origin,
    id: gateway,
    name: name,
    controlPublicKey: key,
    online: online,
  ),
  bindingId: binding,
  status: status,
  accessRevision: revision,
);

void main() {
  late FakeCloudRepository repository;
  late BridgeViewModel bridge;
  late CloudViewModel cloud;
  setUp(() async {
    repository = FakeCloudRepository();
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

  test('restored login discovers all computers and saves keys without a request or chat', () async {
    repository.api.onDevices = (_, _) async => [
      discovered(),
      discovered(
        binding: 'second-binding',
        gateway: 'second-gateway',
        name: 'Offline desktop',
        online: false,
      ),
    ];
    await cloud.initialize();
    expect(cloud.devices.length, 2);
    expect(bridge.computers.length, 4);
    expect(repository.api.discoveryPreparations, 2);

    expect(repository.connects, 0);
    expect(bridge.computer, isNull);
    expect(cloud.devices.every((state) => !state.allowed), true);
    final ids = cloud.devices.map((state) => state.computer.id).toList();
    await cloud.syncDevices();
    expect(cloud.devices.map((state) => state.computer.id).toList(), ids);
    expect(repository.api.discoveryPreparations, 2);
  });

  test('desktop close and restore retain a single device and never need another phone action', () async {
    var status = CloudDeviceStatus.active;
    var revision = 1;
    repository.pairingStatus = 'active';
    repository.api.onDevices = (_, _) async => [
      discovered(status: status, revision: revision),
    ];
    await cloud.initialize();
    final computer = cloud.devices.single.computer;
    expect(cloud.canConnect(computer), true);
    bridge.computer = computer;
    bridge.auth = authenticatedStatus;
    bridge.fresh = true;
    bridge.draftText = 'Keep this unsaved draft';
    status = CloudDeviceStatus.disabled;
    revision++;
    await cloud.syncDevices();
    expect(cloud.canConnect(computer), false);
    expect(bridge.authenticated, false);
    expect(bridge.draftText, 'Keep this unsaved draft');
    expect(repository.suspendedRelays, contains(computer.id));
    expect(repository.removedComputerIds, isEmpty);
    status = CloudDeviceStatus.active;
    revision++;
    await cloud.syncDevices();
    expect(cloud.canConnect(computer), true);
    expect(cloud.devices.single.computer.id, computer.id);
    expect(repository.api.discoveryPreparations, 1);

    expect(repository.connects, 0);
    expect(bridge.authenticated, false);
  });

  test('discovery does not use the chat busy lock and concurrent reads never overlap', () async {
    final started = Completer<void>(),
        reply = Completer<List<CloudDiscoveredDevice>>();
    repository.api.onDevices = (_, _) {
      if (!started.isCompleted) started.complete();
      return reply.future;
    };
    bridge.busy = true;
    final initialization = cloud.initialize();
    await started.future;
    final first = cloud.syncDevices(), second = cloud.syncDevices();
    expect(repository.api.deviceReads, 1);
    reply.complete([discovered()]);
    await Future.wait([initialization, first, second]);
    expect(cloud.devices.length, 1);
    expect(bridge.busy, true);
    expect(repository.connects, 0);
    bridge.busy = false;
  });

  test('logout discards a late directory response before any keys or device are added', () async {
    final started = Completer<void>(),
        reply = Completer<List<CloudDiscoveredDevice>>();
    repository.api.onDevices = (_, _) {
      started.complete();
      return reply.future;
    };
    final initialization = cloud.initialize();
    await started.future;
    final logout = cloud.signOut();
    await logout.timeout(const Duration(seconds: 1));
    expect(cloud.signedIn, false);
    reply.complete([discovered()]);
    await initialization;
    expect(cloud.signedIn, false);
    expect(cloud.devices, isEmpty);
    expect(repository.api.discoveryPreparations, 0);
    expect(bridge.computers, [computerA, computerB]);
    expect(repository.discoveryCancellations, greaterThan(0));
  });

  test('background cancellation fences late local preparation and resume reads immediately', () async {
    final preparing = Completer<void>(), release = Completer<void>();
    repository.api.onDevices = (_, _) async => [discovered()];
    repository.onEnsureDiscovered = (_, _, current) async {
      preparing.complete();
      await release.future;
      expect(current(), false);
      return null;
    };
    final initialization = cloud.initialize();
    await preparing.future;
    cloud.setForeground(false);
    release.complete();
    await initialization;
    expect(repository.savedComputers, [computerA, computerB]);
    expect(repository.pairingChecks, 0);
    repository.onEnsureDiscovered = null;
    cloud.setForeground(true);
    await cloud.refresh();
    await cloud.syncDevices();
    expect(repository.api.deviceReads, greaterThan(1));
    expect(cloud.devices.length, 1);
  });

  test('directory key changes and stale permission revisions never replace saved identity', () async {
    var device = discovered(status: CloudDeviceStatus.active, revision: 5);
    repository.pairingStatus = 'active';
    repository.api.onDevices = (_, _) async => [device];
    await cloud.initialize();
    final computer = cloud.devices.single.computer;
    device = discovered(status: CloudDeviceStatus.disabled, revision: 6);
    await cloud.syncDevices();
    device = discovered(status: CloudDeviceStatus.active, revision: 5);
    await cloud.syncDevices();
    expect(cloud.devices.single.device.status, CloudDeviceStatus.disabled);
    device = discovered(
      status: CloudDeviceStatus.active,
      revision: 7,
      key: 'changed-desktop-key',
    );
    await cloud.syncDevices();
    expect(cloud.devices.single.error, isNotNull);
    expect(cloud.authorized(computer), false);
    expect(
      repository.savedComputers
          .where((item) => item.id == computer.id)
          .single
          .relay!
          .desktopPublicKey,
      'desktop-key',
    );
    expect(repository.api.discoveryPreparations, 1);
  });

  test(
    'other-server responses cannot create a device or forward credentials',
    () async {
      repository.api.onDevices = (_, _) async => [
        discovered(origin: selfhostOrigin),
      ];
      await cloud.initialize();
      expect(cloud.discoveryError, isNotNull);
      expect(cloud.devices, isEmpty);
      expect(repository.api.discoveryPreparations, 0);
    },
  );

  test(
    'expired service and revoked devices remain visible but cannot connect',
    () async {
      repository.api.onEntitlement = (_) async => const CloudEntitlement(
        active: false,
        required_: true,
        expiresAt: '2020-01-01T00:00:00Z',
      );
      repository.api.onDevices = (_, _) async => [
        discovered(status: CloudDeviceStatus.revoked, revision: 9),
      ];
      await cloud.initialize();
      expect(cloud.devices.length, 1);
      expect(cloud.canConnect(cloud.devices.single.computer), false);
      expect(repository.api.discoveryPreparations, 0);
      expect(repository.pairingChecks, 0);
      expect(repository.removedComputerIds, isEmpty);
    },
  );

  test('a server active flag cannot substitute for encrypted local desktop permission', () async {
    repository.api.onDevices = (_, _) async => [
      discovered(status: CloudDeviceStatus.active, revision: 1),
    ];
    repository.pairingStatus = 'pending';
    await cloud.initialize();
    final computer = cloud.devices.single.computer;
    expect(cloud.canConnect(computer), false);
    repository.api.onDevices = (_, _) async => [
      discovered(status: CloudDeviceStatus.active, revision: 1, online: false),
    ];
    await cloud.syncDevices();
    expect(cloud.authorized(computer), false);
    repository.api.onDevices = (_, _) async => [
      discovered(status: CloudDeviceStatus.active, revision: 1),
    ];
    await cloud.syncDevices();
    expect(cloud.canConnect(computer), false);
    repository.pairingStatus = 'active';
    await cloud.syncDevices();
    expect(cloud.canConnect(computer), true);
    expect(repository.api.discoveryPreparations, 1);

    expect(repository.connects, 0);
  });

  test('stable discovery reuses verified identity and an outage preserves the live chat', () async {
    repository.pairingStatus = 'active';
    repository.api.onDevices = (_, _) async => [
      discovered(status: CloudDeviceStatus.active, revision: 1),
    ];
    await cloud.initialize();
    final computer = cloud.devices.single.computer;
    final proofs = repository.pairingChecks;
    bridge.computer = computer;
    bridge.auth = authenticatedStatus;
    bridge.fresh = true;
    await cloud.syncDevices();
    expect(repository.pairingChecks, proofs);
    repository.api.onDevices = (_, _) async =>
        throw StateError('Network error');
    await cloud.syncDevices();
    expect(cloud.discoveryError, isNotNull);
    expect(bridge.authenticated, true);
    expect(bridge.fresh, true);
    expect(repository.suspendedRelays, isEmpty);
    expect(repository.api.entitlements, 0);
  });
}
