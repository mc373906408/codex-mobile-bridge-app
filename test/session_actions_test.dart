import 'dart:async';
import 'dart:convert';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

void main() {
  for (final changedAccount in [false, true]) {
    testWidgets(
      'open chat menu before reading authority, changed account: $changedAccount',
      (tester) async {
        final repository = FakeRepository();
        final model = BridgeViewModel(repository);
        await model.initialize();
        await model.selectComputer(computerA);
        await model.openSession(sessionA);
        await tester.pumpWidget(
          BridgeApp(repository: repository, viewModel: model),
        );
        await tester.pumpAndSettle();

        final delayed = Completer<SessionSnapshot>();
        var snapshotReads = 0;
        repository.onSnapshot = (session) {
          snapshotReads++;
          expect(session, sessionA);
          return delayed.future;
        };
        await tester.tap(find.byTooltip('Chat tools'));
        await tester.pumpAndSettle();
        expect(find.text('Files, Git & terminal'), findsOneWidget);
        expect(snapshotReads, 0);

        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        expect(snapshotReads, 1);
        expect(find.byType(AlertDialog), findsNothing);
        delayed.complete(
          snapshotFor(
            sessionA,
            account: changedAccount ? 'account-b' : 'account-a',
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(AlertDialog),
          changedAccount ? findsNothing : findsOneWidget,
        );
        expect(
          find.byType(SnackBar),
          changedAccount ? findsOneWidget : findsNothing,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        model.dispose();
        await tester.pump();
      },
    );
  }

  testWidgets('chat list follows recent order and collapses project groups', (
    tester,
  ) async {
    final repository = FakeRepository()
      ..onSessions = (_, _, _, _) async => SessionPage(
        sessions: [
          for (var index = 0; index < 60; index++)
            SessionSummary(
              session: SessionRef(
                computerId: computerA.id,
                provider: Provider.codex,
                environment: 'local',
                id: 'chat-$index',
              ),
              title: 'chat-$index',
              cwd: '/project',
              updatedAt: '${index == 19 ? 999 : 100 - index}',
              status: 'idle',
              backend: 'desktop',
              pinned: index == 2,
              metadata: jsonEncode({
                'recency': 100 - index,
                'projectKey': index.isEven ? 'project-a' : 'project-b',
                'projectName': index.isEven ? 'Project A' : 'Project B',
              }),
            ),
        ],
        notice: '',
        nextOffset: null,
      );
    final model = BridgeViewModel(repository);
    await model.initialize();
    await model.selectComputer(computerA);
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('chat-2')).dy,
      lessThan(tester.getTopLeft(find.text('chat-0')).dy),
    );
    model.setPresentation('groupByProject', true);
    await tester.pumpAndSettle();
    final group = find.byKey(const ValueKey('project-group-project-a'));
    expect(group, findsOneWidget);
    expect(find.text('chat-0'), findsOneWidget);
    await tester.tap(group);
    await tester.pumpAndSettle();
    expect(find.text('chat-0'), findsNothing);
    model.setPresentation('groupByProject', false);
    await tester.pumpAndSettle();
    expect(find.text('chat-0'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
  });

  for (final archived in [0, 1, false, true]) {
    testWidgets('session menu accepts list archived=$archived', (tester) async {
      await _checkMenu(
        tester,
        listMetadata: {'archived': archived},
        archived: archived == 1 || archived == true,
      );
    });
  }

  testWidgets('session menu reads the gateway bridgePinned field', (
    tester,
  ) async {
    await _checkMenu(
      tester,
      listMetadata: {'bridgePinned': true},
      archived: false,
      pinned: true,
    );
  });

  testWidgets('numeric snapshot flags override list metadata', (tester) async {
    await _checkMenu(
      tester,
      listMetadata: {'archived': false},
      snapshotMetadata: {
        'session': {'archived': 1, 'pinned': 1},
      },
      archived: true,
      pinned: true,
    );
  });

  testWidgets('false snapshot flags override archived and pinned list state', (
    tester,
  ) async {
    await _checkMenu(
      tester,
      listMetadata: {'archived': 1},
      listPinned: true,
      snapshotMetadata: {
        'session': {'archived': false, 'pinned': 0},
      },
      archived: false,
    );
  });
}

Future<void> _checkMenu(
  WidgetTester tester, {
  required Map<String, Object?> listMetadata,
  Map<String, Object?> snapshotMetadata = const {},
  required bool archived,
  bool pinned = false,
  bool listPinned = false,
}) async {
  final repository = FakeRepository();
  repository.onSessions = (_, _, _, _) async => SessionPage(
    sessions: [
      SessionSummary(
        session: sessionA,
        title: 'A quieter workspace',
        cwd: '/work/bridge',
        updatedAt: '2026-11-14',
        status: 'idle',
        backend: 'desktop',
        pinned: listPinned,
        metadata: jsonEncode(listMetadata),
      ),
    ],
    nextOffset: null,
    notice: '',
  );
  repository.onSnapshot = (session) async =>
      _snapshot(session, snapshotMetadata);
  final model = BridgeViewModel(repository);
  await model.initialize();
  await model.selectComputer(computerA);
  await tester.pumpWidget(BridgeApp(repository: repository, viewModel: model));
  await tester.pumpAndSettle();

  for (var attempt = 0; attempt < 2; attempt++) {
    await tester.longPress(find.text('A quieter workspace'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Files, Git & terminal'), findsOneWidget);
    expect(find.text(pinned ? 'Unpin' : 'Pin'), findsOneWidget);
    final sheet = find.byType(DraggableScrollableSheet);
    final archiveAction = find.text(archived ? 'Restore chat' : 'Archive chat');
    await tester.scrollUntilVisible(
      archiveAction,
      100,
      scrollable: find.descendant(of: sheet, matching: find.byType(Scrollable)),
    );
    expect(archiveAction, findsOneWidget);
    Navigator.of(tester.element(sheet)).pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  expect(repository.sends, 0);
  expect(repository.stops, 0);
  expect(repository.resumedSessions, isEmpty);
  await tester.pumpWidget(const SizedBox.shrink());
  model.dispose();
  await tester.pump();
}

SessionSnapshot _snapshot(SessionRef session, Map<String, Object?> metadata) {
  final base = snapshotFor(session);
  return SessionSnapshot(
    session: base.session,
    title: base.title,
    cwd: base.cwd,
    connected: base.connected,
    running: base.running,
    status: base.status,
    model: base.model,
    effort: base.effort,
    capabilities: base.capabilities,
    approvals: base.approvals,
    history: base.history,
    controlToken: base.controlToken,
    accountIdentity: base.accountIdentity,
    sequence: base.sequence,
    notice: base.notice,
    metadata: jsonEncode(metadata),
  );
}
