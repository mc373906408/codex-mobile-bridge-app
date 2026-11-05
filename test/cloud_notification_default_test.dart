import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/notifications/cloud_push_bridge.dart';
import 'package:bridge_mobile/notifications/cloud_push_controller.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';

void main() {
  for (final restored in [false, true]) {
    for (final locale in ['zh', 'en']) {
      testWidgets(
        'cloud login enables notifications without a switch ($locale, restored=$restored)',
        (tester) async {
          tester.view.physicalSize = const Size(360, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final repository = FakeCloudRepository();
          if (restored) {
            await repository.cloudAccounts.signIn(
              officialCloudOrigin,
              'user@example.com',
              'password',
            );
          }
          final model = BridgeViewModel(repository);
          await model.initialize();
          model.setAppearance(locale: locale);
          final native = FakeCloudPushBridge()
            ..current = const CloudPushState(
              configured: true,
              allowed: true,
              interactive: true,
              platform: 'umeng',
              appId: 'app',
              token: 'synthetic-token',
            );
          final push = CloudPushController(repository, native, interval: null);
          final strings = Strings(Locale(locale));
          await tester.pumpWidget(
            BridgeApp(
              repository: repository,
              viewModel: model,
              cloudPush: push,
            ),
          );
          await tester.pumpAndSettle();
          expect(native.consentWrites, restored ? 1 : 0);

          await tester.tap(find.byKey(const Key('cloud-primary-action')));
          await tester.pumpAndSettle();
          if (!restored) {
            await tester.enterText(
              find.byKey(const Key('cloud-login')),
              'user@example.com',
            );
            await tester.enterText(
              find.byKey(const Key('cloud-password')),
              'password',
            );
            final signIn = find.byKey(const Key('cloud-sign-in'));
            await tester.ensureVisible(signIn);
            await tester.tap(signIn);
            await tester.pumpAndSettle();
          }
          expect(native.current.consent, isTrue);
          expect(native.consentWrites, 1);
          expect(native.permissionRequests, 0);
          expect(
            find.byKey(const Key('cloud-notification-consent')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('accept-cloud-notifications')),
            findsNothing,
          );
          expect(find.byType(AlertDialog), findsNothing);
          expect(repository.connects, 0);

          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip(strings.t('Settings')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('cloud-notification-consent')),
            findsNothing,
          );
          await push.resume();
          await tester.pumpAndSettle();
          expect(native.consentWrites, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          model.dispose();
          await tester.pump();
        },
      );
    }
  }
}
