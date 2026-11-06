import 'dart:ui' as ui;

import 'package:bridge_mobile/ui/design/bridge_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final opaque in [false, true]) {
      testWidgets('glass samples actual backdrop: $brightness opaque=$opaque', (
        tester,
      ) async {
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
                        const Positioned(
                          left: 12,
                          right: 12,
                          top: 20,
                          bottom: 20,
                          child: BridgeGlass(child: SizedBox.expand()),
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
          final redDifference = bytes.getUint8(left) - bytes.getUint8(right);
          final blueDifference =
              bytes.getUint8(right + 2) - bytes.getUint8(left + 2);
          if (opaque) {
            expect(redDifference.abs(), lessThan(3));
            expect(blueDifference.abs(), lessThan(3));
          } else {
            // The old 84–88% surface paint fails this: having a BackdropFilter
            // in the tree alone is not evidence that the backdrop is visible.
            expect(redDifference, greaterThan(85));
            expect(blueDifference, greaterThan(85));
          }
          image.dispose();
        });
      });
    }
  }
}
