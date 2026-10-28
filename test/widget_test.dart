import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

void main() {
  testWidgets('native welcome has a private connection flow', (tester) async {
    final repository = FakeRepository();
    await tester.pumpWidget(BridgeApp(repository: repository));
    await tester.pumpAndSettle();
    expect(find.text('BRIDGE'), findsNothing);
    expect(find.byTooltip('Back to home'), findsOneWidget);
    expect(find.text('Your work. Within reach.'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Add computer'), 200);
    expect(find.text('Add computer'), findsOneWidget);
    expect(find.text('Flutter Demo'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final size in [const Size(390, 844), const Size(1024, 768)]) {
    testWidgets('chat and history fit $size', (tester) async {
      tester.view.physicalSize = size;
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
      expect(find.byKey(const Key('composer')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.byKey(const Key('composer')),
        'A synthetic draft',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(model.draftText, 'A synthetic draft');
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    });
  }

  for (final theme in ['light', 'dark']) {
    testWidgets('Chinese chat fits a compact keyboard layout in $theme', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final repository = FakeRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      model.setAppearance(locale: 'zh', theme: theme);
      await model.selectComputer(computerA);
      await model.openSession(sessionA);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      const text = '\u5408\u6210\u6d4b\u8bd5\n\u7b2c\u4e8c\u884c';
      await tester.enterText(find.byKey(const Key('composer')), text);
      await tester.pump(const Duration(milliseconds: 300));
      expect(model.draftText, text);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    });
  }

  testWidgets('appearance and license controls fit large text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final repository = FakeRepository();
    await tester.pumpWidget(BridgeApp(repository: repository));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Open source licenses'));
    expect(find.text('Open source licenses'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
