import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

final computersTab = find.byKey(const ValueKey('tab-computers'));
final computerCard = find.byKey(ValueKey('computer-card-${computerA.id}'));

Future<void> closeApp(WidgetTester tester, BridgeViewModel model) async {
  await tester.pumpWidget(const SizedBox.shrink());
  model.dispose();
  await tester.pump();
}

void main() {
  for (final locale in ['zh', 'en']) {
    testWidgets(
      'computer navigation retains the selected connection in $locale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final repository = FakeRepository();
        final model = BridgeViewModel(repository);
        await model.initialize();
        model.setAppearance(
          locale: locale,
          theme: locale == 'zh' ? 'light' : 'dark',
        );
        await model.selectComputer(computerA);
        await tester.pumpWidget(
          BridgeApp(repository: repository, viewModel: model),
        );
        await tester.pumpAndSettle();

        expect(find.text('BRIDGE'), findsNothing);
        expect(
          find.byTooltip(locale == 'zh' ? '返回首页' : 'Back to home'),
          findsNothing,
        );
        expect(tester.getSize(computersTab).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(computersTab).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);

        await tester.tap(computersTab);
        await tester.pumpAndSettle();
        expect(model.computer, computerA);
        await tester.scrollUntilVisible(computerCard, 160);
        expect(computerCard, findsOneWidget);
        expect(repository.savedComputers, [computerA, computerB]);
        expect(repository.removedComputerIds, isEmpty);
        final connections = repository.connects;
        await tester.tap(find.byKey(const ValueKey('tab-computers')));
        await tester.pumpAndSettle();
        expect(repository.connects, connections);
        expect(tester.takeException(), isNull);
        await closeApp(tester, model);
      },
    );
  }

  testWidgets('back from chat and computer tab preserve its draft', (
    tester,
  ) async {
    final repository = FakeRepository();
    final model = BridgeViewModel(repository);
    await model.initialize();
    await model.selectComputer(computerA);
    await model.openSession(sessionA);
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('composer')),
      'Keep this draft',
    );
    await tester.binding.handlePopRoute();
    // Complete the mock watch's close future outside the fake clock.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tab-computers')));
    await tester.pumpAndSettle();

    expect(model.computer, computerA);
    expect(model.busy, isFalse);
    expect(computerCard, findsOneWidget);
    expect(find.byKey(const Key('composer')), findsNothing);
    expect(
      (await repository.draft(sessionA, 'account-a')).text,
      'Keep this draft',
    );
    expect(repository.removedComputerIds, isEmpty);
    expect(tester.takeException(), isNull);
    await closeApp(tester, model);
  });

  testWidgets(
    'computer tab keeps a failed connection available without deleting it',
    (tester) async {
      final repository = FakeRepository()
        ..onConnect = (_) async => throw StateError('Network error');
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.selectComputer(computerA);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      expect(model.error, isNotNull);
      expect(model.authenticated, isFalse);

      await tester.tap(find.byKey(const ValueKey('tab-computers')));
      await tester.pumpAndSettle();
      expect(computerCard, findsOneWidget);
      expect(model.error, isNotNull);
      expect(repository.savedComputers, [computerA, computerB]);
      expect(repository.removedComputerIds, isEmpty);
      expect(tester.takeException(), isNull);
      await closeApp(tester, model);
    },
  );

  testWidgets('tabs only change presentation while a write is in progress', (
    tester,
  ) async {
    final repository = FakeRepository();
    final model = BridgeViewModel(repository);
    await model.initialize();
    await model.selectComputer(computerA);
    model.busy = true;
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-button')), findsNothing);
    final connections = repository.connects;
    await tester.tap(computersTab);
    await tester.pumpAndSettle();
    expect(model.computer, computerA);
    expect(model.busy, isTrue);
    expect(repository.connects, connections);
    expect(repository.sends + repository.creates + repository.stops, 0);
    expect(tester.takeException(), isNull);
    await closeApp(tester, model);
  });
}
