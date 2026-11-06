import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
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
    for (final page in [
      'computers',
      'chats',
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
        if (['chats', 'detail', 'login'].contains(page)) {
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
