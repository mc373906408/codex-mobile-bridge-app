import 'dart:async';

import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

NotificationBatch notification({
  String scope = 'scope-a',
  SessionRef session = sessionA,
}) => NotificationBatch(
  enabled: true,
  scope: scope,
  events: [
    NotificationEvent(
      id: 'event-a',
      kind: 'request',
      createdAt: 100,
      session: session,
    ),
  ],
);

void main() {
  late FakeRepository repository;
  late BridgeViewModel model;
  setUp(() async {
    repository = FakeRepository();
    repository.onNotificationEvents = (_) async => notification();
    model = BridgeViewModel(repository);
    await model.initialize();
  });
  tearDown(() async {
    model.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'tap authenticates its saved gateway and opens the current event read-only',
    () async {
      await model.openNotification(
        computerId: computerA.id,
        scope: 'scope-a',
        eventId: 'event-a',
      );
      expect(model.computer, computerA);
      expect(model.selected, sessionA);
      expect(model.readInbox, contains('event-a'));
      expect(repository.connects, 1);
      expect(repository.sends + repository.stops + repository.creates, 0);
    },
  );

  test(
    'stale account or stream cannot open the session from an old notification',
    () async {
      repository.onNotificationEvents = (_) async =>
          notification(scope: 'another-account');
      await model.openNotification(
        computerId: computerA.id,
        scope: 'scope-a',
        eventId: 'event-a',
      );
      expect(model.selected, isNull);
      expect(model.notice, 'This notification has expired; check the inbox.');
    },
  );

  test(
    'an expired event and a removed gateway cannot invent a route',
    () async {
      await model.openNotification(
        computerId: 'removed-computer',
        scope: 'scope-a',
        eventId: 'event-a',
      );
      expect(repository.connects, 0);
      await model.openNotification(
        computerId: computerA.id,
        scope: 'scope-a',
        eventId: 'missing-event',
      );
      expect(model.selected, isNull);
    },
  );

  test(
    'a tap waits for an explicit login instead of bypassing authentication',
    () async {
      repository.onConnect = (_) async => const AuthStatus(
        authenticated: false,
        computerName: '',
        platform: '',
        passwordless: false,
        notifications: false,
        transport: 'poll',
      );
      await model.openNotification(
        computerId: computerA.id,
        scope: 'scope-a',
        eventId: 'event-a',
      );
      expect(model.selected, isNull);
      await model.login('synthetic', 'synthetic');
      expect(model.selected, sessionA);
    },
  );

  test('desktop provider routes are resolved to their original execution environment', () async {
    repository.onNotificationEvents = (_) async => notification(
      session: const SessionRef(
        computerId: 'computer-a',
        provider: Provider.claude,
        environment: 'local',
        id: 'opaque-claude-session',
      ),
    );
    await model.openNotification(
      computerId: computerA.id,
      scope: 'scope-a',
      eventId: 'event-a',
    );
    expect(model.selected, sessionB);
  });

  test(
    'leaving for another gateway discards a late notification lookup',
    () async {
      final gate = Completer<NotificationBatch>();
      repository.onNotificationEvents = (_) => gate.future;
      final opening = model.openNotification(
        computerId: computerA.id,
        scope: 'scope-a',
        eventId: 'event-a',
      );
      await Future<void>.delayed(Duration.zero);
      await model.selectComputer(computerB);
      gate.complete(notification());
      await opening;
      expect(model.computer, computerB);
      expect(model.selected, isNull);
    },
  );

  test(
    'background taps do not reconnect or modify the active selection',
    () async {
      await model.setForeground(false);
      await model.openNotification(
        computerId: computerA.id,
        scope: 'scope-a',
        eventId: 'event-a',
      );
      expect(repository.connects, 0);
      expect(model.selected, isNull);
    },
  );
}
