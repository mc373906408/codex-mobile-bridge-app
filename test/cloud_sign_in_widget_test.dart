import 'dart:async';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/notifications/cloud_push_bridge.dart';
import 'package:bridge_mobile/notifications/cloud_push_controller.dart';
import 'package:bridge_mobile/notifications/notification_bridge.dart';
import 'package:bridge_mobile/ui/cloud_dialog.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';
import 'support/fake_repository.dart';

import 'support/cloud_home_test_support.dart';

void main() {
  testWidgets(
    'home and cloud service share login and default notifications without auto pairing',
    (tester) async {
      final repository = FakeCloudRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      final pushBridge = FakeCloudPushBridge();
      final push = CloudPushController(repository, pushBridge, interval: null);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model, cloudPush: push),
      );
      await tester.pumpAndSettle();
      expectOfficialAddressHidden();
      expect(find.text('Official cloud'), findsNothing);
      expectHomeCloudSummaryRemoved();
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('No cloud relay'), findsNothing);
      expect(find.byKey(const Key('cloud-login')), findsNothing);
      expect(repository.connects, 0);
      await tester.tap(find.byKey(const Key('cloud-primary-action')));
      await tester.pumpAndSettle();
      expect(find.text('Email / Account'), findsOneWidget);
      expectServicePanelsRemoved();
      expectOfficialAddressHidden();
      expect(find.byKey(const Key('current-cloud-origin')), findsNothing);
      await enterCloudLogin(tester);
      expect(find.byKey(const Key('signed-in-cloud-account')), findsOneWidget);
      expect(find.textContaining('2030'), findsNothing);
      expectServicePanelsRemoved();
      expect(find.byKey(const Key('cloud-password')), findsNothing);

      expect(repository.connects, 0);
      expect(pushBridge.consentWrites, 1);
      expect(pushBridge.permissionRequests, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('user@example.com'), findsNothing);
      expect(find.text('Open cloud'), findsOneWidget);
      expect(find.text('Request pairing'), findsNothing);
      expect(find.text('Log out'), findsNothing);
      expect(find.text('Service active'), findsNothing);
      expectHomeCloudSummaryRemoved();
      expectOfficialAddressHidden();
      final requests = repository.api.capabilityOrigins.length;
      model.setAppearance(theme: 'dark');
      await tester.pumpAndSettle();
      expect(repository.api.capabilityOrigins.length, requests);
      await tester.tap(find.byKey(const Key('cloud-primary-action')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('signed-in-cloud-account')), findsOneWidget);
      expect(find.text('user@example.com'), findsOneWidget);
      expect(find.text('Request pairing'), findsNothing);
      expect(find.text('Log out'), findsOneWidget);
      expect(find.text('Service active'), findsNothing);
      expect(find.textContaining('2030'), findsNothing);
      expectServicePanelsRemoved();
      expect(repository.api.logoutOrigins, isEmpty);

      expect(pushBridge.consentWrites, 1);
      expect(pushBridge.permissionRequests, 1);
      expect(find.byKey(const Key('cloud-pair-action')), findsNothing);

      expect(find.byType(CloudConnectionDialog), findsNothing);
      expect(find.byKey(const Key('cloud-sign-out')), findsOneWidget);
      expect(repository.api.logoutOrigins, isEmpty);
      await closeCloudApp(tester, model);
    },
  );

  testWidgets(
    'notification taps wait for durable cloud selection before navigating',
    (tester) async {
      final repository = FakeCloudRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      final native = FakeCloudPushBridge()
        ..current = const CloudPushState(
          allowed: true,
          consent: true,
          interactive: true,
        );
      final push = CloudPushController(repository, native, interval: null);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model, cloudPush: push),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cloud-primary-action')));
      await tester.pumpAndSettle();
      final storing = Completer<void>(), finishWrite = Completer<void>();
      repository.vault.beforeWrite = (key) async {
        if (key == 'bridge.cloud.selection.v1') {
          storing.complete();
          await finishWrite.future;
        }
      };
      await tester.enterText(
        find.byKey(const Key('cloud-login')),
        'user@example.com',
      );
      await tester.enterText(
        find.byKey(const Key('cloud-password')),
        'password',
      );
      await tester.ensureVisible(find.byKey(const Key('cloud-sign-in')));
      await tester.tap(find.byKey(const Key('cloud-sign-in')));
      await tester.pump();
      await storing.future;
      expect(model.busy, false);
      push.pendingTap = const NotificationTap('computer-a', 'scope', 'event');
      await push.resume();
      await tester.pump();
      expect(repository.connects, 0);
      expect(push.pendingTap, isNotNull);
      finishWrite.complete();
      await tester.pumpAndSettle();
      expect(repository.connects, 1);
      expect(model.computer, computerA);
      expect(push.pendingTap, isNull);
      expect(repository.sends, 0);
      await closeCloudApp(tester, model);
    },
  );

  testWidgets(
    'cloud service hides status and notification panels without changing consent',
    (tester) async {
      final repository = FakeCloudRepository();
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      final model = BridgeViewModel(repository);
      await model.initialize();
      final native = FakeCloudPushBridge()
        ..current = const CloudPushState(
          configured: true,
          allowed: true,
          consent: true,
          interactive: true,
          platform: 'umeng',
          appId: 'app',
          token: 'token',
        );
      final push = CloudPushController(repository, native, interval: null);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model, cloudPush: push),
      );
      await tester.pumpAndSettle();
      expectHomeCloudSummaryRemoved();
      expect(
        find.text('Background push is not configured on this server'),
        findsNothing,
      );
      expect(find.text('Background push is enabled'), findsNothing);
      await openCloudService(tester);
      expectServicePanelsRemoved();
      expect(
        find.text('Background push is not configured on this server'),
        findsNothing,
      );
      expect(find.byKey(const Key('signed-in-cloud-account')), findsOneWidget);
      expect(native.permissionRequests, 0);
      expect(native.consentWrites, 0);
      await closeCloudApp(tester, model);
    },
  );

  testWidgets(
    'general settings link to cloud service instead of duplicating its controls',
    (tester) async {
      final repository = FakeCloudRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Account and server settings'), findsOneWidget);
      expect(find.byKey(const Key('cloud-notification-consent')), findsNothing);
      await tester.tap(find.byKey(const Key('settings-cloud-service')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cloud-login')), findsOneWidget);
      expectServicePanelsRemoved();
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
      await closeCloudApp(tester, model);
    },
  );
}
