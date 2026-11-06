import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:bridge_mobile/ui/design/bridge_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

void main() {
  setUpAll(() async {
    // Pin Latin golden typography to the existing licensed font asset.
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

  for (final theme in ['light', 'dark']) {
    testWidgets('scrolling content remains behind glass chrome in $theme', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = FakeRepository()
        ..onSnapshot = (session) async => snapshotFor(
          session,
          messages: [
            for (var i = 0; i < 30; i++)
              message(
                'glass-$i',
                i.isEven
                    ? 'Review connection $i and keep the original execution environment.'
                    : 'The desktop keeps the keys and permissions.\n\n```dart\nawait connection.refresh();\n```\nThis is synthetic content for a scrolling glass test.',
                role: i.isEven ? 'user' : 'assistant',
              ),
          ],
        );
      final model = BridgeViewModel(repository);
      await model.initialize();
      model.setAppearance(theme: theme);
      await model.selectComputer(computerA);
      await model.openSession(sessionA);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('glass-scroll-capture'),
          child: BridgeApp(repository: repository, viewModel: model),
        ),
      );
      await tester.pumpAndSettle();
      final list = tester.widget<ListView>(
        find.byKey(const Key('chat-transcript')),
      );
      final glass = find.byType(BridgeGlass);
      final viewport = tester.getRect(find.byKey(const Key('chat-transcript')));
      final header = tester.getRect(glass.first);
      final footer = tester.getRect(glass.last);
      expect(viewport.top, lessThan(header.bottom));
      expect(viewport.bottom, greaterThanOrEqualTo(footer.bottom));
      list.controller!.jumpTo(list.controller!.position.maxScrollExtent * .55);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const Key('glass-scroll-capture')),
        matchesGoldenFile('goldens/glass-scroll-$theme.png'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    });

    for (final page in [
      'computers',
      'chats',
      'agents',
      'detail',
      'settings',
      'login',
      'add',
    ]) {
      testWidgets('$page $theme golden', (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repository = FakeRepository();
        if (page == 'login') {
          repository.onConnect = (_) async => const AuthStatus(
            authenticated: false,
            computerName: 'Studio',
            platform: 'Windows',
            passwordless: false,
            notifications: false,
            transport: 'poll',
          );
        }
        final model = BridgeViewModel(repository);
        await model.initialize();
        model.setAppearance(theme: theme, locale: 'en');
        if (['chats', 'agents', 'detail', 'login'].contains(page)) {
          await model.selectComputer(computerA);
        }
        if (page == 'detail') await model.openSession(sessionA);
        await tester.pumpWidget(
          RepaintBoundary(
            key: const Key('capture'),
            child: BridgeApp(repository: repository, viewModel: model),
          ),
        );
        await tester.pumpAndSettle();
        if (page == 'settings') {
          await tester.tap(find.byKey(const ValueKey('tab-settings')));
        }
        if (page == 'add') {
          await tester.tap(find.byKey(const Key('add-local-computer')));
        }
        if (page == 'agents') {
          await tester.tap(find.byKey(const Key('provider-picker')));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byKey(const Key('capture')),
          matchesGoldenFile('goldens/$page-$theme.png'),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        model.dispose();
        await tester.pump();
      });
    }
  }

  for (final size in [const Size(320, 640), const Size(1024, 900)]) {
    for (final locale in ['zh', 'en']) {
      testWidgets('all roots fit large text $size $locale', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
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
        for (final tab in ['settings', 'chats', 'computers']) {
          await tester.tap(find.byKey(ValueKey('tab-$tab')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        model.dispose();
        await tester.pump();
      });
    }
  }

  for (final locale in ['zh', 'en']) {
    for (final keyboard in [false, true]) {
      testWidgets('large-text conversation with keyboard=$keyboard $locale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        if (keyboard) {
          tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        }
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
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
        expect(tester.takeException(), isNull);
        await model.openSession(sessionA);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('composer')),
          'first line\nsecond line\nthird line',
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(find.byKey(const Key('composer'))).bottom,
          lessThanOrEqualTo(keyboard ? 400 : 640),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        model.dispose();
        await tester.pump();
      });
    }
  }
}
