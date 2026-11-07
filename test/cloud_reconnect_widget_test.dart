import 'dart:async';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/src/rust/api/types.dart';
import 'package:bridge_mobile/ui/cloud_home.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:bridge_mobile/viewmodels/cloud_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';
import 'support/fake_repository.dart';

CloudDiscoveredDevice device({
  CloudDeviceStatus status = CloudDeviceStatus.active,
  String publicKey = 'desktop-key',
  int revision = 1,
}) => CloudDiscoveredDevice(
  gateway: CloudGateway(
    origin: officialCloudOrigin,
    id: 'gateway',
    name: 'Cloud studio',
    controlPublicKey: publicKey,
    online: true,
  ),
  bindingId: 'cloud-computer',
  status: status,
  accessRevision: revision,
);

Future<void> pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<void> runCloudTest(
  WidgetTester tester,
  Future<void> Function(
    FakeCloudRepository repository,
    BridgeViewModel model,
    CloudViewModel cloud,
  )
  body, {
  CloudDeviceStatus status = CloudDeviceStatus.active,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repository = FakeCloudRepository()
    ..savedComputers = []
    ..pairingStatus = status.name;
  repository.api.onDevices = (_, _) async => [device(status: status)];
  await repository.cloudAccounts.signIn(
    officialCloudOrigin,
    'synthetic@example.com',
    'synthetic-password',
  );
  final model = BridgeViewModel(repository);
  await model.initialize();
  try {
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    final cloud = tester.widget<CloudHome>(find.byType(CloudHome)).cloud!;
    await body(repository, model, cloud);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
  }
}

Future<void> selectCloud(WidgetTester tester) async {
  final card = find.byKey(const ValueKey('computer-card-cloud-computer'));
  await tester.ensureVisible(card);
  await tester.tap(card);
  await pumpFrames(tester);
}

void expectConnectingList() {
  expect(find.byKey(const Key('cloud-device-info')), findsNothing);
  expect(find.byKey(const Key('cloud-pairing-safety-code')), findsNothing);
  expect(find.text('Chats'), findsWidgets);
  expect(find.byType(LinearProgressIndicator), findsOneWidget);
}

void main() {
  for (final resume in [false, true]) {
    testWidgets(
      'known desktop connects independently of ${resume ? 'unlock' : 'service refresh'}',
      (tester) => runCloudTest(tester, (repository, model, cloud) async {
        await selectCloud(tester);
        await tester.pumpAndSettle();
        expect(model.authenticated, isTrue);
        expect(repository.connects, 1);
        await tester.tap(find.byKey(const ValueKey('tab-computers')));
        await tester.pumpAndSettle();

        final service = Completer<CloudCapabilities>();
        repository.api.onCapabilities = (_) => service.future;
        Future<void>? refreshing;
        if (resume) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await pumpFrames(tester);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else {
          refreshing = cloud.refresh();
        }
        await pumpFrames(tester);
        expect(cloud.canConnect(cloud.devices.single.computer), isTrue);
        final existingConnections = repository.connects;
        await selectCloud(tester);
        await tester.pumpAndSettle();
        expect(model.authenticated, isTrue);
        expect(repository.connects, existingConnections);

        service.complete(hostedCapabilities);
        await refreshing;
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('cloud-device-info')), findsNothing);
        expect(find.text('A quieter workspace'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(model.authenticated, isTrue);
        expect(repository.connects, existingConnections);
        expect(repository.creates, 0);
        expect(repository.sends, 0);
      }),
    );
  }

  testWidgets(
    'first pending connection still offers the safety code',
    (tester) => runCloudTest(tester, (repository, model, cloud) async {
      await selectCloud(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cloud-device-info')), findsOneWidget);
      expect(
        find.byKey(const Key('cloud-pairing-safety-code')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('connect-cloud-device')), findsNothing);
      expect(repository.connects, 0);
      expect(model.authenticated, isFalse);
    }, status: CloudDeviceStatus.pending),
  );

  for (final outcome in ['home', 'disabled', 'identity']) {
    testWidgets(
      'pending reconnect respects $outcome before gateway access',
      (tester) => runCloudTest(tester, (repository, model, cloud) async {
        final authentication = Completer<AuthStatus>();
        repository.onConnect = (_) => authentication.future;
        await pumpFrames(tester);
        await selectCloud(tester);
        expectConnectingList();
        if (outcome == 'home') {
          await tester.tap(find.byKey(const ValueKey('tab-computers')));
          await pumpFrames(tester);
        } else if (outcome == 'disabled') {
          repository.api.onDevices = (_, _) async => [
            device(status: CloudDeviceStatus.disabled, revision: 2),
          ];
        } else if (outcome == 'identity') {
          repository.api.onDevices = (_, _) async => [
            device(publicKey: 'different-desktop-key', revision: 2),
          ];
        }
        if (outcome != 'home') await cloud.syncDevices();
        authentication.complete(authenticatedStatus);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('cloud-device-info')), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(repository.connects, 1);
        expect(model.authenticated, outcome == 'home');
        if (outcome == 'home') {
          expect(model.computer?.id, 'cloud-computer');
          expect(find.byKey(const Key('cloud-home-scroll')), findsOneWidget);
        }
        expect(
          repository.savedComputers.single.relay!.desktopPublicKey,
          'desktop-key',
        );
      }),
    );
  }
}
