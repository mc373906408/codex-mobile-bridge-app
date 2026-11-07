import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/ui/cloud_home.dart';
import 'package:bridge_mobile/ui/cloud_service_page.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:bridge_mobile/viewmodels/cloud_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';
import 'support/fake_repository.dart';

import 'support/cloud_home_test_support.dart';

void main() {
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
    'stale old-server selection still requires explicit login without a saved menu',
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
      await tester.tap(find.byKey(const ValueKey('tab-computers')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('saved-computers-menu')), findsNothing);
      tester.widget<CloudHome>(find.byType(CloudHome)).onComputer(old);
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
}
