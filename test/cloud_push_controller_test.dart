import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bridge_mobile/notifications/cloud_push_bridge.dart';
import 'package:bridge_mobile/notifications/cloud_push_controller.dart';
import 'package:bridge_mobile/notifications/notification_bridge.dart';
import 'package:bridge_mobile/src/rust/api/types.dart';

class _Repository implements CloudPushRepository {
  final List<String> calls = [];
  bool enabled = true;
  bool failRegistration = false;
  Completer<NotificationBatch>? pending;

  @override
  Future<bool> cloudEnabled(Computer computer) async => enabled;

  @override
  Future<void> registerCloudPush(
    Computer computer,
    CloudPushState state,
  ) async {
    calls.add('register:${state.enabled}');
    if (failRegistration) throw StateError('provider unavailable');
  }

  @override
  Future<NotificationBatch> notificationEvents(Computer computer) async {
    calls.add('read');
    return pending?.future ??
        NotificationBatch(scope: 'scope', enabled: true, events: const []);
  }

  @override
  Future<void> acknowledgeCloudPush(Computer computer, List<String> ids) async {
    calls.add(ids.isEmpty ? 'heartbeat' : 'ack:${ids.join(',')}');
  }
}

class _Bridge implements CloudPushBridge {
  _Bridge(this.calls);
  final List<String> calls;
  List<String> receipts = [];
  bool failCommit = false;
  int batches = 0;
  VoidCallback? changed;
  CloudPushState current = const CloudPushState(
    configured: true,
    allowed: true,
    consent: true,
    interactive: true,
    platform: 'apns',
    appId: 'test.app',
    token: 'local-test-token',
  );

  @override
  bool get supported => true;
  @override
  void bind(VoidCallback changed) {
    this.changed = changed;
  }

  @override
  Future<CloudPushState> state() async => current;
  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<CloudPushState> setConsent(bool enabled, String noticeVersion) async {
    calls.add('consent:$enabled:$noticeVersion');
    current = CloudPushState(
      configured: current.configured,
      allowed: current.allowed,
      consent: enabled,
      interactive: true,
      platform: current.platform,
      appId: current.appId,
      token: current.token,
      noticeVersion: noticeVersion,
    );
    changed?.call();
    return current;
  }

  @override
  Future<void> directBatch(String computerId, NotificationBatch batch) async {
    calls.add('commit');
    if (failCommit) throw StateError('storage unavailable');
    batches++;
    receipts = ['durable-receipt'];
  }

  @override
  Future<List<String>> pendingReceipts(String computerId) async => receipts;
  @override
  Future<void> markAcknowledged(String computerId, List<String> ids) async {
    calls.add('mark');
    receipts.removeWhere(ids.contains);
  }

  @override
  Future<NotificationTap?> takeTap() async => null;
  @override
  void dispose() {}
}

Computer _computer(String id, {ConnectionType type = ConnectionType.relay}) =>
    Computer(
      id: id,
      name: 'Local test',
      baseUrl: 'https://relay.example.test',
      connectionType: type,
    );

void main() {
  test(
    'consent and permission are independent revisions even before registration',
    () {
      const off = CloudPushState(allowed: true);
      const accepted = CloudPushState(allowed: true, consent: true);
      expect(off.enabled, false);
      expect(accepted.enabled, false);
      expect(off.revision, isNot(accepted.revision));
      expect(accepted.directAllowed, true);
    },
  );

  test(
    'explicit opt-out fences an in-flight read and removes the endpoint',
    () async {
      final repository = _Repository()
        ..pending = Completer<NotificationBatch>();
      final bridge = _Bridge(repository.calls);
      final controller = CloudPushController(
        repository,
        bridge,
        interval: null,
      );
      addTearDown(controller.dispose);
      controller.configure([_computer('relay')]);
      final initialization = controller.initialize();
      while (!repository.calls.contains('read')) {
        await Future<void>.delayed(Duration.zero);
      }
      await controller.setConsent(false, 'cloud-notifications-v1');
      repository.pending!.complete(
        NotificationBatch(scope: 'scope', enabled: true, events: const []),
      );
      await initialization;
      await Future<void>.delayed(Duration.zero);
      expect(bridge.batches, 0);
      expect(repository.calls, contains('register:false'));
      expect(repository.calls, isNot(contains('heartbeat')));
    },
  );

  test('system permission alone never enables cloud reads', () async {
    final repository = _Repository();
    final bridge = _Bridge(repository.calls)
      ..current = const CloudPushState(allowed: true);
    final controller = CloudPushController(repository, bridge, interval: null);
    addTearDown(controller.dispose);
    controller.configure([_computer('relay')]);
    await controller.initialize();
    expect(repository.calls, ['register:false']);
  });

  test(
    'SDK-free builds can explicitly allow generic direct cloud updates',
    () async {
      final repository = _Repository();
      final bridge = _Bridge(repository.calls)
        ..current = const CloudPushState(allowed: true, consent: true);
      final controller = CloudPushController(
        repository,
        bridge,
        interval: null,
      );
      addTearDown(controller.dispose);
      controller.configure([_computer('relay')]);
      await controller.initialize();
      expect(repository.calls.first, 'register:false');
      expect(repository.calls, contains('commit'));
      expect(repository.calls.last, 'heartbeat');
    },
  );

  test(
    'durable receipt commit precedes ACK and the direct lease heartbeat',
    () async {
      final repository = _Repository();
      final bridge = _Bridge(repository.calls);
      final controller = CloudPushController(
        repository,
        bridge,
        interval: null,
      );
      addTearDown(controller.dispose);
      controller.configure([
        _computer('relay'),
        _computer('direct', type: ConnectionType.direct),
      ]);
      await controller.initialize();
      expect(repository.calls, [
        'register:true',
        'read',
        'commit',
        'ack:durable-receipt',
        'mark',
        'heartbeat',
      ]);
    },
  );

  test(
    'a failed durable commit cannot ACK or renew the direct lease',
    () async {
      final repository = _Repository();
      final bridge = _Bridge(repository.calls)..failCommit = true;
      final controller = CloudPushController(
        repository,
        bridge,
        interval: null,
      );
      addTearDown(controller.dispose);
      controller.configure([_computer('relay')]);
      await controller.initialize();
      expect(repository.calls, ['register:true', 'read', 'commit']);
    },
  );

  test('registration retries are bounded but never block durable receipt reconciliation', () async {
    final repository = _Repository()..failRegistration = true;
    final bridge = _Bridge(repository.calls)..receipts = ['extension-receipt'];
    final controller = CloudPushController(repository, bridge, interval: null);
    addTearDown(controller.dispose);
    controller.configure([_computer('relay')]);
    await controller.initialize();
    for (var i = 0; i < 9; i++) {
      await controller.resume();
    }
    expect(
      repository.calls.where((call) => call.startsWith('register:')),
      hasLength(6),
    );
    expect(repository.calls, contains('ack:extension-receipt'));
    expect(
      repository.calls.where((call) => call == 'heartbeat'),
      hasLength(10),
    );
  });

  test(
    'permission withdrawal disables the endpoint and does not renew its lease',
    () async {
      final repository = _Repository();
      final bridge = _Bridge(repository.calls);
      final controller = CloudPushController(
        repository,
        bridge,
        interval: null,
      );
      addTearDown(controller.dispose);
      controller.configure([_computer('relay')]);
      await controller.initialize();
      repository.calls.clear();
      bridge.current = const CloudPushState(
        configured: true,
        platform: 'apns',
        appId: 'test.app',
      );
      bridge.receipts = ['already-durable'];
      await controller.resume();
      expect(repository.calls, [
        'register:false',
        'ack:already-durable',
        'mark',
      ]);
    },
  );

  test('disabled accounts are fenced and must register again after an explicit login', () async {
    final repository = _Repository()..enabled = false;
    final bridge = _Bridge(repository.calls);
    final controller = CloudPushController(repository, bridge, interval: null);
    addTearDown(controller.dispose);
    controller.configure([_computer('relay')]);
    await controller.initialize();
    expect(repository.calls, isEmpty);
    repository.enabled = true;
    await controller.resume();
    expect(repository.calls.first, 'register:true');
    repository.enabled = false;
    await controller.resume();
    repository.enabled = true;
    repository.calls.clear();
    await controller.resume();
    expect(repository.calls.first, 'register:true');
  });

  test(
    'configuration changes discard an in-flight source before receipt storage',
    () async {
      final repository = _Repository()
        ..pending = Completer<NotificationBatch>();
      final bridge = _Bridge(repository.calls);
      final controller = CloudPushController(
        repository,
        bridge,
        interval: null,
      );
      addTearDown(controller.dispose);
      controller.configure([_computer('relay')]);
      final initialization = controller.initialize();
      while (!repository.calls.contains('read')) {
        await Future<void>.delayed(Duration.zero);
      }
      controller.configure([]);
      repository.pending!.complete(
        NotificationBatch(scope: 'scope', enabled: true, events: const []),
      );
      await initialization;
      await Future<void>.delayed(Duration.zero);
      expect(bridge.batches, 0);
      expect(repository.calls, isNot(contains('heartbeat')));
    },
  );
}
