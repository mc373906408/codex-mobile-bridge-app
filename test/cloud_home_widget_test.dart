import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/notifications/cloud_push_bridge.dart';
import 'package:bridge_mobile/notifications/cloud_push_controller.dart';
import 'package:bridge_mobile/notifications/notification_bridge.dart';
import 'package:bridge_mobile/src/rust/api/types.dart';
import 'package:bridge_mobile/ui/cloud_dialog.dart';
import 'package:bridge_mobile/ui/cloud_service_page.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:bridge_mobile/viewmodels/cloud_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';
import 'support/fake_repository.dart';

Future<void> closeCloudApp(WidgetTester tester, BridgeViewModel model) async {
  await tester.pumpWidget(const SizedBox.shrink());
  model.dispose();
  await tester.pump();
}

Future<void> enterCloudLogin(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('cloud-login')),
    'user@example.com',
  );
  await tester.enterText(find.byKey(const Key('cloud-password')), 'password');
  final button = find.byKey(const Key('cloud-sign-in'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void expectOfficialAddressHidden() {
  expect(
    find.textContaining(
      Uri.parse(officialCloudOrigin).host,
      skipOffstage: false,
    ),
    findsNothing,
  );
}

void expectHomeCloudSummaryRemoved() {
  for (final key in [
    'cloud-overview',
    'cloud-account-label',
    'cloud-service-status',
    'cloud-direct-notification-status',
    'cloud-background-push-status',
  ]) {
    expect(find.byKey(Key(key), skipOffstage: false), findsNothing);
  }
}

void expectServicePanelsRemoved({
  Strings strings = const Strings(Locale('en')),
}) {
  for (final key in [
    'cloud-service-status',
    'cloud-pair-computer',
    'cloud-direct-notification-status',
    'cloud-background-push-status',
    'cloud-notification-consent',
  ]) {
    expect(find.byKey(Key(key), skipOffstage: false), findsNothing);
  }
  for (final label in [
    'Service status',
    'Cloud task notifications',
    'Private cloud notifications',
  ]) {
    expect(find.text(strings.t(label)), findsNothing);
  }
}

void expectServerSelectionHidden({
  Strings strings = const Strings(Locale('en')),
}) {
  expect(find.text(strings.t('Cloud server')), findsNothing);
  for (final key in [
    'official-cloud-option',
    'selfhost-cloud-option',
    'current-cloud-origin',
    'use-saved-connection-server',
  ]) {
    expect(find.byKey(Key(key)), findsNothing);
  }
}

Future<void> openCloudService(
  WidgetTester tester, {
  Strings strings = const Strings(Locale('en')),
}) async {
  await tester.tap(find.byTooltip(strings.t('Settings')));
  await tester.pumpAndSettle();
  final link = find.byKey(const Key('settings-cloud-service'));
  await tester.ensureVisible(link);
  await tester.tap(link);
  await tester.pumpAndSettle();
}

TextField cloudCredentialField(WidgetTester tester, String key) =>
    tester.widget<TextField>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(TextField),
      ),
    );

void expectClearCloudLoginFields(WidgetTester tester, Strings strings) {
  expect(find.text(strings.t('Email / Account')), findsOneWidget);
  for (final key in ['cloud-login', 'cloud-password']) {
    final field = cloudCredentialField(tester, key);
    final decoration = field.decoration!;
    expect(decoration.counterText, '');
    expect(decoration.hintText, isNotEmpty);
    expect(decoration.filled, isTrue);
    for (final border in [
      decoration.enabledBorder,
      decoration.focusedBorder,
      decoration.disabledBorder,
      decoration.errorBorder,
      decoration.focusedErrorBorder,
    ]) {
      expect(border, isA<OutlineInputBorder>());
      expect(border!.borderSide.style, BorderStyle.solid);
      expect(border.borderSide.width, greaterThan(0));
    }
    expect(field.maxLength, key == 'cloud-login' ? 320 : 1024);
  }
  expect(cloudCredentialField(tester, 'cloud-password').obscureText, isTrue);
  expect(find.textContaining(RegExp(r'^\d+/(320|1024)$')), findsNothing);
}

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

  for (final offline in [false, true]) {
    testWidgets(
      'cloud control logout preserves saved computers${offline ? ' when offline' : ''}',
      (tester) async {
        final computers = [computerB, cloudComputer(), computerA];
        final repository = FakeCloudRepository()..savedComputers = computers;
        await repository.cloudAccounts.signIn(
          officialCloudOrigin,
          'user@example.com',
          'password',
        );
        if (offline) {
          repository.api.onLogout = (_) async => throw StateError('offline');
        }
        final model = BridgeViewModel(repository);
        await model.initialize();
        model.setAppearance(locale: 'zh');
        final native = FakeCloudPushBridge();
        final push = CloudPushController(repository, native, interval: null);
        await tester.pumpWidget(
          BridgeApp(repository: repository, viewModel: model, cloudPush: push),
        );
        await tester.pumpAndSettle();

        expect(find.text('进入云端'), findsOneWidget);
        expect(find.text('退出登录'), findsNothing);
        expect(find.byKey(const Key('cloud-pair-action')), findsNothing);
        await tester.tap(find.byKey(const Key('cloud-primary-action')));
        await tester.pumpAndSettle();
        expect(find.text('退出登录'), findsOneWidget);
        expectServerSelectionHidden(strings: const Strings(Locale('zh')));
        expect(find.byKey(const Key('cloud-pair-action')), findsNothing);
        expect(repository.api.logoutOrigins, isEmpty);
        await tester.tap(find.byKey(const Key('cloud-sign-out')));
        await tester.pumpAndSettle();

        expect(find.text('退出登录'), findsNothing);
        expect(find.text('登录'), findsOneWidget);
        expect(find.byKey(const Key('cloud-pair-action')), findsNothing);
        expect(find.byType(CloudConnectionDialog), findsNothing);
        expect(find.byKey(const Key('cloud-login')), findsOneWidget);
        expect(find.text('云端服务器'), findsOneWidget);
        expect(find.byKey(const Key('selfhost-cloud-option')), findsOneWidget);
        expect(repository.api.logoutOrigins, [officialCloudOrigin]);

        expect(repository.api.loginOrigins, [officialCloudOrigin]);
        expect(repository.connects, 0);
        expect(repository.savedComputers, computers);
        expect(repository.removedComputerIds, isEmpty);
        expect(native.consentWrites, 1);
        expect(native.permissionRequests, 1);
        if (offline) {
          expect(
            find.byKey(const Key('cloud-operation-error')),
            findsOneWidget,
          );
          expect(find.text('本机已退出并停用此账号，但暂无法确认服务器端退出是否成功。'), findsOneWidget);
        }
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text('登录'), findsOneWidget);
        expect(find.byKey(const Key('cloud-login')), findsNothing);
        for (final computer in computers) {
          expect(
            find.byKey(ValueKey('computer-card-${computer.id}')),
            computer.connectionType == ConnectionType.relay
                ? findsNothing
                : findsOneWidget,
          );
        }
        expectHomeCloudSummaryRemoved();
        expectOfficialAddressHidden();
        expect(tester.takeException(), isNull);
        await closeCloudApp(tester, model);
      },
    );
  }

  testWidgets('cloud controls are disabled during logout', (tester) async {
    final repository = FakeCloudRepository();
    await repository.cloudAccounts.signIn(
      officialCloudOrigin,
      'user@example.com',
      'password',
    );
    final logout = Completer<void>();
    repository.api.onLogout = (_) => logout.future;
    final model = BridgeViewModel(repository);
    await model.initialize();
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('cloud-primary-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cloud-sign-out')));
    await tester.pump();
    expect(repository.api.logoutOrigins, [officialCloudOrigin]);
    expect(find.byKey(const Key('cloud-pair-action')), findsNothing);
    expectServerSelectionHidden();
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('cloud-sign-out')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('cloud-primary-action'), skipOffstage: false),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('cloud-sign-out')));
    await tester.pump();
    expect(repository.api.logoutOrigins, [officialCloudOrigin]);

    logout.complete();
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.byKey(const Key('cloud-pair-action')), findsNothing);
    expect(find.byKey(const Key('cloud-sign-out')), findsNothing);
    expect(find.text('Cloud server'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);

    expect(repository.connects, 0);
    expect(tester.takeException(), isNull);
    await closeCloudApp(tester, model);
  });

  testWidgets('cloud entry and controls cannot run while backgrounded', (
    tester,
  ) async {
    final repository = FakeCloudRepository();
    await repository.cloudAccounts.signIn(
      officialCloudOrigin,
      'user@example.com',
      'password',
    );
    final model = BridgeViewModel(repository);
    await model.initialize();
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    final primary = find.byKey(const Key('cloud-primary-action'));
    final initialAction = tester.widget<FilledButton>(primary).onPressed!;
    await model.setForeground(false);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(primary).onPressed, isNull);
    initialAction();
    await tester.pumpAndSettle();
    expect(repository.api.logoutOrigins, isEmpty);
    expect(find.text('Open cloud'), findsOneWidget);
    expect(find.byKey(const Key('cloud-pair-action')), findsNothing);
    expect(find.byKey(const Key('cloud-sign-out')), findsNothing);

    await model.setForeground(true);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(primary).onPressed, isNotNull);
    await tester.tap(primary);
    await tester.pumpAndSettle();
    final signOut = find.byKey(const Key('cloud-sign-out'));
    final staleSignOut = tester.widget<OutlinedButton>(signOut).onPressed!;
    await model.setForeground(false);
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(signOut).onPressed, isNull);
    expect(find.byKey(const Key('cloud-pair-action')), findsNothing);
    staleSignOut();
    await tester.pumpAndSettle();
    expect(repository.api.logoutOrigins, isEmpty);

    expect(find.byType(CloudConnectionDialog), findsNothing);
    await model.setForeground(true);
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(signOut).onPressed, isNotNull);
    expect(find.byKey(const Key('cloud-pair-action')), findsNothing);
    expect(tester.takeException(), isNull);
    await closeCloudApp(tester, model);
  });

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
    'server selection is hidden until explicit logout and preserves computers',
    (tester) async {
      final repository = FakeCloudRepository();
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      final model = BridgeViewModel(repository);
      await model.initialize();
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      await openCloudService(tester);
      expectServerSelectionHidden();
      expect(repository.api.logoutOrigins, isEmpty);
      await tester.tap(find.byKey(const Key('cloud-sign-out')));
      await tester.pumpAndSettle();
      expect(find.text('Cloud server'), findsOneWidget);
      expect(repository.api.logoutOrigins, [officialCloudOrigin]);
      await tester.tap(find.byKey(const Key('selfhost-cloud-option')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('cloud-server-input')),
        ' $selfhostOrigin/ ',
      );
      await tester.tap(find.byKey(const Key('save-cloud-server')));
      await tester.pumpAndSettle();
      expect(repository.api.logoutOrigins, [officialCloudOrigin]);
      expect(find.text(selfhostOrigin), findsOneWidget);
      expect(find.byKey(const Key('current-cloud-origin')), findsOneWidget);
      expect(find.text('Email / Account'), findsOneWidget);
      expect(find.byKey(const Key('signed-in-cloud-account')), findsNothing);
      expect(repository.savedComputers, [computerA, computerB]);
      expect(repository.removedComputerIds, isEmpty);
      await enterCloudLogin(tester);
      expectServerSelectionHidden();
      expect(find.byKey(const Key('signed-in-cloud-account')), findsOneWidget);
      expect(repository.api.logoutOrigins, [officialCloudOrigin]);
      await closeCloudApp(tester, model);
    },
  );

  testWidgets('stale server choices cannot sign out an account or switch', (
    tester,
  ) async {
    final repository = FakeCloudRepository();
    final model = BridgeViewModel(repository);
    await model.initialize();
    final cloud = CloudViewModel(
      accounts: repository.cloudAccounts,
      bridge: model,
    );
    await cloud.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: CloudServicePage(
          cloud: cloud,
          strings: const Strings(Locale('en')),
          requestedOrigin: selfhostOrigin,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final staleSavedServer = tester
        .widget<OutlinedButton>(
          find.byKey(const Key('use-saved-connection-server')),
        )
        .onPressed!;
    final staleSelfhost = tester
        .widget<ChoiceChip>(find.byKey(const Key('selfhost-cloud-option')))
        .onSelected!;
    staleSelfhost(true);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('cloud-server-input')),
      selfhostOrigin,
    );
    // An input dialog opened while signed out must recheck current auth on save.
    await cloud.signIn('user@example.com', 'password');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-cloud-server')));
    await tester.pumpAndSettle();
    expectServerSelectionHidden();
    staleSavedServer();
    staleSelfhost(true);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(cloud.signedIn, true);
    expect(cloud.origin, officialCloudOrigin);
    expect(repository.api.logoutOrigins, isEmpty);
    await closeCloudApp(tester, model);
    cloud.dispose();
  });

  testWidgets(
    'hidden old-server entries still require explicit login when selected',
    (tester) async {
      final repository = FakeCloudRepository();
      await repository.cloudAccounts.signIn(selfhostOrigin, 'user', 'password');
      await repository.cloudAccounts.signIn(
        officialCloudOrigin,
        'user@example.com',
        'password',
      );
      final old = cloudComputer(origin: selfhostOrigin);
      await repository.saveComputer(old);
      final model = BridgeViewModel(repository);
      await model.initialize();
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(ValueKey('computer-card-${old.id}'));
      expect(card, findsNothing);
      await openCloudService(tester);
      await tester.tap(find.byKey(const Key('cloud-sign-out')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(card, findsNothing);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(old.name));
      await tester.pumpAndSettle();
      expect(find.text('Cloud login required'), findsOneWidget);
      expect(repository.connects, 0);
      await tester.tap(find.byKey(const Key('open-cloud-for-connection')));
      await tester.pumpAndSettle();
      expect(find.text('Saved connection server'), findsOneWidget);
      expect(
        find.byKey(const Key('use-saved-connection-server')),
        findsOneWidget,
      );
      expect(find.text('user@example.com'), findsOneWidget);
      expect(repository.api.logoutOrigins, [officialCloudOrigin]);
      expect(repository.connects, 0);
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
        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text(computer.name));
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

  if (const bool.fromEnvironment('BRIDGE_HOME_SCREENSHOTS')) {
    for (final (dark, signedIn) in const [
      (false, false),
      (false, true),
      (true, false),
      (true, true),
    ]) {
      final preview =
          '${dark ? 'dark' : 'light'}-${signedIn ? 'signed-in' : 'signed-out'}';
      testWidgets('render cloud home $preview preview', (tester) async {
        final cjk = File(r'C:\Windows\Fonts\simhei.ttf');
        final cjkBytes = Platform.isWindows && cjk.existsSync()
            ? ByteData.sublistView(cjk.readAsBytesSync())
            : null;
        for (final family in ['PlexSans', 'PlexMono']) {
          // Widget tests have no platform font fallback for local CJK previews.
          final loader = FontLoader(family)
            ..addFont(
              cjkBytes == null
                  ? rootBundle.load('assets/fonts/$family.ttf')
                  : Future.value(cjkBytes),
            );
          await loader.load();
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repository = FakeCloudRepository();
        if (signedIn) {
          await repository.cloudAccounts.signIn(
            officialCloudOrigin,
            'user@example.com',
            'password',
          );
          await repository.saveComputer(cloudComputer());
        }
        final model = BridgeViewModel(repository);
        await model.initialize();
        model.setAppearance(
          locale: cjkBytes == null ? 'en' : 'zh',
          theme: dark ? 'dark' : 'light',
        );
        final boundaryKey = GlobalKey();
        final native = FakeCloudPushBridge()
          ..current = CloudPushState(
            allowed: true,
            consent: dark,
            interactive: true,
          );
        final push = CloudPushController(repository, native, interval: null);
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: BridgeApp(
              repository: repository,
              viewModel: model,
              cloudPush: push,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expectHomeCloudSummaryRemoved();
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory(
            '.tmp/cloud-controls-inside-01a19f0a-20261103',
          )..createSync(recursive: true);
          await File('${directory.path}/home-$preview.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        final strings = Strings(Locale(cjkBytes == null ? 'en' : 'zh'));
        await openCloudService(tester, strings: strings);
        expectServicePanelsRemoved(strings: strings);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '.tmp/cloud-controls-inside-01a19f0a-20261103/service-$preview.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        if (signedIn) {
          await tester.tap(find.byKey(const Key('cloud-sign-out')));
          await tester.pumpAndSettle();
        }
        expectClearCloudLoginFields(tester, strings);
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '.tmp/cloud-controls-inside-01a19f0a-20261103/login-$preview.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await closeCloudApp(tester, model);
      });
    }
  }
}
