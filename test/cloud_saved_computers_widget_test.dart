import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/ui/cloud_home.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';

import 'support/cloud_home_test_support.dart';

void main() {
  for (final locale in ['zh', 'en']) {
    testWidgets(
      'signed-out cloud stays hidden on home and saved-server info remains non-destructive in $locale',
      (tester) async {
        final strings = Strings(Locale(locale));
        final repository = FakeCloudRepository();
        final account = await repository.cloudAccounts.signIn(
          selfhostOrigin,
          'user',
          'password',
        );
        await repository.cloudAccounts.signOut(account);
        final computer = cloudComputer();
        await repository.saveComputer(computer);
        final model = BridgeViewModel(repository);
        await model.initialize();
        model.setAppearance(locale: locale);
        await tester.pumpWidget(
          BridgeApp(repository: repository, viewModel: model),
        );
        await tester.pumpAndSettle();
        final card = find.byKey(ValueKey('computer-card-${computer.id}'));
        final dismissible = find.byKey(
          ValueKey('remove-computer-${computer.id}'),
        );
        expect(card, findsNothing);
        expectOfficialAddressHidden();
        expect(find.text(selfhostOrigin), findsNothing);
        expectHomeCloudSummaryRemoved();
        expect(dismissible, findsNothing);
        expect(find.byKey(const Key('remove-connection-dialog')), findsNothing);
        expect(repository.removedComputerIds, isEmpty);
        expect(repository.savedComputers, contains(computer));
        expect(find.byKey(const Key('saved-computers-menu')), findsNothing);
        tester.widget<CloudHome>(find.byType(CloudHome)).onComputer(computer);
        await tester.pumpAndSettle();
        expectOfficialAddressHidden();
        expect(repository.connects, 0);
        await tester.tap(find.byKey(const Key('open-cloud-for-connection')));
        await tester.pumpAndSettle();
        expectOfficialAddressHidden();
        expect(find.text(strings.t('Saved connection server')), findsOneWidget);
        expect(find.text(selfhostOrigin), findsOneWidget);

        await tester.tap(find.byKey(const Key('use-saved-connection-server')));
        await tester.pumpAndSettle();
        expectOfficialAddressHidden();
        expect(
          find.byKey(const Key('confirm-cloud-server-switch')),
          findsNothing,
        );
        expectOfficialAddressHidden();
        expect(find.byKey(const Key('current-cloud-origin')), findsNothing);
        expect(repository.api.logoutOrigins, [selfhostOrigin]);
        expect(repository.api.capabilityOrigins.last, officialCloudOrigin);
        expect(repository.connects, 0);
        await closeCloudApp(tester, model);
      },
    );

    testWidgets('official relay reconnect uses its name in $locale', (
      tester,
    ) async {
      final repository = FakeCloudRepository();
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      final computer = cloudComputer();
      await repository.saveComputer(computer);
      repository.onConnect = (_) async => throw StateError('Network error');
      final model = BridgeViewModel(repository);
      await model.initialize();
      model.setAppearance(locale: locale);
      await model.selectComputer(computer);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      expectOfficialAddressHidden();
      expect(
        find.text(Strings(Locale(locale)).t('Official cloud')),
        findsOneWidget,
      );
      expect(
        find.text(Strings(Locale(locale)).t('Manage cloud service')),
        findsOneWidget,
      );
      expect(model.computer?.relay?.origin, officialCloudOrigin);
      await closeCloudApp(tester, model);
    });

    for (final width in [320.0, 1280.0]) {
      testWidgets(
        'cloud home and management fit $locale at ${width.toInt()}px with large text',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = 1.8;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final repository = FakeCloudRepository();
          await repository.cloudAccounts.signIn(
            officialCloudOrigin,
            'a-long-cloud-account-name@example.com',
            'password',
          );
          await repository.saveComputer(cloudComputer());
          final model = BridgeViewModel(repository);
          await model.initialize();
          model.setAppearance(
            locale: locale,
            theme: locale == 'zh' ? 'light' : 'dark',
          );
          await tester.pumpWidget(
            BridgeApp(repository: repository, viewModel: model),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('No cloud relay'), findsNothing);
          final cloudChoice = tester.getRect(
            find.byKey(const Key('cloud-connection-option')),
          );
          final directChoice = tester.getRect(
            find.byKey(const Key('direct-connection-option')),
          );
          if (width == 320) {
            expect(directChoice.top, greaterThan(cloudChoice.bottom));
          } else {
            expect(cloudChoice.top, closeTo(directChoice.top, .01));
            expect(cloudChoice.left, lessThan(directChoice.left));
          }
          expect(
            tester
                .getRect(find.byKey(const Key('saved-computers-section')))
                .top,
            greaterThan(directChoice.bottom),
          );
          expectHomeCloudSummaryRemoved();
          await openCloudService(tester, strings: Strings(Locale(locale)));
          expect(tester.takeException(), isNull);
          expectServicePanelsRemoved(strings: Strings(Locale(locale)));
          await tester.ensureVisible(find.byKey(const Key('cloud-sign-out')));
          expect(tester.takeException(), isNull);
          await closeCloudApp(tester, model);
        },
      );
    }
  }
}
