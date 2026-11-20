import 'dart:async';
import 'dart:convert';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/ui/pages/session_list_tile.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

void main() {
  late FakeRepository repository;
  late BridgeViewModel model;

  setUp(() async {
    repository = FakeRepository();
    model = BridgeViewModel(repository);
    await model.initialize();
    await model.selectComputer(computerA);
  });

  tearDown(() => model.dispose());

  testWidgets('visible list preloads running and unread chats one at a time', (
    tester,
  ) async {
    final read = _listedChat(1, updated: '2026-11-20T10:00:00Z');
    final unread = _listedChat(2, updated: '2026-11-20T09:00:00Z');
    final running = _listedChat(3, status: 'running');
    model.sessions = [read, unread, running];
    await model.markSessionRead(read.session, true);
    final replies = <SessionRef, Completer<SessionSnapshot>>{};
    repository.onSnapshot = (session) {
      final reply = Completer<SessionSnapshot>();
      expect(replies, isNot(contains(session)));
      replies[session] = reply;
      return reply.future;
    };
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    expect(replies.keys, [running.session]);
    replies[running.session]!.complete(snapshotFor(running.session));
    await tester.pumpAndSettle();
    expect(replies.keys, [running.session, unread.session]);
    replies[unread.session]!.complete(snapshotFor(unread.session));
    await tester.pumpAndSettle();
    expect(replies.keys, [running.session, unread.session]);
    expect(model.selected, isNull);
    expect(model.isSessionRead(unread.session), isFalse);
    expect(repository.watched, isEmpty);
    expect(repository.resumedSessions, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('unread preloads leave room for later running activity', () async {
    final rows = [for (var index = 0; index < 9; index++) _listedChat(index)];
    final activity = _PrefetchActivityRepository()
      ..onSessions = (_, _, _, _) async =>
          SessionPage(sessions: rows, notice: '', nextOffset: null);
    final state = BridgeViewModel(activity);
    addTearDown(state.dispose);
    await state.initialize();
    await state.selectComputer(computerA);
    state.setPresentation('showActivity', false);
    final calls = <SessionRef>[];
    activity.onSnapshot = (session) async {
      calls.add(session);
      return snapshotFor(session);
    };
    for (var attempt = 0; attempt < 9; attempt++) {
      await state.prefetchListedSessions(rows);
    }
    expect(calls, rows.take(4).map((row) => row.session));
    activity.running = rows.skip(4).map((row) => row.session).toList();
    await state.refreshSessionActivity();
    for (var attempt = 0; attempt < 9; attempt++) {
      await state.prefetchListedSessions(rows);
    }
    expect(calls, rows.take(8).map((row) => row.session));
    expect(state.sessionActivity(rows.last.session), isNull);
    expect(activity.watched, isEmpty);
  });

  testWidgets('first list visit preloads a read-only preview before any tap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preload = Completer<SessionSnapshot>();
    final synchronizing = Completer<SessionSnapshot>();
    final calls = <SessionRef>[];
    repository.onSnapshot = (session) {
      calls.add(session);
      return calls.length == 1 ? preload.future : synchronizing.future;
    };
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    expect(calls, [sessionA]);
    expect(model.selected, isNull);
    expect(model.isSessionRead(sessionA), isFalse);
    expect(repository.watched, isEmpty);
    preload.complete(
      snapshotFor(sessionA, messages: [message('preview', 'Preloaded reply')]),
    );
    await tester.pump();

    await tester.tap(find.byType(SessionListTile));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(calls, [sessionA, sessionA]);
    expect(find.byKey(const ValueKey('preview')).hitTestable(), findsOneWidget);
    expect(find.text('Syncing…'), findsOneWidget);
    final tools = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == 'Chat tools',
    );
    expect(tester.widget<IconButton>(tools).onPressed, isNull);
    expect(model.snapshot, isNull);
    expect(model.messages, isEmpty);
    expect(
      model.canConnectSession || model.canSend || model.draftEditable,
      isFalse,
    );
    expect(repository.sends + repository.imageReads, 0);
    expect(find.text('Older messages'), findsNothing);

    synchronizing.complete(
      snapshotFor(sessionA, messages: [message('latest', 'Live reply')]),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('latest')).hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('preview')), findsNothing);
    expect(model.isSessionRead(sessionA), isTrue);
    expect(calls, [sessionA, sessionA]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'tapping while preload is in flight shares one authenticated read',
    () async {
      final read = Completer<SessionSnapshot>();
      var calls = 0;
      repository.onSnapshot = (_) {
        calls++;
        return read.future;
      };
      final row = model.sessions.single;
      final preload = model.prefetchListedSessions([row]);
      await model.prefetchListedSessions([row]);
      final opening = model.openListedSession(row);
      await Future<void>.delayed(Duration.zero);
      expect(model.selected, sessionA);
      expect(calls, 1);
      expect(model.fresh, isFalse);
      read.complete(snapshotFor(sessionA));
      await Future.wait([preload, opening]);
      expect(model.fresh, isTrue);
      expect(model.isSessionRead(sessionA), isTrue);
      expect(calls, 1);
    },
  );

  test(
    'a failed shared preload falls back to a normal foreground read',
    () async {
      final failure = Completer<SessionSnapshot>();
      var calls = 0;
      repository.onSnapshot = (session) async {
        if (++calls == 1) return failure.future;
        return snapshotFor(session);
      };
      final row = model.sessions.single;
      final preload = model.prefetchListedSessions([row]);
      final opening = model.openListedSession(row);
      await Future<void>.delayed(Duration.zero);
      failure.completeError(StateError('Network error'));
      await Future.wait([preload, opening]);
      expect(calls, 2);
      expect(model.error, isNull);
      expect(model.fresh, isTrue);
    },
  );

  test(
    'late speculative content cannot repopulate an invalidated cache',
    () async {
      final latePage = Completer<SessionSnapshot>();
      final activeRead = Completer<SessionSnapshot>();
      var calls = 0;
      repository.onSnapshot = (_) =>
          ++calls == 1 ? latePage.future : activeRead.future;
      final row = model.sessions.single;
      final preload = model.prefetchListedSessions([row]);
      model.clearChatCaches();
      latePage.complete(snapshotFor(sessionA));
      await preload;
      final opening = model.openListedSession(row);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      expect(model.chatPreview, isNull);
      activeRead.complete(snapshotFor(sessionA));
      await opening;
    },
  );

  test('previews do not survive a new authenticated connection', () async {
    final row = model.sessions.single;
    await model.prefetchListedSessions([row]);
    await model.backToComputers();
    await model.selectComputer(computerA);
    final read = Completer<SessionSnapshot>();
    repository.onSnapshot = (_) => read.future;
    final opening = model.openSession(sessionA);
    await Future<void>.delayed(Duration.zero);
    expect(model.chatPreview, isNull);
    read.complete(snapshotFor(sessionA, account: 'new-account'));
    await opening;
    expect(model.snapshot?.accountIdentity, 'new-account');
  });

  test(
    'an initial failure discards staged content and leaves controls locked',
    () async {
      final row = model.sessions.single;
      await model.prefetchListedSessions([row]);
      final failed = Completer<SessionSnapshot>();
      repository.onSnapshot = (_) => failed.future;
      final opening = model.openListedSession(row);
      await Future<void>.delayed(Duration.zero);
      expect(model.chatPreview, isNotNull);
      failed.completeError(StateError('Gateway error (403): Access denied'));
      await opening;
      expect(model.chatPreview, isNull);
      expect(model.messages, isEmpty);
      expect(model.snapshot, isNull);
      expect(model.isSessionRead(sessionA), isFalse);
      expect(model.fresh, isFalse);
      expect(model.error, isNotNull);
    },
  );

  test(
    'a newer account snapshot replaces rather than merging cached rows',
    () async {
      final row = model.sessions.single;
      await model.prefetchListedSessions([row]);
      final read = Completer<SessionSnapshot>();
      repository.onSnapshot = (_) => read.future;
      final opening = model.openListedSession(row);
      await Future<void>.delayed(Duration.zero);
      expect(model.chatPreview?.account, 'account-a');
      read.complete(
        snapshotFor(
          sessionA,
          account: 'account-b',
          messages: [message('other-account', 'Live account B')],
        ),
      );
      await opening;
      expect(model.chatPreview, isNull);
      expect(model.messages.single.id, 'other-account');
      expect(model.snapshot?.accountIdentity, 'account-b');
    },
  );
}

SessionSummary _listedChat(
  int index, {
  String status = 'idle',
  String updated = '2026-11-20T08:00:00Z',
}) => SessionSummary(
  session: SessionRef(
    computerId: computerA.id,
    provider: Provider.codex,
    environment: 'local',
    id: 'listed-$index',
  ),
  title: 'Conversation $index',
  cwd: '/work/bridge',
  updatedAt: updated,
  status: status,
  backend: 'desktop',
);

class _PrefetchActivityRepository extends FakeRepository {
  List<SessionRef> running = [];

  @override
  Future<GatewayState> gatewayResource(
    Computer computer,
    Provider provider,
    String entry,
    GatewayResource resource,
    Map<String, Object?> parameters,
  ) async {
    if (resource != GatewayResource.sessionActivity) {
      return super.gatewayResource(
        computer,
        provider,
        entry,
        resource,
        parameters,
      );
    }
    return GatewayState(
      identity: 'gateway',
      data: jsonEncode({
        'sessions': [
          for (final session in running)
            {
              'host': session.environment,
              'id': session.id,
              'status': 'active',
              'connected': true,
            },
        ],
      }),
    );
  }
}
