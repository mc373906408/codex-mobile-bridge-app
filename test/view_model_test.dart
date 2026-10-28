import 'dart:async';

import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

Future<void> tick() async {
  for (var index = 0; index < 5; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeRepository repository;
  late BridgeViewModel model;
  setUp(() async {
    repository = FakeRepository();
    model = BridgeViewModel(repository);
    await model.initialize();
    await model.selectComputer(computerA);
    await model.openSession(sessionA);
  });
  tearDown(() async {
    model.dispose();
    await tick();
  });

  test(
    'a slow previous connection never replaces the selected computer',
    () async {
      final old = Completer<AuthStatus>();
      repository.onConnect = (computer) async =>
          computer.id == computerA.id ? old.future : authenticatedStatus;
      final pending = model.selectComputer(computerA);
      await tick();
      await model.selectComputer(computerB);
      old.complete(authenticatedStatus);
      await pending;
      expect(model.computer, computerB);
      expect(model.authenticated, isTrue);
    },
  );

  test(
    'history arriving after a live revision cannot replace that revision',
    () async {
      final old = Completer<HistoryPage>();
      repository.onHistory = (_, _) => old.future;
      final loading = model.loadOlder();
      repository.emit(
        snapshotFor(
          sessionA,
          token: 'live-token',
          messages: [message('live-a', 'New live state')],
        ),
      );
      await tick();
      old.complete(
        HistoryPage(
          messages: [message('obsolete-a', 'Obsolete history')],
          before: null,
          hasMore: false,
          epoch: 'epoch-a',
          reset: false,
        ),
      );
      await loading;
      expect(model.messages.map((row) => row.id), ['live-a']);
      expect(model.snapshot!.controlToken, 'live-token');
      expect(model.fresh, isTrue);
    },
  );

  test('two taps submit one operation and acceptance clears only its draft revision', () async {
    final result = Completer<OperationOutcome>();
    repository.onSend = (_, _) => result.future;
    model.editDraft('one message');
    final first = model.send();
    await model.send();
    await tick();
    expect(repository.sends, 1);
    result.complete(repository.accepted('first'));
    await first;
    expect(model.draftText, isEmpty);
    expect(model.busy, isFalse);
    expect((await repository.draft(sessionA, 'account-a')).text, isEmpty);
  });

  test(
    'editing while a write is in flight preserves the newer draft',
    () async {
      final result = Completer<OperationOutcome>();
      repository.onSend = (_, _) => result.future;
      model.editDraft('submitted text');
      final sending = model.send();
      await tick();
      model.editDraft('my next draft');
      result.complete(repository.accepted('first'));
      await sending;
      await model.flushDraft();
      expect(model.draftText, 'my next draft');
      expect(
        (await repository.draft(sessionA, 'account-a')).text,
        'my next draft',
      );
    },
  );

  test('unknown submission keeps the draft and blocks repeat sends', () async {
    repository.onSend = (_, id) async => OperationOutcome(
      id: id,
      kind: OutcomeKind.unknown,
      message: 'Check the computer',
      createdSession: null,
    );
    model.editDraft('keep this draft');
    await model.send();
    expect(model.draftText, 'keep this draft');
    expect(model.pending, hasLength(1));
    expect(model.canSend, isFalse);
    await model.send();
    expect(repository.sends, 1);
    await model.markReviewed(model.pending.single);
    expect(model.canSend, isTrue);
    expect(repository.sends, 1);
  });

  test(
    'background cancels reads but retains an in-flight write acknowledgement',
    () async {
      final result = Completer<OperationOutcome>();
      repository.onSend = (_, _) => result.future;
      model.editDraft('send before background');
      final sending = model.send();
      await tick();
      await model.setForeground(false);
      expect(model.fresh, isFalse);
      expect(model.canSend, isFalse);
      expect(repository.stops, 0);
      result.complete(repository.accepted('first'));
      await sending;
      expect(model.draftText, isEmpty);
      await model.setForeground(true);
      expect(model.draftText, isEmpty);
      expect(repository.sends, 1);
      expect(repository.connects, greaterThan(1));
    },
  );

  test(
    'late foreground reauthentication is ignored after backgrounding again',
    () async {
      await model.setForeground(false);
      final auth = Completer<AuthStatus>();
      repository.onConnect = (_) => auth.future;
      final resume = model.setForeground(true);
      await tick();
      await model.setForeground(false);
      auth.complete(authenticatedStatus);
      await resume;
      expect(model.foreground, isFalse);
      expect(model.fresh, isFalse);
      await model.perform((snapshot, id) => repository.stop(snapshot, id));
      expect(repository.stops, 0);
    },
  );

  test('a snapshot completed in the background cannot grant control', () async {
    await model.backToSessions();
    final snapshot = Completer<SessionSnapshot>();
    repository.onSnapshot = (_) => snapshot.future;
    final opening = model.openSession(sessionA);
    await tick();
    await model.setForeground(false);
    snapshot.complete(snapshotFor(sessionA));
    await opening;
    expect(model.snapshot, isNull);
    expect(model.fresh, isFalse);
    expect(model.draftEditable, isFalse);
  });

  test(
    'old account draft restoration never crosses a newer account boundary',
    () async {
      model.editDraft('private account A draft');
      final first = Completer<Draft>(), second = Completer<Draft>();
      repository.onDraft = (_, account) =>
          account == 'account-b' ? first.future : second.future;
      repository.emit(snapshotFor(sessionA, account: 'account-b', token: 'b'));
      await tick();
      repository.emit(snapshotFor(sessionA, account: 'account-c', token: 'c'));
      await tick();
      second.complete(
        const Draft(text: 'account C only', attachments: [], revision: 4),
      );
      await tick();
      first.complete(
        const Draft(text: 'account B private', attachments: [], revision: 9),
      );
      await tick();
      expect(model.draftText, 'account C only');
      expect(model.snapshot!.accountIdentity, 'account-c');
      expect(
        repository.drafts[repository.scope(sessionA, 'account-a')]!.text,
        'private account A draft',
      );
    },
  );

  test('missing identity has no restorable or sendable draft', () async {
    model.editDraft('account scoped draft');
    repository.emit(snapshotFor(sessionA, account: ''));
    await tick();
    expect(model.draftEditable, isFalse);
    expect(model.draftText, isEmpty);
    expect(model.canSend, isFalse);
  });

  test('a local persistence failure prevents a network write', () async {
    repository.onSaveDraft = (_, _, _) async => throw StateError('Disk full');
    model.editDraft('do not lose this');
    await model.send();
    expect(repository.sends, 0);
    expect(model.draftText, 'do not lose this');
    expect(
      model.error,
      isA<StateError>().having(
        (error) => error.message,
        'message',
        'Disk full',
      ),
    );
    expect(model.canSend, isFalse);
    repository.onSaveDraft = null;
  });

  test('new-chat dialogs from an earlier connection cannot submit', () async {
    final original = model.connectionGeneration;
    await model.setForeground(false);
    await model.setForeground(true);
    final project = (await repository.projects(
      computerA,
      Provider.codex,
      'local',
    )).single;
    await model.createChat(project, 'Title', '', expectedConnection: original);
    expect(repository.creates, 0);
  });

  test(
    'desktop inbox navigation resolves the original SSH environment',
    () async {
      const event = InboxEntry(
        id: 'notification-a',
        title: 'Ready',
        body: 'A new reply',
        session: SessionRef(
          computerId: 'computer-a',
          provider: Provider.claude,
          environment: 'local',
          id: 'opaque-claude-session',
        ),
      );
      await model.openInboxEntry(event);
      expect(model.selected, sessionB);
      expect(model.provider, Provider.claude);
    },
  );

  test('appearance and in-app read markers are saved locally', () async {
    model.setAppearance(theme: 'dark', locale: 'zh');
    model.inbox = const [
      InboxEntry(id: 'scoped-event', title: 'Ready', body: '', session: null),
    ];
    model.markInboxRead();
    await tick();
    expect(repository.savedPreferences.theme, 'dark');
    expect(repository.savedPreferences.locale, 'zh');
    expect(repository.savedPreferences.readInbox, ['scoped-event']);
  });
}
