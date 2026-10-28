import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

void main() {
  for (final locale in ['zh', 'en']) {
    for (final returnHome in [false, true]) {
      testWidgets(
        'home controls recover after resume in $locale, returned=$returnHome',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          final repository = FakeRepository();
          final model = BridgeViewModel(repository);
          await model.initialize();
          model.setAppearance(locale: locale);
          if (returnHome) await model.selectComputer(computerA);
          await tester.pumpWidget(
            BridgeApp(repository: repository, viewModel: model),
          );
          await tester.pumpAndSettle();
          final home = find.byKey(const Key('home-button'));
          if (returnHome) {
            await tester.tap(home);
            await tester.pumpAndSettle();
          }
          final add = find.ancestor(
            of: find.text(locale == 'zh' ? '添加电脑' : 'Add computer'),
            matching: find.byWidgetPredicate(
              (widget) => widget is FilledButton,
            ),
          );
          final card = find.byKey(ValueKey('remove-computer-${computerA.id}'));
          final tile = find.descendant(
            of: card,
            matching: find.byType(ListTile),
          );
          await tester.scrollUntilVisible(add, 160);
          await tester.pumpAndSettle();
          expect(tester.widget<FilledButton>(add).onPressed, isNotNull);
          final connections = repository.connects;

          for (var cycle = 0; cycle < 3; cycle++) {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
            await tester.pump();
            expect(model.foreground, isFalse);

            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            // Android can draw a visible, unfocused frame before resuming.
            await tester.pump();
            expect(tester.widget<FilledButton>(add).onPressed, isNull);
            expect(tester.widget<ListTile>(tile).onTap, isNull);
            expect(
              tester.widget<Dismissible>(card).direction,
              DismissDirection.none,
            );

            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await tester.pumpAndSettle();
            expect(model.foreground, isTrue);
            expect(model.busy, isFalse);
            expect(tester.widget<FilledButton>(add).onPressed, isNotNull);
            expect(tester.widget<ListTile>(tile).onTap, isNotNull);
            expect(tester.widget<IconButton>(home).onPressed, isNotNull);
            expect(
              tester.widget<Dismissible>(card).direction,
              DismissDirection.endToStart,
            );
            expect(repository.connects, connections);
          }

          await tester.tap(add);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          await tester.tap(find.text(locale == 'zh' ? '取消' : 'Cancel'));
          await tester.pumpAndSettle();
          await tester.drag(card, Offset(-tester.getSize(card).width * .75, 0));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('remove-connection-dialog')),
            findsOneWidget,
          );
          await tester.tap(find.text(locale == 'zh' ? '取消' : 'Cancel'));
          await tester.pumpAndSettle();
          expect(repository.removedComputerIds, isEmpty);
          await tester.tap(tile);
          await tester.pumpAndSettle();
          expect(model.computer, computerA);
          expect(repository.connects, connections + 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          model.dispose();
          await tester.pump();
        },
      );
    }
  }
}
