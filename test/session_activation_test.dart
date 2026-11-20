import 'dart:async';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

const resumable = CapabilitySet(
  send: false,
  steer: false,
  stop: false,
  approve: false,
  resume: true,
  models: false,
  attachments: false,
  arbitraryFiles: false,
);

SessionSnapshot disconnected(SessionRef session) =>
    snapshotFor(session, connected: false, capabilities: resumable);

void main() {
  late FakeRepository repository;
  late BridgeViewModel model;

  setUp(() async {
    repository = FakeRepository()
      ..onSnapshot = (session) async => disconnected(session);
    model = BridgeViewModel(repository);
    await model.initialize();
    await model.selectComputer(computerA);
  });

  tearDown(() => model.dispose());

  for (final provider in [Provider.codex, Provider.claude]) {
    test(
      'explicit open connects the original $provider instance and host once',
      () async {
        final session = SessionRef(
          computerId: computerA.id,
          provider: provider,
          entry: 'original-instance',
          environment: 'remote-ssh:original-host',
          id: sessionA.id,
        );
        repository.onResume = (value, id) async {
          repository.onSnapshot = (session) async => snapshotFor(session);
          return repository.accepted(id);
        };

        await model.openSession(session, activate: true);

        expect(repository.resumedSessions.single.session, session);
        expect(repository.resumedSessions.single.controlToken, 'control-a');
        expect(model.snapshot!.connected, isTrue);
        expect(model.selected, session);
        expect(model.messages, isNotEmpty);
        expect(model.connectingSession, isFalse);
        model.editDraft('Keep this unsent draft');
        expect(model.canSend, isTrue);
        expect(repository.sends + repository.stops + repository.creates, 0);
      },
    );
  }

  test('passive reads, subscription updates and foreground recovery never activate', () async {
    await model.openSession(sessionA);
    repository.emit(disconnected(sessionA));
    await Future<void>.delayed(Duration.zero);
    await model.openSession(sessionA);
    await model.markSessionRead(sessionA, true);
    await model.setForeground(false);
    await model.setForeground(true);
    expect(repository.resumedSessions, isEmpty);
    expect(model.snapshot!.connected, isFalse);
  });

  test('connected or unsupported sessions are never resumed on open', () async {
    repository.onSnapshot = (session) async =>
        snapshotFor(session, capabilities: resumable);
    await model.openSession(sessionA, activate: true);
    repository.onSnapshot = (session) async =>
        snapshotFor(session, connected: false);
    await model.openSession(sessionA, activate: true);
    expect(repository.resumedSessions, isEmpty);
  });

  test('a delayed previous open cannot cancel the latest chat watch', () async {
    await model.openSession(sessionA);
    final saveGate = Completer<void>();
    var saves = 0;
    repository.onSaveDraft = (_, _, _) async {
      if (++saves == 1) await saveGate.future;
    };
    final earlier = model.openSession(sessionB);
    await Future<void>.delayed(Duration.zero);
    final latest = model.openSession(
      const SessionRef(
        computerId: 'computer-a',
        provider: Provider.codex,
        environment: 'local',
        id: '33333333-3333-4333-8333-333333333333',
      ),
    );
    await latest;
    saveGate.complete();
    await earlier;
    expect(model.selected?.id, '33333333-3333-4333-8333-333333333333');
    expect(
      repository.streams.entries.where(
        (entry) =>
            !entry.value.isClosed &&
            repository.watched[entry.key] == model.selected,
      ),
      hasLength(1),
    );
  });

  test('a delayed back action cannot close a newly selected chat', () async {
    await model.openSession(sessionA);
    final saveGate = Completer<void>();
    var saves = 0;
    repository.onSaveDraft = (_, _, _) async {
      if (++saves == 1) await saveGate.future;
    };
    final earlier = model.backToSessions();
    await Future<void>.delayed(Duration.zero);
    final latest = model.openSession(sessionB);
    await latest;
    saveGate.complete();
    await earlier;
    expect(model.selected, sessionB);
    expect(
      repository.streams.entries.where(
        (entry) =>
            !entry.value.isClosed && repository.watched[entry.key] == sessionB,
      ),
      hasLength(1),
    );
  });

  test('send mode is restored from each chat draft independently', () async {
    repository.onSnapshot = (session) async => snapshotFor(
      session,
      capabilities: const CapabilitySet(
        send: true,
        steer: true,
        stop: false,
        approve: true,
        resume: false,
        models: true,
        attachments: true,
        arbitraryFiles: true,
      ),
    );
    await model.openSession(sessionA);
    model.setSteer(true);
    expect(model.sendMode, 'steer');
    await model.openSession(sessionB);
    expect(model.sendMode, 'send');
    expect(model.draftOptions, isEmpty);
  });

  test(
    'an in-flight connection rejects duplicate opens and retry taps',
    () async {
      final started = Completer<void>();
      final finish = Completer<OperationOutcome>();
      repository.onResume = (_, id) {
        started.complete();
        return finish.future;
      };
      final opening = model.openSession(sessionA, activate: true);
      await started.future;
      expect(model.connectingSession, isTrue);
      expect(model.messages, isNotEmpty);
      await model.openSession(sessionA, activate: true);
      await model.connectSession();
      expect(repository.resumedSessions, hasLength(1));
      repository.onSnapshot = (session) async => snapshotFor(session);
      finish.complete(repository.accepted('connection-result'));
      await opening;
      expect(model.connectingSession, isFalse);
      expect(model.busy, isFalse);
    },
  );

  test(
    'late history for an abandoned selection cannot activate its session',
    () async {
      final history = Completer<SessionSnapshot>();
      final requested = Completer<void>();
      repository.onSnapshot = (session) async {
        if (session == sessionA) {
          requested.complete();
          return history.future;
        }
        return snapshotFor(session);
      };
      final opening = model.openSession(sessionA, activate: true);
      await requested.future;
      await model.openSession(sessionB, activate: true);
      history.complete(disconnected(sessionA));
      await opening;
      expect(model.selected, sessionB);
      expect(repository.resumedSessions, isEmpty);
    },
  );

  test(
    'backgrounding during the initial read cancels activation intent',
    () async {
      final history = Completer<SessionSnapshot>();
      final requested = Completer<void>();
      repository.onSnapshot = (_) {
        requested.complete();
        return history.future;
      };
      final opening = model.openSession(sessionA, activate: true);
      await requested.future;
      await model.setForeground(false);
      history.complete(disconnected(sessionA));
      await opening;
      expect(repository.resumedSessions, isEmpty);
      expect(model.connectingSession, isFalse);
    },
  );

  for (final provider in [Provider.codex, Provider.claude]) {
    test(
      'unknown $provider activation is not replayed by reopen or retry',
      () async {
        final session = provider == Provider.codex ? sessionA : sessionB;
        repository.onResume = (_, id) async => OperationOutcome(
          id: id,
          kind: OutcomeKind.unknown,
          message: 'Previous submission is unresolved; it was not replayed',
          createdSession: null,
        );
        await model.openSession(session, activate: true);
        expect(model.pending, hasLength(1));
        expect(model.hasPendingSessionConnection, isTrue);
        expect(model.canConnectSession, isFalse);
        await model.backToSessions();
        await model.openSession(session, activate: true);
        await model.connectSession();
        repository.emit(disconnected(session));
        await Future<void>.delayed(Duration.zero);
        expect(repository.resumedSessions, hasLength(1));
        expect(model.pending, hasLength(1));
        expect(repository.sends + repository.stops + repository.creates, 0);

        await model.markReviewed(model.pending.single);
        expect(model.canConnectSession, isTrue);
        expect(repository.resumedSessions, hasLength(1));
      },
    );
  }

  test('unreadable pending operations cannot allow an uncertain connection to replay', () async {
    repository.onResume = (_, id) async => OperationOutcome(
      id: id,
      kind: OutcomeKind.unknown,
      message: 'Previous submission is unresolved; it was not replayed',
      createdSession: null,
    );
    await model.openSession(sessionA, activate: true);
    repository.onPending = (_, _) async =>
        throw StateError('Local state could not be saved');
    await model.openSession(sessionA, activate: true);
    await model.connectSession();
    expect(repository.resumedSessions, hasLength(1));
    expect(model.error, isNotNull);
    expect(model.connectingSession, isFalse);
  });

  test(
    'backgrounding during the final pending check prevents submission',
    () async {
      var reads = 0;
      final checking = Completer<void>();
      final finish = Completer<List<PendingOperation>>();
      repository.onPending = (_, _) async {
        if (++reads == 2) {
          checking.complete();
          return finish.future;
        }
        return [];
      };
      final opening = model.openSession(sessionA, activate: true);
      await checking.future;
      await model.setForeground(false);
      finish.complete([]);
      await opening;
      expect(repository.resumedSessions, isEmpty);
      expect(model.busy, isFalse);
      expect(model.connectingSession, isFalse);
    },
  );

  test('an account change during the final check cannot activate with old authority', () async {
    var reads = 0;
    final checking = Completer<void>();
    final finish = Completer<List<PendingOperation>>();
    repository.onPending = (_, _) async {
      if (++reads == 2) {
        checking.complete();
        return finish.future;
      }
      return [];
    };
    final opening = model.openSession(sessionA, activate: true);
    await checking.future;
    repository.emit(
      snapshotFor(
        sessionA,
        connected: false,
        capabilities: resumable,
        account: 'different-account',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    finish.complete([]);
    await opening;
    expect(repository.resumedSessions, isEmpty);
    expect(model.snapshot!.accountIdentity, 'different-account');
    expect(model.error, isA<StateError>());
  });

  for (final locale in ['zh', 'en']) {
    testWidgets(
      'one list tap connects with progress and no continue step in $locale',
      (tester) async {
        final finish = Completer<void>();
        repository.onResume = (_, id) async {
          await finish.future;
          repository.onSnapshot = (session) async => snapshotFor(session);
          return repository.accepted(id);
        };
        model.setAppearance(locale: locale);
        await tester.pumpWidget(
          BridgeApp(repository: repository, viewModel: model),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('A quieter workspace'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(repository.resumedSessions, hasLength(1));
        expect(find.byKey(const Key('session-connecting')), findsOneWidget);
        expect(find.byKey(const Key('retry-session-connection')), findsNothing);
        expect(find.text('继续会话'), findsNothing);
        expect(find.text('Continue session'), findsNothing);
        expect(find.byKey(const Key('chat-transcript')), findsOneWidget);
        expect(model.messages, isNotEmpty);

        finish.complete();
        await tester.pumpAndSettle();
        expect(model.snapshot!.connected, isTrue);
        expect(find.byKey(const Key('session-connecting')), findsNothing);
        expect(find.byKey(const Key('retry-session-connection')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('a failed automatic connection offers one explicit retry', (
    tester,
  ) async {
    repository.onResume = (_, id) async => OperationOutcome(
      id: id,
      kind: OutcomeKind.notSubmitted,
      message: 'The desktop gateway is offline. Waiting to reconnect.',
      createdSession: null,
    );
    model.setAppearance(locale: 'zh');
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('A quieter workspace'));
    await tester.pumpAndSettle();
    expect(repository.resumedSessions, hasLength(1));
    expect(
      find.text(const Strings(Locale('zh')).t('Retry connection')),
      findsOneWidget,
    );
    expect(find.text('继续会话'), findsNothing);
    repository.emit(disconnected(sessionA));
    await tester.pumpAndSettle();
    expect(repository.resumedSessions, hasLength(1));
    repository.onResume = (_, id) async {
      repository.onSnapshot = (session) async => snapshotFor(session);
      return repository.accepted(id);
    };
    await tester.tap(find.byKey(const Key('retry-session-connection')));
    await tester.pumpAndSettle();
    expect(repository.resumedSessions, hasLength(2));
    expect(model.snapshot!.connected, isTrue);
    expect(find.byKey(const Key('retry-session-connection')), findsNothing);
    expect(repository.sends + repository.stops + repository.creates, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
