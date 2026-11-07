import 'dart:convert';
import 'dart:io';

import 'package:bridge_mobile/data/bridge_types.dart';
import 'package:bridge_mobile/src/rust/api/client.dart';
import 'package:bridge_mobile/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _sid = '11111111-1111-4111-8111-111111111111';
const _reason = '正在后台读取 SSH 主机；本机会话可正常使用。';

void main() {
  const library = String.fromEnvironment('BRIDGE_NATIVE_LIB');
  test(
    'real FFI preserves session hosts, labels and partial loading diagnostics',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library));
      final directory = await Directory.systemTemp.createTemp(
        'bridge-session-ffi-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final handler = server.listen(_respond);
      final computer = Computer(
        id: newId(),
        name: 'Desktop',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final client = await BridgeClient.open(
        computer: computer,
        databasePath: '${directory.path}/state.sqlite',
        platform: 'iOS',
        credentials: null,
      );
      addTearDown(() async {
        await client.pause();
        client.dispose();
        await handler.cancel();
        await server.close(force: true);
        RustLib.dispose();
        await directory.delete(recursive: true);
      });
      expect((await client.authenticate()).authenticated, isTrue);
      final page = await client.sessions(
        provider: Provider.codex,
        query: '',
        offset: 0,
      );
      expect(page.sessions.single.session.computerId, computer.id);
      expect(page.sessions.single.session.environment, 'local');
      expect(page.sessions.single.environmentLabel, 'This computer');
      expect(page.environmentIssues.single.environment, 'ssh:lab');
      expect(page.environmentIssues.single.label, 'Lab');
      expect(page.environmentIssues.single.reason, _reason);
      expect(page.environmentIssues.single.loading, isTrue);
      expect(page.notice, isEmpty);
    },
    skip: library.isEmpty
        ? 'Run python scripts/test_native.py to load the real library'
        : false,
  );
}

Future<void> _respond(HttpRequest request) async {
  final Object body;
  if (request.uri.path == '/api/auth') {
    body = {
      'authenticated': true,
      'csrf': 'synthetic',
      'computer': {'name': 'Desktop'},
    };
  } else if (request.uri.path == '/api/sessions') {
    expect(request.uri.queryParameters['source'], 'all');
    body = {
      'sessions': [
        {
          'id': _sid,
          'host': 'local',
          'hostLabel': 'This computer',
          'title': 'Chat',
        },
      ],
      'unavailableHosts': [
        {'host': 'ssh:lab', 'label': 'Lab', 'error': _reason},
      ],
    };
  } else {
    request.response.statusCode = HttpStatus.notFound;
    body = {'error': 'Unexpected test route'};
  }
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}
