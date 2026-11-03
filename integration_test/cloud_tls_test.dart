import 'dart:convert';
import 'dart:io';

import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/src/rust/api/cloud.dart' as cloud;
import 'package:bridge_mobile/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/synthetic_tls.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native cloud TLS keeps trust checks and reaches official service',
    (tester) async {
      await RustLib.init();
      addTearDown(RustLib.dispose);
      final context = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(syntheticCertificate))
        ..usePrivateKeyBytes(utf8.encode(syntheticPrivateKey));
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      var untrustedRequests = 0;
      final handler = server.listen(
        (request) {
          untrustedRequests++;
          request.response.close();
        },
        onError: (Object error) {
          if (error is! HandshakeException) throw error;
        },
      );
      addTearDown(() async {
        await handler.cancel();
        await server.close(force: true);
      });

      await expectLater(
        cloud.cloudCapabilities(origin: 'https://127.0.0.1:${server.port}'),
        throwsA(isA<Exception>()),
      );
      expect(untrustedRequests, 0);

      final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final httpHandler = httpServer.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'control_noise': 'Noise_KK_25519_ChaChaPoly_BLAKE2s',
            'preview_noise': 'Noise_K_25519_ChaChaPoly_BLAKE2s',
            'relay_protocols': [1],
            'mode': 'selfhost',
            'login': 'username',
          }),
        );
        await request.response.close();
      });
      addTearDown(() async {
        await httpHandler.cancel();
        await httpServer.close(force: true);
      });
      expect(
        (await cloud.cloudCapabilities(
          origin: 'http://127.0.0.1:${httpServer.port}',
        )).mode,
        'selfhost',
      );

      final firstRequest = Stopwatch()..start();
      final capabilities = await cloud.cloudCapabilities(
        origin: officialCloudOrigin,
      );
      firstRequest.stop();
      expect(capabilities.mode, 'hosted');
      expect(capabilities.login, 'email');
      expect(capabilities.entitlementRequired, isTrue);
      expect(firstRequest.elapsed, lessThan(const Duration(seconds: 20)));

      final official = Uri.parse(officialCloudOrigin);
      final addresses = await InternetAddress.lookup(
        official.host,
        type: InternetAddressType.IPv4,
      );
      await expectLater(
        cloud.cloudCapabilities(
          origin: 'https://${addresses.first.address}:${official.port}',
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        (await cloud.cloudCapabilities(origin: officialCloudOrigin)).login,
        'email',
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Native cloud TLS verified')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Native cloud TLS verified'), findsOneWidget);
    },
  );
}
