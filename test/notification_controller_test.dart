import 'dart:async';
import 'dart:convert';

import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/notifications/notification_bridge.dart';
import 'package:bridge_mobile/notifications/notification_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_notifications.dart';
import 'support/fake_repository.dart';

NotificationBatch batch(
  List<String> ids, {
  String scope = 'scope-a',
  bool enabled = true,
}) => NotificationBatch(
  enabled: enabled,
  scope: scope,
  events: [
    for (var i = 0; i < ids.length; i++)
      NotificationEvent(
        id: ids[i],
        kind: i.isEven ? 'completion' : 'request',
        createdAt: 100.0 + i,
        session: sessionA,
      ),
  ],
);

void main() {
  late FakeRepository repository;
  late FakeNotificationBridge bridge;
  late NotificationController controller;
  var current = batch([]);

  setUp(() async {
    repository = FakeRepository()..savedComputers = [computerA];
    bridge = FakeNotificationBridge();
    current = batch(['historical']);
    repository.onNotificationEvents = (_) async => current;
    controller = NotificationController(repository, bridge, pollInterval: null);
    controller.updateConfiguration([computerA], 'zh');
    await controller.initialize();
  });
  tearDown(() => controller.dispose());

  Future<void> recreateController() async {
    controller.dispose();
    controller = NotificationController(repository, bridge, pollInterval: null);
    controller.updateConfiguration([computerA], 'zh');
    await controller.initialize();
  }

  test('automatically listens on startup without a setting or an unnecessary permission prompt', () async {
    var reads = 0;
    repository.onNotificationEvents = (_) async {
      reads++;
      return current;
    };
    await controller.pollNow();
    expect(reads, 1);
    expect(bridge.permissionRequests, 0);
    expect(bridge.ensureRequests, 1);
    expect(controller.state.allowed, isTrue);
    expect(controller.state.running, isTrue);
  });

  test(
    'first startup baselines history, then delivers each new event only once',
    () async {
      await controller.pollNow();
      expect(bridge.shown, isEmpty);
      current = batch(['historical', 'new-completion', 'new-request']);
      await controller.pollNow();
      await controller.pollNow();
      expect(bridge.shown, ['new-completion', 'new-request']);
      expect(controller.online, 1);
      expect(repository.sends + repository.stops + repository.creates, 0);
    },
  );

  test(
    'deduplication survives controller recreation with saved settings',
    () async {
      await controller.pollNow();
      current = batch(['historical', 'received']);
      await controller.pollNow();
      controller.dispose();
      controller = NotificationController(
        repository,
        bridge,
        pollInterval: null,
      );
      controller.updateConfiguration([computerA], 'zh');
      await controller.initialize();
      current = batch(['historical', 'received', 'missed-while-away']);
      await controller.pollNow();
      expect(bridge.shown, ['received', 'missed-while-away']);
    },
  );

  test(
    'account or stream change clears old routes and baselines new scope',
    () async {
      await controller.pollNow();
      current = batch(['other-account-history'], scope: 'scope-b');
      await controller.pollNow();
      expect(bridge.shown, isEmpty);
      current = batch([
        'other-account-history',
        'other-account-new',
      ], scope: 'scope-b');
      await controller.pollNow();
      expect(bridge.shown, ['other-account-new']);
      expect(bridge.cleared, [computerA.id, computerA.id]);
    },
  );

  test(
    'first startup requests the OS permission and starts after a grant',
    () async {
      bridge.current = const NotificationState();
      await recreateController();
      expect(bridge.permissionRequests, 1);
      expect(controller.state.allowed, isTrue);
      expect(controller.state.running, isTrue);
      await controller.pollNow();
      expect(bridge.shown, isEmpty);
    },
  );

  test('permission denial never starts a listener or loops prompts across resumes and restarts', () async {
    bridge.current = const NotificationState();
    bridge.permission = false;
    var reads = 0;
    repository.onNotificationEvents = (_) async {
      reads++;
      return current;
    };
    await recreateController();
    await controller.resume();
    await controller.resume();
    await recreateController();
    await controller.pollNow();
    expect(bridge.permissionRequests, 1);
    expect(reads, 0);
    expect(controller.state.allowed, isFalse);
    expect(controller.state.running, isFalse);
    expect(controller.statusText, 'Allow notifications in Android settings');
    expect(bridge.shown, isEmpty);
  });

  test('granting permission in OS settings resumes listening without an app toggle', () async {
    bridge.current = const NotificationState();
    bridge.permission = false;
    await recreateController();
    bridge.current = const NotificationState(allowed: true);
    await controller.resume();
    await controller.pollNow();
    current = batch(['historical', 'after-grant']);
    await controller.pollNow();
    expect(controller.state.running, isTrue);
    expect(bridge.permissionRequests, 1);
    expect(bridge.shown, ['after-grant']);
  });

  test(
    'initialization in the background waits for a visible Activity',
    () async {
      bridge.current = const NotificationState();
      bridge.foreground = false;
      await recreateController();
      await controller.pollNow();
      expect(bridge.permissionRequests, 0);
      expect(controller.state.running, isFalse);
      bridge.foreground = true;
      await controller.resume();
      expect(bridge.permissionRequests, 1);
      expect(controller.state.running, isTrue);
    },
  );

  test(
    'revoking OS permission during an in-flight read discards its completion',
    () async {
      await controller.pollNow();
      final saved = bridge.ledger;
      final gate = Completer<NotificationBatch>();
      repository.onNotificationEvents = (_) => gate.future;
      final polling = controller.pollNow();
      await Future<void>.delayed(Duration.zero);
      bridge.current = const NotificationState();
      await controller.refreshState();
      gate.complete(batch(['historical', 'late']));
      await polling;
      expect(bridge.shown, isEmpty);
      expect(bridge.ledger, saved);
    },
  );

  test(
    'removed gateways cannot deliver or retain notification cursors',
    () async {
      await controller.pollNow();
      final gate = Completer<NotificationBatch>();
      repository.onNotificationEvents = (_) => gate.future;
      final polling = controller.pollNow();
      await Future<void>.delayed(Duration.zero);
      final removal = controller.updateConfiguration([], 'zh');
      gate.complete(batch(['historical', 'late']));
      await polling;
      await removal;
      expect(bridge.shown, isEmpty);
      expect(bridge.computers, isEmpty);
      expect(jsonDecode(bridge.ledger!), isEmpty);
    },
  );

  test('OS permission restoration keeps deduplication and catches up with unseen events', () async {
    await controller.pollNow();
    current = batch(['historical', 'received']);
    await controller.pollNow();
    bridge.current = const NotificationState();
    await controller.refreshState();
    current = batch(['historical', 'received', 'while-unavailable']);
    await controller.pollNow();
    expect(bridge.shown, ['received']);
    bridge.current = const NotificationState(allowed: true);
    await controller.resume();
    await controller.pollNow();
    await controller.pollNow();
    expect(bridge.shown, ['received', 'while-unavailable']);
  });

  test('offline gateway does not block another saved gateway', () async {
    controller.updateConfiguration([computerA, computerB], 'en');
    repository.onNotificationEvents = (computer) async {
      if (computer.id == computerA.id) throw StateError('offline');
      return current;
    };
    await controller.pollNow();
    current = batch(['historical', 'online-event']);
    await controller.pollNow();
    expect(bridge.shown, ['online-event']);
    expect(controller.online, 1);
    expect(controller.total, 2);
    expect(bridge.locale, 'en');
  });

  test('optional gateway capability is respected and later establishes a new baseline', () async {
    await controller.pollNow();
    current = batch([], enabled: false);
    await controller.pollNow();
    expect(controller.online, 0);
    current = batch(['historical', 'while-unavailable']);
    await controller.pollNow();
    expect(bridge.shown, isEmpty);
  });

  test('overlapping poll requests never race', () async {
    final gate = Completer<NotificationBatch>();
    var reads = 0;
    repository.onNotificationEvents = (_) {
      reads++;
      return gate.future;
    };
    final first = controller.pollNow();
    await controller.pollNow();
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);
    gate.complete(current);
    await first;
  });

  test('unsuccessful native delivery remains retryable', () async {
    await controller.pollNow();
    bridge.deliver = false;
    current = batch(['historical', 'retry-after-permission']);
    await controller.pollNow();
    bridge.deliver = true;
    await controller.pollNow();
    expect(bridge.shown, ['retry-after-permission']);
  });

  test('catch-up is bounded and old skipped alerts do not replay', () async {
    await controller.pollNow();
    current = batch([for (var i = 0; i < 200; i++) 'event-$i']);
    await controller.pollNow();
    await controller.pollNow();
    expect(bridge.shown, [for (var i = 190; i < 200; i++) 'event-$i']);
    final saved = jsonDecode(bridge.ledger!) as Map;
    expect((saved[computerA.id]['seen'] as List).length, 200);
  });

  test(
    'native listener stopped outside the app cancels further polling',
    () async {
      await controller.pollNow();
      final saved = bridge.ledger;
      bridge.current = const NotificationState(allowed: true);
      await controller.refreshState();
      current = batch(['historical', 'after-native-stop']);
      await controller.pollNow();
      expect(bridge.shown, isEmpty);
      expect(bridge.ledger, saved);
      await controller.resume();
      await controller.pollNow();
      expect(bridge.shown, ['after-native-stop']);
    },
  );

  test('test notification leaves automatic monitoring running', () async {
    await controller.sendTest();
    expect(bridge.tests, 1);
    expect(controller.state.running, isTrue);
    expect(
      controller.message,
      'Test notification sent. Check the notification shade.',
    );
  });

  test('cold-start notification tap is retained until consumed', () async {
    bridge.tap = const NotificationTap('pc-a', 'scope-a', 'event-a');
    await controller.refreshState();
    expect(controller.consumeTap()?.eventId, 'event-a');
    expect(controller.consumeTap(), isNull);
  });

  test(
    'untrusted or incomplete route data cannot become a notification tap',
    () {
      expect(
        NotificationTap.parse({
          'computerId': 'pc-a',
          'scope': '',
          'eventId': 'x',
        }),
        isNull,
      );
      expect(
        NotificationTap.parse({
          'computerId': 'pc-a',
          'scope': 's',
          'eventId': 3,
        }),
        isNull,
      );
      expect(NotificationTap.parse('not a map'), isNull);
    },
  );

  test('corrupt saved cursor is treated as first startup rather than historical alerts', () async {
    controller.dispose();
    bridge.ledger = '{broken';
    bridge.current = const NotificationState(running: true, allowed: true);
    controller = NotificationController(repository, bridge, pollInterval: null);
    controller.updateConfiguration([computerA], 'zh');
    await controller.initialize();
    await controller.pollNow();
    expect(bridge.shown, isEmpty);
    expect(controller.message, isNull);
  });

  test('the retired enabled field cannot gate notification state', () async {
    bridge.current = NotificationState.fromMap({
      'enabled': false,
      'allowed': true,
      'running': true,
    });
    await controller.refreshState();
    await controller.pollNow();
    current = batch(['historical', 'after-upgrade']);
    await controller.pollNow();
    expect(bridge.shown, ['after-upgrade']);
  });

  test('a failed foreground start can retry automatically on resume', () async {
    bridge.current = const NotificationState(allowed: true);
    bridge.startError = StateError('Activity not ready');
    await recreateController();
    expect(controller.state.running, isFalse);
    expect(controller.message, isNotNull);
    bridge.startError = null;
    await controller.resume();
    expect(controller.state.running, isTrue);
    expect(controller.message, isNull);
  });

  test(
    'unsupported platforms do not request permission or start monitoring',
    () async {
      bridge.supported = false;
      final starts = bridge.ensureRequests;
      await recreateController();
      await controller.resume();
      expect(controller.state.supported, isFalse);
      expect(bridge.ensureRequests, starts);
      expect(bridge.permissionRequests, 0);
    },
  );
}
