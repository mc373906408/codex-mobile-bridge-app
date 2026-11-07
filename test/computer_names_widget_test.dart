import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

Future<void> closeApp(WidgetTester tester, BridgeViewModel model) async {
  await tester.pumpWidget(const SizedBox.shrink());
  model.dispose();
  await tester.pump();
}

void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });
  testWidgets('iOS rename cancellation leaves stored names untouched', (
    tester,
  ) async {
    final repository = FakeRepository();
    final model = BridgeViewModel(repository);
    await model.initialize();
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    final options = find.byKey(ValueKey('computer-options-${computerA.id}'));
    await tester.ensureVisible(options);
    await tester.tap(options);
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActionSheet), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('computer-name')), findsNothing);
    await tester.tap(options);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename computer'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('computer-name')),
      'Cancelled name',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(model.computerName(computerA), 'Studio');
    expect(repository.savedComputerNames, isEmpty);
    expect(repository.connects, 0);
    await closeApp(tester, model);
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));
  testWidgets('rename failure keeps the dialog and allows retry', (
    tester,
  ) async {
    final repository = FakeRepository()
      ..onSaveComputerNames = (_) async =>
          throw StateError('Synthetic failure');
    final model = BridgeViewModel(repository);
    await model.initialize();
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(ValueKey('computer-card-${computerA.id}'));
    await tester.ensureVisible(card);
    await tester.longPress(card);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('computer-name')),
      'My desktop',
    );
    await tester.tap(find.byKey(const Key('save-computer-name')));
    await tester.pumpAndSettle();
    expect(find.text('Could not save the name. Try again.'), findsOneWidget);
    expect(model.computerName(computerA), 'Studio');
    repository.onSaveComputerNames = null;
    await tester.tap(find.byKey(const Key('save-computer-name')));
    await tester.pumpAndSettle();
    expect(model.computerName(computerA), 'My desktop');
    expect(find.byKey(const Key('rename-computer-dialog')), findsNothing);
    await closeApp(tester, model);
  }, variant: platforms);

  for (final scale in [1.0, 2.0]) {
    testWidgets('chat header omits the device name at scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = FakeRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.renameComputer(
        computerA,
        '设计工作室的 MacBook Pro / Design Studio',
      );
      await model.selectComputer(computerA);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('设计工作室的 MacBook Pro / Design Studio'),
        findsNothing,
      );
      expect(find.text('设计工作室的 MacBook Pro / Design Studio'), findsNothing);
      expect(find.byKey(const Key('provider-picker')), findsOneWidget);
      for (final action in ['Inbox', 'New chat', 'Refresh']) {
        expect(
          tester.getRect(find.byTooltip(action)).right,
          lessThanOrEqualTo(320),
        );
      }
      expect(tester.takeException(), isNull);
      await closeApp(tester, model);
    }, variant: platforms);
  }

  for (final locale in ['zh', 'en']) {
    testWidgets('rename from computer card persists the name in $locale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = FakeRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      model.setAppearance(locale: locale);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      final options = find.byKey(ValueKey('computer-options-${computerA.id}'));
      await tester.ensureVisible(options);
      await tester.tap(options);
      await tester.pumpAndSettle();
      await tester.tap(find.text(locale == 'zh' ? '重命名' : 'Rename computer'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('computer-name')), '');
      await tester.tap(find.byKey(const Key('save-computer-name')));
      await tester.pumpAndSettle();
      expect(
        find.text(locale == 'zh' ? '请输入设备名称' : 'Enter a device name'),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const Key('computer-name')), '书房工作电脑');
      await tester.tap(find.byKey(const Key('save-computer-name')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rename-computer-dialog')), findsNothing);
      expect(find.text('书房工作电脑'), findsOneWidget);
      final card = find.byKey(ValueKey('computer-card-${computerA.id}'));
      await tester.ensureVisible(card);
      await tester.tap(
        find.descendant(of: card, matching: find.text('书房工作电脑')),
      );
      await tester.pumpAndSettle();
      expect(model.computer?.id, computerA.id);
      expect(model.computerName(model.computer!), '书房工作电脑');
      expect(repository.savedComputerNames.values, contains('书房工作电脑'));
      expect(find.text('书房工作电脑'), findsNothing);
      expect(find.byKey(const Key('provider-picker')), findsOneWidget);
      expect(find.byKey(const Key('connected-computer')), findsNothing);
      expect(repository.sends + repository.creates + repository.stops, 0);
      expect(tester.takeException(), isNull);
      await closeApp(tester, model);
    }, variant: platforms);
  }
}
