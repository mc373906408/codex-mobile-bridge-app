import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/notifications/notification_bridge.dart';
import 'package:bridge_mobile/notifications/notification_controller.dart';
import 'package:bridge_mobile/ui/notification_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_notifications.dart';
import 'support/fake_repository.dart';

void main() {
  testWidgets('app resume automatically restores background listening', (
    tester,
  ) async {
    final bridge = FakeNotificationBridge();
    final controller = NotificationController(
      FakeRepository(),
      bridge,
      pollInterval: null,
    );
    await tester.pumpWidget(
      BridgeApp(repository: controller.repository, notifications: controller),
    );
    await tester.pumpAndSettle();
    final starts = bridge.ensureRequests;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    bridge.current = const NotificationState(allowed: true);
    await controller.refreshState();
    expect(controller.state.running, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(bridge.ensureRequests, greaterThan(starts));
    expect(controller.state.running, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'a notification tap dismisses settings and reveals its conversation',
    (tester) async {
      final repository = FakeRepository();
      repository.onNotificationEvents = (_) async => const NotificationBatch(
        enabled: true,
        scope: 'scope-a',
        events: [
          NotificationEvent(
            id: 'event-a',
            kind: 'completion',
            createdAt: 100,
            session: sessionA,
          ),
        ],
      );
      final bridge = FakeNotificationBridge();
      final controller = NotificationController(
        repository,
        bridge,
        pollInterval: null,
      );
      await tester.pumpWidget(
        BridgeApp(repository: repository, notifications: controller),
      );
      await tester.pumpAndSettle();
      expect(controller.state.running, isTrue);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationSettings), findsOneWidget);
      bridge.tap = NotificationTap(computerA.id, 'scope-a', 'event-a');
      bridge.onTap!();
      await tester.pumpAndSettle();
      expect(find.byType(NotificationSettings), findsNothing);
      expect(find.text('A quieter workspace'), findsOneWidget);
      expect(repository.connects, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  for (final locale in ['zh', 'en']) {
    testWidgets(
      'automatic notification status and test feedback in $locale fit a phone without a toggle',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final bridge = FakeNotificationBridge();
        final controller = NotificationController(
          FakeRepository(),
          bridge,
          pollInterval: null,
        );
        await controller.initialize();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: NotificationSettings(
                  controller: controller,
                  strings: Strings(Locale(locale)),
                ),
              ),
            ),
          ),
        );
        final s = Strings(Locale(locale));
        expect(find.text(s.t('Android notifications')), findsOneWidget);
        expect(
          find.text(
            s.t(
              'Task notifications are automatic. Allow Android notifications to receive alerts.',
            ),
          ),
          findsOneWidget,
        );
        expect(find.byType(SwitchListTile), findsNothing);
        expect(find.byType(Switch), findsNothing);
        expect(
          find.byKey(const Key('background-notifications-toggle')),
          findsNothing,
        );
        expect(controller.state.running, isTrue);
        await tester.ensureVisible(find.byKey(const Key('test-notification')));
        await tester.tap(find.byKey(const Key('test-notification')));
        await tester.pumpAndSettle();
        expect(bridge.tests, 1);
        expect(
          find.text(
            s.t('Test notification sent. Check the notification shade.'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );
  }
}
