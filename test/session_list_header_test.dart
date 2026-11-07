import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

class _InboxRepository extends FakeRepository {
  @override
  Future<List<InboxEntry>> inbox(Computer computer) async => const [
    InboxEntry(id: 'compact-inbox', title: 'Ready', body: 'Review complete'),
  ];
}

Future<void> closeApp(WidgetTester tester, BridgeViewModel model) async {
  await tester.pumpWidget(const SizedBox.shrink());
  model.dispose();
  await tester.pump();
}

void main() {
  for (final width in [320.0, 390.0]) {
    for (final locale in ['zh', 'en']) {
      testWidgets('compact chat header groups controls at $width in $locale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repository = FakeRepository();
        final model = BridgeViewModel(repository);
        await model.initialize();
        model.setAppearance(locale: locale);
        await model.selectComputer(computerA);
        await tester.pumpWidget(
          BridgeApp(repository: repository, viewModel: model),
        );
        await tester.pumpAndSettle();
        final s = Strings(Locale(locale));
        final header = tester.getRect(
          find.byKey(const Key('session-list-header')),
        );
        final picker = tester.getRect(find.byKey(const Key('provider-picker')));
        final search = tester.getRect(find.byType(TextFormField));
        expect(header.height, lessThan(150));
        expect(picker.top, header.top + 12);
        expect(search.top, greaterThan(picker.bottom));
        expect(search.left, picker.left);
        expect(search.right, header.right - 16);
        for (final control in ['Inbox', 'New chat', 'Refresh']) {
          final button = find.byTooltip(s.t(control));
          expect(header.contains(tester.getCenter(button)), isTrue);
          expect(tester.getCenter(button).dy, picker.center.dy);
          expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(48));
        }
        expect(find.byKey(const Key('chats-title')), findsNothing);
        expect(find.text('Studio'), findsNothing);
        expect(find.byKey(const Key('home-button')), findsNothing);
        expect(find.text('Claude'), findsNothing);
        expect(find.text('DeepSeek'), findsNothing);
        expect(tester.takeException(), isNull);
        await closeApp(tester, model);
      });
    }
  }

  testWidgets(
    'agent dropdown overlays the list and back preserves its search',
    (tester) async {
      final repository = FakeRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.selectComputer(computerA);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'review');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      final rowBefore = tester.getRect(find.text('A quieter workspace'));
      final picker = find.byKey(const Key('provider-picker'));
      final pickerBefore = tester.getRect(picker);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('DeepSeek'), findsOneWidget);
      expect(tester.getRect(picker), pickerBefore);
      expect(tester.getRect(find.text('A quieter workspace')), rowBefore);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Claude'), findsNothing);
      expect(model.computer, computerA);
      expect(model.provider, Provider.codex);
      expect(model.query, 'review');
      expect(picker, findsOneWidget);

      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('provider-option-codex')));
      await tester.pumpAndSettle();
      expect(model.query, 'review');

      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('provider-option-claude')));
      await tester.pumpAndSettle();
      expect(model.provider, Provider.claude);
      expect(model.computer, computerA);
      expect(model.query, isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(
        find.byKey(const ValueKey('provider-option-claude')),
        findsNothing,
      );
      expect(repository.sends + repository.creates + repository.stops, 0);
      expect(tester.takeException(), isNull);
      await closeApp(tester, model);
    },
  );

  testWidgets('an open agent dropdown cannot switch during a write', (
    tester,
  ) async {
    final repository = FakeRepository();
    final model = BridgeViewModel(repository);
    await model.initialize();
    await model.selectComputer(computerA);
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('provider-picker')));
    await tester.pumpAndSettle();
    model.busy = true;
    await tester.tap(find.byKey(const ValueKey('provider-option-claude')));
    await tester.pumpAndSettle();
    expect(model.provider, Provider.codex);
    expect(model.computer, computerA);
    expect(repository.sends + repository.creates + repository.stops, 0);
    expect(tester.takeException(), isNull);
    await closeApp(tester, model);
  });

  testWidgets(
    'merged inbox keeps its unread count and marks entries on opening',
    (tester) async {
      final repository = _InboxRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.selectComputer(computerA);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      expect(model.unreadCount, 1);
      final badge = find.descendant(
        of: find.byTooltip('Inbox'),
        matching: find.byType(Badge),
      );
      expect(tester.widget<Badge>(badge).isLabelVisible, isTrue);
      await tester.tap(find.byTooltip('Inbox'));
      await tester.pumpAndSettle();
      expect(find.text('Review complete'), findsOneWidget);
      expect(model.unreadCount, 0);
      expect(repository.savedPreferences.readInbox, contains('compact-inbox'));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(model.computer, computerA);
      expect(find.byKey(const Key('provider-picker')), findsOneWidget);
      expect(repository.sends + repository.creates + repository.stops, 0);
      await closeApp(tester, model);
    },
  );

  for (final locale in ['zh', 'en']) {
    testWidgets('agent dropdown fits large text on a narrow phone in $locale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = FakeRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      model.setAppearance(locale: locale);
      await model.selectComputer(computerA);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('provider-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('provider-option-deepseek')));
      await tester.pumpAndSettle();
      expect(model.provider, Provider.deepseek);
      final picker = tester.getRect(find.byKey(const Key('provider-picker')));
      expect(
        picker.bottom,
        lessThan(tester.getRect(find.byType(TextFormField)).top),
      );
      expect(
        picker.top,
        lessThan(
          tester
              .getRect(find.byTooltip(Strings(Locale(locale)).t('Inbox')))
              .top,
        ),
      );
      expect(tester.takeException(), isNull);
      await closeApp(tester, model);
    });
  }
}
