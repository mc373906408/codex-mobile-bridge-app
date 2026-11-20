import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/data/bridge_types.dart';
import 'package:bridge_mobile/ui/cloud_dialog.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:bridge_mobile/viewmodels/cloud_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';

import 'support/cloud_home_test_support.dart';

void main() {
  testWidgets(
    'a broken saved pairing requests only its replacement and waits for approval',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 650);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final repository = FakeCloudRepository()
        ..pairingError = StateError(
          'The desktop could not verify the saved cloud pairing keys',
        );
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      var requests = 0;
      var status = CloudDeviceStatus.active;
      repository.api.onPairingRequest = (gateway, replace) async {
        expect(gateway.id, 'recovery-gateway');
        expect(replace, 'old-binding');
        requests++;
        status = CloudDeviceStatus.pending;
        repository.pairingError = null;
        return CloudDiscoveredDevice(
          gateway: gateway,
          bindingId: 'new-binding',
          status: status,
          accessRevision: 0,
          accessAllowed: false,
        );
      };
      repository.api.onDevices = (origin, _) async => [
        CloudDiscoveredDevice(
          gateway: CloudGateway(
            origin: origin,
            id: 'recovery-gateway',
            name: 'Desktop',
            controlPublicKey: 'desktop-key',
            online: true,
          ),
          bindingId: requests == 0 ? 'old-binding' : 'new-binding',
          status: status,
          accessRevision: status == CloudDeviceStatus.active ? 1 : 0,
        ),
      ];
      final model = BridgeViewModel(repository);
      await model.initialize();
      final cloud = CloudViewModel(
        accounts: repository.cloudAccounts,
        bridge: model,
      );
      await cloud.initialize();

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: CloudConnectionDialog(
            model: model,
            cloud: cloud,
            computer: cloud.devices.single.computer,
            strings: const Strings(Locale('zh')),
          ),
        ),
      );
      final recovery = find.byKey(const Key('start-cloud-pairing'));
      await tester.tap(recovery);
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(cloud.devices.single.computer.id, 'new-binding');
      expect(find.byKey(const Key('paste-cloud-pairing-qr')), findsOneWidget);
      expect(find.byKey(const Key('connect-cloud-device')), findsNothing);
      expect(repository.connects, 0);

      status = CloudDeviceStatus.active;
      repository.pairingStatus = 'active';
      await cloud.syncDevices();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('connect-cloud-device')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      cloud.dispose();
      model.dispose();
    },
  );

  testWidgets('unreadable desktop pairing response remains blocked and clear', (
    tester,
  ) async {
    final repository = FakeCloudRepository()
      ..pairingError = StateError(
        'Incompatible gateway response: relay pairing validation failed: desktop gateway secure response authentication failed',
      );
    await repository.cloudAccounts.signIn(
      officialCloudOrigin,
      'user@example.com',
      'password',
    );
    repository.api.onDevices = (origin, _) async => [
      CloudDiscoveredDevice(
        gateway: CloudGateway(
          origin: origin,
          id: 'pairing-error-gateway',
          name: 'Desktop',
          controlPublicKey: 'desktop-key',
          online: true,
        ),
        bindingId: 'pairing-error-binding',
        status: CloudDeviceStatus.active,
        accessRevision: 1,
        accessAllowed: true,
      ),
    ];
    final model = BridgeViewModel(repository);
    await model.initialize();
    final cloud = CloudViewModel(
      accounts: repository.cloudAccounts,
      bridge: model,
    );
    await cloud.initialize();
    final computer = cloud.devices.single.computer;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => CloudConnectionDialog(
                  model: model,
                  cloud: cloud,
                  computer: computer,
                  strings: const Strings(Locale('en')),
                ),
              ),
              child: const Text('Device info'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Device info'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Desktop approval confirmed; encrypted identity verification failed',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'The desktop gateway secure response could not be authenticated. Check the desktop gateway connection and update the gateway if needed.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('connect-cloud-device')), findsNothing);
    expect(repository.connects, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    cloud.dispose();
    model.dispose();
  });

  testWidgets(
    'selecting an unpaired computer requests it once and connects after scan and approval',
    (tester) async {
      final repository = FakeCloudRepository();
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      var status = CloudDeviceStatus.unpaired;
      var revision = 0;
      var requests = 0;
      repository.api.onPairingRequest = (gateway, replace) async {
        expect(gateway.id, 'manual-test-gateway');
        expect(replace, isNull);
        requests++;
        status = CloudDeviceStatus.pending;
        return CloudDiscoveredDevice(
          gateway: gateway,
          bindingId: 'manual-test-binding',
          status: status,
          accessRevision: 0,
        );
      };
      repository.api.onDevices = (origin, _) async => [
        CloudDiscoveredDevice(
          gateway: CloudGateway(
            origin: origin,
            id: 'manual-test-gateway',
            name: 'Cloud studio',
            controlPublicKey: 'desktop-key',
            online: true,
          ),
          bindingId: status == CloudDeviceStatus.unpaired
              ? ''
              : 'manual-test-binding',
          status: status,
          accessRevision: revision,
        ),
      ];
      final model = BridgeViewModel(repository);
      await model.initialize();
      final cloud = CloudViewModel(
        accounts: repository.cloudAccounts,
        bridge: model,
      );
      await cloud.initialize();
      final computer = cloud.devices.single.computer;
      expect(computer.relay!.origin, officialCloudOrigin);
      expect(computer.relay!.accountId, cloudAccountId);
      expect(requests, 0);
      expect(repository.api.discoveryPreparations, 0);
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': 'test-qr'};
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => CloudConnectionDialog(
                    model: model,
                    cloud: cloud,
                    computer: computer,
                    strings: const Strings(Locale('en')),
                  ),
                ),
                child: const Text('Device info'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Device info'));
      await tester.pumpAndSettle();
      expectOfficialAddressHidden();
      expect(requests, 1);
      expect(find.byKey(const Key('cloud-login')), findsNothing);
      expect(find.text('Password'), findsNothing);
      expect(find.byKey(const Key('cloud-computer-name')), findsNothing);
      expect(find.text('Request pairing'), findsNothing);
      expect(find.byKey(const Key('paste-cloud-pairing-qr')), findsOneWidget);
      expect(find.byKey(const Key('connect-cloud-device')), findsNothing);

      await tester.tap(find.byKey(const Key('paste-cloud-pairing-qr')));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for desktop approval'), findsOneWidget);
      expect(repository.pairingScans, ['test-qr']);
      expect(repository.connects, 0);
      status = CloudDeviceStatus.active;
      revision++;
      repository.pairingStatus = 'active';
      await cloud.syncDevices();
      await tester.pumpAndSettle();
      expect(repository.api.discoveryPreparations, 1);
      expect(find.byType(CloudConnectionDialog), findsNothing);
      expect(model.authenticated, true);

      expect(repository.connects, 1);
      expect(requests, 1);

      await closeCloudApp(tester, model);
      cloud.dispose();
    },
  );
}
