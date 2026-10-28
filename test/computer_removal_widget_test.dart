import 'dart:async';

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

Finder cardFor(Computer computer) =>
    find.byKey(ValueKey('remove-computer-${computer.id}'));
final removalDialog = find.byKey(const Key('remove-connection-dialog'));
final confirmRemoval = find.byKey(const Key('confirm-remove-connection'));

Future<BridgeViewModel> showComputers(
  WidgetTester tester,
  FakeRepository repository, {
  String locale = 'zh',
  String theme = 'light',
}) async {
  final model = BridgeViewModel(repository);
  await model.initialize();
  model.setAppearance(locale: locale, theme: theme);
  await tester.pumpWidget(BridgeApp(repository: repository, viewModel: model));
  await tester.pumpAndSettle();
  return model;
}

Future<void> closeComputers(WidgetTester tester, BridgeViewModel model) async {
  await tester.pumpWidget(const SizedBox.shrink());
  model.dispose();
  await tester.pump();
}

Future<void> swipeCard(
  WidgetTester tester,
  Computer computer, {
  bool left = true,
}) async {
  final card = cardFor(computer);
  await tester.scrollUntilVisible(card, 160);
  await tester.ensureVisible(card);
  await tester.pumpAndSettle();
  final distance = tester.getSize(card).width * .75;
  await tester.drag(card, Offset(left ? -distance : distance, 0));
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in ['zh', 'en']) {
    testWidgets('left swipe confirms only the selected connection in $locale', (
      tester,
    ) async {
      final repository = FakeRepository();
      final model = await showComputers(tester, repository, locale: locale);
      expect(
        find.text(
          locale == 'zh' ? '左滑卡片移除连接' : 'Swipe left to remove a connection',
        ),
        findsOneWidget,
      );
      await swipeCard(tester, computerA, left: false);
      expect(removalDialog, findsNothing);
      expect(repository.removedComputerIds, isEmpty);
      expect(cardFor(computerA), findsOneWidget);

      await swipeCard(tester, computerA);
      expect(removalDialog, findsOneWidget);
      expect(
        find.descendant(of: removalDialog, matching: find.text(computerA.name)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: removalDialog,
          matching: find.text(computerA.baseUrl),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          locale == 'zh' ? '不会删除电脑上的网关或聊天。' : 'The gateway and conversations on your computer are not deleted.',
        ),
        findsOneWidget,
      );
      expect(repository.removedComputerIds, isEmpty);
      await tester.tap(find.text(locale == 'zh' ? '取消' : 'Cancel'));
      await tester.pumpAndSettle();
      expect(cardFor(computerA), findsOneWidget);
      expect(model.computers, [computerA, computerB]);

      await swipeCard(tester, computerA);
      await tester.tap(confirmRemoval);
      await tester.pumpAndSettle();
      expect(cardFor(computerA), findsNothing);
      expect(cardFor(computerB), findsOneWidget);
      expect(repository.removedComputerIds, [computerA.id]);
      expect(repository.savedComputers, [computerB]);
      expect(repository.connects, 0);

      await swipeCard(tester, computerB);
      await tester.tap(confirmRemoval);
      await tester.pumpAndSettle();
      expect(find.byType(Dismissible), findsNothing);
      expect(model.computers, isEmpty);
      expect(repository.savedComputers, isEmpty);
      expect(repository.removedComputerIds, [computerA.id, computerB.id]);
      expect(
        find.text(locale == 'zh' ? '添加电脑' : 'Add computer'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await closeComputers(tester, model);
    });
  }

  testWidgets('a left drag reveals the removal action on the right edge', (
    tester,
  ) async {
    final repository = FakeRepository();
    final model = await showComputers(tester, repository);
    final card = cardFor(computerA);
    await tester.scrollUntilVisible(card, 160);
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    final bounds = tester.getRect(card);
    final surface = find.descendant(of: card, matching: find.byType(Card));
    final originalLeft = tester.getRect(surface).left;
    final gesture = await tester.startGesture(bounds.center);
    await gesture.moveBy(const Offset(-24, 0));
    await tester.pump();
    await gesture.moveBy(Offset(-bounds.width * .25, 0));
    await tester.pump();

    expect(tester.getRect(surface).left, lessThan(originalLeft));
    final action = find.descendant(of: card, matching: find.text('移除'));
    expect(tester.getRect(action).left, greaterThan(bounds.center.dx));
    expect(removalDialog, findsNothing);
    expect(repository.removedComputerIds, isEmpty);

    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(cardFor(computerA), findsOneWidget);
    expect(tester.takeException(), isNull);
    await closeComputers(tester, model);
  });

  testWidgets('ordinary card taps still connect without removing anything', (
    tester,
  ) async {
    final repository = FakeRepository();
    final model = await showComputers(tester, repository);
    await tester.scrollUntilVisible(cardFor(computerA), 160);
    await tester.tap(find.text(computerA.name));
    await tester.pumpAndSettle();
    expect(model.computer, computerA);
    expect(repository.connects, 1);
    expect(repository.removedComputerIds, isEmpty);
    expect(removalDialog, findsNothing);
    expect(tester.takeException(), isNull);
    await closeComputers(tester, model);
  });

  testWidgets('failed removal restores the card and shows a Chinese error', (
    tester,
  ) async {
    final repository = FakeRepository()
      ..onRemoveComputer = (_) async => throw StateError(
        'Local state could not be saved. Check the computer before retrying',
      );
    final model = await showComputers(tester, repository);
    await swipeCard(tester, computerA);
    await tester.tap(confirmRemoval);
    await tester.pumpAndSettle();
    expect(model.busy, isFalse);
    expect(model.computers, [computerA, computerB]);
    expect(cardFor(computerA), findsOneWidget);
    expect(find.text('本机状态保存失败，请先在电脑端核对操作结果，不要重复提交。'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(tester.takeException(), isNull);

    repository.onRemoveComputer = null;
    await swipeCard(tester, computerA);
    await tester.tap(confirmRemoval);
    await tester.pumpAndSettle();
    expect(cardFor(computerA), findsNothing);
    expect(model.error, isNull);
    expect(tester.takeException(), isNull);
    await closeComputers(tester, model);
  });

  testWidgets('a pending removal disables new swipes and connection taps', (
    tester,
  ) async {
    final pending = Completer<void>();
    final repository = FakeRepository()
      ..onRemoveComputer = (_) => pending.future;
    final model = await showComputers(tester, repository);
    await swipeCard(tester, computerA);
    await tester.tap(confirmRemoval);
    await tester.pumpAndSettle();
    expect(model.busy, isTrue);
    expect(model.computers, [computerA, computerB]);
    expect(
      tester.widget<Dismissible>(cardFor(computerB)).direction,
      DismissDirection.none,
    );
    await tester.scrollUntilVisible(cardFor(computerB), 160);
    await tester.tap(find.text(computerB.name));
    await model.removeComputer(computerA);
    expect(repository.removedComputerIds, [computerA.id]);
    expect(repository.connects, 0);

    pending.complete();
    await tester.pumpAndSettle();
    expect(model.busy, isFalse);
    expect(cardFor(computerA), findsNothing);
    expect(cardFor(computerB), findsOneWidget);
    expect(tester.takeException(), isNull);
    await closeComputers(tester, model);
  });

  for (final theme in ['light', 'dark']) {
    testWidgets(
      'swipe confirmation fits compact large-text layouts in $theme',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        const computer = Computer(
          id: 'long-name',
          name: 'A development computer with a deliberately long display name',
          baseUrl: 'https://a-long-gateway-address.example:8787',
        );
        final repository = FakeRepository()..savedComputers = [computer];
        final model = await showComputers(tester, repository, theme: theme);
        await swipeCard(tester, computer);
        expect(removalDialog, findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(repository.removedComputerIds, isEmpty);
        expect(cardFor(computer), findsOneWidget);
        expect(tester.takeException(), isNull);
        await closeComputers(tester, model);
      },
    );
  }
}
