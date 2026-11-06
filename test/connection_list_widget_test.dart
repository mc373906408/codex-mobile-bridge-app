import 'dart:async';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';
import 'support/fake_repository.dart';

class _ConnectingRepository extends FakeRepository {
  Completer<void>? clientsReady;

  @override
  Future<List<ClientInfo>> clients(Computer computer) async {
    await clientsReady?.future;
    return super.clients(computer);
  }
}

SessionPage conversations(Computer target) => SessionPage(
  sessions: [
    SessionSummary(
      session: SessionRef(
        computerId: target.id,
        provider: Provider.codex,
        environment: 'local',
        id: 'synthetic-conversation',
      ),
      title: 'A loaded conversation',
      cwd: '/synthetic/project',
      updatedAt: '2026-11-05',
      status: 'idle',
      backend: 'desktop',
    ),
  ],
  nextOffset: null,
  notice: '',
);

Future<BridgeViewModel> showApp(
  WidgetTester tester,
  FakeRepository repository, {
  String locale = 'en',
}) async {
  final model = BridgeViewModel(repository);
  await model.initialize();
  model.setAppearance(locale: locale);
  await tester.pumpWidget(BridgeApp(repository: repository, viewModel: model));
  await tester.pumpAndSettle();
  return model;
}

Future<void> closeApp(WidgetTester tester, BridgeViewModel model) async {
  await tester.pumpWidget(const SizedBox.shrink());
  model.dispose();
  await tester.pump();
}

Finder iconButtonWithTooltip(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == tooltip,
);

void expectRefreshingList(Strings s) {
  expect(find.text(s.t('Chats')), findsWidgets);
  expect(find.text('Codex'), findsOneWidget);
  expect(find.text('Claude'), findsNothing);
  expect(find.text('DeepSeek'), findsNothing);
  expect(find.byType(LinearProgressIndicator), findsOneWidget);
  expect(find.text(s.t('No conversations yet')), findsNothing);
  expect(
    find.text(s.t('Enable and configure this client on the computer first.')),
    findsNothing,
  );
  expect(find.text(s.t('Manage cloud service')), findsNothing);
  expect(find.text(s.t('Reconnect')), findsNothing);
  expect(find.text(s.t('Password')), findsNothing);
  expect(find.byKey(const Key('composer')), findsNothing);
}

Future<void> pumpConnectionFrame(WidgetTester tester) async {
  // Connection selection flushes the previous draft/watch before notifying.
  await tester.pump();
  await tester.pump();
}

void main() {
  for (final relay in [false, true]) {
    for (final locale in ['zh', 'en']) {
      testWidgets(
        'connection enters refreshing conversations directly: relay=$relay, $locale',
        (tester) async {
          tester.view.physicalSize = locale == 'zh'
              ? const Size(390, 844)
              : const Size(1024, 768);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final target = relay ? cloudComputer() : computerA;
          final authReady = Completer<AuthStatus>();
          final clientsReady = Completer<void>();
          final listReady = Completer<SessionPage>();
          final repository = _ConnectingRepository()
            ..savedComputers = [target]
            ..onConnect = ((_) => authReady.future)
            ..clientsReady = clientsReady
            ..onSessions = (_, _, _, _) => listReady.future;
          final model = await showApp(tester, repository, locale: locale);
          final s = Strings(Locale(locale));

          // Drive the real selection state without depending on cloud discovery.
          final selecting = model.selectComputer(target);
          await pumpConnectionFrame(tester);
          expectRefreshingList(s);
          expect(model.authenticated, isFalse);
          expect(
            tester
                .widget<IconButton>(iconButtonWithTooltip(s.t('New chat')))
                .onPressed,
            isNull,
          );
          expect(
            tester
                .widget<IconButton>(iconButtonWithTooltip(s.t('Refresh')))
                .onPressed,
            isNull,
          );
          final providerBefore = model.provider;
          expect(
            tester
                .widget<PopupMenuButton<Provider>>(
                  find.byKey(const Key('provider-picker')),
                )
                .enabled,
            isFalse,
          );
          await tester.tap(find.byKey(const Key('provider-picker')));
          await tester.pump();
          expect(find.text('Claude'), findsNothing);
          expect(model.provider, providerBefore);
          expect(
            tester.widget<TextField>(find.byType(TextField)).enabled,
            isFalse,
          );
          await tester.pump(const Duration(seconds: 1));
          expectRefreshingList(s);

          authReady.complete(authenticatedStatus);
          await pumpConnectionFrame(tester);
          expectRefreshingList(s);
          clientsReady.complete();
          await pumpConnectionFrame(tester);
          expectRefreshingList(s);
          listReady.complete(conversations(target));
          await selecting;
          await tester.pumpAndSettle();
          expect(find.text('A loaded conversation'), findsOneWidget);
          expect(find.byType(LinearProgressIndicator), findsNothing);
          expect(find.text(s.t('Manage cloud service')), findsNothing);
          expect(repository.creates, 0);
          expect(repository.sends, 0);

          final refreshReady = Completer<SessionPage>();
          repository.onSessions = (_, _, _, _) => refreshReady.future;
          final refreshing = model.refreshSessions();
          await pumpConnectionFrame(tester);
          expectRefreshingList(s);
          expect(find.text('A loaded conversation'), findsOneWidget);
          refreshReady.complete(conversations(target));
          await refreshing;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await closeApp(tester, model);
        },
      );
    }
  }

  testWidgets('empty state waits for the first list response', (tester) async {
    final listReady = Completer<SessionPage>();
    final repository = FakeRepository()
      ..onSessions = (_, _, _, _) => listReady.future;
    final model = await showApp(tester, repository);
    final selecting = model.selectComputer(computerA);
    await pumpConnectionFrame(tester);
    expectRefreshingList(const Strings(Locale('en')));
    listReady.complete(
      const SessionPage(sessions: [], nextOffset: null, notice: ''),
    );
    await selecting;
    await tester.pumpAndSettle();
    expect(find.text('No conversations yet'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await closeApp(tester, model);
  });

  testWidgets(
    'failed cloud authentication reveals recovery only after the attempt',
    (tester) async {
      final target = cloudComputer();
      final authReady = Completer<AuthStatus>();
      final repository = FakeRepository()
        ..savedComputers = [target]
        ..onConnect = (_) => authReady.future;
      final model = await showApp(tester, repository);
      final selecting = model.selectComputer(target);
      await pumpConnectionFrame(tester);
      expectRefreshingList(const Strings(Locale('en')));
      authReady.completeError(StateError('Network error'));
      await selecting;
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Manage cloud service'), findsOneWidget);
      expect(find.text('Reconnect'), findsOneWidget);
      expect(model.authenticated, isFalse);
      expect(repository.connects, 1);
      await closeApp(tester, model);
    },
  );

  testWidgets(
    'direct password form appears only when authentication needs it',
    (tester) async {
      final authReady = Completer<AuthStatus>();
      final repository = FakeRepository()..onConnect = (_) => authReady.future;
      final model = await showApp(tester, repository);
      await tester.tap(find.byKey(const ValueKey('computer-card-computer-a')));
      await pumpConnectionFrame(tester);
      expectRefreshingList(const Strings(Locale('en')));
      authReady.complete(
        const AuthStatus(
          authenticated: false,
          computerName: 'Studio',
          platform: 'Windows',
          passwordless: false,
          notifications: false,
          transport: 'poll',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Username'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(model.authenticated, isFalse);
      await closeApp(tester, model);
    },
  );

  testWidgets(
    'switching tabs preserves pending authentication without navigating back',
    (tester) async {
      final target = cloudComputer();
      final authReady = Completer<AuthStatus>();
      final repository = FakeRepository()
        ..savedComputers = [target]
        ..onConnect = (_) => authReady.future;
      final model = await showApp(tester, repository);
      final selecting = model.selectComputer(target);
      await pumpConnectionFrame(tester);
      expectRefreshingList(const Strings(Locale('en')));
      await tester.tap(find.byKey(const ValueKey('tab-computers')));
      await tester.pumpAndSettle();
      authReady.complete(authenticatedStatus);
      await selecting;
      await tester.pumpAndSettle();
      expect(model.computer, target);
      expect(model.authenticated, isTrue);
      expect(find.text('Choose a conversation'), findsNothing);
      expect(find.text('Manage cloud service'), findsNothing);
      expect(find.byKey(const Key('cloud-home-scroll')), findsOneWidget);
      expect(repository.sends + repository.creates + repository.stops, 0);
      await closeApp(tester, model);
    },
  );

  testWidgets(
    'revoked cloud access exits loading and ignores late authentication',
    (tester) async {
      final target = cloudComputer();
      final authReady = Completer<AuthStatus>();
      final repository = FakeRepository()
        ..savedComputers = [target]
        ..onConnect = (_) => authReady.future;
      final model = await showApp(tester, repository);
      final selecting = model.selectComputer(target);
      await pumpConnectionFrame(tester);
      expectRefreshingList(const Strings(Locale('en')));
      await model.cloudAccessChanged(target, false);
      await tester.pumpAndSettle();
      authReady.complete(authenticatedStatus);
      await selecting;
      await tester.pumpAndSettle();
      expect(model.authenticated, isFalse);
      expect(model.loading, isFalse);
      expect(find.text('Choose a conversation'), findsNothing);
      expect(find.text('Manage cloud service'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await closeApp(tester, model);
    },
  );

  testWidgets(
    'explicit connection cancellation rejects a late authentication',
    (tester) async {
      final authReady = Completer<AuthStatus>();
      final repository = FakeRepository()..onConnect = (_) => authReady.future;
      final model = await showApp(tester, repository);
      final selecting = model.selectComputer(computerA);
      await pumpConnectionFrame(tester);
      await tester.tap(find.byKey(const Key('cancel-connection')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      authReady.complete(authenticatedStatus);
      await selecting;
      await tester.pumpAndSettle();
      expect(model.computer, isNull);
      expect(model.authenticated, isFalse);
      expect(repository.sends + repository.creates + repository.stops, 0);
      expect(find.byKey(const Key('cloud-home-scroll')), findsOneWidget);
      await closeApp(tester, model);
    },
  );
}
