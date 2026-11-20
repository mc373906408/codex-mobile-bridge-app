import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/notifications/notification_bridge.dart';
import 'package:bridge_mobile/notifications/notification_controller.dart';
import 'package:bridge_mobile/ui/notification_settings.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
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

  test('global and host alert preferences survive restart and include a new computer by default', () async {
    final repository = FakeRepository();
    final first = BridgeViewModel(repository);
    await first.initialize();
    first.setComputerNotificationsEnabled(computerB, false);
    first.setNotificationsEnabled(false);
    await Future<void>.delayed(Duration.zero);
    first.dispose();
    final restored = BridgeViewModel(repository);
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.notificationsEnabled, false);
    expect(restored.computerNotificationsEnabled(computerB), false);
    restored.setNotificationsEnabled(true);
    expect(restored.computerNotificationsEnabled(computerA), true);
    expect(
      restored.computerNotificationsEnabled(
        const Computer(id: 'new', name: 'New', baseUrl: 'https://new.test'),
      ),
      true,
    );
    expect(restored.computerNotificationsEnabled(computerB), false);
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
      'notification status and source controls in $locale fit a phone',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final bridge = FakeNotificationBridge();
        final repository = FakeRepository();
        final model = BridgeViewModel(repository);
        await model.initialize();
        final controller = NotificationController(
          repository,
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
                  model: model,
                  computers: model.computers,
                  strings: Strings(Locale(locale)),
                ),
              ),
            ),
          ),
        );
        final s = Strings(Locale(locale));
        expect(find.text(s.t('All computer notifications')), findsOneWidget);
        expect(
          find.text(
            s.t(
              'Allow system notifications for alerts while Bridge is in the background.',
            ),
          ),
          findsOneWidget,
        );
        expect(find.byType(SwitchListTile), findsNWidgets(3));
        expect(
          find.byKey(const Key('computer-notification-computer-a')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('computer-notification-computer-b')),
          findsOneWidget,
        );
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
        model.dispose();
      },
    );
  }
}
