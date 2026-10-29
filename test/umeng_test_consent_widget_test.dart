import 'dart:async';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/notifications/notification_bridge.dart';
import 'package:bridge_mobile/notifications/notification_controller.dart';
import 'package:bridge_mobile/privacy/umeng_test_consent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_notifications.dart';
import 'support/fake_repository.dart';
import 'support/fake_umeng_consent.dart';

const dialogKey = Key('umeng-test-consent-dialog');
const acceptKey = Key('umeng-consent-accept');
const declineKey = Key('umeng-consent-decline');

Future<UmengTestConsentController> launch(
  WidgetTester tester,
  FakeUmengTestConsentBridge bridge, {
  FakeRepository? repository,
  NotificationController? notifications,
}) async {
  final controller = UmengTestConsentController(bridge);
  await tester.pumpWidget(
    BridgeApp(
      repository: repository ?? FakeRepository(),
      umengConsent: controller,
      notifications: notifications,
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  tearDown(
    () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    ),
  );

  testWidgets(
    'test consent appears once and refusal leaves direct notifications running',
    (tester) async {
      final repository = FakeRepository();
      final notifications = NotificationController(
        repository,
        FakeNotificationBridge(),
        pollInterval: null,
      );
      final bridge = FakeUmengTestConsentBridge();
      final controller = await launch(
        tester,
        bridge,
        repository: repository,
        notifications: notifications,
      );
      expect(find.byKey(dialogKey), findsOneWidget);
      expect(bridge.choices, isEmpty);
      expect(notifications.state.running, isTrue);
      await tester.tap(find.byKey(declineKey));
      await tester.pumpAndSettle();
      expect(controller.state.decision, 'declined');
      expect(find.byKey(dialogKey), findsNothing);
      expect(notifications.state.running, isTrue);
      await controller.refresh();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(dialogKey), findsNothing);
      expect(
        repository.sends +
            repository.stops +
            repository.creates +
            repository.uploads,
        0,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await launch(tester, bridge);
      expect(find.byKey(dialogKey), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'successful acceptance can be reviewed and withdrawn without a notification switch',
    (tester) async {
      final bridge = FakeUmengTestConsentBridge();
      final controller = await launch(tester, bridge);
      await tester.tap(find.byKey(acceptKey));
      await tester.pumpAndSettle();
      expect(controller.state.accepted, isTrue);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('umeng-consent-withdraw')),
      );
      await tester.tap(find.byKey(const Key('umeng-consent-withdraw')));
      await tester.pumpAndSettle();
      expect(controller.state.decision, 'declined');
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(SwitchListTile), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('umeng-consent-review')));
      await tester.tap(find.byKey(const Key('umeng-consent-review')));
      await tester.pumpAndSettle();
      expect(find.byKey(dialogKey), findsOneWidget);
      expect(bridge.choices, ['accepted', 'declined']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'registered push has an explicit token copy action and withdrawal removes it',
    (tester) async {
      final bridge = FakeUmengTestConsentBridge()
        ..current = const UmengTestConsentState(
          eligible: true,
          interactive: true,
          decision: 'accepted',
          pushStatus: 'registered',
          hasDeviceToken: true,
        );
      await launch(tester, bridge);
      expect(find.byKey(dialogKey), findsNothing);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      final copy = find.byKey(const Key('umeng-copy-token'));
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(bridge.copies, 1);
      expect(find.byKey(const Key('umeng-push-status')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('umeng-consent-withdraw')),
      );
      await tester.tap(find.byKey(const Key('umeng-consent-withdraw')));
      await tester.pumpAndSettle();
      expect(copy, findsNothing);
      expect(bridge.choices, ['declined']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'outside taps and back never grant consent or immediately repeat the prompt',
    (tester) async {
      final bridge = FakeUmengTestConsentBridge();
      final controller = await launch(tester, bridge);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.byKey(dialogKey), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.byKey(dialogKey), findsNothing);
      expect(bridge.choices, isEmpty);
      expect(controller.state.accepted, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'saving is not reported as consent until native storage confirms it',
    (tester) async {
      final bridge = FakeUmengTestConsentBridge();
      final controller = await launch(tester, bridge);
      final gate = Completer<UmengTestConsentState>();
      bridge.onWrite = (_) => gate.future;
      await tester.tap(find.byKey(acceptKey));
      await tester.pump();
      expect(controller.state.accepted, isFalse);
      expect(
        tester.widget<FilledButton>(find.byKey(acceptKey)).onPressed,
        isNull,
      );
      expect(
        tester.widget<OutlinedButton>(find.byKey(declineKey)).onPressed,
        isNull,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(dialogKey), findsOneWidget);
      gate.complete(
        const UmengTestConsentState(
          eligible: true,
          interactive: true,
          decision: 'accepted',
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.state.accepted, isTrue);
      expect(find.byKey(dialogKey), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed storage leaves the notice open and never exposes the native failure',
    (tester) async {
      final bridge = FakeUmengTestConsentBridge()
        ..writeError = StateError('PRIVATE');
      final controller = await launch(tester, bridge);
      await tester.tap(find.byKey(acceptKey));
      await tester.pumpAndSettle();
      expect(controller.state.accepted, isFalse);
      expect(find.byKey(dialogKey), findsOneWidget);
      expect(find.byKey(const Key('umeng-consent-error')), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      bridge.writeError = null;
      await tester.tap(find.byKey(declineKey));
      await tester.pumpAndSettle();
      expect(find.byKey(dialogKey), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unsupported devices have no test privacy prompt or settings entry',
    (tester) async {
      final bridge = FakeUmengTestConsentBridge()
        ..current = const UmengTestConsentState();
      await launch(tester, bridge);
      expect(find.byKey(dialogKey), findsNothing);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('umeng-consent-review')), findsNothing);
      expect(bridge.choices, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'the notice waits for native foreground permission prompting to finish',
    (tester) async {
      final bridge = FakeUmengTestConsentBridge()
        ..current = const UmengTestConsentState(eligible: true);
      await launch(tester, bridge);
      expect(find.byKey(dialogKey), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      bridge.current = const UmengTestConsentState(
        eligible: true,
        interactive: true,
      );
      bridge.onChanged!();
      await tester.pumpAndSettle();
      expect(find.byKey(dialogKey), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(dialogKey), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'an open notice disables decisions until the activity regains focus',
    (tester) async {
      final bridge = FakeUmengTestConsentBridge();
      final controller = await launch(tester, bridge);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      bridge.current = const UmengTestConsentState(eligible: true);
      bridge.onChanged!();
      await tester.pumpAndSettle();
      expect(controller.state.interactive, isFalse);
      expect(find.byKey(dialogKey), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(acceptKey)).onPressed,
        isNull,
      );
      expect(
        tester.widget<OutlinedButton>(find.byKey(declineKey)).onPressed,
        isNull,
      );
      expect(bridge.choices, isEmpty);
      bridge.current = const UmengTestConsentState(
        eligible: true,
        interactive: true,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byKey(acceptKey)).onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(declineKey));
      await tester.pumpAndSettle();
      expect(controller.state.decision, 'declined');
      expect(find.byKey(dialogKey), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unavailable privacy guidance neither grants consent nor prevents refusal',
    (tester) async {
      final bridge = FakeUmengTestConsentBridge()
        ..detailsError = StateError('PRIVATE');
      final controller = await launch(tester, bridge);
      await tester.ensureVisible(
        find.byKey(const Key('umeng-privacy-details')),
      );
      await tester.tap(find.byKey(const Key('umeng-privacy-details')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('umeng-consent-error')), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(controller.state.accepted, isFalse);
      expect(bridge.choices, isEmpty);
      await tester.tap(find.byKey(declineKey));
      await tester.pumpAndSettle();
      expect(controller.state.decision, 'declined');
      expect(find.byKey(dialogKey), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a notification tap waits for the privacy notice without being lost',
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
      final notificationBridge = FakeNotificationBridge();
      final notifications = NotificationController(
        repository,
        notificationBridge,
        pollInterval: null,
      );
      await launch(
        tester,
        FakeUmengTestConsentBridge(),
        repository: repository,
        notifications: notifications,
      );
      notificationBridge.tap = NotificationTap(
        computerA.id,
        'scope-a',
        'event-a',
      );
      notificationBridge.onTap!();
      await tester.pumpAndSettle();
      expect(find.byKey(dialogKey), findsOneWidget);
      expect(repository.connects, 0);
      await tester.tap(find.byKey(declineKey));
      await tester.pumpAndSettle();
      expect(find.byKey(dialogKey), findsNothing);
      expect(find.text('A quieter workspace'), findsOneWidget);
      expect(repository.connects, 1);
      expect(repository.sends + repository.stops + repository.creates, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final locale in ['zh', 'en']) {
    testWidgets('the $locale notice remains usable after rotating the phone', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = FakeRepository()
        ..savedPreferences = UiPreferences(
          theme: 'light',
          locale: locale,
          readInbox: const [],
        );
      final bridge = FakeUmengTestConsentBridge();
      await launch(tester, bridge, repository: repository);
      await tester.binding.setSurfaceSize(const Size(568, 320));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('umeng-privacy-details')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('umeng-privacy-details')));
      expect(bridge.details, 1);
      expect(bridge.choices, isEmpty);
      await tester.ensureVisible(find.byKey(acceptKey));
      await tester.pumpAndSettle();
      expect(find.byKey(acceptKey).hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.byKey(declineKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(declineKey));
      await tester.pumpAndSettle();
      expect(bridge.choices, ['declined']);
      expect(find.byKey(dialogKey), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final theme in ['light', 'dark']) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'the complete $locale notice fits a small phone in $theme at ${scale}x text',
          (tester) async {
            await tester.binding.setSurfaceSize(const Size(320, 568));
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(() => tester.binding.setSurfaceSize(null));
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final repository = FakeRepository()
              ..savedPreferences = UiPreferences(
                theme: theme,
                locale: locale,
                readInbox: const [],
              );
            final bridge = FakeUmengTestConsentBridge();
            await launch(tester, bridge, repository: repository);
            final s = Strings(Locale(locale));
            expect(
              find.text(s.t('Lenovo test: U-Push consent')),
              findsOneWidget,
            );
            expect(find.byKey(acceptKey), findsOneWidget);
            expect(find.byKey(declineKey), findsOneWidget);
            await tester.ensureVisible(
              find.byKey(const Key('umeng-privacy-details')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const Key('umeng-privacy-details')));
            await tester.pumpAndSettle();
            expect(bridge.details, 1);
            expect(bridge.choices, isEmpty);
            await tester.ensureVisible(find.byKey(acceptKey));
            await tester.pumpAndSettle();
            expect(find.byKey(acceptKey).hitTestable(), findsOneWidget);
            await tester.ensureVisible(find.byKey(declineKey));
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(declineKey));
            await tester.pumpAndSettle();
            expect(bridge.choices, ['declined']);
            expect(find.byKey(dialogKey), findsNothing);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }
}
