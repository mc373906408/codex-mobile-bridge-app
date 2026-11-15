import 'dart:ui' as ui;

import 'package:bridge_mobile/ui/design/bridge_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final style in BridgeGlassStyle.values) {
      for (final opaque in [false, true]) {
        testWidgets(
          'glass samples actual backdrop: $brightness $style opaque=$opaque',
          (tester) async {
            final capture = GlobalKey();
            await tester.pumpWidget(
              MaterialApp(
                theme: bridgeTheme(brightness),
                home: Center(
                  child: RepaintBoundary(
                    key: capture,
                    child: SizedBox(
                      width: 320,
                      height: 200,
                      child: BridgeVisualEnvironment(
                        reduceTransparency: opaque,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: ColoredBox(color: Colors.red)),
                                Expanded(child: ColoredBox(color: Colors.blue)),
                              ],
                            ),
                            Positioned(
                              left: 12,
                              right: 12,
                              top: 20,
                              bottom: 20,
                              child: BridgeGlass(
                                style: style,
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.runAsync(() async {
              final image =
                  await (capture.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              final left = (100 * image.width + 64) * 4;
              final right = (100 * image.width + 256) * 4;
              final redDifference =
                  bytes.getUint8(left) - bytes.getUint8(right);
              final blueDifference =
                  bytes.getUint8(right + 2) - bytes.getUint8(left + 2);
              if (opaque) {
                expect(redDifference.abs(), lessThan(3));
                expect(blueDifference.abs(), lessThan(3));
              } else if (style == BridgeGlassStyle.regular) {
                // Text controls retain a little backdrop color without letting
                // the underlying transcript dominate their surface.
                expect(redDifference, inInclusiveRange(1, 35));
                expect(blueDifference, inInclusiveRange(1, 35));
              } else {
                // The old 84–88% surface paint fails this: having a BackdropFilter
                // in the tree alone is not evidence that the backdrop is visible.
                expect(redDifference, greaterThan(85));
                expect(blueDifference, greaterThan(85));
              }
              image.dispose();
            });
          },
        );
      }
    }
  }

  testWidgets('native glass receives material and recreates it when changed', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final created = <Map<Object?, Object?>>[];
    final disposed = <int>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async {
        if (call.method == 'create') {
          final arguments = call.arguments as Map;
          final bytes = arguments['params'] as Uint8List;
          final parameters = const StandardMessageCodec().decodeMessage(
            ByteData.sublistView(bytes),
          ) as Map;
          created.add({'id': arguments['id'], ...parameters});
        } else if (call.method == 'dispose') {
          disposed.add(call.arguments as int);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      );
    });

    Widget material(BridgeGlassStyle style, {bool framed = true}) =>
        MaterialApp(
          theme: bridgeTheme(Brightness.light),
          home: BridgeVisualEnvironment(
            reduceTransparency: false,
            nativeGlass: true,
            child: Center(
              child: SizedBox(
                width: 320,
                height: 60,
                child: BridgeGlass(
                  style: style,
                  framed: framed,
                  child: const Text('Readable controls'),
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(material(BridgeGlassStyle.clear));
    await tester.pumpAndSettle();
    await tester.pumpWidget(material(BridgeGlassStyle.regular));
    await tester.pumpAndSettle();
    expect(created.map((value) => value['style']), ['clear', 'regular']);
    expect(disposed, contains(created.first['id']));
    expect(created.last, containsPair('radius', 24.0));
    expect(created.last, containsPair('dark', false));
    expect(created.last, containsPair('framed', true));
    await tester.pumpWidget(material(BridgeGlassStyle.regular, framed: false));
    await tester.pumpAndSettle();
    expect(created.last, containsPair('framed', false));
    expect(created.last, containsPair('radius', 0.0));
    expect(created.last, containsPair('surfaceColor', 0xFFFFFFFF));
    expect(disposed, contains(created[1]['id']));
    expect(find.text('Readable controls'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });
}
