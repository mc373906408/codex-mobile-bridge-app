import 'dart:async';
import 'dart:convert';

import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/ui/business/common.dart';
import 'package:bridge_mobile/ui/business/creation_page.dart';
import 'package:bridge_mobile/ui/business/session_controls.dart';
import 'package:bridge_mobile/ui/business/skill_picker.dart';
import 'package:bridge_mobile/ui/business/workspace_page.dart';
import 'package:bridge_mobile/ui/design/bridge_theme.dart';
import 'package:bridge_mobile/ui/message_card.dart';
import 'package:bridge_mobile/ui/pages/session_list_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class _UiRepository extends FakeRepository {
  _UiRepository({this.pendingProjectOperation = false});

  bool pendingProjectOperation;
  (SessionRef, String, String)? projectReview;

  @override
  Future<void> markReviewed(
    SessionRef session,
    String account,
    String id,
  ) async {
    projectReview = (session, account, id);
    pendingProjectOperation = false;
  }

  @override
  Future<String> sessionResource(
    SessionRef session,
    SessionResource resource,
    Map<String, dynamic> parameters,
  ) async => jsonEncode(switch (resource) {
    SessionResource.catalog =>
      parameters['kind'] == 'skills'
          ? {
              'skills': [
                {
                  'id': 'skill',
                  'name': 'Sample skill',
                  'description': 'Read the selected project',
                },
              ],
            }
          : {
              'models': [
                {
                  'id': 'model-a',
                  'name': 'GPT-6 Astra · agent',
                  'efforts': ['low', 'high'],
                  'defaultEffort': 'high',
                },
              ],
            },
    SessionResource.files => {
      'entries': [
        {'path': 'src', 'name': 'src', 'kind': 'directory'},
        {
          'path': 'README.md',
          'name': 'README.md',
          'kind': 'file',
          'size': 4096,
        },
      ],
    },
    SessionResource.gitStatus => {
      'available': true,
      'scope': '.',
      'branch': 'main',
      'entries': [],
    },
    SessionResource.sideChats => {
      'chats': [
        {'id': 'child', 'title': 'Related task', 'status': 'idle'},
      ],
    },
    _ => <String, dynamic>{},
  });

  @override
  Future<GatewayState> gatewayResource(
    Computer computer,
    Provider provider,
    String entry,
    GatewayResource resource,
    Map<String, dynamic> parameters,
  ) async => GatewayState(
    identity: 'gateway',
    data: jsonEncode(switch (resource) {
      GatewayResource.projects => {
        'createModels': true,
        'pendingProjectOperations': [
          if (pendingProjectOperation)
            {
              'id': 'unconfirmed-registration',
              'action': 'gateway/RegisterProject',
              'identity': 'original-coding-account',
            },
        ],
        'projects': [
          {
            'key': 'project',
            'name': 'Project',
            'environment': 'local',
            'type': 'desktop',
          },
        ],
        'environments': [
          {
            'key': 'local',
            'name': 'This computer',
            'type': 'desktop',
            'canBrowse': false,
          },
        ],
      },
      GatewayResource.creationModels => {
        'models': [
          {
            'id': 'model-a',
            'name': 'GPT-6 Astra · agent',
            'isDefault': true,
            'efforts': ['low', 'high'],
            'defaultEffort': 'high',
          },
        ],
        'currentModel': 'model-a',
      },
      GatewayResource.sessionActivity => <String, dynamic>{},
    }),
  );
}

void main() {
  testWidgets(
    'new chat can mark a project operation reviewed without retrying',
    (tester) async {
      final repository = _UiRepository(pendingProjectOperation: true);
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.selectComputer(computerA);
      final scope = GatewayBusiness(model);
      await tester.pumpWidget(MaterialApp(home: CreationDialog(scope: scope)));
      await tester.pumpAndSettle();
      final review = find.widgetWithText(
        TextButton,
        'Review project registration',
      );
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(repository.projectReview, isNull);
      await tester.tap(find.text('Mark reviewed'));
      await tester.pumpAndSettle();
      final (session, identity, operation) = repository.projectReview!;
      expect(session.computerId, computerA.id);
      expect(session.id, 'management');
      expect(identity, 'original-coding-account');
      expect(operation, 'unconfirmed-registration');
      expect(review, findsNothing);
      expect(repository.creates, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      scope.dispose();
      model.dispose();
    },
  );

  testWidgets('context dialog closes without leaving the selected chat', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = FakeRepository();
    final model = BridgeViewModel(repository);
    await model.initialize();
    await model.selectComputer(computerA);
    await model.openSession(sessionA);
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Context usage'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(model.selected, sessionA);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
  });

  for (final width in [390.0, 1024.0]) {
    testWidgets('opening chat at $width shows the newest message', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final transcript = [
        for (var index = 0; index < 39; index++)
          message(
            'row-$index',
            'Message $index. ${'Longer content. ' * (index % 7)}',
          ),
        message('latest', 'Most recent response'),
      ];
      final initialSnapshot = Completer<SessionSnapshot>();
      var snapshotReads = 0;
      var olderReads = 0;
      final repository = FakeRepository()
        ..onSnapshot = (session) async {
          if (++snapshotReads == 1) return initialSnapshot.future;
          return snapshotFor(session, messages: transcript);
        }
        ..onHistory = (_, _) async {
          olderReads++;
          return HistoryPage(
            messages: [message('older-anchor', 'Old history')],
            before: null,
            hasMore: false,
            epoch: 'epoch-a',
            reset: false,
          );
        };
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.selectComputer(computerA);
      model.setPresentation('readingPositions', {
        model.viewKey(snapshotFor(sessionA)): {
          'offset': 240,
          'oldest': 'older-anchor',
        },
      });
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      final conversations = find.byType(SessionListTile);
      expect(conversations, findsOneWidget);
      await tester.tap(conversations);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final latest = find.byKey(const ValueKey('latest'));
      expect(find.text('Older messages'), findsNothing);
      expect(snapshotReads, 1);
      expect(latest, findsNothing);
      initialSnapshot.complete(snapshotFor(sessionA, messages: transcript));
      await tester.pump();
      expect(latest.hitTestable(), findsOneWidget);
      expect(olderReads, 0);
      final list = find.byKey(const Key('chat-transcript'));
      tester.widget<ScrollView>(list).controller!.jumpTo(600);
      await tester.pump();
      expect(latest.hitTestable(), findsNothing);

      if (width < 840) {
        await tester.tap(find.byTooltip('Back to conversations'));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        expect(model.selected, isNull);
      }
      await tester.tap(conversations);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(repository.watched.length, 2);
      expect(latest.hitTestable(), findsOneWidget);
      final position = tester.widget<ScrollView>(list).controller!.position;
      expect(position.pixels, position.minScrollExtent);
      expect(olderReads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    });
  }

  testWidgets('scrolling toward older history loads one page without a jump', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transcript = [
      for (var index = 0; index < 10; index++)
        message('row-$index', 'Current page $index'),
    ];
    final history = Completer<HistoryPage>();
    var historyReads = 0;
    final repository = FakeRepository()
      ..onSnapshot = (session) async {
        return snapshotFor(session, messages: transcript);
      }
      ..onHistory = (_, cursor) {
        expect(cursor, 'older');
        historyReads++;
        return history.future;
      };
    final model = BridgeViewModel(repository);
    await model.initialize();
    await model.selectComputer(computerA);
    await model.openSession(sessionA);
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    final list = find.byKey(const Key('chat-transcript'));
    expect(find.text('Older messages'), findsNothing);
    final scrollable = find.descendant(
      of: list,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.up,
      ),
    );
    expect(historyReads, 0);
    for (var attempt = 0; attempt < 12 && historyReads == 0; attempt++) {
      await tester.drag(list, const Offset(0, 170));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(historyReads, 1);
    expect(model.loadingHistory, isTrue);
    await tester.drag(list, const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 300));
    expect(historyReads, 1);
    final first = find.byKey(const ValueKey('row-0'));
    expect(first.hitTestable(), findsOneWidget);
    final before = tester.getCenter(first);
    history.complete(
      HistoryPage(
        messages: [message('older-page', 'Previous page')],
        before: null,
        hasMore: false,
        epoch: 'epoch-a',
        reset: false,
      ),
    );
    await tester.pump();
    expect(historyReads, 1);
    expect(tester.getCenter(first), before);
    final older = find.byKey(const ValueKey('older-page'));
    await tester.scrollUntilVisible(older, 140, scrollable: scrollable);
    expect(tester.getCenter(older).dy, lessThan(tester.getCenter(first).dy));
    await tester.drag(list, const Offset(0, 140));
    await tester.pumpAndSettle();
    expect(historyReads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
  });

  testWidgets(
    'pulling toward the start of a short chat loads history',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var historyReads = 0;
      final repository = FakeRepository()
        ..onSnapshot = (session) async =>
            snapshotFor(session, messages: [message('latest', 'Short chat')]);
      repository.onHistory = (_, _) async {
        historyReads++;
        return HistoryPage(
          messages: [message('older', 'Earlier message')],
          before: null,
          hasMore: false,
          epoch: 'epoch-a',
          reset: false,
        );
      };
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.selectComputer(computerA);
      await model.openSession(sessionA);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(const Key('chat-transcript'));
      final position = tester.widget<ScrollView>(list).controller!.position;
      expect(position.pixels, position.maxScrollExtent);
      expect(find.text('Older messages'), findsNothing);
      expect(historyReads, 0);

      await tester.drag(list, const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(historyReads, 0);
      await tester.drag(list, const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(historyReads, 1);
      expect(find.byKey(const ValueKey('older')).hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('live messages follow the bottom and preserve older reading', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transcript = [
      for (var index = 0; index < 40; index++)
        message('row-$index', 'Message $index. ${'Text. ' * (index % 7)}'),
    ];
    final repository = FakeRepository()
      ..onSnapshot = (session) async =>
          snapshotFor(session, messages: transcript);
    final model = BridgeViewModel(repository);
    await model.initialize();
    await model.selectComputer(computerA);
    await model.openSession(sessionA);
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    transcript.add(message('live', 'New message while following'));
    repository.emit(snapshotFor(sessionA, messages: transcript));
    await tester.pump();
    expect(find.byKey(const ValueKey('live')).hitTestable(), findsOneWidget);
    final controller = tester
        .widget<ScrollView>(find.byKey(const Key('chat-transcript')))
        .controller!;
    controller.jumpTo(850);
    await tester.pump();
    final visible = find.byType(MessageCard).hitTestable().first;
    final anchor = find.byKey(tester.widget(visible).key!);
    final before = tester.getTopLeft(anchor);
    transcript.add(message('more-live', 'A longer live update. ' * 12));
    repository.emit(snapshotFor(sessionA, messages: transcript));
    await tester.pump();
    expect(anchor.hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(anchor), before);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
  });

  testWidgets('a short chat cannot scroll its fitting messages out of view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = FakeRepository()
      ..onSnapshot = (session) async => snapshotFor(
        session,
        messages: [message('first', 'One'), message('second', 'Two')],
      );
    final model = BridgeViewModel(repository);
    await model.initialize();
    await model.selectComputer(computerA);
    await model.openSession(sessionA);
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    final position = tester
        .widget<ScrollView>(find.byKey(const Key('chat-transcript')))
        .controller!
        .position;
    expect(position.minScrollExtent, position.maxScrollExtent);
    expect(find.byKey(const ValueKey('first')).hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('second')).hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
  });

  testWidgets(
    'workspace tab preserves the mounted transcript and reading offset',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _UiRepository()
        ..onSnapshot = (session) async => snapshotFor(
          session,
          messages: [
            for (var i = 0; i < 40; i++)
              message('$i', 'A longer transcript message $i'),
          ],
        );
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.selectComputer(computerA);
      await model.openSession(sessionA);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<ScrollView>(find.byKey(const Key('chat-transcript')))
          .controller!;
      controller.jumpTo(300);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('New tab'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ScrollView>(
              find.byKey(const Key('chat-transcript'), skipOffstage: false),
            )
            .controller,
        same(controller),
      );
      await tester.tap(find.text('Chat').first);
      await tester.pumpAndSettle();
      expect(controller.offset, 300);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    },
  );
  for (final language in ['en', 'zh']) {
    for (final page in [
      'workspace',
      'git',
      'terminal',
      'tasks',
      'controls',
      'skills',
      'queue',
      'creation',
    ]) {
      testWidgets('UI surface $page fits narrow large $language text', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final repository = _UiRepository();
        final model = BridgeViewModel(repository);
        await model.initialize();
        await model.selectComputer(computerA);
        await model.openSession(sessionA);
        final scope = SessionBusiness(model, model.snapshot!);
        final gateway = GatewayBusiness(model);
        final Widget body = switch (page) {
          'workspace' ||
          'git' ||
          'terminal' ||
          'tasks' => WorkspacePage(scope: scope),
          'controls' => SessionControlsPage(scope: scope),
          'queue' => MessageQueuePage(scope: scope),
          _ => const SizedBox.shrink(),
        };
        await tester.pumpWidget(
          MaterialApp(
            theme: bridgeTheme(Brightness.light),
            locale: Locale(language),
            supportedLocales: const [Locale('en'), Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: page == 'creation' || page == 'skills'
                ? Builder(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        onPressed: () => page == 'skills'
                            ? skillPickerDialog(context, scope)
                            : showDialog<void>(
                                context: context,
                                builder: (_) => CreationDialog(scope: gateway),
                              ),
                        child: const Text('Open'),
                      ),
                    ),
                  )
                : body,
          ),
        );
        await tester.pumpAndSettle();
        if (['git', 'terminal', 'tasks'].contains(page)) {
          final tab = switch (page) {
            'git' => 'Git',
            'terminal' => language == 'zh' ? '终端' : 'Terminal',
            _ => language == 'zh' ? '派生任务' : 'Related tasks',
          };
          await tester.ensureVisible(find.text(tab));
          await tester.tap(find.text(tab));
          await tester.pumpAndSettle();
          expect(
            tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
            page == 'git'
                ? 1
                : page == 'terminal'
                ? 2
                : 3,
          );
        }
        if (page == 'creation' || page == 'skills') {
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        expect(repository.sends + repository.stops + repository.creates, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        scope.dispose();
        gateway.dispose();
        model.dispose();
        await tester.pump();
      });
    }
  }
}
