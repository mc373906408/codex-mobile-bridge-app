import 'dart:convert';
import 'dart:io';

import 'package:bridge_mobile/src/rust/api/client.dart';
import 'package:bridge_mobile/src/rust/api/types.dart';
import 'package:bridge_mobile/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import '../test/support/synthetic_tls.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('packaged Rust, Android TLS initialization, and secure storage', (
    tester,
  ) async {
    await RustLib.init();
    final temporary = await getTemporaryDirectory();
    final directory = await temporary.createTemp('bridge-native-smoke-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final security = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(syntheticCertificate))
      ..usePrivateKeyBytes(utf8.encode(syntheticPrivateKey));
    final tlsServer = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      security,
    );
    var tlsRequests = 0;
    final tlsHandler = tlsServer.listen(
      (request) {
        tlsRequests++;
        request.response.close();
      },
      onError: (Object error) {
        if (error is! HandshakeException) throw error;
      },
    );
    const sid = '11111111-1111-4111-8111-111111111111';
    var sends = 0;
    final handler = server.listen((request) async {
      try {
        final body = await utf8.decoder.bind(request).join();
        final Object response;
        if (request.uri.path == '/api/auth') {
          response = {
            'authenticated': true,
            'csrf': 'synthetic-csrf',
            'draftIdentity': 'synthetic-gateway',
            'transport': 'poll',
          };
        } else if (request.uri.path.endsWith('/timeline')) {
          response = {
            'epoch': 'synthetic-epoch',
            'sequence': 1,
            'rows': [
              {
                'key': 'reply',
                'role': 'assistant',
                'text': 'Native core ready',
              },
            ],
            'meta': {
              'id': sid,
              'host': 'local',
              'connected': true,
              'status': 'idle',
              'draftAccountIdentity': 'synthetic-account',
              'access': {'canSend': true},
              'requests': [],
            },
          };
        } else if (request.uri.path.endsWith('/send')) {
          sends++;
          expect(request.headers.value('x-csrf-token'), 'synthetic-csrf');
          expect(request.headers.contentLength, utf8.encode(body).length);
          response = {'status': 'unknown'};
        } else {
          request.response.statusCode = 404;
          response = {'error': 'Unexpected synthetic route'};
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(response));
        await request.response.close();
      } on SocketException {
        // Cancellation closes an in-flight test connection.
      } on HttpException {
        // Cancellation closes an in-flight test connection.
      }
    });
    const secure = FlutterSecureStorage();
    final key = 'bridge.integration.${newId()}';
    LocalDatabase? database;
    BridgeClient? client;
    BridgeClient? tlsClient;
    addTearDown(() async {
      await client?.pause();
      client?.dispose();
      await tlsClient?.pause();
      tlsClient?.dispose();
      database?.dispose();
      await secure.delete(key: key);
      await handler.cancel();
      await server.close(force: true);
      await tlsHandler.cancel();
      await tlsServer.close(force: true);
      RustLib.dispose();
    });

    await secure.write(key: key, value: 'synthetic-credential');
    expect(await secure.read(key: key), 'synthetic-credential');
    final computer = Computer(
      id: newId(),
      name: 'Synthetic mobile test',
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
    final path = '${directory.path}/state.sqlite';
    tlsClient = await BridgeClient.open(
      computer: Computer(
        id: newId(),
        name: 'Synthetic untrusted certificate',
        baseUrl: 'https://127.0.0.1:${tlsServer.port}',
      ),
      databasePath: path,
      platform: Platform.isIOS ? 'iOS' : 'Android',
      credentials: null,
    );
    await expectLater(tlsClient.authenticate(), throwsA(isA<Exception>()));
    expect(tlsRequests, 0);
    database = await LocalDatabase.open(path: path);
    await database.saveComputer(computer: computer);
    expect((await database.computers()).single, computer);
    client = await BridgeClient.open(
      computer: computer,
      databasePath: path,
      platform: Platform.isIOS ? 'iOS' : 'Android',
      credentials: null,
    );
    expect((await client.authenticate()).authenticated, isTrue);
    final session = SessionRef(
      computerId: computer.id,
      provider: Provider.codex,
      environment: 'local',
      id: sid,
    );
    final snapshot = await client.snapshot(session: session);
    final id = newId();
    for (var attempt = 0; attempt < 2; attempt++) {
      final outcome = await client.send(
        session: session,
        token: snapshot.controlToken,
        id: id,
        text: 'Synthetic mobile message',
        attachments: [],
        steer: false,
      );
      expect(outcome.kind, OutcomeKind.unknown);
    }
    expect(sends, 1);
    expect(
      (await database.pending(
        session: session,
        account: snapshot.accountIdentity,
      )).single.id,
      id,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: Text(snapshot.history.messages.single.text)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Native core ready'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
