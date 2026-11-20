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
    testWidgets('scrolling transcript stays between glass controls in $theme', (
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
      await loadChatIcon(tester);
      await tester.pumpAndSettle();
      final list = tester.widget<ScrollView>(
        find.byKey(const Key('chat-transcript')),
      );
      final viewport = tester.getRect(find.byKey(const Key('chat-transcript')));
      final header = tester.getRect(
        find.ancestor(
          of: find.byTooltip('New tab'),
          matching: find.byType(BridgeGlass),
        ),
      );
      final footer = tester.getRect(
        find.ancestor(
          of: find.byKey(const Key('composer')),
          matching: find.byType(BridgeGlass),
        ),
      );
      expect(viewport.top, greaterThanOrEqualTo(header.bottom));
      expect(viewport.bottom, lessThanOrEqualTo(footer.top));
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
      'rename',
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
        if (page == 'detail') await loadChatIcon(tester);
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
        if (page == 'rename') {
          final card = find.byKey(ValueKey('computer-card-${computerA.id}'));
          await tester.ensureVisible(card);
          await tester.longPress(card);
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

  for (final (theme, locale, scale) in [
    ('light', 'zh', 1.0),
    ('dark', 'en', 2.0),
  ]) {
    testWidgets('composer choice menus match the app style in $theme', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = FakeRepository()
        ..onSnapshot = (session) async => snapshotFor(
          session,
          capabilities: const CapabilitySet(
            send: true,
            steer: true,
            stop: true,
            approve: false,
            resume: false,
            models: true,
            attachments: true,
            arbitraryFiles: true,
          ),
          metadata: '{"capabilities":{"goal":true}}',
        );
      final model = BridgeViewModel(repository);
      await model.initialize();
      model.setAppearance(theme: theme, locale: locale);
      await model.selectComputer(computerA);
      await model.openSession(sessionA);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();

      Finder trigger(String label) =>
          find.widgetWithText(PopupMenuButton<String>, label);
      Finder choice(String value) => find.byWidgetPredicate(
        (widget) =>
            widget is CheckedPopupMenuItem<String> && widget.value == value,
      );
      Future<void> openMenu(
        String label,
        String selected,
        List<String> values,
      ) async {
        await tester.tap(trigger(label));
        await tester.pumpAndSettle();
        final items = tester.widgetList<CheckedPopupMenuItem<String>>(
          find.byType(CheckedPopupMenuItem<String>),
        );
        expect(items.map((item) => item.value), values);
        expect(items.where((item) => item.checked).map((item) => item.value), [
          selected,
        ]);
        expect(items.map((item) => item.height), everyElement(52.0));
        final surface = tester.widget<Material>(
          find.ancestor(
            of: choice(selected),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Material && widget.type == MaterialType.card,
            ),
          ),
        );
        final scheme = Theme.of(tester.element(choice(selected))).colorScheme;
        expect(surface.color, scheme.surface);
        expect(surface.surfaceTintColor, Colors.transparent);
        expect(surface.elevation, 4);
        expect(
          (surface.shape as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(20),
        );
        final check = find.descendant(
          of: choice(selected),
          matching: find.byIcon(Icons.done),
        );
        expect(IconTheme.of(tester.element(check)).color, scheme.primary);
        expect(tester.takeException(), isNull);
      }

      final chinese = locale == 'zh';
      const sendModes = ['send', 'queue', 'steer'];
      const workModes = ['default', 'plan', 'goal'];
      await openMenu(chinese ? '发送新消息' : 'New message', 'send', sendModes);
      await tester.tap(choice('queue'));
      await tester.pumpAndSettle();
      expect(model.sendMode, 'queue');

      await openMenu(chinese ? '普通模式' : 'Normal mode', 'default', workModes);
      await tester.tap(choice('plan'));
      await tester.pumpAndSettle();
      expect(model.draftOptions['workMode'], 'plan');
      final plan = chinese ? '计划模式' : 'Plan mode';
      await openMenu(plan, 'plan', workModes);
      await tester.tapAt(const Offset(12, 120));
      await tester.pumpAndSettle();
      expect(find.byType(CheckedPopupMenuItem<String>), findsNothing);
      expect(model.draftOptions['workMode'], 'plan');

      await openMenu(chinese ? '排队发送' : 'Queue message', 'queue', sendModes);
      await tester.tap(choice('steer'));
      await tester.pumpAndSettle();
      expect(model.sendMode, 'steer');
      expect(
        tester.widget<PopupMenuButton<String>>(trigger(plan)).enabled,
        false,
      );
      expect(repository.sends, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    });
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

Future<void> loadChatIcon(WidgetTester tester) async {
  // Image decoding runs outside the widget test's fake clock; settling frames
  // alone can capture the title before its asset is ready on a busy runner.
  await tester.runAsync(
    () => precacheImage(
      const AssetImage('assets/client-icons/codex.png'),
      tester.element(find.byType(BridgeApp)),
    ),
  );
}
