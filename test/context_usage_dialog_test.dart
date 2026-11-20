import 'dart:async';
import 'dart:convert';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class _CompactRepository extends FakeRepository {
  final writes = <(SessionSnapshot, SessionCommand, Map<String, Object?>)>[];
  final outcome = Completer<OutcomeKind>();

  @override
  Future<BusinessReply> sessionCommand(
    SessionSnapshot snapshot,
    String id,
    SessionCommand command,
    Map<String, Object?> parameters,
  ) async {
    writes.add((snapshot, command, parameters));
    final kind = await outcome.future;
    return BusinessReply(
      outcome: OperationOutcome(
        id: id,
        kind: kind,
        message: kind == OutcomeKind.accepted
            ? ''
            : 'The result needs review; the request will not be replayed',
      ),
      data: '{}',
    );
  }
}

SessionSnapshot _snapshot(
  SessionRef session, {
  String account = 'account-a',
  String token = 'control-a',
  bool connected = true,
  bool running = false,
  bool? compact = true,
  bool waiting = false,
  bool lastPrompt = false,
  int usedTokens = 209675,
}) {
  final state = {
    if (waiting)
      'requests': [
        {'id': 'approval'},
      ],
    (lastPrompt ? 'lastPromptContextUsage' : 'contextUsage'): {
      'usedTokens': usedTokens,
      'contextWindow': 875900,
    },
  };
  final capabilities = {'compact': ?compact};
  return snapshotFor(
    session,
    connected: connected,
    running: running,
    account: account,
    token: token,
    metadata: jsonEncode(
      session.provider == Provider.codex
          ? {...state, 'capabilities': capabilities}
          : {'session': state, 'capabilities': capabilities},
    ),
  );
}

Future<BridgeViewModel> _openPanel(
  WidgetTester tester,
  _CompactRepository repository, {
  SessionRef session = sessionA,
  String locale = 'en',
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final model = BridgeViewModel(repository);
  await model.initialize();
  model.setAppearance(locale: locale);
  await model.selectComputer(computerA);
  await model.openSession(session);
  await tester.pumpWidget(BridgeApp(repository: repository, viewModel: model));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip(locale == 'zh' ? '上下文用量' : 'Context usage'));
  await tester.pumpAndSettle();
  return model;
}

Future<void> _closeApp(WidgetTester tester, BridgeViewModel model) async {
  await tester.pumpWidget(const SizedBox.shrink());
  model.dispose();
  await tester.pump();
}

void main() {
  final action = find.widgetWithText(FilledButton, 'Compact context');
  final confirm = find.widgetWithText(FilledButton, 'Confirm');

  testWidgets('compact uses the live session after explicit confirmation', (
    tester,
  ) async {
    final repository = _CompactRepository()
      ..onSnapshot = (session) async => _snapshot(session);
    final model = await _openPanel(tester, repository);
    expect(find.text('23.9%'), findsOneWidget);
    expect(find.text('209,675'), findsOneWidget);
    expect(find.text('875,900'), findsOneWidget);
    expect(repository.writes, isEmpty);
    model.editDraft('Unsaved thought');
    await tester.pump();

    await tester.tap(action);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repository.writes, isEmpty);

    await tester.tap(action);
    await tester.pumpAndSettle();
    repository.emit(_snapshot(sessionA, token: 'live-control'));
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(repository.writes, hasLength(1));
    final (snapshot, command, parameters) = repository.writes.single;
    expect(snapshot.session, sessionA);
    expect(snapshot.accountIdentity, 'account-a');
    expect(snapshot.controlToken, 'live-control');
    expect(command, SessionCommand.compact);
    expect(parameters, isEmpty);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Submitting…'),
          )
          .onPressed,
      isNull,
    );

    repository.outcome.complete(OutcomeKind.accepted);
    await tester.pumpAndSettle();
    expect(find.text('Compaction requested.'), findsOneWidget);
    expect(tester.widget<FilledButton>(action).onPressed, isNull);
    expect(find.text('209,675'), findsOneWidget);

    repository.emit(_snapshot(sessionA, usedTokens: 10200));
    await tester.pumpAndSettle();
    expect(find.text('10,200'), findsOneWidget);
    expect(find.text('209,675'), findsNothing);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(model.selected, sessionA);
    expect(model.draftText, 'Unsaved thought');
    expect(repository.sends, 0);
    await _closeApp(tester, model);
  });

  testWidgets('live state disables compaction without hiding the action', (
    tester,
  ) async {
    final repository = _CompactRepository()
      ..onSnapshot = (session) async => _snapshot(session, compact: null);
    final model = await _openPanel(tester, repository);
    expect(tester.widget<FilledButton>(action).onPressed, isNull);
    expect(
      find.text('Manual compaction is unavailable for this chat.'),
      findsOneWidget,
    );
    for (final (snapshot, reason) in [
      (
        _snapshot(sessionA, connected: false),
        'Connect this chat before compacting.',
      ),
      (
        _snapshot(sessionA, running: true),
        'Wait for this chat to become idle.',
      ),
      (
        _snapshot(sessionA, waiting: true),
        'Wait for this chat to become idle.',
      ),
    ]) {
      repository.emit(snapshot);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.widget<FilledButton>(action).onPressed, isNull);
      expect(find.text(reason), findsOneWidget);
    }
    repository.emit(_snapshot(sessionA));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
    expect(repository.writes, isEmpty);
    await _closeApp(tester, model);
  });

  testWidgets('a changed account while confirming cannot compact', (
    tester,
  ) async {
    final repository = _CompactRepository()
      ..onSnapshot = (session) async => _snapshot(session);
    final model = await _openPanel(tester, repository);
    await tester.tap(action);
    await tester.pumpAndSettle();
    repository.emit(_snapshot(sessionA, account: 'account-b'));
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(repository.writes, isEmpty);
    expect(tester.widget<FilledButton>(action).onPressed, isNull);
    expect(find.text('The chat changed. Reopen this panel.'), findsOneWidget);
    expect(find.text('209,675'), findsNothing);
    await _closeApp(tester, model);
  });

  testWidgets('disconnecting during confirmation never submits', (
    tester,
  ) async {
    final repository = _CompactRepository()
      ..onSnapshot = (session) async => _snapshot(session);
    final model = await _openPanel(tester, repository);
    await tester.tap(action);
    await tester.pumpAndSettle();
    repository.emit(_snapshot(sessionA, connected: false));
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(repository.writes, isEmpty);
    expect(find.text('Connect this chat before compacting.'), findsOneWidget);
    expect(tester.widget<FilledButton>(action).onPressed, isNull);
    await _closeApp(tester, model);
  });

  testWidgets('an unknown result is not replayed or displayed as success', (
    tester,
  ) async {
    final repository = _CompactRepository()
      ..onSnapshot = (session) async => _snapshot(session);
    final model = await _openPanel(tester, repository);
    await tester.tap(action);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    repository.outcome.complete(OutcomeKind.unknown);
    await tester.pumpAndSettle();
    expect(find.text('Compaction requested.'), findsNothing);
    expect(
      find.textContaining('verify any submission on the computer'),
      findsOneWidget,
    );
    expect(tester.widget<FilledButton>(action).onPressed, isNull);
    expect(repository.writes, hasLength(1));
    await _closeApp(tester, model);
  });

  testWidgets('Chinese large text fits and last input is not a usage ratio', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final repository = _CompactRepository()
      ..onSnapshot = (session) async => _snapshot(session, lastPrompt: true);
    final model = await _openPanel(
      tester,
      repository,
      session: sessionB,
      locale: 'zh',
      size: const Size(320, 640),
    );
    expect(find.text('最近一次模型输入'), findsOneWidget);
    expect(find.text('23.9%'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '压缩上下文'))
          .onPressed,
      isNotNull,
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 350);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    final compact = find.widgetWithText(FilledButton, '压缩上下文');
    await tester.ensureVisible(compact);
    await tester.pumpAndSettle();
    expect(compact.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(model.selected, sessionB);
    await _closeApp(tester, model);
  });
}
