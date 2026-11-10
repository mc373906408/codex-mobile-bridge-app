import 'dart:convert';
import 'dart:io';

import 'package:bridge_mobile/data/bridge_types.dart';
import 'package:bridge_mobile/src/rust/api/client.dart';
import 'package:bridge_mobile/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const library = String.fromEnvironment('BRIDGE_NATIVE_LIB');
  test(
    'production desktop HTTP handler accepts native business and bounded file requests',
    () async {
      final root = await Directory('.tmp').absolute.create(recursive: true);
      final directory = await root.createTemp('web-parity-');
      final desktop = Directory(
        const String.fromEnvironment(
          'BRIDGE_DESKTOP_ROOT',
          defaultValue: '../codex-mobile-bridge',
        ),
      ).absolute;
      expect(
        File('${desktop.path}/bridge/api/httpd.py').existsSync(),
        isTrue,
        reason: 'Desktop checkout is required for the real HTTP fixture',
      );
      final process = await Process.start('python', [
        '-B',
        'scripts/web_parity_fixture.py',
        '--desktop',
        desktop.path,
        '--directory',
        directory.path,
      ]);
      final errors = StringBuffer();
      final stderr = process.stderr
          .transform(utf8.decoder)
          .listen(errors.write);
      BridgeClient? clientToClose;
      var nativeInitialized = false;
      addTearDown(() async {
        try {
          await clientToClose?.pause();
          clientToClose?.dispose();
          if (nativeInitialized) RustLib.dispose();
        } finally {
          try {
            process.stdin.writeln('stop');
            await process.stdin.flush();
            await process.stdin.close();
            await process.exitCode.timeout(const Duration(seconds: 10));
          } catch (_) {
            process.kill();
            await process.exitCode;
          }
          await stderr.cancel();
          if (!directory.path.startsWith(
            '${root.path}${Platform.pathSeparator}web-parity-',
          )) {
            throw StateError('Invalid cleanup path');
          }
          await directory.delete(recursive: true);
        }
        expect(
          errors.toString().contains('Traceback'),
          isFalse,
          reason: errors.toString(),
        );
      });
      final first = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 30));
      final info = jsonDecode(first) as Map<String, dynamic>;
      await RustLib.init(externalLibrary: ExternalLibrary.open(library));
      nativeInitialized = true;
      final computer = Computer(
        id: newId(),
        name: 'Synthetic desktop',
        baseUrl: info['origin'],
      );
      final client = await BridgeClient.open(
        computer: computer,
        databasePath: '${directory.path}/state.sqlite',
        platform: 'Android',
        credentials: null,
      );
      clientToClose = client;
      await client.login(username: 'fixture', password: 'fixture-only');
      final session = SessionRef(
        computerId: computer.id,
        provider: Provider.codex,
        entry: '',
        environment: 'local',
        id: info['session'],
      );
      final snapshot = await client.snapshot(session: session);
      Future<Map<String, dynamic>> read(
        SessionResource resource,
        Map<String, Object?> args,
      ) async => jsonDecode(
        await client.sessionResource(
          session: session,
          resource: resource,
          parameters: jsonEncode(args),
        ),
      ) as Map<String, dynamic>;
      Future<BusinessReply> write(
        SessionCommand command,
        Map<String, Object?> args,
      ) => client.sessionCommand(
        session: session,
        account: snapshot.accountIdentity,
        token: snapshot.controlToken,
        id: newId(),
        command: command,
        parameters: jsonEncode(args),
      );
      final listing = await read(SessionResource.files, {});
      expect(
        (listing['entries'] as List).map((e) => e['name']),
        contains('hello.txt'),
      );
      final preview = await read(SessionResource.filePreview, {
        'path': 'hello.txt',
      });
      expect(preview['text'], 'Hello 世界\nline two\n');
      var offset = 0;
      final complete = StringBuffer();
      while (true) {
        final detail = await read(SessionResource.messageDetail, {
          'key': 'native-fixture.row',
          'version': 'v1',
          'offset': offset,
        });
        expect(detail['key'], 'row');
        expect(detail['offset'], offset);
        expect(detail['version'], 'v1');
        complete.write(detail['text']);
        if (detail['next'] == null) break;
        offset = detail['next'];
      }
      expect(complete.toString(), List.filled(12000, '完整内容 ').join());
      await File('${info['project']}/hello.txt')
          .writeAsString('Hello changed\n');
      final staleGit = await read(SessionResource.gitStatus, {});
      Future<Map<String, dynamic>> git(
        String action, [
        Map<String, Object?> fields = const {},
      ]) async {
        final status = await read(SessionResource.gitStatus, {});
        final result = await write(SessionCommand.git, {
          'action': action,
          'version': status['version'],
          ...fields,
        });
        expect(result.outcome.kind, OutcomeKind.accepted, reason: result.data);
        return jsonDecode(result.data);
      }

      await git('stage', {'path': 'hello.txt'});
      expect(
        (await read(SessionResource.gitDiff, {
          'path': 'hello.txt',
          'section': 'staged',
        }))['text'],
        contains('Hello changed'),
      );
      final denied = await write(SessionCommand.git, {
        'action': 'unstage',
        'path': 'hello.txt',
        'version': staleGit['version'],
      });
      expect(denied.outcome.kind, OutcomeKind.unknown);
      final database = await LocalDatabase.open(
        path: '${directory.path}/state.sqlite',
      );
      await database.markReviewed(
        session: session,
        account: snapshot.accountIdentity,
        id: denied.outcome.id,
        confirmed: true,
      );
      await git('unstage', {'path': 'hello.txt'});
      await git('stage', {'path': 'hello.txt'});
      await git('commit', {'message': 'Native FFI commit'});
      final history = await read(SessionResource.gitHistory, {
        'limit': 40,
        'ref': 'current',
      });
      expect(
        (history['commits'] as List).first['subject'],
        'Native FFI commit',
      );
      await git('create-branch', {'branch': 'fixture-feature'});
      await File('${info['project']}/hello.txt')
          .writeAsString('feature branch\n');
      await git('stage', {'path': 'hello.txt'});
      await git('commit', {'message': 'Feature'});
      await git('switch-branch', {'branch': 'fixture-main'});
      await File('${info['project']}/hello.txt').writeAsString('main branch\n');
      await git('stage', {'path': 'hello.txt'});
      await git('commit', {'message': 'Main'});
      expect(
        (await git('merge', {'branch': 'fixture-feature'}))['outcome'],
        'conflict',
      );
      await git('abort-merge');
      expect((await read(SessionResource.gitStatus, {}))['operation'], isNull);
      database.dispose();
      Future<GatewayState> gatewayRead(
        GatewayResource resource, {
        Provider provider = Provider.codex,
        String entry = '',
      }) => client.gatewayResource(
        provider: provider,
        entry: entry,
        resource: resource,
        parameters: '{}',
      );
      final notifications = await gatewayRead(GatewayResource.webhook);
      final endpoint = await client.gatewayCommand(
        provider: Provider.codex,
        entry: '',
        identity: notifications.identity,
        id: newId(),
        command: GatewayCommand.webhookEndpoints,
        parameters: jsonEncode({
          'action': 'upsert',
          'webhookName': 'Fixture endpoint',
          'webhookEnabled': false,
          'webhookHeaders': {'X-Fixture': 'test'},
          'webhookProvider': 'generic',
        }),
      );
      expect(
        endpoint.outcome.kind,
        OutcomeKind.accepted,
        reason: endpoint.data,
      );
      expect(
        (jsonDecode(endpoint.data)['webhookEndpoints'] as List)
            .single['webhookName'],
        'Fixture endpoint',
      );
      final environments = await gatewayRead(
        GatewayResource.wslEnvironments,
        provider: Provider.claude,
      );
      final wsl =
          (jsonDecode(environments.data)['environments'] as List).single['id']
              as String;
      final accounts = await gatewayRead(
        GatewayResource.wslAccounts,
        provider: Provider.claude,
        entry: wsl,
      );
      final models = await client.gatewayCommand(
        provider: Provider.claude,
        entry: wsl,
        identity: accounts.identity,
        id: newId(),
        command: GatewayCommand.wslAccounts,
        parameters: jsonEncode({
          'action': 'models',
          'id': 'api-one',
          'refresh': true,
        }),
      );
      expect(models.outcome.kind, OutcomeKind.accepted, reason: models.data);
      final firstChunk = await client.downloadChunk(
        session: session,
        account: snapshot.accountIdentity,
        path: 'large.bin',
        archive: false,
        offset: 0,
        etag: '',
      );
      expect(firstChunk.data.length, 4194304);
      expect(firstChunk.etag, isNotEmpty);
      final last = await client.downloadChunk(
        session: session,
        account: snapshot.accountIdentity,
        path: 'large.bin',
        archive: false,
        offset: firstChunk.data.length,
        etag: firstChunk.etag,
      );
      expect(firstChunk.data.length + last.data.length, 5120000);
      final archive = await client.downloadChunk(
        session: session,
        account: snapshot.accountIdentity,
        path: 'folder',
        archive: true,
        offset: 0,
        etag: '',
      );
      expect(archive.data.take(2), [80, 75]);
      await File('${info['project']}/large.bin').writeAsBytes([1, 2, 3]);
      await expectLater(
        client.downloadChunk(
          session: session,
          account: snapshot.accountIdentity,
          path: 'large.bin',
          archive: false,
          offset: firstChunk.data.length,
          etag: firstChunk.etag,
        ),
        throwsA(anything),
      );
      expect(
        (await read(SessionResource.sideChats, {'view': 'native'}))['chats'],
        isEmpty,
      );
      expect(
        (await write(SessionCommand.sideChat, {
          'action': 'create',
          'creationId': newId(),
        })).outcome.kind,
        OutcomeKind.accepted,
      );
      final terminal = newId();
      expect(
        (await write(SessionCommand.terminal, {
          'action': 'open',
          'id': terminal,
          'cols': 80,
          'rows': 24,
        })).outcome.kind,
        OutcomeKind.accepted,
      );
      expect(
        (await write(SessionCommand.terminal, {
          'action': 'input',
          'id': terminal,
          'inputId': newId(),
          'data': '你好\u0003',
        })).outcome.kind,
        OutcomeKind.accepted,
      );
      expect(
        (await write(SessionCommand.terminal, {
          'action': 'resize',
          'id': terminal,
          'cols': 120,
          'rows': 40,
        })).outcome.kind,
        OutcomeKind.accepted,
      );
      final completion = await write(SessionCommand.terminal, {
        'action': 'complete',
        'id': terminal,
        'text': 'cat fo',
        'selectionStart': 6,
      });
      expect(
        jsonDecode(completion.data)['candidates'][0]['insertText'],
        'folder/',
      );
      expect(
        (await write(SessionCommand.terminal, {
          'action': 'close',
          'id': terminal,
        })).outcome.kind,
        OutcomeKind.accepted,
      );
      final gateway = await client.gatewayResource(
        provider: Provider.codex,
        entry: '',
        resource: GatewayResource.projects,
        parameters: '{}',
      );
      final registered = await client.gatewayCommand(
        provider: Provider.codex,
        entry: '',
        identity: gateway.identity,
        id: newId(),
        command: GatewayCommand.registerProject,
        parameters: jsonEncode({
          'path': info['project'],
          'host': 'local',
          'kind': 'cli',
          'createDirectory': false,
        }),
      );
      expect(
        registered.outcome.kind,
        OutcomeKind.accepted,
        reason: registered.data,
      );
      await File('${directory.path}/account-state.txt')
          .writeAsString('account-two');
      await expectLater(
        client.gatewayCommand(
          provider: Provider.codex,
          entry: '',
          identity: gateway.identity,
          id: newId(),
          command: GatewayCommand.registerProject,
          parameters: jsonEncode({
            'path': info['project'],
            'host': 'local',
            'kind': 'cli',
            'createDirectory': false,
          }),
        ),
        throwsA(anything),
      );
      expect(
        await File('${directory.path}/registered').readAsString(),
        '1',
        reason: 'Stale account writes must never reach the HTTP handler',
      );
      await File('${directory.path}/delay-projects').create();
      final lateRead = expectLater(
        client.gatewayResource(
          provider: Provider.codex,
          entry: '',
          resource: GatewayResource.projects,
          parameters: '{}',
        ),
        throwsA(anything),
      );
      for (
        var i = 0;
        !await File('${directory.path}/reading-projects').exists();
        i++
      ) {
        if (i > 200) {
          fail('The real HTTP handler did not start the delayed read');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await File('${directory.path}/account-state.txt')
          .writeAsString('account-three');
      await lateRead;
    },
    skip: library.isEmpty
        ? 'Requires built Rust library and sibling desktop checkout'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
