import 'dart:convert';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

void main() {
  for (final archived in [0, 1, false, true]) {
    testWidgets('session menu accepts list archived=$archived', (tester) async {
      await _checkMenu(
        tester,
        listMetadata: {'archived': archived},
        archived: archived == 1 || archived == true,
      );
    });
  }

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
