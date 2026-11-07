import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/notifications/cloud_push_controller.dart';
import 'package:bridge_mobile/data/bridge_types.dart';
import 'package:bridge_mobile/ui/cloud_dialog.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';
import 'support/fake_repository.dart';

import 'support/cloud_home_test_support.dart';

void main() {
  for (final locale in ['zh', 'en']) {
    for (final theme in ['light', 'dark']) {
      for (final width in [320.0, 390.0]) {
        testWidgets(
          'cloud leads parallel first-screen actions in $locale $theme at ${width.toInt()}px',
          (tester) async {
            tester.view.physicalSize = Size(width, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final repository = FakeCloudRepository();
            if (theme == 'dark') {
              await repository.cloudAccounts.signIn(
                officialCloudOrigin,
                'user@example.com',
                'password',
              );
            }
            final loginCount = repository.api.loginOrigins.length;
            final model = BridgeViewModel(repository);
            await model.initialize();
            model.setAppearance(locale: locale, theme: theme);
            await tester.pumpWidget(
              BridgeApp(repository: repository, viewModel: model),
            );
            await tester.pumpAndSettle();

            final cloud = tester.getRect(
              find.byKey(const Key('cloud-connection-option')),
            );
            final direct = tester.getRect(
              find.byKey(const Key('direct-connection-option')),
            );
            final viewport = tester.getRect(
              find.byKey(const Key('cloud-home-scroll')),
            );
            expect(cloud.top, closeTo(direct.top, .01));
            expect(cloud.height, closeTo(direct.height, .01));
            expect(cloud.left, lessThan(direct.left));
            expect(cloud.top, greaterThanOrEqualTo(viewport.top));
            expect(direct.bottom, lessThanOrEqualTo(viewport.bottom));
            expect(
              tester
                  .getRect(find.byKey(const Key('cloud-primary-action')))
                  .bottom,
              closeTo(
                tester
                    .getRect(find.byKey(const Key('add-local-computer')))
                    .bottom,
                .01,
              ),
            );
            expect(
              tester
                  .getRect(find.byKey(const Key('saved-computers-section')))
                  .top,
              greaterThan(direct.bottom),
            );
            expect(
              tester
                  .widget<FilledButton>(
                    find.byKey(const Key('cloud-primary-action')),
                  )
                  .onPressed,
              isNotNull,
            );
            final strings = Strings(Locale(locale));
            expect(
              find.descendant(
                of: find.byKey(const Key('cloud-primary-action')),
                matching: find.text(
                  strings.t(theme == 'dark' ? 'Open cloud' : 'Sign in'),
                ),
              ),
              findsOneWidget,
            );
            expect(find.byKey(const Key('cloud-pair-action')), findsNothing);
            expect(find.byKey(const Key('cloud-sign-out')), findsNothing);
            expect(
              tester
                  .widget<OutlinedButton>(
                    find.byKey(const Key('add-local-computer')),
                  )
                  .onPressed,
              isNotNull,
            );
            expect(
              find.text(Strings(Locale(locale)).t('Your cloud workspace')),
              findsNothing,
            );
            expectHomeCloudSummaryRemoved();
            expectOfficialAddressHidden();
            expect(repository.connects, 0);
            expect(repository.api.loginOrigins.length, loginCount);
            expect(tester.takeException(), isNull);
            await closeCloudApp(tester, model);
          },
        );
      }
    }
  }

  for (final locale in ['zh', 'en']) {
    for (final theme in ['light', 'dark']) {
      testWidgets(
        'signed-in cloud entry opens first-screen controls in $locale $theme',
        (tester) async {
          tester.view.physicalSize = const Size(320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final repository = FakeCloudRepository();
          await repository.cloudAccounts.signIn(
            officialCloudOrigin,
            'user@example.com',
            'password',
          );
          final model = BridgeViewModel(repository);
          await model.initialize();
          model.setAppearance(locale: locale, theme: theme);
          final strings = Strings(Locale(locale));
          await tester.pumpWidget(
            BridgeApp(repository: repository, viewModel: model),
          );
          await tester.pumpAndSettle();

          expect(find.text(strings.t('Open cloud')), findsOneWidget);
          expect(find.byKey(const Key('cloud-pair-action')), findsNothing);
          expect(find.byKey(const Key('cloud-sign-out')), findsNothing);
          await tester.tap(find.byKey(const Key('cloud-primary-action')));
          await tester.pumpAndSettle();

          expect(find.text(strings.t('Cloud service')), findsOneWidget);
          expect(find.text(strings.t('Log out')), findsOneWidget);
          expect(find.text(strings.t('Request pairing')), findsNothing);
          expect(find.byType(CloudConnectionDialog), findsNothing);
          final viewport = tester.getRect(
            find.byKey(const Key('cloud-service-scroll')),
          );
          for (final key in ['cloud-sign-out']) {
            final action = tester.getRect(find.byKey(Key(key)));
            expect(action.top, greaterThanOrEqualTo(viewport.top));
            expect(action.bottom, lessThanOrEqualTo(viewport.bottom));
          }
          expectServerSelectionHidden(strings: strings);
          expectServicePanelsRemoved(strings: strings);
          expectOfficialAddressHidden();
          expect(repository.api.logoutOrigins, isEmpty);

          expect(repository.api.loginOrigins, [officialCloudOrigin]);
          expect(repository.connects, 0);
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          expect(find.text(strings.t('Open cloud')), findsOneWidget);
          expect(find.byKey(const Key('cloud-pair-action')), findsNothing);
          expect(find.byKey(const Key('cloud-sign-out')), findsNothing);
          expect(tester.takeException(), isNull);
          await closeCloudApp(tester, model);
        },
      );
    }
  }

  testWidgets(
    'direct order is retained while unconfirmed cloud entries stay hidden',
    (tester) async {
      final relay = cloudComputer();
      final computers = [computerB, relay, computerA];
      final repository = FakeCloudRepository()..savedComputers = computers;
      final model = BridgeViewModel(repository);
      await model.initialize();
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      final positions = [
        for (final computer in [computerB, computerA])
          tester
              .getTopLeft(find.byKey(ValueKey('computer-card-${computer.id}')))
              .dy,
      ];
      expect(positions[0], lessThan(positions[1]));
      expect(find.byKey(ValueKey('computer-card-${relay.id}')), findsNothing);
      expect(repository.savedComputers, computers);
      expect(repository.connects, 0);
      await closeCloudApp(tester, model);
    },
  );

  for (final cloudUnavailable in [false, true]) {
    testWidgets(
      'direct connects without cloud login or consent when cloud unavailable=$cloudUnavailable',
      (tester) async {
        final repository = FakeCloudRepository();
        if (cloudUnavailable) {
          repository.api.onCapabilities = (_) async =>
              throw StateError('Network error');
        }
        final model = BridgeViewModel(repository);
        await model.initialize();
        final native = FakeCloudPushBridge();
        final push = CloudPushController(repository, native, interval: null);
        await tester.pumpWidget(
          BridgeApp(repository: repository, viewModel: model, cloudPush: push),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('add-local-computer')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('cloud-login')), findsNothing);
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField && widget.decoration?.labelText == 'Name',
          ),
          'Direct workstation',
        );
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                widget.decoration?.labelText == 'Gateway address',
          ),
          'https://desktop.example',
        );
        await tester.tap(find.text('Save and connect'));
        await tester.pumpAndSettle();
        expect(model.computer?.connectionType, ConnectionType.direct);
        expect(model.computer?.name, 'Direct workstation');
        expect(repository.connects, 1);
        expect(repository.api.loginOrigins, isEmpty);

        expect(native.consentWrites, 0);
        expect(native.permissionRequests, 0);
        await closeCloudApp(tester, model);
      },
    );
  }
}
