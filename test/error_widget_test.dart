import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/main.dart';
import 'package:bridge_mobile/ui/dialogs.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

const _network =
    'The gateway could not be reached or its certificate was not trusted';
const _networkZh = '无法连接网关，或安全证书不受信任。请检查网关地址、网络连接和证书配置。';
const _trace = '\n\nStack backtrace:\n   0: secret-token private/path.rs';

class _InvalidAddressRepository extends FakeRepository {
  @override
  Future<ConnectionInput> parseConnection(String value) async =>
      throw AnyhowException('Invalid gateway address: invalid input$_trace');
}

void main() {
  for (final theme in ['light', 'dark']) {
    testWidgets('connection errors are Chinese on compact $theme screens', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = FakeRepository()
        ..onConnect = (_) async => throw AnyhowException('$_network$_trace');
      final model = BridgeViewModel(repository);
      await model.initialize();
      model.setAppearance(locale: 'zh', theme: theme);
      await model.selectComputer(computerA);
      expect(model.error, isA<AnyhowException>());
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      expect(find.text(_networkZh), findsOneWidget);
      expect(find.textContaining('AnyhowException'), findsNothing);
      expect(find.textContaining('Stack backtrace'), findsNothing);
      expect(find.textContaining('secret-token'), findsNothing);
      expect(tester.takeException(), isNull);

      model.setAppearance(locale: 'en');
      await tester.pumpAndSettle();
      expect(find.text(_network), findsOneWidget);
      expect(find.text(_networkZh), findsNothing);
      expect(find.textContaining('Stack backtrace'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    });
  }

  testWidgets('add computer dialog localizes validation errors', (
    tester,
  ) async {
    final repository = _InvalidAddressRepository();
    final model = BridgeViewModel(repository);
    await model.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                addComputerDialog(context, model, const Strings(Locale('zh'))),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'not a gateway');
    await tester.tap(find.text('保存并连接'));
    await tester.pumpAndSettle();
    expect(find.text('网关地址无效，请填写完整的安全连接地址，或局域网地址和端口。'), findsOneWidget);
    expect(find.textContaining('AnyhowException'), findsNothing);
    expect(find.textContaining('secret-token'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
  });

  testWidgets('stream failures and gateway notices use localized copy', (
    tester,
  ) async {
    final repository = FakeRepository()
      ..onSessions = (_, _, _, _) async => const SessionPage(
        sessions: [],
        nextOffset: null,
        notice: 'Some execution environments are unavailable',
      );
    final model = BridgeViewModel(repository);
    await model.initialize();
    model.setAppearance(locale: 'zh');
    await model.selectComputer(computerA);
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    expect(find.text('部分执行环境暂不可用，请在电脑端检查连接。'), findsOneWidget);
    await model.openSession(sessionA);
    await tester.pumpAndSettle();
    expect(find.text('部分执行环境暂不可用，请在电脑端检查连接。'), findsOneWidget);

    final entry = repository.streams.entries.single;
    entry.value.add(
      GatewayEvent(
        subscriptionId: entry.key,
        snapshot: null,
        authenticationRequired: false,
        message: 'AnyhowException($_network$_trace)',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(_networkZh), findsOneWidget);
    expect(model.fresh, isFalse);
    model.dismissError();
    entry.value.addError(AnyhowException('$_network$_trace'));
    await tester.pumpAndSettle();
    expect(find.text(_networkZh), findsOneWidget);
    expect(find.textContaining('secret-token'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
  });

  testWidgets('unknown submission errors stay Chinese without replaying', (
    tester,
  ) async {
    final repository = FakeRepository()
      ..onSend = (_, id) async => OperationOutcome(
        id: id,
        kind: OutcomeKind.unknown,
        message: 'Unexpected upstream error secret-token$_trace',
        createdSession: null,
      );
    final model = BridgeViewModel(repository);
    await model.initialize();
    model.setAppearance(locale: 'zh');
    await model.selectComputer(computerA);
    await model.openSession(sessionA);
    model.editDraft('Do not replay this message');
    await model.send();
    await model.send();
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂时无法确认操作结果。请检查连接；如已提交请求，请先在电脑上核对。'), findsOneWidget);
    expect(find.textContaining('secret-token'), findsNothing);
    expect(repository.sends, 1);
    expect(model.pending, hasLength(1));
    expect(model.canSend, isFalse);
    expect(model.draftText, 'Do not replay this message');
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
  });

  testWidgets('native startup failure defaults to Chinese guidance', (
    tester,
  ) async {
    await tester.pumpWidget(const NativeStartupFailureApp());
    await tester.pumpAndSettle();
    expect(find.textContaining('原生核心启动失败'), findsOneWidget);
    expect(find.textContaining('请重启应用'), findsOneWidget);
    expect(find.textContaining('Native core'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
