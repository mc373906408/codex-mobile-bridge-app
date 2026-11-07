import 'dart:io';
import 'dart:ui' as ui;

import 'package:bridge_mobile/app.dart';
import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/notifications/cloud_push_bridge.dart';
import 'package:bridge_mobile/notifications/cloud_push_controller.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';

import 'support/cloud_home_test_support.dart';

void main() {
  if (const bool.fromEnvironment('BRIDGE_HOME_SCREENSHOTS')) {
    for (final (dark, signedIn) in const [
      (false, false),
      (false, true),
      (true, false),
      (true, true),
    ]) {
      final preview =
          '${dark ? 'dark' : 'light'}-${signedIn ? 'signed-in' : 'signed-out'}';
      testWidgets('render cloud home $preview preview', (tester) async {
        final cjk = File(r'C:\Windows\Fonts\simhei.ttf');
        final cjkBytes = Platform.isWindows && cjk.existsSync()
            ? ByteData.sublistView(cjk.readAsBytesSync())
            : null;
        for (final family in ['PlexSans', 'PlexMono']) {
          // Widget tests have no platform font fallback for local CJK previews.
          final loader = FontLoader(family)
            ..addFont(
              cjkBytes == null
                  ? rootBundle.load('assets/fonts/$family.ttf')
                  : Future.value(cjkBytes),
            );
          await loader.load();
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repository = FakeCloudRepository();
        if (signedIn) {
          await repository.cloudAccounts.signIn(
            officialCloudOrigin,
            'user@example.com',
            'password',
          );
          await repository.saveComputer(cloudComputer());
        }
        final model = BridgeViewModel(repository);
        await model.initialize();
        model.setAppearance(
          locale: cjkBytes == null ? 'en' : 'zh',
          theme: dark ? 'dark' : 'light',
        );
        final boundaryKey = GlobalKey();
        final native = FakeCloudPushBridge()
          ..current = CloudPushState(
            allowed: true,
            consent: dark,
            interactive: true,
          );
        final push = CloudPushController(repository, native, interval: null);
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: BridgeApp(
              repository: repository,
              viewModel: model,
              cloudPush: push,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expectHomeCloudSummaryRemoved();
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory(
            '.tmp/cloud-controls-inside-01a19f0a-20261103',
          )..createSync(recursive: true);
          await File('${directory.path}/home-$preview.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        final strings = Strings(Locale(cjkBytes == null ? 'en' : 'zh'));
        await openCloudService(tester, strings: strings);
        expectServicePanelsRemoved(strings: strings);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '.tmp/cloud-controls-inside-01a19f0a-20261103/service-$preview.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        if (signedIn) {
          await tester.tap(find.byKey(const Key('cloud-sign-out')));
          await tester.pumpAndSettle();
        }
        expectClearCloudLoginFields(tester, strings);
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '.tmp/cloud-controls-inside-01a19f0a-20261103/login-$preview.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await closeCloudApp(tester, model);
      });
    }
  }
}
