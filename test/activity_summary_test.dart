import 'dart:async';
import 'dart:convert';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/ui/activity_summary.dart';
import 'package:bridge_mobile/ui/business/appearance_settings.dart';
import 'package:bridge_mobile/ui/message_card.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

ChatMessage step(
  String id, {
  String kind = 'commandExecution',
  String turn = 'turn-a',
  String status = 'completed',
}) => ChatMessage(
  id: id,
  role: 'activity',
  title: kind == 'reasoning' ? '思考摘要' : '执行命令',
  text: kind == 'reasoning'
      ? 'A brief thought summary'
      : 'git status --short --branch $id',
  output: 'Full output for $id',
  truncated: false,
  attachments: const [],
  metadata: jsonEncode({'kind': kind, 'turnId': turn, 'turnStatus': status}),
);

ChatMessage retry(
  String id,
  int attempt, {
  int total = 5,
  String turn = 'turn-a',
  String? text,
  String role = 'assistant',
  bool truncated = false,
  String output = '',
  List<Attachment> attachments = const [],
}) => ChatMessage(
  id: id,
  role: role,
  title: '',
  text: text ?? 'Reconnecting... $attempt/$total',
  output: output,
  truncated: truncated,
  attachments: attachments,
  metadata: jsonEncode({
    'kind': 'agentMessage',
    'turnId': turn,
    'turnStatus': 'inProgress',
  }),
);

Future<BridgeViewModel> open(FakeRepository repository) async {
  final model = BridgeViewModel(repository);
  await model.initialize();
  await model.selectComputer(computerA);
  await model.openSession(sessionA);
  return model;
}

void main() {
  setUpAll(() async {
    final bytes = rootBundle.load('assets/fonts/PlexSans.ttf');
    for (final family in ['Ahem', 'Roboto', '.SF UI Text', '.SF UI Display']) {
      await (FontLoader(family)..addFont(bytes)).load();
    }
    await (FontLoader(
      'PlexMono',
    )..addFont(rootBundle.load('assets/fonts/PlexMono.ttf'))).load();
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        ))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  test('groups adjacent work by turn without hiding answers or errors', () {
    final messages = [
      message('user', 'Request', role: 'user'),
      step('thought', kind: 'reasoning'),
      step('one'),
      step('two'),
      message('answer', 'Answer'),
      step('three'),
      message('error', 'A real failure', role: 'error'),
      step('four'),
      step('five', turn: 'turn-b'),
    ];
    final rows = groupTranscriptRows(messages, const ChatAppearance({}));
    expect(rows.map((r) => r.messages.length), [1, 3, 1, 1, 1, 1, 1]);
    expect(
      rows.expand((r) => r.messages).map((m) => m.id),
      messages.map((m) => m.id),
    );
    final hidden = groupTranscriptRows(
      messages,
      const ChatAppearance({'showReasoning': false, 'showProcess': false}),
    );
    expect(hidden.expand((r) => r.messages).map((m) => m.id), [
      'user',
      'answer',
      'error',
    ]);
  });

  test('completed history cannot animate for a new active turn', () {
    final snapshot = snapshotFor(
      sessionA,
      running: true,
      metadata: jsonEncode({'activeTurnId': 'turn-b'}),
    );
    final completed = groupTranscriptRows([
      step('old'),
    ], const ChatAppearance({})).single;
    expect(completed.belongsToRunningTurn(snapshot), isFalse);
    final other = groupTranscriptRows([
      step('old', status: 'inProgress'),
    ], const ChatAppearance({})).single;
    expect(other.belongsToRunningTurn(snapshot), isFalse);
    final active = groupTranscriptRows([
      step('live', turn: 'turn-b', status: 'inProgress'),
    ], const ChatAppearance({})).single;
    expect(active.belongsToRunningTurn(snapshot), isTrue);
  });

  test('only complete native retry notices become connection status', () {
    for (final text in [
      'Reconnecting... 3/5',
      'Reconnecting… 3/5',
      '正在重新连接 3/5',
    ]) {
      final status = reconnectStatus(retry('retry', 3, text: text));
      expect(status?.attempt, 3);
      expect(status?.total, 5);
    }
    expect(
      reconnectStatus(retry('native-error', 3, role: 'error'))?.attempt,
      3,
    );
    for (final item in [
      retry('user', 3, role: 'user'),
      retry(
        'error',
        3,
        role: 'error',
        text: 'Reconnecting... 3/5\nConnection failed',
      ),
      retry('tool-output', 3, role: 'activity'),
      retry('truncated', 3, truncated: true),
      retry('output', 3, output: 'Connection refused'),
      retry(
        'image',
        3,
        attachments: [
          const Attachment(
            id: 'image',
            name: 'example',
            image: true,
            source: 'upload',
          ),
        ],
      ),
      retry('quote', 3, text: '> Reconnecting... 3/5'),
      retry('code', 3, text: '`Reconnecting... 3/5`'),
      retry(
        'paragraph',
        3,
        text: 'Reconnecting... 3/5\nPlease check the network.',
      ),
      retry('example', 3, text: 'Example: Reconnecting... 3/5'),
      retry('zero', 0),
      retry('invalid', 6),
    ]) {
      expect(reconnectStatus(item), isNull, reason: item.id);
    }
  });

  test('retry runs retain source rows and stop at transcript boundaries', () {
    final messages = [
      retry('one', 1),
      retry('two', 2, role: 'error', turn: 'turn-b'),
      retry('three', 3, role: 'error', turn: 'turn-c'),
      retry('new-cycle', 1),
      retry('new-total', 2, total: 8),
      retry('new-turn', 3, total: 8, turn: 'turn-b'),
      message('answer', 'Connection restored'),
      retry('after-answer', 4, total: 8, turn: 'turn-b'),
      message('error', 'Connection failed', role: 'error'),
      retry('after-error', 5, total: 8, turn: 'turn-b'),
      step('command', turn: 'turn-b'),
      retry('after-command', 6, total: 8, turn: 'turn-b'),
      message('user', 'Continue', role: 'user'),
      retry('after-user', 7, total: 8, turn: 'turn-b'),
    ];
    final rows = groupTranscriptRows(messages, const ChatAppearance({}));
    expect(rows.first.reconnect?.attempt, 3);
    expect(rows.first.messages.map((m) => m.id), ['one', 'two', 'three']);
    expect(rows.first.turnId, 'turn-c');
    expect(rows.map((r) => r.messages.length), [
      3,
      1,
      2,
      1,
      1,
      1,
      1,
      1,
      1,
      1,
      1,
    ]);
    expect(rows.expand((r) => r.messages), orderedEquals(messages));
    final hidden = groupTranscriptRows(
      messages,
      const ChatAppearance({'showProcess': false}),
    );
    expect(hidden.where((r) => r.reconnect != null).length, 7);
    expect(
      hidden.expand((r) => r.messages).any((m) => m.id == 'error'),
      isTrue,
    );
  });

  for (final language in ['zh', 'en']) {
    testWidgets(
      'retry status updates in place without message actions in $language',
      (tester) async {
        final repository = FakeRepository()
          ..onSnapshot = (session) async => snapshotFor(
            session,
            running: true,
            messages: [retry('one', 1, role: 'error')],
            metadata: jsonEncode({'activeTurnId': 'turn-a'}),
          );
        final model = await open(repository);
        model.setAppearance(locale: language);
        await tester.pumpWidget(
          BridgeApp(repository: repository, viewModel: model),
        );
        await tester.pump(const Duration(milliseconds: 300));
        final statusElement = tester.element(find.byType(ReconnectStatusRow));
        final prefix = language == 'zh' ? '正在重新连接' : 'Reconnecting';
        expect(find.text('$prefix 1/5'), findsOneWidget);
        repository.emit(
          snapshotFor(
            sessionA,
            running: true,
            messages: [
              retry('one', 1, role: 'error'),
              retry('two', 2, role: 'error', turn: 'turn-b'),
              retry('three', 3, role: 'error', turn: 'turn-c'),
            ],
            metadata: jsonEncode({'activeTurnId': 'turn-c'}),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.element(find.byType(ReconnectStatusRow)),
          same(statusElement),
        );
        expect(find.text('$prefix 3/5'), findsOneWidget);
        expect(find.text('$prefix 1/5'), findsNothing);
        expect(find.byType(MessageCard), findsNothing);
        expect(find.byType(WorkActivityLabel), findsOneWidget);
        expect(
          tester
              .widget<WorkActivityLabel>(find.byType(WorkActivityLabel))
              .running,
          isTrue,
        );
        expect(model.messages.length, 3);

        repository.emit(
          snapshotFor(
            sessionA,
            messages: [
              retry('one', 1, role: 'error'),
              retry('two', 2, role: 'error'),
              retry('three', 3, role: 'error'),
              message('answer', 'Recovered'),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ReconnectStatusRow), findsOneWidget);
        expect(
          tester
              .widget<ReconnectStatusRow>(find.byType(ReconnectStatusRow))
              .running,
          isFalse,
        );
        expect(find.text('Recovered'), findsOneWidget);
        expect(find.byType(MessageCard), findsOneWidget);
        expect(repository.sends, 0);
        expect(repository.resumedSessions, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        model.dispose();
        await tester.pump();
      },
    );
  }

  for (final theme in ['light', 'dark']) {
    testWidgets('merged retry status $theme screenshot', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = FakeRepository()
        ..onSnapshot = (session) async => snapshotFor(
          session,
          messages: [
            step('before'),
            retry('one', 1, role: 'error'),
            retry('two', 2, role: 'error'),
            retry('three', 3, role: 'error'),
            step('after'),
          ],
        );
      final model = await open(repository);
      model.setAppearance(theme: theme);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('retry-capture'),
          child: BridgeApp(repository: repository, viewModel: model),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/client-icons/codex.png'),
          tester.element(find.byType(BridgeApp)),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const Key('retry-capture')),
        matchesGoldenFile('goldens/reconnect-$theme.png'),
      );
      expect(find.text('Reconnecting 3/5'), findsOneWidget);
      expect(find.byType(MessageCard), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    });
  }

  testWidgets(
    'one summary expands compact rows and keeps its state on updates',
    (tester) async {
      final rows = [step('one'), step('two'), step('three', kind: 'reasoning')];
      final repository = FakeRepository()
        ..onSnapshot = (session) async => snapshotFor(session, messages: rows);
      final model = await open(repository);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ActivitySummary), findsOneWidget);
      expect(find.text('Ran commands'), findsOneWidget);
      expect(find.textContaining('git status'), findsNothing);
      await tester.ensureVisible(find.text('Ran commands'));
      await tester.tap(find.text('Ran commands'));
      await tester.pumpAndSettle();
      expect(find.text('Ran git status --short --branch one'), findsOneWidget);
      expect(find.textContaining('Full output'), findsNothing);
      await tester.tap(find.text('Ran git status --short --branch one'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Full output for one'), findsOneWidget);
      repository.emit(snapshotFor(sessionA, messages: [...rows, step('four')]));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ActivitySummary>(find.byType(ActivitySummary)).expanded,
        isTrue,
      );
      expect(find.text('Ran git status --short --branch four'), findsOneWidget);
      expect(find.textContaining('Full output for one'), findsOneWidget);
      await tester.ensureVisible(find.text('Ran commands'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ran commands'));
      await tester.pumpAndSettle();
      expect(find.textContaining('git status'), findsNothing);
      expect(repository.sends, 0);
      expect(repository.resumedSessions, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    },
  );

  for (final theme in ['light', 'dark']) {
    testWidgets('compact activity list $theme screenshots', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = FakeRepository()
        ..onSnapshot = (session) async => snapshotFor(
          session,
          messages: [
            step('thinking', kind: 'reasoning'),
            for (var i = 0; i < 6; i++)
              step('check-project-and-current-branch-$i'),
          ],
        );
      final model = await open(repository);
      model.setAppearance(theme: theme);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('activity-capture'),
          child: BridgeApp(repository: repository, viewModel: model),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/client-icons/codex.png'),
          tester.element(find.byType(BridgeApp)),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const Key('activity-capture')),
        matchesGoldenFile('goldens/activity-collapsed-$theme.png'),
      );
      await tester.tap(find.text('Ran commands'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const Key('activity-capture')),
        matchesGoldenFile('goldens/activity-expanded-$theme.png'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    });
  }

  testWidgets('live group stops its pulse when the stream reports completion', (
    tester,
  ) async {
    final repository = FakeRepository()
      ..onSnapshot = (session) async => snapshotFor(
        session,
        running: true,
        messages: [step('live', status: 'inProgress')],
        metadata: jsonEncode({'activeTurnId': 'turn-a'}),
      );
    final model = await open(repository);
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<ActivitySummary>(find.byType(ActivitySummary)).running,
      isTrue,
    );
    expect(find.byType(WorkActivityLabel), findsOneWidget);
    repository.emit(snapshotFor(sessionA, messages: [step('live')]));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ActivitySummary>(find.byType(ActivitySummary)).running,
      isFalse,
    );
    expect(find.text('Ran commands'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
  });

  testWidgets(
    'running pulse stops on completion, reduced motion and hidden tabs',
    (tester) async {
      Widget label({
        bool running = true,
        bool reduced = false,
        bool visible = true,
      }) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: TickerMode(
            enabled: visible,
            child: WorkActivityLabel(label: 'Working', running: running),
          ),
        ),
      );
      await tester.pumpWidget(label());
      double opacity() => tester
          .widget<Opacity>(
            find.descendant(
              of: find.byType(WorkActivityLabel),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;
      final initial = opacity();
      await tester.pump(const Duration(milliseconds: 600));
      expect(opacity(), isNot(initial));
      for (final widget in [
        label(running: false),
        label(reduced: true),
        label(visible: false),
      ]) {
        await tester.pumpWidget(widget);
        await tester.pumpAndSettle();
        expect(opacity(), 1);
        expect(tester.binding.transientCallbackCount, 0);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: IndexedStack(
            index: 1,
            children: const [
              WorkActivityLabel(
                label: 'Hidden workspace transcript',
                running: true,
              ),
              Text('Workspace'),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final language in ['zh', 'en']) {
    testWidgets('expanded activities fit narrow large $language text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = FakeRepository()
        ..onSnapshot = (session) async => snapshotFor(
          session,
          messages: [
            step('very-long-project-name-and-command-line'),
            step('two'),
          ],
        );
      final model = await open(repository);
      model.setAppearance(locale: language);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(language == 'zh' ? '运行了命令' : 'Ran commands'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final preview = tester.widget<Text>(
        find.textContaining('very-long-project-name-and-command-line'),
      );
      expect(preview.maxLines, 1);
      expect(preview.overflow, TextOverflow.ellipsis);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    });
  }

  for (final language in ['en', 'zh']) {
    testWidgets(
      'copy confirms clipboard success in $language and has no overflow menu',
      (tester) async {
        final repository = FakeRepository();
        final model = await open(repository);
        final response = Completer<void>();
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
              await response.future;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final record = message('copy', 'Complete message text');
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: const [Locale('en'), Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(
              body: MessageCard(
                message: record,
                session: sessionA,
                repository: repository,
                strings: Strings(Locale(language)),
                model: model,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final copy = language == 'zh' ? '复制' : 'Copy',
            done = language == 'zh' ? '已复制' : 'Copied';
        await tester.tap(find.text(copy));
        await tester.pump();
        expect(find.text(done), findsNothing);
        response.complete();
        await tester.pumpAndSettle();
        expect(copied, 'Complete message text');
        expect(find.text(done), findsOneWidget);
        expect(find.byType(PopupMenuButton<String>), findsNothing);
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.text(copy), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        model.dispose();
        await tester.pump();
      },
    );
  }

  testWidgets('clipboard failure never reports copied', (tester) async {
    final repository = FakeRepository();
    final model = await open(repository);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'copy_failed');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageCard(
            message: message('copy', 'Text'),
            session: sessionA,
            repository: repository,
            strings: Strings(const Locale('en')),
            model: model,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(find.text('Copied'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
  });
}
