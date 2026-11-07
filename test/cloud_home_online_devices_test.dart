import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/data/bridge_types.dart';
import 'package:bridge_mobile/ui/cloud_home.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:bridge_mobile/viewmodels/cloud_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';
import 'support/fake_repository.dart';

CloudDiscoveredDevice homeDevice({
  String binding = 'online-binding',
  String gateway = 'online-gateway',
  bool online = true,
  CloudDeviceStatus status = CloudDeviceStatus.pending,
}) => CloudDiscoveredDevice(
  gateway: CloudGateway(
    origin: officialCloudOrigin,
    id: gateway,
    name: 'Desktop',
    controlPublicKey: 'desktop-key',
    online: online,
  ),
  bindingId: binding,
  status: status,
  accessRevision: 0,
);

Finder homeCard(String id) => find.byKey(ValueKey('computer-card-$id'));

void expectHomeCount(int count) {
  expect(
    find.descendant(
      of: find.byKey(const Key('saved-computers-section')),
      matching: find.text('$count'),
    ),
    findsOneWidget,
  );
}

Future<void> showOnlineHome(
  WidgetTester tester,
  BridgeViewModel bridge,
  CloudViewModel cloud, {
  String locale = 'en',
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: ListenableBuilder(
        listenable: Listenable.merge([bridge, cloud]),
        builder: (context, _) => CloudHome(
          model: bridge,
          cloud: cloud,
          strings: Strings(Locale(locale)),
          onCloud: () {},
          onComputer: (_) {},
        ),
      ),
    ),
  ),
);

void main() {
  late FakeCloudRepository repository;
  late BridgeViewModel bridge;
  late CloudViewModel cloud;

  Future<void> initializeFixture() async {
    repository = FakeCloudRepository()..savedComputers = [];
    bridge = BridgeViewModel(repository);
    await bridge.initialize();
    await repository.cloudAccounts.signIn(
      officialCloudOrigin,
      'user@example.com',
      'password',
    );
    cloud = CloudViewModel(accounts: repository.cloudAccounts, bridge: bridge);
  }

  Future<void> runHomeTest(
    WidgetTester tester,
    Future<void> Function() work,
  ) async {
    // Account queues and their timers must belong to this widget test's async zone.
    await initializeFixture();
    try {
      await work();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      cloud.dispose();
      bridge.dispose();
      await tester.pump();
    }
  }

  for (final locale in ['en', 'zh']) {
    testWidgets(
      'home hides the offline namesake but keeps online pending and direct devices in $locale',
      (tester) => runHomeTest(tester, () async {
        final cached = cloudComputer(id: 'unconfirmed-binding');
        await repository.saveComputer(computerA);
        await repository.saveComputer(cached);
        await bridge.reloadComputers();
        repository.api.onDevices = (_, _) async => [
          homeDevice(),
          homeDevice(
            binding: 'offline-binding',
            gateway: 'offline-gateway',
            online: false,
            status: CloudDeviceStatus.active,
          ),
        ];
        await cloud.initialize();
        final saved = List<Computer>.of(repository.savedComputers);
        await showOnlineHome(tester, bridge, cloud, locale: locale);
        await tester.pumpAndSettle();

        final card = homeCard('online-binding');
        final strings = Strings(Locale(locale));
        expect(card, findsOneWidget);
        expect(homeCard('offline-binding'), findsNothing);
        expect(homeCard(cached.id), findsNothing);
        expect(homeCard(computerA.id), findsOneWidget);
        expectHomeCount(2);
        expect(find.text('Desktop'), findsOneWidget);
        expect(
          find.descendant(of: card, matching: find.text(strings.t('Online'))),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: card,
            matching: find.text(strings.t('Waiting for desktop permission')),
          ),
          findsNothing,
        );
        for (final label in [
          'P2P direct',
          'Cloud relay',
          'Official cloud',
          'Connection allowed on desktop',
        ]) {
          expect(
            find.descendant(of: card, matching: find.text(strings.t(label))),
            findsNothing,
          );
        }
        if (locale == 'zh') {
          expect(find.text('Online'), findsNothing);
          expect(find.text('在线'), findsOneWidget);
        }
        expect(cloud.canConnect(cloud.devices.first.computer), false);
        expect(
          find.byKey(const ValueKey('remove-computer-online-binding')),
          findsNothing,
        );
        await tester.ensureVisible(card);
        await tester.drag(card, Offset(-tester.getSize(card).width * .75, 0));
        await tester.pumpAndSettle();
        expect(homeCard('online-binding'), findsOneWidget);
        expect(find.byKey(const Key('remove-connection-dialog')), findsNothing);
        expect(repository.savedComputers, saved);
        expect(cloud.devices.length, 2);
        expect(repository.removedComputerIds, isEmpty);

        expect(repository.connects, 0);
        expect(tester.takeException(), isNull);
      }),
    );

    testWidgets(
      'all offline cloud devices produce a non-destructive empty home in $locale',
      (tester) => runHomeTest(tester, () async {
        repository.api.onDevices = (_, _) async => [homeDevice(online: false)];
        await cloud.initialize();
        final saved = List<Computer>.of(repository.savedComputers);
        await showOnlineHome(tester, bridge, cloud, locale: locale);
        await tester.pumpAndSettle();

        final strings = Strings(Locale(locale));
        expect(homeCard('online-binding'), findsNothing);
        expectHomeCount(0);
        expect(
          find.text(strings.t('No online cloud computers')),
          findsOneWidget,
        );
        expect(
          find.text(
            strings.t(
              'Offline cloud computers stay saved and reappear automatically when they reconnect.',
            ),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('add-local-computer')), findsOneWidget);
        expect(repository.savedComputers, saved);
        expect(cloud.devices.length, 1);
        expect(repository.removedComputerIds, isEmpty);
        expect(tester.takeException(), isNull);
      }),
    );
  }

  testWidgets(
    'online transitions hide and restore the same cloud card without deleting keys or drafts',
    (tester) => runHomeTest(tester, () async {
      var online = true;
      repository.api.onDevices = (_, _) async => [homeDevice(online: online)];
      await cloud.initialize();
      await showOnlineHome(tester, bridge, cloud);
      await tester.pumpAndSettle();
      final saved = List<Computer>.of(repository.savedComputers);
      final preparations = repository.api.discoveryPreparations;
      bridge.draftText = 'Keep this unsent draft';
      expect(homeCard('online-binding'), findsOneWidget);
      expectHomeCount(1);

      online = false;
      await cloud.syncDevices();
      await tester.pumpAndSettle();
      expect(homeCard('online-binding'), findsNothing);
      expectHomeCount(0);
      expect(repository.savedComputers, saved);
      expect(bridge.draftText, 'Keep this unsent draft');

      online = true;
      await cloud.syncDevices();
      await tester.pumpAndSettle();
      expect(homeCard('online-binding'), findsOneWidget);
      expectHomeCount(1);
      expect(repository.savedComputers, saved);
      expect(repository.api.discoveryPreparations, preparations);
      expect(repository.removedComputerIds, isEmpty);

      expect(bridge.draftText, 'Keep this unsent draft');
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'a failed directory read hides stale cloud cards but preserves direct devices',
    (tester) => runHomeTest(tester, () async {
      await repository.saveComputer(computerA);
      await bridge.reloadComputers();
      repository.api.onDevices = (_, _) async => [homeDevice()];
      await cloud.initialize();
      await showOnlineHome(tester, bridge, cloud);
      await tester.pumpAndSettle();
      final saved = List<Computer>.of(repository.savedComputers);
      expect(homeCard('online-binding'), findsOneWidget);
      expectHomeCount(2);

      repository.api.onDevices = (_, _) async =>
          throw StateError('Network error');
      await cloud.syncDevices();
      await tester.pumpAndSettle();
      expect(homeCard('online-binding'), findsNothing);
      expect(homeCard(computerA.id), findsOneWidget);
      expectHomeCount(1);
      expect(find.byKey(const Key('cloud-discovery-error')), findsOneWidget);
      expect(repository.savedComputers, saved);
      expect(cloud.devices.single.device.gateway.online, true);
      expect(repository.removedComputerIds, isEmpty);

      repository.api.onDevices = (_, _) async => [homeDevice()];
      await cloud.syncDevices();
      await tester.pumpAndSettle();
      expect(homeCard('online-binding'), findsOneWidget);
      expectHomeCount(2);
      expect(tester.takeException(), isNull);
    }),
  );
}
