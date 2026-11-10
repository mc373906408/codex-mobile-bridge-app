import 'dart:convert';
import 'dart:async';

import 'package:bridge_mobile/ui/business/content_preview.dart';
import 'package:bridge_mobile/ui/business/message_content.dart';
import 'package:bridge_mobile/ui/business/output_directives.dart';
import 'package:bridge_mobile/ui/business/appearance_settings.dart';
import 'package:bridge_mobile/ui/business/gateway_settings.dart';
import 'package:bridge_mobile/ui/business/approval_page.dart';
import 'package:bridge_mobile/ui/business/common.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/data/bridge_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:markdown/markdown.dart' as md;

import 'support/fake_repository.dart';

void main() {
  testWidgets('business errors hide native traces and keep retry reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    var retried = false;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: BusinessLoading(
            error:
                'AnyhowException(Relay connection: access_denied\n\nStack backtrace:\n${List.filled(80, '   0: secret-diagnostic').join('\n')})',
            retry: () => retried = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('访问被拒绝'), findsOneWidget);
    expect(find.textContaining('secret-diagnostic'), findsNothing);
    await tester.ensureVisible(find.text('重新读取'));
    await tester.tap(find.text('重新读取'));
    expect(retried, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('management exposes native and WSL switches without using aggregate enabled state', () {
    final rows = managedClientRows({
      'clients': [
        {
          'id': 'codex',
          'enabled': true,
          'entries': [
            {'id': 'desktop', 'enabled': false},
            {'id': 'wsl:one', 'enabled': true},
          ],
        },
        {
          'id': 'claude',
          'enabled': true,
          'nativeEnabled': false,
          'entries': [
            {'id': 'wsl-claude:two', 'enabled': true},
          ],
        },
        {'id': 'codex:independent', 'enabled': true},
      ],
    });
    expect(rows.map((r) => r['id']), [
      'codex',
      'wsl:one',
      'claude',
      'wsl-claude:two',
      'codex:independent',
    ]);
    expect(rows[0]['enabled'], isFalse);
    expect(rows[2]['enabled'], isFalse);
    expect(rows[1]['family'], 'codex');
    expect(rows[3]['family'], 'claude');
  });

  for (final language in ['en', 'zh']) {
    testWidgets(
      'appearance controls fit a narrow screen with large $language text',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final state = BridgeViewModel(FakeRepository());
        await state.initialize();
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: const [Locale('en'), Locale('zh')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: AppearanceSettingsPage(model: state),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byType(DropdownButton<String>).first,
          120,
        );
        await tester.tap(find.byType(DropdownButton<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('IBM Plex Sans').last);
        await tester.pumpAndSettle();
        expect(state.presentation['fontFamily'], 'PlexSans');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      },
    );
  }

  testWidgets(
    'approval preserves offered decisions and the original wire identifier',
    (tester) async {
      final repository = _ApprovalRepository();
      final state = BridgeViewModel(repository);
      await state.initialize();
      await state.selectComputer(computerA);
      final request = ApprovalRequest(
        id: '17',
        wireId: '17',
        fingerprint: 'request-version',
        kind: ApprovalKind.command,
        title: 'Run command',
        detail: '',
        supported: true,
        canAccept: true,
        canDecline: true,
        questions: const [],
        metadata: jsonEncode({
          'method': 'item/commandExecution/requestApproval',
          'params': {
            'availableDecisions': ['acceptForSession', 'decline'],
          },
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ApprovalPage(
            model: state,
            snapshot: snapshotFor(sessionA),
            request: request,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Allow once'), findsNothing);
      await tester.tap(find.text('Allow for this chat'));
      await tester.pumpAndSettle();
      expect(repository.response?['requestId'], 17);
      expect(repository.response?['response'], {
        'decision': 'acceptForSession',
      });
      expect(
        repository.response?['expectedRequestFingerprint'],
        'request-version',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  test('read markers reject another account and late verification after a new list', () async {
    final repository = FakeRepository();
    final state = BridgeViewModel(repository);
    await state.initialize();
    await state.selectComputer(computerA);
    await state.markSessionRead(sessionA, true);
    expect(state.isSessionRead(sessionA), isTrue);
    final delayed = Completer<SessionSnapshot>();
    repository.onSnapshot = (_) => delayed.future;
    await state.refreshSessions();
    expect(state.isSessionRead(sessionA), isFalse);
    repository.onSnapshot = (s) async => snapshotFor(s, account: 'account-b');
    await state.refreshSessions();
    await Future<void>.delayed(Duration.zero);
    delayed.complete(snapshotFor(sessionA));
    await Future<void>.delayed(Duration.zero);
    expect(state.isSessionRead(sessionA), isFalse);
    await state.markSessionRead(sessionA, true);
    expect(state.isSessionRead(sessionA), isTrue);
    repository.onSessions = (_, _, _, _) async => const SessionPage(
      sessions: [
        SessionSummary(
          session: sessionA,
          title: 'Changed',
          cwd: '/work/bridge',
          updatedAt: '2026-11-10',
          status: 'idle',
          backend: 'desktop',
        ),
      ],
      notice: '',
      nextOffset: null,
    );
    await state.refreshSessions();
    expect(state.isSessionRead(sessionA), isFalse);
    state.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test('visibility preferences preserve user and error content', () {
    const value = ChatAppearance({
      'showReasoning': false,
      'showProcess': false,
      'messageSize': 99,
      'codeSize': 1,
    });
    expect(value.visible('user', {'phase': 'commentary'}), isTrue);
    expect(value.visible('error', {'kind': 'reasoning'}), isTrue);
    expect(value.visible('reasoning', {}), isFalse);
    expect(value.visible('assistant', {'kind': 'reasoning'}), isFalse);
    expect(value.visible('assistant', {'phase': 'commentary'}), isFalse);
    expect(value.visible('assistant', {}), isTrue);
    expect(value.fontSize, 32);
    expect(value.codeSize, 8);
  });

  test(
    'output directives preserve Windows paths and reject malformed actions',
    () {
      final comment = readOutputDirective(
        r'::code-comment{title="[P1] Fix" body="Use \"quoted\" values" file="D:\work\x.dart" start=21 end=23 priority=1}',
        0,
      )!;
      expect(comment['attributes']['file'], r'D:\work\x.dart');
      expect(comment['attributes']['body'], 'Use "quoted" values');
      for (final value in [
        ':codex-followup[Run]{prompt="a" prompt="b"}',
        ':codex-followup[Run]{prompt="a" url="https://example.test"}',
        '::code-comment{title="x" body="y" file="z" start=3 end=2}',
        '::code-comment{title="x" body="y" file="z" priority=4}',
        ':codex-file-citation{path="x" artifact_kind=1}',
      ]) {
        expect(readOutputDirective(value, 0), isNull, reason: value);
      }
      expect(
        readOutputDirective(
          ':codex-followup[Run]{prompt="${List.filled(65536, 'x').join()}"}',
          0,
        ),
        isNull,
      );
      final code = md.markdownToHtml(
        '`:codex-followup[Run]{prompt="echo x"}`',
        inlineSyntaxes: [OutputDirectiveSyntax()],
      );
      expect(code, contains('<code>'));
      expect(code, isNot(contains('bridge-directive')));
    },
  );

  testWidgets(
    'follow-up fills a draft callback without executing and review opens the supplied line',
    (tester) async {
      String? prompt;
      (String, int)? location;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RichMessageText(
                text: ':codex-followup[Inspect]{prompt="Inspect only"}\n\n::code-comment{title="Finding" body="Check this line" file="src/main.dart" start=24 priority=2}',
                onPrompt: (value) => prompt = value,
                onFile: (path, line) => location = (path, line),
              ),
            ),
          ),
        ),
      );
      expect(prompt, isNull);
      await tester.tap(find.text('Inspect'));
      expect(prompt, 'Inspect only');
      await tester.tap(find.text('src/main.dart:24'));
      expect(location, ('src/main.dart', 24));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source preview positions the requested line under large text scaling',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: SourcePreviewPage(
            title: 'sample.dart',
            text: List.generate(500, (i) => 'line ${i + 1}').join('\n'),
            line: 240,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('240'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'HTML is confined to an opaque sandbox and Mermaid cannot inject a script',
    () {
      final html = isolatedPreviewHtml(
        '<script>fetch("https://example.test")</script><iframe src="file:///private"></iframe>',
      );
      expect(html, contains('sandbox=""'));
      expect(html, contains("connect-src 'none'"));
      expect(html, isNot(contains('<script>fetch')));
      final diagram = isolatedPreviewHtml(
        '</pre><script>alert(1)</script>',
        renderer: 'window.mermaid={initialize:function(){}}',
        nonce: 'fixture',
      );
      expect(diagram, contains('&lt;/pre&gt;&lt;script&gt;'));
      expect(diagram, contains('securityLevel:"strict"'));
      expect(diagram, isNot(contains('<script>alert')));
    },
  );

  test(
    'quotes survive draft reload, remain removable and are account scoped',
    () async {
      final repository = FakeRepository();
      final state = BridgeViewModel(repository);
      await state.initialize();
      await state.selectComputer(computerA);
      await state.openSession(sessionA);
      state.addQuote('alpha\nbeta', 'source-a');
      state.editDraft('Reply');
      expect(state.composedText, '> alpha\n> beta\n\nReply');
      await state.flushDraft();
      await state.openSession(sessionA);
      expect(state.quotes.single['source'], 'source-a');
      repository.onSnapshot = (session) async =>
          snapshotFor(session, account: 'account-b');
      await state.openSession(sessionA);
      expect(state.quotes, isEmpty);
      expect(
        repository.drafts.values.any(
          (d) => jsonDecode(d.options)['quotes'] is List,
        ),
        isTrue,
      );
      state.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );
}

class _ApprovalRepository extends FakeRepository {
  Map<String, Object?>? response;
  @override
  Future<BusinessReply> sessionCommand(
    SessionSnapshot snapshot,
    String id,
    SessionCommand command,
    Map<String, Object?> parameters,
  ) async {
    response = parameters;
    return BusinessReply(
      outcome: OperationOutcome(
        kind: OutcomeKind.accepted,
        message: '',
        id: id,
      ),
      data: '{}',
    );
  }
}
