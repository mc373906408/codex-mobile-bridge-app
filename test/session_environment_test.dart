import 'dart:async';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/l10n/environment_messages.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/ui/pages/session_environment_notice.dart';
import 'package:bridge_mobile/ui/pages/session_list_tile.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

const failedIssue = EnvironmentIssue(
  environment: 'ssh:lab',
  label: 'Lab server',
  reason: 'SSH connection refused',
  loading: false,
);
const pendingIssue = EnvironmentIssue(
  environment: 'remote-ssh-discovered:10.0.0.2',
  label: '10.0.0.2',
  reason: '正在后台读取 SSH 主机；本机会话可正常使用。',
  loading: true,
);
const partialPage = SessionPage(
  sessions: [],
  nextOffset: null,
  notice: '',
  environmentIssues: [failedIssue],
);

void main() {
  testWidgets('local chats show their computer and keep their routing', (
    tester,
  ) async {
    final repository = FakeRepository();
    final page = await repository.sessions(computerA, Provider.codex, '', 0);
    SessionRef? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionListTile(
            row: page.sessions.single,
            computerName: 'Desktop',
            selected: false,
            onTap: () => opened = page.sessions.single.session,
          ),
        ),
      ),
    );
    expect(find.text('Desktop  /  bridge'), findsOneWidget);
    expect(find.textContaining('local'), findsNothing);
    await tester.tap(find.text('A quieter workspace'));
    expect(opened?.environment, 'local');
    expect(opened?.computerId, computerA.id);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'host, cause and pending status fit a narrow screen at $scale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: SessionEnvironmentNotice(
                    issues: const [pendingIssue, failedIssue],
                    computerName: 'Desktop',
                    strings: Strings(const Locale('zh')),
                    onRefresh: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text('SSH · 10.0.0.2 · 读取中'), findsOneWidget);
        expect(find.text('SSH · Lab server · 读取失败'), findsOneWidget);
        expect(find.text('SSH connection refused'), findsOneWidget);
        expect(find.textContaining('执行环境'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('reload recovers the partial list and removes diagnostics', (
    tester,
  ) async {
    final repository = FakeRepository()
      ..onSessions = (_, _, _, _) async => partialPage;
    final model = BridgeViewModel(repository);
    await model.initialize();
    model.setAppearance(locale: 'zh');
    await model.selectComputer(computerA);
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    expect(find.text('部分聊天尚未加载'), findsOneWidget);
    expect(find.text('还没有聊天'), findsNothing);
    repository.onSessions = null;
    await tester.tap(find.text('重新加载列表'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionEnvironmentNotice), findsNothing);
    expect(find.text('Studio  /  bridge'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
  });

  for (final changeComputer in [false, true]) {
    test(
      'late diagnostics cannot cross ${changeComputer ? 'computers' : 'agents'}',
      () async {
        final repository = FakeRepository()
          ..onSessions = (_, _, _, _) async => partialPage;
        final model = BridgeViewModel(repository);
        await model.initialize();
        await model.selectComputer(computerA);
        expect(model.environmentIssues, hasLength(1));
        final pending = Completer<SessionPage>();
        repository.onSessions = (_, _, _, _) => pending.future;
        final refreshing = model.refreshSessions();
        repository.onSessions = null;
        if (changeComputer) {
          await model.selectComputer(computerB);
        } else {
          await model.selectProvider(Provider.claude);
        }
        expect(model.environmentIssues, isEmpty);
        pending.complete(partialPage);
        await refreshing;
        expect(model.environmentIssues, isEmpty);
        model.dispose();
      },
    );
  }

  test('diagnostics retain useful details and redact credentials', () {
    expect(
      diagnosticText('SSH connection refused on port 22'),
      'SSH connection refused on port 22',
    );
    expect(
      diagnosticText('https://user:password@example.test'),
      'https://[redacted]@example.test',
    );
    expect(
      diagnosticText('token=secret-value\nConnection failed'),
      'token=[redacted]\nConnection failed',
    );
    expect(
      environmentIssueReason(failedIssue, chinese: false),
      failedIssue.reason,
    );
  });
}
