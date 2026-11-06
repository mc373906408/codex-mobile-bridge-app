import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/ui/design/accessibility_bridge.dart';
import 'package:bridge_mobile/ui/design/bridge_theme.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

void main() {
  testWidgets('iOS swipe returns from detail without losing its draft', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = FakeRepository();
    final model = BridgeViewModel(repository);
    await model.initialize();
    await model.selectComputer(computerA);
    await tester.pumpWidget(
      BridgeApp(repository: repository, viewModel: model),
    );
    await tester.pumpAndSettle();
    await model.openSession(sessionA);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('composer')),
      'Swipe keeps this draft',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.dragFrom(const Offset(1, 200), const Offset(340, 0));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(model.selected, isNull);
    expect(model.computer, computerA);
    expect(
      (await repository.draft(sessionA, 'account-a')).text,
      'Swipe keeps this draft',
    );
    expect(repository.sends + repository.creates + repository.stops, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'tabs preserve connection, session, draft and list state without writes',
    (tester) async {
      final repository = FakeRepository();
      final model = BridgeViewModel(repository);
      await model.initialize();
      await model.selectComputer(computerA);
      await model.openSession(sessionA);
      // Wide layout exposes tabs while a conversation is open.
      tester.view.physicalSize = const Size(1024, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        BridgeApp(repository: repository, viewModel: model),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('composer')),
        'Keep this local draft',
      );
      await tester.pump(const Duration(milliseconds: 350));
      final connects = repository.connects;
      for (final tab in ['settings', 'computers', 'computers', 'chats']) {
        await tester.tap(find.byKey(ValueKey('tab-$tab')));
        await tester.pumpAndSettle();
        expect(model.computer, computerA);
        expect(model.selected, sessionA);
        expect(model.draftText, 'Keep this local draft');
        expect(repository.connects, connects);
      }
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('composer')))
            .controller!
            .text,
        'Keep this local draft',
      );
      expect(repository.sends + repository.stops + repository.creates, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'unselected chat tab guides selection and back returns to computers',
    (tester) async {
      final repository = FakeRepository();
      await tester.pumpWidget(BridgeApp(repository: repository));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tab-chats')));
      await tester.pumpAndSettle();
      expect(find.text('Choose computer'), findsOneWidget);
      expect(repository.connects, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add-local-computer')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('phone details hide tabs and system back saves draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
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
    expect(find.byKey(const ValueKey('tab-chats')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('composer')),
      'Draft before back',
    );
    await tester.binding.handlePopRoute();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(model.selected, isNull);
    expect(model.computer, computerA);
    expect(find.byKey(const ValueKey('tab-chats')), findsOneWidget);
    expect(
      (await repository.draft(sessionA, 'account-a')).text,
      'Draft before back',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.pump();
  });

  testWidgets('high contrast removes all backdrop filters', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(highContrast: true),
          child: BridgeGlass(child: const Text('Readable')),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('iOS transparency channel fails opaque and responds to changes', (
    tester,
  ) async {
    const channel = MethodChannel('test/accessibility');
    final bridge = AccessibilityBridge(
      platform: TargetPlatform.iOS,
      channel: channel,
    );
    var reduced = false;
    expect(bridge.reduceTransparency, isTrue);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'supportsLiquidGlass' ? true : reduced,
    );
    await bridge.initialize();
    expect(bridge.reduceTransparency, isFalse);
    expect(bridge.nativeGlass, isTrue);
    reduced = true;
    await bridge.refresh();
    expect(bridge.reduceTransparency, isTrue);
    expect(bridge.nativeGlass, isTrue);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    await bridge.refresh();
    expect(bridge.reduceTransparency, isTrue);
    expect(bridge.nativeGlass, isFalse);
    bridge.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });

  testWidgets(
    'older iOS bridge falls back without losing a known transparency preference',
    (tester) async {
      const channel = MethodChannel('test/old-accessibility');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'reduceTransparency') return false;
        throw MissingPluginException();
      });
      final bridge = AccessibilityBridge(
        platform: TargetPlatform.iOS,
        channel: channel,
      );
      await bridge.initialize();
      expect(bridge.nativeGlass, isFalse);
      expect(bridge.reduceTransparency, isFalse);
      bridge.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    },
  );

  testWidgets('reduce transparency overrides native material capability', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: BridgeVisualEnvironment(
          reduceTransparency: true,
          nativeGlass: true,
          child: BridgeGlass(child: Text('Readable controls')),
        ),
      ),
    );
    expect(find.byType(UiKitView), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('Readable controls'), findsOneWidget);
  });
}
