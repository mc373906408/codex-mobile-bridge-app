import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:bridge_mobile/data/bridge_repository.dart';
import 'package:bridge_mobile/data/cloud_accounts.dart';
import 'package:bridge_mobile/notifications/cloud_push_bridge.dart';
import 'package:bridge_mobile/notifications/cloud_push_controller.dart';
import 'package:bridge_mobile/src/rust/api/client.dart' as native;
import 'package:bridge_mobile/src/rust/frb_generated.dart';
import 'package:bridge_mobile/viewmodels/bridge_view_model.dart';
import 'package:bridge_mobile/viewmodels/cloud_view_model.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/fake_cloud.dart';

late String auditRoot;

class AuditPaths extends PathProviderPlatform {
  AuditPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class AuditPreviews implements CloudPreviewStorage {
  bool unavailable = false;
  @override
  Future<void> save(String computerId, String credentials) async {
    if (unavailable) {
      throw StateError('Synthetic native preview storage unavailable');
    }
  }

  @override
  Future<void> remove(String computerId) async {}
}

class AuditRepository extends NativeBridgeRepository {
  AuditRepository(this.manager, AuditPreviews previews)
    : super(previewStorage: previews);
  final CloudAccountManager manager;
  @override
  CloudAccountManager get cloudAccounts => manager;
  // The audit exercises native directory/endpoint operations, not chat or Noise I/O.
  @override
  Future<NotificationBatch> notificationEvents(Computer computer) async =>
      const NotificationBatch(scope: '', enabled: false, events: []);
}

class AuditPushBridge extends FakeCloudPushBridge {
  AuditPushBridge() {
    current = const CloudPushState(
      configured: true,
      allowed: true,
      consent: true,
      interactive: true,
      platform: 'umeng',
      appId: 'synthetic-app',
      token: 'synthetic-token',
    );
  }
  @override
  Future<CloudPushState> setConsent(bool enabled, String noticeVersion) async {
    current = CloudPushState(
      configured: true,
      allowed: true,
      consent: enabled,
      interactive: true,
      platform: 'umeng',
      appId: 'synthetic-app',
      token: 'synthetic-token',
      noticeVersion: noticeVersion,
    );
    return current;
  }
}

// Fixed, public synthetic X25519 keys; only origin changes with the loopback port.
String safetyCode(Map<String, dynamic> secret) {
  final c = secret['connection'] as Map<String, dynamic>;
  List<int> hex(String value) => [
    for (var i = 0; i < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16),
  ];
  final origin = utf8.encode(c['origin'] as String);
  final data = BytesBuilder()
    ..add(utf8.encode('bridge/pairing-safety/v1\u0000'))
    ..add([origin.length >> 8, origin.length & 255])
    ..add(origin)
    ..add(hex((c['gateway_id'] as String).replaceAll('-', '')))
    ..add(hex((c['binding_id'] as String).replaceAll('-', '')))
    ..add(
      hex('a84dc7c3c8f058b1b2dc4cd1e9b5dc0a7987f88b6a9564cde3391fc421159e77'),
    )
    ..add(base64Decode(c['desktop_public_key'] as String))
    ..add(base64Decode(secret['control_public'] as String))
    ..add(base64Decode(secret['desktop_preview_public'] as String))
    ..add(base64Decode(secret['preview_public'] as String));
  final code = sha256.convert(data.toBytes()).toString().toUpperCase();
  return [for (var i = 0; i < 64; i += 8) code.substring(i, i + 8)].join(' ');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const library = String.fromEnvironment('BRIDGE_NATIVE_LIB');
  if (library.isEmpty) {
    test(
      'native cloud state boundaries',
      () {},
      skip: 'Run python scripts/test_native.py with the real Rust library',
    );
    return;
  }
  late Map<String, dynamic> secret;
  late Map<String, dynamic> connection;
  late HttpServer server;
  late StreamSubscription<HttpRequest> handler;
  late AuditRepository repository;
  late AuditPreviews previews;
  late BridgeViewModel bridge;
  late CloudViewModel cloud;
  late FakeCloudApi api;
  late Computer computer;
  var status = CloudDeviceStatus.active;
  var revision = 1;
  var bindingReads = 0;
  var directIdentity = 'synthetic-account-a';
  var creationWrites = 0;
  Completer<void>? bindingStarted, bindingRelease;
  final endpointChanges = <bool>[];
  var fixtureNumber = 0;

  setUpAll(() async {
    if (library.isEmpty) {
      throw StateError('This audit requires the actual Rust library');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    final root = await Directory('.tmp/native-boundaries').absolute
        .create(recursive: true);
    auditRoot = (await root.createTemp('run-')).path;
    secret = jsonDecode(
      await File('test/fixtures/cloud_identity.json').readAsString(),
    );
    connection = Map<String, dynamic>.from(secret['connection']);
    secret['connection'] = connection;
  });
  tearDownAll(RustLib.dispose);

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection['origin'] = 'http://127.0.0.1:${server.port}';
    secret['pairing_code'] = safetyCode(secret);
    status = CloudDeviceStatus.active;
    revision = 1;
    bindingReads = 0;
    directIdentity = 'synthetic-account-a';
    creationWrites = 0;
    bindingStarted = null;
    bindingRelease = null;
    endpointChanges.clear();
    PathProviderPlatform.instance = AuditPaths(
      '$auditRoot/native-fixture-${fixtureNumber++}',
    );
    FlutterSecureStorage.setMockInitialValues({
      'bridge.credentials.v1.${connection['binding_id']}': jsonEncode(secret),
    });
    final vault = FakeCloudVault();
    api = FakeCloudApi();
    final account = CloudAccountRef(
      origin: connection['origin'],
      accountId: connection['account_id'],
      login: 'synthetic-user',
      enabled: true,
    );
    final manager = CloudAccountManager(vault: vault, api: api);
    vault.values['bridge.cloud.accounts.v1'] = jsonEncode([account.toJson()]);
    vault.values[manager.credentialKey(account)] = api.credentials(
      account.origin,
      account.accountId,
      account.login,
    );
    previews = AuditPreviews();
    repository = AuditRepository(manager, previews);
    await repository.initialize();
    computer = Computer(
      id: connection['binding_id'],
      name: 'Synthetic desktop',
      baseUrl: connection['origin'],
      connectionType: ConnectionType.relay,
      relay: RelayConnection(
        origin: connection['origin'],
        accountId: connection['account_id'],
        gatewayId: connection['gateway_id'],
        bindingId: connection['binding_id'],
        desktopPublicKey: connection['desktop_public_key'],
      ),
    );
    await repository.saveComputer(computer);
    api.onDevices = (_, _) async => [
      CloudDiscoveredDevice(
        gateway: CloudGateway(
          origin: connection['origin'],
          id: connection['gateway_id'],
          name: computer.name,
          controlPublicKey: connection['desktop_public_key'],
          online: true,
        ),
        bindingId: computer.id,
        status: status,
        accessRevision: revision,
      ),
    ];
    handler = server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      Object response;
      if (request.method == 'GET' &&
          request.uri.path == '/v1/bindings/${computer.id}') {
        bindingReads++;
        if (bindingStarted?.isCompleted == false) bindingStarted!.complete();
        await bindingRelease?.future;
        response = {
          'id': computer.id, 'gateway_id': connection['gateway_id'],
          'installation_id': secret['installation_id'],
          'gateway_public_key': connection['desktop_public_key'],
          'mobile_public_key': secret['control_public'], 'status': status.name,
          // Existing verified keys are loaded; this fixture does not simulate a Noise desktop.
          'gateway_online': false, 'device_revoked': false,
        };
      } else if (request.method == 'POST' &&
          request.uri.path == '/v1/push/endpoints') {
        endpointChanges.add((jsonDecode(body) as Map)['enabled'] == true);
        response = {'registered': true};
      } else if (request.method == 'GET' && request.uri.path == '/api/auth') {
        response = {
          'authenticated': true,
          'csrf': 'synthetic-csrf',
          'draftIdentity': directIdentity,
          'transport': 'poll',
        };
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/projects') {
        response = {
          'projects': [
            {'key': 'synthetic-project-a', 'host': 'local'},
          ],
        };
      } else if (request.method == 'POST' &&
          request.uri.path == '/api/sessions') {
        creationWrites++;
        response = {'status': 'unknown'};
      } else {
        request.response.statusCode = 404;
        response = {'code': 'unexpected_audit_route'};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    bridge = BridgeViewModel(repository);
    await bridge.initialize();
    cloud = CloudViewModel(accounts: manager, bridge: bridge);
  });

  tearDown(() async {
    cloud.dispose();
    bridge.dispose();
    await repository.close();
    await handler.cancel();
    await server.close(force: true);
  });

  test(
    ' native repository restores a verified connection after desktop disable',
    () async {
      await cloud.initialize();
      expect(cloud.canConnect(computer), true);
      status = CloudDeviceStatus.disabled;
      revision++;
      await cloud.syncDevices();
      expect(cloud.canConnect(computer), false);
      final before = bindingReads;
      status = CloudDeviceStatus.active;
      revision++;
      await cloud.syncDevices();
      await cloud.syncDevices();
      expect(
        cloud.canConnect(computer),
        true,
        reason: 'Reopening must recheck the fixed identity',
      );
      expect(bindingReads, greaterThan(before));
    },
  );

  test(
    'a late verification response cannot reopen a suspended repository',
    () async {
      await cloud.initialize();
      await repository.suspendRelay(computer);
      bindingStarted = Completer<void>();
      bindingRelease = Completer<void>();
      final checking = repository.relayPairingState(computer);
      final rejected = expectLater(checking, throwsA(anything));
      await bindingStarted!.future;
      await repository.suspendRelay(computer);
      bindingRelease!.complete();
      await rejected;
      expect(await repository.cloudEnabled(computer), false);
      await expectLater(repository.connect(computer), throwsStateError);
    },
  );

  test('wrong cloud credentials cannot use the withdrawal-only path', () async {
    await cloud.initialize();
    final changed = jsonDecode(jsonEncode(secret)) as Map<String, dynamic>;
    changed['connection']['account_id'] =
        '99999999-9999-4999-8999-999999999999';
    FlutterSecureStorage.setMockInitialValues({
      'bridge.credentials.v1.${computer.id}': jsonEncode(changed),
    });
    await repository.suspendRelay(computer);
    await expectLater(
      repository.registerCloudPush(computer, const CloudPushState()),
      throwsA(anything),
    );
    expect(endpointChanges, isEmpty);
  });

  test(
    ' optional preview storage failure does not disable verified cloud chat',
    () async {
      previews.unavailable = true;
      await cloud.initialize();
      expect(bindingReads, 1);
      expect(repository.storageWarning, contains('notification storage'));
      expect(await repository.cloudEnabled(computer), false);
      expect(
        cloud.canConnect(computer),
        true,
        reason: 'Preview failures must not disable the control identity',
      );
      previews.unavailable = false;
      await cloud.syncDevices();
      expect(repository.storageWarning, isNull);
      expect(await repository.cloudEnabled(computer), true);
    },
  );

  test(' consent withdrawal reaches an endpoint after connection permission is closed', () async {
    await cloud.initialize();
    final push = CloudPushController(
      repository,
      AuditPushBridge(),
      interval: null,
    );
    addTearDown(push.dispose);
    push.configure(bridge.computers.where(cloud.matches).toList());
    await push.initialize();
    expect(endpointChanges, [true]);
    status = CloudDeviceStatus.disabled;
    revision++;
    await cloud.syncDevices();
    // Account-scoped withdrawal work includes disabled bindings.
    push.configure(bridge.computers.where(cloud.matches).toList());
    await Future<void>.delayed(Duration.zero);
    await push.setConsent(false, 'cloud-notifications-v1');
    await push.resume();
    expect(push.state.consent, false);
    expect(
      endpointChanges,
      contains(false),
      reason: 'The endpoint was enabled, but disabling the connection removes it from withdrawal work',
    );
  });

  test(
    ' unresolved new-chat records remain scoped to the authenticated account',
    () async {
      final pc = Computer(
        id: 'synthetic-direct',
        name: 'Synthetic direct',
        baseUrl: connection['origin'],
      );
      final dbPath =
          '$auditRoot/native-fixture-${fixtureNumber - 1}/bridge.sqlite';
      final database = await native.LocalDatabase.open(path: dbPath);
      final client = await native.BridgeClient.open(
        computer: pc,
        databasePath: dbPath,
        platform: 'Android',
        credentials: null,
      );
      addTearDown(() async {
        await client.pause();
        client.dispose();
        database.dispose();
      });
      final result = await client.create(
        project: const ProjectOption(
          key: 'synthetic-project-a',
          name: 'Synthetic project',
          cwd: '/synthetic',
          environment: 'local',
          requiresMessage: false,
          provider: Provider.codex,
        ),
        title: 'Synthetic chat',
        text: '',
        id: native.newId(),
      );
      expect(result.kind, OutcomeKind.unknown);
      directIdentity = 'synthetic-account-b';
      expect((await client.authenticate()).authenticated, true);
      final visible = await client.pendingCreations();
      expect(visible, isEmpty);
      await expectLater(
        client.reviewCreation(
          id: result.id,
          account: 'synthetic-account-a',
          confirmed: true,
        ),
        throwsA(anything),
      );
      directIdentity = 'synthetic-account-a';
      final restored = await client.pendingCreations();
      expect(restored.single.operation.id, result.id);
      expect(restored.single.accountIdentity, directIdentity);
      await client.reviewCreation(
        id: result.id,
        account: restored.single.accountIdentity,
        confirmed: true,
      );
      expect(await client.pendingCreations(), isEmpty);
      expect(creationWrites, 1);
    },
  );
}
