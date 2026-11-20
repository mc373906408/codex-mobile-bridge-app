import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/notifications/notification_bridge.dart';
import 'package:bridge_mobile/notifications/notification_controller.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/fake_notifications.dart';
import '../test/support/fake_repository.dart';

class _TwoComputers extends FakeRepository {
  final events = <String, List<String>>{computerA.id: [], computerB.id: []};

  SessionRef sessionOn(Computer pc) => SessionRef(
    computerId: pc.id,
    provider: Provider.codex,
    environment: 'local',
    id: sessionA.id,
  );

  @override
  Future<NotificationBatch> notificationEvents(Computer pc) async =>
      NotificationBatch(
        enabled: true,
        scope: pc.id,
        events: [
          for (final (i, id) in events[pc.id]!.indexed)
            NotificationEvent(
              id: id,
              kind: 'request',
              createdAt: 100.0 + i,
              session: sessionOn(pc),
            ),
        ],
      );

  @override
  Future<List<InboxEntry>> inbox(Computer pc) async => [
    for (final id in events[pc.id]!)
      InboxEntry(id: id, title: id, body: '', session: sessionOn(pc)),
  ];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'another computer can notify, open its chat and be muted from Settings',
    (tester) async {
      final repository = _TwoComputers();
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.selectComputer(computerA);
      await model.openSession(sessionA);
      final system = FakeNotificationBridge()..backgroundListening = false;
      final alerts = NotificationController(
        repository,
        system,
        pollInterval: null,
      );
      await tester.pumpWidget(
        BridgeApp(
          repository: repository,
          viewModel: model,
          notifications: alerts,
        ),
      );
      await tester.pumpAndSettle();
      await alerts.pollNow();
      final editor = find.byKey(const Key('composer'));
      await tester.enterText(editor, 'Draft on Studio');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Context usage'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      expect(model.selected, sessionA);
      repository.events[computerB.id]!.add('Review on Workshop');
      await alerts.pollNow();
      expect(system.shown, ['Review on Workshop']);
      expect(model.draftText, 'Draft on Studio');
      system.tap = NotificationTap(
        computerB.id,
        computerB.id,
        system.shown.single,
      );
      system.onTap!();
      await tester.pumpAndSettle();
      expect(model.selected, repository.sessionOn(computerB));
      await model.backToSessions();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tab-settings')));
      await tester.pumpAndSettle();
      final mute = find.byKey(
        ValueKey('computer-notification-${computerB.id}'),
      );
      await tester.dragUntilVisible(
        mute.hitTestable(),
        find.byKey(const PageStorageKey('settings-scroll')),
        const Offset(0, -260),
      );
      await tester.pumpAndSettle();
      await tester.tap(mute.hitTestable());
      await tester.pumpAndSettle();
      expect(model.computerNotificationsEnabled(computerB), isFalse);
      repository.events[computerA.id]!.add('Studio is ready');
      repository.events[computerB.id]!.add('Quiet update from Workshop');
      await alerts.pollNow();
      expect(system.shown, ['Review on Workshop', 'Studio is ready']);
      await tester.tap(find.byKey(const ValueKey('tab-computers')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Inbox'));
      await tester.pumpAndSettle();
      expect(find.text('Quiet update from Workshop'), findsOneWidget);
      await tester.tap(find.text('Studio is ready'));
      await tester.pumpAndSettle();
      expect(model.selected, sessionA);
      expect(
        tester.widget<TextField>(editor).controller!.text,
        'Draft on Studio',
      );
      expect(repository.sends + repository.stops + repository.creates, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    },
  );
}
