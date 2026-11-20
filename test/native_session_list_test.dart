import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bridge_mobile/data/bridge_types.dart';
import 'package:bridge_mobile/notifications/notification_controller.dart';

import 'package:bridge_mobile/src/rust/api/client.dart';
import 'package:bridge_mobile/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_notifications.dart';
import 'support/fake_repository.dart';

const _sid = '11111111-1111-4111-8111-111111111111';
const _reason = '正在后台读取 SSH 主机；本机会话可正常使用。';

class _NativeFeeds extends FakeRepository {
  final gatewayClients = <String, BridgeClient>{};

  @override
  Future<NotificationFeed> notificationFeed(Computer computer) =>
      gatewayClients[computer.id]!.notificationFeed();

  @override
  Future<NotificationBatch> notificationEvents(Computer computer) =>
      gatewayClients[computer.id]!.notificationEvents();
}

void main() {
  const library = String.fromEnvironment('BRIDGE_NATIVE_LIB');
  test(
    'two authenticated HTTP gateways publish independently and share no read markers',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library));
      final directory = await Directory.systemTemp.createTemp(
        'bridge-inbox-ffi-',
      );
      final repo = _NativeFeeds();
      final system = FakeNotificationBridge();
      final alerts = NotificationController(repo, system, pollInterval: null);
      final servers = <HttpServer>[];
      final computers = <Computer>[];
      final eventReads = [0, 0];
      final ids = ['history'];
      Completer<void>? slowA;
      addTearDown(() async {
        alerts.dispose();
        for (final client in repo.gatewayClients.values) {
          await client.pause();
          client.dispose();
        }
        for (final server in servers) {
          await server.close(force: true);
        }
        RustLib.dispose();
        await directory.delete(recursive: true);
      });
      for (var i = 0; i < 2; i++) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        servers.add(server);
        final computer = Computer(
          id: 'computer-$i',
          name: 'Host $i',
          baseUrl: 'http://127.0.0.1:${server.port}',
        );
        computers.add(computer);
        server.listen((request) async {
          final Object result;
          if (request.uri.path == '/api/auth') {
            result = {
              'authenticated': true,
              'csrf': 'test',
              'draftIdentity': 'account-$i',
              'notifications': true,
              'transport': 'poll',
            };
          } else {
            expect(request.uri.path, '/api/mobile/events');
            expect(request.method, 'GET');
            eventReads[i]++;
            if (i == 0 && slowA != null) {
              await slowA.future;
            }
            result = {
              'streamId': 'stream',
              'events': [
                for (final (index, id) in ids.indexed)
                  {
                    'id': id,
                    'kind': 'completion',
                    'createdAt': 100 + index,
                    'threadId': _sid,
                    'host': 'local',
                    'title': '${computer.name} $id',
                    'body': 'Private fixture content',
                  },
              ],
            };
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(result));
          await request.response.close();
        });
        repo.gatewayClients[computer.id] = await BridgeClient.open(
          computer: computer,
          databasePath: '${directory.path}/state.sqlite',
          platform: 'iOS',
          credentials: null,
        );
      }
      await alerts.updateConfiguration(computers, 'en');
      await alerts.initialize();
      await alerts.pollNow();
      expect(eventReads, [1, 1]);
      expect(alerts.inbox.map((item) => item.id).toSet(), hasLength(2));
      expect(system.shown, isEmpty);
      await alerts.updateConfiguration(
        computers,
        'en',
        mutedComputerIds: {computers.last.id},
      );
      ids.add('new');
      final fast = Completer<void>();
      void observe() {
        if (!fast.isCompleted &&
            alerts.inbox.any((e) => e.title == 'Host 1 new')) {
          fast.complete();
        }
      }

      alerts.addListener(observe);
      slowA = Completer<void>();
      final round = alerts.pollNow();
      try {
        await fast.future.timeout(const Duration(seconds: 5));
        expect(alerts.inbox.any((e) => e.title == 'Host 0 new'), false);
      } finally {
        slowA.complete();
        await round;
        alerts.removeListener(observe);
      }
      expect(eventReads, [2, 2]);
      expect(alerts.inbox, hasLength(4));
      expect(system.shown, [
        alerts.inbox.singleWhere((item) => item.title == 'Host 0 new').eventId,
      ]);
    },
    skip: library.isEmpty
        ? 'Run scripts/test_native.py to supply the real FFI library'
        : false,
  );
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
      expect(page.sessions.single.pinned, isTrue);
      final grouped = await client.sessionsForEntry(
        provider: Provider.codex,
        entry: '',
        query: 'Group',
        offset: 0,
        source: 'all',
        archived: false,
        groupByProject: true,
      );
      expect(grouped.sessions.single.session, page.sessions.single.session);
      expect(page.sessions.single.environmentLabel, 'This computer');
      expect(page.environmentIssues.single.environment, 'ssh:lab');
      expect(page.environmentIssues.single.label, 'Lab');
      expect(page.environmentIssues.single.reason, _reason);
      expect(page.environmentIssues.single.loading, isTrue);
      expect(page.notice, isEmpty);
      final activity = await client.gatewayResource(
        provider: Provider.codex,
        entry: '',
        resource: GatewayResource.sessionActivity,
        parameters: jsonEncode({
          'hosts': {
            'local': [_sid],
          },
        }),
      );
      final active = jsonDecode(activity.data)['sessions'] as List;
      expect(active.single['status'], 'active');
      expect(active.single['turnId'], 'turn-one');
      expect(active.single['turnStatus'], 'inProgress');
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
    expect(
      request.uri.queryParameters['order'],
      request.uri.queryParameters['q'] == 'Group' ? 'project' : 'recent',
    );
    body = {
      'sessions': [
        {
          'id': _sid,
          'host': 'local',
          'hostLabel': 'This computer',
          'title': 'Chat',
          'pinned': false,
          'bridgePinned': true,
        },
      ],
      'unavailableHosts': [
        {'host': 'ssh:lab', 'label': 'Lab', 'error': _reason},
      ],
    };
  } else if (request.uri.path == '/api/activity') {
    expect(request.method, 'POST');
    expect(request.headers.value('X-CSRF-Token'), 'synthetic');
    expect(jsonDecode(await utf8.decoder.bind(request).join()), {
      'hosts': {
        'local': [_sid],
      },
    });
    body = {
      'sessions': [
        {
          'id': _sid,
          'host': 'local',
          'connected': true,
          'status': 'active',
          'turnId': 'turn-one',
          'turnStatus': 'inProgress',
        },
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
