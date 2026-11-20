import 'dart:convert';
import 'dart:io';

import 'package:bridge_mobile/notifications/cloud_push_bridge.dart';
import 'package:bridge_mobile/src/rust/api/client.dart' show newId;
import 'package:bridge_mobile/src/rust/frb_generated.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

String _previewCredentials() => jsonEncode({
  'origin': 'https://relay.example',
  'gateway_id': newId(),
  'binding_id': newId(),
  'private_key': base64Encode(List.filled(32, 1)),
  'desktop_public_key': base64Encode(List.filled(32, 2)),
});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('both iOS preview removals succeed when queued together', (
    tester,
  ) async {
    await RustLib.init();
    addTearDown(RustLib.dispose);
    final storage = NativeCloudPreviewStorage();
    final computers = [newId(), newId()];
    addTearDown(() async {
      for (final computer in computers) {
        await storage.remove(computer);
      }
    });
    for (final computer in computers) {
      await storage.save(computer, _previewCredentials());
    }

    await Future.wait(computers.map(storage.remove));

    for (final computer in computers) {
      await storage.save(computer, _previewCredentials());
    }
  }, skip: !Platform.isIOS);

  testWidgets('iOS preview removal still reports invalid input', (
    tester,
  ) async {
    await expectLater(
      NativeCloudPreviewStorage().remove(''),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'cloud_preview_unavailable',
        ),
      ),
    );
  }, skip: !Platform.isIOS);
}
