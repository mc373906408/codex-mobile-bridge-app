import 'dart:async';
import 'dart:convert';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/ui/business/workspace_tools.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

const parent = SessionRef(
  computerId: 'computer-a',
  provider: Provider.codex,
  entry: 'instance-a',
  environment: 'codex:instance-a',
  id: 'workspace-parent',
);

class _WorkspaceRepository extends FakeRepository {
  final reads = <(SessionRef, SessionResource, Map<String, dynamic>)>[];
  final writes = <(SessionRef, SessionCommand, Map<String, dynamic>)>[];

  @override
  Future<String> sessionResource(
    SessionRef session,
    SessionResource resource,
    Map<String, dynamic> parameters,
  ) async {
    if (resource != SessionResource.catalog) {
      reads.add((session, resource, parameters));
    }
    return jsonEncode(switch (resource) {
      SessionResource.files => {
        'entries': [
          {'path': 'example.txt', 'name': 'example.txt', 'kind': 'file'},
        ],
      },
      SessionResource.filePreview => {'kind': 'text', 'text': 'Sample source'},
      SessionResource.gitStatus => {
        'available': true,
        'branch': 'workbench-test',
        'scope': '.',
        'version': 'state-a',
        'entries': [
          {'path': 'example.txt', 'index': '.', 'worktree': 'M'},
        ],
      },
      SessionResource.gitDiff => {'text': '+Sample change'},
      SessionResource.terminal => {'mode': 'pty', 'shell': 'test-shell'},
      SessionResource.sideChats => {
        'chats': [
          {'id': 'existing-side', 'title': 'Saved side chat'},
        ],
      },
      SessionResource.tasks => {
        'tasks': [
          {'id': 'background', 'title': 'Provider background task'},
        ],
      },
      SessionResource.subagents when parameters.containsKey('id') => {
        'historyComplete': false,
        'turns': [
          {
            'status': 'completed',
            'messages': [
              {'role': 'assistant', 'text': 'Saved agent result'},
            ],
          },
        ],
      },
      SessionResource.subagents => {
        'agents': [
          {'id': 'agent-a', 'parentId': session.id, 'title': 'Research agent'},
          {'id': 'agent-b', 'parentId': 'agent-a', 'title': 'Nested agent'},
        ],
      },
      _ => <String, dynamic>{},
    });
  }

  @override
  Future<BusinessReply> sessionCommand(
    SessionSnapshot snapshot,
    String id,
    SessionCommand command,
    Map<String, dynamic> parameters,
  ) async {
    writes.add((snapshot.session, command, parameters));
    return BusinessReply(
      outcome: OperationOutcome(
        id: id,
        kind: OutcomeKind.accepted,
        message: '',
      ),
      data: jsonEncode(switch (command) {
        SessionCommand.sideChat => {'id': 'created-side'},
        SessionCommand.terminal => {'output': 'Sample terminal output'},
        _ => <String, dynamic>{},
      }),
    );
  }
}

Finder _choice(WorkspaceTool tool) =>
    find.byKey(ValueKey(('new-workspace-tool', tool)));

Future<BridgeViewModel> _mount(
  WidgetTester tester,
  _WorkspaceRepository repository, {
  SessionRef session = parent,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final model = BridgeViewModel(repository);
  await model.initialize();
  await model.selectComputer(computerA);
  await model.openSession(session);
  await tester.pumpWidget(BridgeApp(repository: repository, viewModel: model));
  await tester.pumpAndSettle();
  return model;
}

Future<void> _unmount(WidgetTester tester, BridgeViewModel model) async {
  await tester.pumpWidget(const SizedBox.shrink());
  model.dispose();
  await tester.pump();
}

void _expectRead(
  (SessionRef, SessionResource, Map<String, dynamic>) request,
  SessionResource resource,
  Map<String, dynamic> parameters,
) {
  expect(request.$1, parent);
  expect(request.$2, resource);
  expect(request.$3, parameters);
}

Future<void> _tap(WidgetTester tester, Finder item) async {
  await tester.tap(item);
  await tester.pumpAndSettle();
}

Future<void> _settleSessionChange(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}

Future<void> _addTool(WidgetTester tester, WorkspaceTool tool) async {
  await _tap(tester, find.byTooltip('New tab'));
  await tester.ensureVisible(_choice(tool));
  await _tap(tester, _choice(tool));
}

void main() {
  testWidgets(
    'new tab picker does not dim the chat and lists tools in Web order',
    (tester) async {
      final repository = _WorkspaceRepository();
      final model = await _mount(tester, repository);
      await tester.enterText(find.byType(TextField), 'Keep my draft');
      await _tap(tester, find.byTooltip('New tab'));
      final title = find.text('New tab');
      expect(title, findsOneWidget);
      expect(
        ModalRoute.of(tester.element(title))?.barrierColor,
        Colors.transparent,
      );
      var previousTop = 0.0;
      for (final tool in WorkspaceTool.values) {
        final choice = _choice(tool);
        expect(tester.widget<OutlinedButton>(choice).onPressed, isNotNull);
        final top = tester.getTopLeft(choice).dy;
        expect(top, greaterThan(previousTop));
        previousTop = top;
      }
      expect(repository.reads, isEmpty);
      expect(repository.writes, isEmpty);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(title, findsNothing);
      await _tap(tester, find.byTooltip('New tab'));
      await _tap(tester, find.byTooltip('Close'));
      expect(title, findsNothing);
      expect(find.text('Keep my draft'), findsOneWidget);
      expect(model.draftText, 'Keep my draft');
      await _unmount(tester, model);
    },
  );

  testWidgets('Files and Git open their own tabs and retain panel state', (
    tester,
  ) async {
    final repository = _WorkspaceRepository();
    final model = await _mount(tester, repository);
    await _addTool(tester, WorkspaceTool.files);
    expect(repository.reads.map((request) => request.$2), [
      SessionResource.files,
    ]);
    expect(find.byTooltip('Upload file'), findsOneWidget);
    await _tap(tester, find.text('example.txt'));
    _expectRead(repository.reads.last, SessionResource.filePreview, {
      'path': 'example.txt',
    });
    await tester.pageBack();
    await tester.pumpAndSettle();
    await _addTool(tester, WorkspaceTool.git);
    expect(find.text('workbench-test'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Branches'), findsOneWidget);
    await _tap(tester, find.text('example.txt'));
    _expectRead(repository.reads.last, SessionResource.gitDiff, {
      'path': 'example.txt',
      'section': 'unstaged',
    });
    await tester.pageBack();
    await tester.pumpAndSettle();
    await _addTool(tester, WorkspaceTool.files);
    expect(find.byTooltip('Close Files tab'), findsOneWidget);
    expect(
      repository.reads.where((request) => request.$2 == SessionResource.files),
      hasLength(1),
    );
    await _tap(tester, find.byTooltip('Close Files tab'));
    expect(find.byTooltip('Close Files tab'), findsNothing);
    expect(
      find.byKey(const Key('chat-transcript')).hitTestable(),
      findsOneWidget,
    );
    final beforeReopen = repository.reads.length;
    final watchCount = repository.watched.length;
    unawaited(model.openSession(parent));
    await _settleSessionChange(tester);
    expect(model.loadingHistory, isFalse);
    expect(repository.watched, hasLength(watchCount + 1));
    expect(find.byTooltip('Close Git tab'), findsOneWidget);
    expect(repository.reads, hasLength(beforeReopen));
    expect(repository.writes, isEmpty);
    await _unmount(tester, model);
  });

  testWidgets(
    'Terminal inspects first and never opens or closes a shell implicitly',
    (tester) async {
      final repository = _WorkspaceRepository();
      final model = await _mount(tester, repository);
      await _addTool(tester, WorkspaceTool.terminal);
      _expectRead(repository.reads.single, SessionResource.terminal, {
        'mode': 'pty',
      });
      expect(find.text('test-shell'), findsOneWidget);
      expect(repository.writes, isEmpty);
      await _tap(tester, find.text('Open terminal'));
      expect(repository.writes, isEmpty);
      await _tap(tester, find.text('Confirm'));
      expect(repository.writes.single.$2, SessionCommand.terminal);
      expect(repository.writes.single.$3['action'], 'open');
      await _tap(tester, find.byTooltip('Close Terminal tab'));
      expect(repository.writes, hasLength(1));
      await _unmount(tester, model);
    },
  );

  for (final create in [false, true]) {
    testWidgets(
      'Side chat ${create ? 'creates' : 'opens'} in the original instance',
      (tester) async {
        final repository = _WorkspaceRepository();
        final model = await _mount(tester, repository);
        await _addTool(tester, WorkspaceTool.sideChat);
        _expectRead(repository.reads.single, SessionResource.sideChats, {
          'view': 'native',
        });
        expect(repository.writes, isEmpty);
        await _tap(
          tester,
          find.text(create ? 'New side chat' : 'Saved side chat'),
        );
        await _settleSessionChange(tester);
        expect(model.selected?.id, create ? 'created-side' : 'existing-side');
        expect(model.selected?.entry, parent.entry);
        expect(model.selected?.environment, parent.environment);
        if (create) {
          final (session, command, parameters) = repository.writes.single;
          expect(session, parent);
          expect(command, SessionCommand.sideChat);
          expect(parameters['action'], 'create');
          expect(parameters['creationId'], isNotEmpty);
        } else {
          expect(repository.writes, isEmpty);
        }
        expect(find.byTooltip('Close Side chat tab'), findsNothing);
        await _unmount(tester, model);
      },
    );
  }

  testWidgets(
    'Subagents reads saved records and pauses when the tab is hidden',
    (tester) async {
      final repository = _WorkspaceRepository();
      final model = await _mount(tester, repository);
      await _addTool(tester, WorkspaceTool.subagents);
      _expectRead(repository.reads.single, SessionResource.subagents, {});
      expect(find.text('Nested agent'), findsOneWidget);
      await _tap(tester, find.text('Nested agent'));
      expect(repository.reads.last.$3, {'id': 'agent-b'});
      expect(find.text('Saved history; status is not live'), findsOneWidget);
      expect(
        find.text('Only the latest 10 turns are available'),
        findsOneWidget,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Chat'));
      await tester.pump(const Duration(seconds: 11));
      expect(repository.reads, hasLength(2));
      expect(repository.writes, isEmpty);
      await _unmount(tester, model);
    },
  );

  testWidgets(
    'Web capability rules disable unavailable tools but allow provider tasks',
    (tester) async {
      final repository = _WorkspaceRepository()
        ..onSnapshot = (session) async => snapshotFor(
          session,
          metadata:
              '{"session":{},"capabilities":{"terminal":false,"tasks":true}}',
        );
      final model = await _mount(tester, repository, session: sessionB);
      await _tap(tester, find.byTooltip('New tab'));
      for (final tool in [WorkspaceTool.terminal, WorkspaceTool.sideChat]) {
        expect(tester.widget<OutlinedButton>(_choice(tool)).onPressed, isNull);
      }
      expect(find.text('Unavailable in this client'), findsNWidgets(2));
      expect(repository.reads, isEmpty);
      await _tap(tester, _choice(WorkspaceTool.subagents));
      expect(find.text('Provider background task'), findsOneWidget);
      expect(repository.reads.single.$2, SessionResource.tasks);
      expect(repository.writes, isEmpty);
      await _unmount(tester, model);
    },
  );

  testWidgets('account changes discard stale picker results and tools', (
    tester,
  ) async {
    var account = 'account-a';
    final repository = _WorkspaceRepository()
      ..onSnapshot = (session) async => snapshotFor(session, account: account);
    final model = await _mount(tester, repository);
    await _addTool(tester, WorkspaceTool.files);
    await _tap(tester, find.byTooltip('New tab'));
    account = 'account-b';
    repository.emit(snapshotFor(parent, account: account));
    await tester.pumpAndSettle();
    await _tap(tester, _choice(WorkspaceTool.git));
    expect(find.byTooltip('Close Files tab'), findsNothing);
    expect(find.byTooltip('Close Git tab'), findsNothing);
    expect(repository.reads.map((request) => request.$2), [
      SessionResource.files,
    ]);
    await _unmount(tester, model);
  });

  for (final locale in ['zh', 'en']) {
    testWidgets('picker scrolls with large $locale text on a narrow screen', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = _WorkspaceRepository()
        ..savedPreferences = UiPreferences(
          theme: 'dark',
          locale: locale,
          readInbox: const [],
        );
      final model = await _mount(
        tester,
        repository,
        size: const Size(320, 640),
      );
      await _tap(tester, find.byTooltip(locale == 'zh' ? '新标签页' : 'New tab'));
      await tester.ensureVisible(_choice(WorkspaceTool.subagents));
      await tester.pumpAndSettle();
      expect(_choice(WorkspaceTool.subagents).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester, model);
    });
  }
}
