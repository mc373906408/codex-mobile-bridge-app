import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/data/bridge_types.dart';
import 'package:bridge_mobile/ui/cloud_dialog.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:bridge_mobile/viewmodels/cloud_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';

import 'support/cloud_home_test_support.dart';

void main() {
  testWidgets(
    'automatic discovery uses the selected account and info stays read-only until desktop permission',
    (tester) async {
      final repository = FakeCloudRepository();
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      var status = CloudDeviceStatus.pending;
      var revision = 0;
      repository.api.onDevices = (origin, _) async => [
        CloudDiscoveredDevice(
          gateway: CloudGateway(
            origin: origin,
            id: 'manual-test-gateway',
            name: 'Cloud studio',
            controlPublicKey: 'desktop-key',
            online: true,
          ),
          bindingId: 'manual-test-binding',
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
      expect(find.text('Official cloud'), findsOneWidget);
      expect(find.byKey(const Key('cloud-login')), findsNothing);
      expect(find.text('Password'), findsNothing);
      expect(find.byKey(const Key('cloud-computer-name')), findsNothing);
      expect(find.text('Request pairing'), findsNothing);
      expect(
        find.byKey(const Key('cloud-pairing-safety-code')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('connect-cloud-device')), findsNothing);

      expect(repository.connects, 0);
      await tester.pump(const Duration(minutes: 10));
      await tester.pumpAndSettle();

      expect(model.authenticated, false);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Device info'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('cloud-pairing-safety-code')),
        findsOneWidget,
      );
      status = CloudDeviceStatus.active;
      revision++;
      repository.pairingStatus = 'active';
      await cloud.syncDevices();
      await tester.pumpAndSettle();
      expect(model.authenticated, false);
      expect(repository.connects, 0);
      expect(repository.api.discoveryPreparations, 1);
      await tester.tap(find.byKey(const Key('connect-cloud-device')));
      await tester.pumpAndSettle();
      expect(find.byType(CloudConnectionDialog), findsNothing);
      expect(model.authenticated, true);

      expect(repository.connects, 1);

      await closeCloudApp(tester, model);
      cloud.dispose();
    },
  );
}
