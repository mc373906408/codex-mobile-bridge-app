import 'dart:async';
import 'dart:convert';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/data/session_activity.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

const _id = '11111111-1111-4111-8111-111111111111';
final _key = activityKey('local', _id);

Map<String, dynamic> activity({
  String host = 'local',
  String status = 'active',
  String? turn = 'one',
  String? result = 'inProgress',
  bool connected = true,
  bool awaiting = false,
}) => {
  'id': _id,
  'host': host,
  'status': status,
  'turnId': turn,
  'turnStatus': result,
  'connected': connected,
  'awaiting': awaiting,
};

void main() {
  test('host-qualified running and completed states persist until viewed', () {
    final tracker = SessionActivityTracker();
    tracker.update([activity(), activity(host: 'ssh:lab')]);
    expect(tracker.indicator(_key), SessionActivityKind.running);
    tracker.update([activity(status: 'idle', result: 'completed')]);
    expect(tracker.indicator(_key), SessionActivityKind.completed);
    final restored = SessionActivityTracker(
      jsonDecode(jsonEncode(tracker.rows)),
    );
    expect(restored.indicator(_key), SessionActivityKind.completed);
    expect(
      restored.indicator(activityKey('ssh:lab', _id)),
      SessionActivityKind.running,
    );
    restored.read(_key);
    expect(
      restored.update([activity(status: 'idle', result: 'completed')]),
      isFalse,
    );
    expect(restored.indicator(_key), isNull);
    restored.update([
      activity(status: 'idle', turn: 'two', result: 'completed'),
    ]);
    expect(restored.indicator(_key), SessionActivityKind.completed);
  });

  test('first or delayed historical terminal is a baseline, not unread', () {
    final tracker = SessionActivityTracker();
    tracker.update([activity(status: 'idle', turn: null, result: null)]);
    tracker.update([activity(status: 'idle', result: 'completed')]);
    expect(tracker.indicator(_key), isNull);
    tracker.update([activity(status: 'idle', turn: null, result: null)]);
    tracker.update([activity(status: 'idle', result: 'completed')]);
    expect(tracker.indicator(_key), isNull);
    tracker.update([activity(turn: 'two')]);
    tracker.update([
      activity(status: 'idle', turn: 'two', result: 'completed'),
    ]);
    expect(tracker.indicator(_key), SessionActivityKind.completed);
  });

  test(
    'offline, approval, failed and interrupted are distinct from completion',
    () {
      final tracker = SessionActivityTracker();
      tracker.update([activity(awaiting: true)]);
      expect(tracker.indicator(_key), SessionActivityKind.awaiting);
      tracker.update([activity(connected: false)]);
      expect(tracker.indicator(_key), SessionActivityKind.unknown);
      tracker.update([activity(status: 'idle', result: 'failed')]);
      expect(tracker.indicator(_key), SessionActivityKind.failed);
      tracker.update([activity(turn: 'two')]);
      tracker.update([
        activity(status: 'idle', turn: 'two', result: 'interrupted'),
      ]);
      expect(tracker.indicator(_key), SessionActivityKind.interrupted);
      tracker.update([
        activity(status: 'idle', turn: 'three', result: 'completed'),
      ], visible: _key);
      expect(tracker.indicator(_key), isNull);
    },
  );

  testWidgets(
    'list polls activity, exposes status semantics and respects display setting',
    (tester) async {
      final repository = _ActivityRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.selectComputer(computerA);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Running'), findsOneWidget);
      repository.updates = [activity(status: 'idle', result: 'completed')];
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
        model.sessionActivity(sessionA),
        SessionActivityKind.completed,
        reason:
            'requests=${repository.calls}, foreground=${model.foreground}, loading=${model.loading}',
      );
      expect(find.byTooltip('Completed, unread'), findsOneWidget);
      model.setPresentation('showActivity', false);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Completed, unread'), findsNothing);
      expect(repository.sends, 0);
      expect(repository.resumedSessions, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    },
  );

  test(
    'visible loaded chat clears unread; hidden selection keeps it',
    () async {
      final repository = _ActivityRepository();
      final model = await _model(repository);
      await model.openSession(sessionA);
      repository.updates = [activity(status: 'idle', result: 'completed')];
      await model.refreshSessionActivity();
      expect(model.sessionActivity(sessionA), SessionActivityKind.completed);
      model.visibleActivitySession = () => sessionA;
      model.acknowledgeVisibleActivity();
      expect(model.sessionActivity(sessionA), isNull);
      model.visibleActivitySession = () => null;
      repository.updates = [
        activity(status: 'idle', turn: 'two', result: 'completed'),
      ];
      await model.refreshSessionActivity();
      expect(model.sessionActivity(sessionA), SessionActivityKind.completed);
      model.dispose();
    },
  );

  testWidgets('hidden chat tab retains completion until the chat is visible', (
    tester,
  ) async {
    final repository = _ActivityRepository();
    final model = BridgeViewModel(repository);
    await model.initialize();
    await model.selectComputer(computerA);
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('A quieter workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tab-settings')));
    await tester.pumpAndSettle();
    repository.updates = [activity(status: 'idle', result: 'completed')];
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(model.sessionActivity(sessionA), SessionActivityKind.completed);
    await tester.tap(find.byKey(const ValueKey('tab-chats')));
    await tester.pumpAndSettle();
    expect(model.sessionActivity(sessionA), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
  });

  test('new list response supersedes an older pending activity read', () async {
    final repository = _ActivityRepository();
    final model = await _model(repository);
    final pending = Completer<GatewayState>();
    repository.next = pending.future;
    final reading = model.refreshSessionActivity();
    repository.next = null;
    repository.updates = [activity(status: 'idle', result: 'completed')];
    await model.refreshSessions();
    await Future<void>.delayed(Duration.zero);
    expect(model.sessionActivity(sessionA), SessionActivityKind.completed);
    pending.complete(
      GatewayState(
        identity: 'account-a',
        data: jsonEncode({
          'sessions': [activity()],
        }),
      ),
    );
    await reading;
    expect(model.sessionActivity(sessionA), SessionActivityKind.completed);
    model.dispose();
  });

  test(
    'same list never overlaps requests and late background response is ignored',
    () async {
      final repository = _ActivityRepository();
      final model = await _model(repository);
      final pending = Completer<GatewayState>();
      repository.next = pending.future;
      final before = repository.calls;
      final reading = model.refreshSessionActivity();
      await model.refreshSessionActivity();
      expect(repository.calls, before + 1);
      await model.setForeground(false);
      pending.complete(
        GatewayState(
          identity: 'account-a',
          data: jsonEncode({
            'sessions': [activity(status: 'idle', result: 'completed')],
          }),
        ),
      );
      await reading;
      expect(model.sessionActivity(sessionA), isNull);
      model.dispose();
    },
  );

  test(
    'gateway identities isolate baselines and preserve each unread completion',
    () async {
      final repository = _ActivityRepository();
      final model = await _model(repository);
      repository.updates = [activity(status: 'idle', result: 'completed')];
      await model.refreshSessionActivity();
      expect(model.sessionActivity(sessionA), SessionActivityKind.completed);
      repository.identity = 'account-b';
      await model.refreshSessionActivity();
      expect(model.sessionActivity(sessionA), isNull);
      repository.identity = 'account-a';
      await model.refreshSessionActivity();
      expect(model.sessionActivity(sessionA), SessionActivityKind.completed);
      model.dispose();
    },
  );

  test(
    'read failure marks known activity unknown without an operation error',
    () async {
      final repository = _ActivityRepository();
      final model = await _model(repository);
      repository.failure = StateError('offline');
      await model.refreshSessionActivity();
      expect(model.sessionActivity(sessionA), SessionActivityKind.unknown);
      expect(model.error, isNull);
      model.dispose();
    },
  );
}

Future<BridgeViewModel> _model(_ActivityRepository repository) async {
  final model = BridgeViewModel(repository);
  await model.initialize();
  await model.selectComputer(computerA);
  await Future<void>.delayed(Duration.zero);
  return model;
}

class _ActivityRepository extends FakeRepository {
  List<Map<String, dynamic>> updates = [activity()];
  String identity = 'account-a';
  Future<GatewayState>? next;
  Object? failure;
  int calls = 0;

  @override
  Future<GatewayState> gatewayResource(
    Computer computer,
    Provider provider,
    String entry,
    GatewayResource resource,
    Map<String, Object?> parameters,
  ) async {
    expectSync(resource, GatewayResource.sessionActivity);
    expectSync(parameters, {
      'hosts': {
        'local': [_id],
      },
    });
    calls++;
    if (failure != null) throw failure!;
    if (next != null) return next!;
    return GatewayState(
      identity: identity,
      data: jsonEncode({'sessions': updates}),
    );
  }
}
