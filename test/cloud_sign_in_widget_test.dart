import 'dart:async';
import 'dart:io';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/data/bridge_types.dart';
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
    'cloud account shows each saved pairing ID even when the computer is offline',
    (tester) async {
      final repository = FakeCloudRepository();
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      repository.api.onDevices = (_, _) async => [
        for (final (binding, gateway, name) in [
          ('studio-binding', 'studio-gateway', 'Studio'),
          ('office-binding', 'office-gateway', 'Office'),
          ('new-binding', 'new-gateway', 'Unpaired computer'),
        ])
          CloudDiscoveredDevice(
            gateway: CloudGateway(
              origin: officialCloudOrigin,
              id: gateway,
              name: name,
              controlPublicKey: 'desktop-control-key',
              online: false,
            ),
            bindingId: binding,
            status: binding == 'new-binding'
                ? CloudDeviceStatus.unpaired
                : CloudDeviceStatus.active,
            accessRevision: 1,
          ),
      ];
      repository.savedSafetyCodes.addAll({
        'studio-binding': '${'12345678 ' * 7}EE44BAB8',
        'office-binding': '${'12345678 ' * 7}5311DB76',
      });
      final model = BridgeViewModel(repository);
      await model.initialize();
      model.setAppearance(locale: 'zh');
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cloud-primary-action')));
      await tester.pumpAndSettle();

      expect(find.text('本机配对 ID'), findsOneWidget);
      expect(find.text('Studio · EE44BAB8'), findsOneWidget);
      expect(find.text('Office · 5311DB76'), findsOneWidget);
      expect(find.textContaining('12345678'), findsNothing);
      expect(find.textContaining('Unpaired computer'), findsNothing);
      expect(repository.pairingChecks, 0);
      await closeCloudApp(tester, model);
    },
  );

  testWidgets('cloud connection failure keeps the signed-in account visible', (
    tester,
  ) async {
    final repository = FakeCloudRepository();
    await repository.cloudAccounts.signIn(
      officialCloudOrigin,
      'user@example.com',
      'password',
    );
    repository.api.onCapabilities = (_) async =>
        throw const SocketException('private-host secret-token');
    repository.api.onDevices = (_, _) async =>
        throw const SocketException('private-host secret-token');
    final model = BridgeViewModel(repository);
    await model.initialize();
    model.setAppearance(locale: 'zh');
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cloud-primary-action')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('signed-in-cloud-account')), findsOneWidget);
    expect(find.byKey(const Key('cloud-login')), findsNothing);
    expect(find.text('暂时无法连接云服务，请检查网络或云服务状态。'), findsOneWidget);
    expect(find.textContaining('网关连接暂时中断'), findsNothing);
    expect(find.textContaining('secret-token'), findsNothing);
    expect(repository.api.logoutOrigins, isEmpty);
    expect(repository.api.loginOrigins, [officialCloudOrigin]);
    expect(tester.takeException(), isNull);
    await closeCloudApp(tester, model);
  });

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
      final target = cloudComputer();
      final directory = Completer<List<CloudDiscoveredDevice>>();
      repository.api.onDevices = (_, _) => directory.future;
      repository.pairingStatus = 'active';
      final session = SessionRef(
        computerId: target.id,
        provider: Provider.codex,
        environment: 'local',
        id: sessionA.id,
      );
      repository.onNotificationEvents = (_) async => NotificationBatch(
        enabled: true,
        scope: 'scope',
        events: [
          NotificationEvent(
            id: 'event',
            kind: 'completion',
            createdAt: 100,
            session: session,
          ),
        ],
      );
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
      push.pendingTap = NotificationTap(target.id, 'scope', 'event');
      await push.resume();
      await tester.pump();
      expect(repository.connects, 0);
      expect(push.pendingTap, isNotNull);
      finishWrite.complete();
      await tester.pumpAndSettle();
      expect(repository.connects, 0);
      expect(push.pendingTap, isNotNull);
      directory.complete([
        CloudDiscoveredDevice(
          bindingId: target.id,
          gateway: CloudGateway(
            origin: officialCloudOrigin,
            id: 'gateway',
            name: target.name,
            controlPublicKey: 'desktop-key',
            online: true,
          ),
          status: CloudDeviceStatus.active,
          accessRevision: 1,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(repository.connects, 1);
      expect(model.computer?.id, target.id);
      expect(model.selected, session);
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
      await tester.ensureVisible(
        find.byKey(const Key('settings-cloud-service')),
      );
      await tester.pumpAndSettle();
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
