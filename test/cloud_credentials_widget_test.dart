import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';

import 'support/cloud_home_test_support.dart';

void main() {
  for (final locale in ['zh', 'en']) {
    for (final theme in ['light', 'dark']) {
      for (final selfHosted in [false, true]) {
        testWidgets(
          'cloud credentials use visible boxes and no counters in $locale $theme selfhost=$selfHosted',
          (tester) async {
            tester.view.physicalSize = const Size(320, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final repository = FakeCloudRepository();
            if (selfHosted) {
              repository.vault.values['bridge.cloud.selection.v1'] =
                  '{"origin":"$selfhostOrigin","accountId":null}';
            }
            final model = BridgeViewModel(repository);
            await model.initialize();
            model.setAppearance(locale: locale, theme: theme);
            final strings = Strings(Locale(locale));
            await tester.pumpWidget(
              BridgeApp(repository: repository, viewModel: model),
            );
            await tester.pumpAndSettle();
            await openCloudService(tester, strings: strings);
            expectClearCloudLoginFields(tester, strings);
            await tester.enterText(
              find.byKey(const Key('cloud-login')),
              'custom_account',
            );
            await tester.enterText(
              find.byKey(const Key('cloud-password')),
              'password',
            );
            expectClearCloudLoginFields(tester, strings);
            expect(tester.takeException(), isNull);
            expect(repository.api.loginOrigins, isEmpty);
            await closeCloudApp(tester, model);
          },
        );
      }
    }
  }

  testWidgets(
    'cloud account input keeps length limits without displaying counters',
    (tester) async {
      final repository = FakeCloudRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      await openCloudService(tester);
      await tester.enterText(find.byKey(const Key('cloud-login')), 'a' * 321);
      expect(
        cloudCredentialField(tester, 'cloud-login').controller!.text.length,
        320,
      );
      await tester.enterText(
        find.byKey(const Key('cloud-password')),
        'b' * 1025,
      );
      expect(
        cloudCredentialField(tester, 'cloud-password').controller!.text.length,
        1024,
      );
      expectClearCloudLoginFields(tester, const Strings(Locale('en')));
      expect(repository.api.loginOrigins, isEmpty);
      await closeCloudApp(tester, model);
    },
  );

  testWidgets('custom account names are accepted by the unified login field', (
    tester,
  ) async {
    final repository = FakeCloudRepository();
    final model = BridgeViewModel(repository);
    await model.initialize();
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    await openCloudService(tester);
    await tester.enterText(
      find.byKey(const Key('cloud-login')),
      'custom_account',
    );
    await tester.enterText(find.byKey(const Key('cloud-password')), 'password');
    await tester.ensureVisible(find.byKey(const Key('cloud-sign-in')));
    await tester.tap(find.byKey(const Key('cloud-sign-in')));
    await tester.pumpAndSettle();
    expect(find.text('custom_account'), findsOneWidget);
    expect(find.byKey(const Key('signed-in-cloud-account')), findsOneWidget);
    expect(repository.api.loginOrigins, [officialCloudOrigin]);

    expect(repository.connects, 0);
    await closeCloudApp(tester, model);
  });
}
