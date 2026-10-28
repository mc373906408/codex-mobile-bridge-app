import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bridge_mobile/src/rust/api/client.dart';
import 'package:bridge_mobile/src/rust/api/types.dart';
import 'package:bridge_mobile/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const library = String.fromEnvironment('BRIDGE_NATIVE_LIB');
  if (library.isEmpty) {
    test(
      'native FFI contract smoke',
      () {},
      skip: 'Run python scripts/test_native.py to build and load the real library',
    );
    return;
  }

  test(
    'real FFI async calls, SQLite, stream cancellation and at-most-once writes',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library));
      final root = await Directory('.tmp').absolute.create(recursive: true);
      final directory = await root.createTemp('ffi-smoke-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const sid = '11111111-1111-4111-8111-111111111111';
      var sends = 0, stops = 0;
      final handler = server.listen((request) async {
        try {
          final path = request.uri.path;
          final body = await utf8.decoder.bind(request).join();
          Object result;
          if (path == '/api/auth') {
            request.response.cookies.add(
              Cookie('codex_mobile_session_smoke', 'test-only-cookie')
                ..httpOnly = true,
            );
            result = {
              'authenticated': true,
              'csrf': 'test-only-csrf',
              'draftIdentity': 'smoke-gateway',
              'transport': 'poll',
              'computer': {'name': 'Synthetic gateway'},
            };
          } else if (path.endsWith('/timeline')) {
            result = {
              'epoch': 'smoke-epoch',
              'sequence': 1,
              'before': null,
              'hasMore': false,
              'rows': [
                {
                  'key': 'smoke-message',
                  'role': 'assistant',
                  'text': 'A synthetic reply',
                },
              ],
              'meta': {
                'id': sid,
                'host': 'local',
                'title': 'Synthetic chat',
                'cwd': '/test',
                'connected': true,
                'status': 'idle',
                'draftAccountIdentity': 'smoke-account',
                'access': {'canSend': true},
                'requests': [],
              },
            };
          } else if (path.endsWith('/send')) {
            sends++;
            expect(request.headers.value('x-csrf-token'), 'test-only-csrf');
            expect(request.headers.contentLength, utf8.encode(body).length);
            expect((jsonDecode(body) as Map)['text'], 'Synthetic message');
            result = {'status': 'unknown'};
          } else if (path.endsWith('/stop')) {
            stops++;
            result = {'ok': true};
          } else if (path.endsWith('/poll')) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            result = {'state': null};
          } else {
            request.response.statusCode = 404;
            result = {'error': 'Unexpected test route'};
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(result));
          await request.response.close();
        } on SocketException {
          // The Rust cancellation path closes the in-flight long poll.
        } on HttpException {
          // The Rust cancellation path closes the in-flight long poll.
        }
      });
      LocalDatabase? database;
      BridgeClient? client;
      addTearDown(() async {
        await client?.pause();
        client?.dispose();
        database?.dispose();
        await handler.cancel();
        await server.close(force: true);
        RustLib.dispose();
        final resolved = directory.absolute.path;
        if (!resolved.startsWith(
          '${root.path}${Platform.pathSeparator}ffi-smoke-',
        )) {
          throw StateError(
            'Refusing to remove a directory outside the smoke-test workspace',
          );
        }
        for (var attempt = 0; ; attempt++) {
          try {
            await directory.delete(recursive: true);
            break;
          } on FileSystemException {
            if (attempt >= 10) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      });

      final computer = Computer(
        id: newId(),
        name: 'Synthetic gateway',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final path = '${directory.path}${Platform.pathSeparator}state.sqlite';
      database = await LocalDatabase.open(path: path);
      await database.saveComputer(computer: computer);
      expect((await database.computers()).single, computer);
      client = await BridgeClient.open(
        computer: computer,
        databasePath: path,
        platform: 'Android',
        credentials: null,
      );
      expect((await client.authenticate()).authenticated, isTrue);
      final session = SessionRef(
        computerId: computer.id,
        provider: Provider.codex,
        environment: 'local',
        id: sid,
      );
      final current = await client.snapshot(session: session);
      expect(current.history.messages.single.text, 'A synthetic reply');
      expect(current.accountIdentity, isNotEmpty);
      await database.saveDraft(
        session: session,
        account: current.accountIdentity,
        draft: const Draft(
          text: 'Synthetic draft',
          attachments: [],
          revision: 2,
        ),
      );
      expect(
        (await database.draft(
          session: session,
          account: current.accountIdentity,
        )).text,
        'Synthetic draft',
      );

      final subscription = newId();
      final stream = StreamIterator(
        client.watchSession(session: session, subscriptionId: subscription),
      );
      expect(
        await stream.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(stream.current.subscriptionId, subscription);
      await client.cancelWatch(subscriptionId: subscription);
      await stream.cancel();
      expect(stops, 0);

      final operation = newId();
      for (var attempt = 0; attempt < 2; attempt++) {
        final result = await client.send(
          session: session,
          token: current.controlToken,
          id: operation,
          text: 'Synthetic message',
          attachments: [],
          steer: false,
        );
        expect(result.kind, OutcomeKind.unknown);
      }
      expect(sends, 1);
      expect(
        (await database.pending(
          session: session,
          account: current.accountIdentity,
        )).single.id,
        operation,
      );
      await database.markReviewed(
        session: session,
        account: current.accountIdentity,
        id: operation,
        confirmed: true,
      );
      expect(
        await database.pending(
          session: session,
          account: current.accountIdentity,
        ),
        isEmpty,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
