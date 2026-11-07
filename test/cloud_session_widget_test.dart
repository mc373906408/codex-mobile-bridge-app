import 'dart:async';

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
}
