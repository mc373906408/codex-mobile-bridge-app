import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../src/rust/api/client.dart' as native;
import '../src/rust/api/cloud.dart' as cloud_native;
import 'bridge_types.dart';
import '../notifications/cloud_push_bridge.dart';
import 'cloud_accounts.dart';
import 'computer_names.dart';
import 'business_repository.dart';

export 'bridge_types.dart';

part 'native_repository_connections.dart';
part 'native_repository_sessions.dart';
part 'native_repository_cloud.dart';
part 'native_repository_business.dart';

abstract class BridgeRepository extends BusinessRepository {
  Future<void> initialize();
  String? get storageWarning => null;
  Future<UiPreferences> preferences();
  Future<void> savePreferences(UiPreferences value);
  Future<Map<String, String>> computerNames();
  Future<void> saveComputerNames(Map<String, String> names);
  String newId();
  Future<ConnectionInput> parseConnection(String value);
  Future<List<Computer>> computers();
  Future<void> saveComputer(Computer computer);
  Future<void> removeComputer(Computer computer);
  Future<AuthStatus> connect(Computer computer);
  Stream<String> connectionStates(Computer computer) => const Stream.empty();
  Future<RelayTransportStatus?> relayTransportStatus(Computer computer) async =>
      null;
  Future<AuthStatus> login(Computer computer, String username, String password);
  Future<AuthStatus> pair(Computer computer, String token);
  Future<List<ClientInfo>> clients(Computer computer);
  Future<SessionPage> sessions(
    Computer computer,
    Provider provider,
    String query,
    int offset,
  );
  Future<SessionSnapshot> snapshot(SessionRef session);
  Future<SessionPage> sessionsForEntry(
    Computer computer,
    Provider provider,
    String entry,
    String query,
    int offset,
    String source,
    bool archived,
  ) {
    if (entry.isNotEmpty || source != 'all' || archived) {
      throw UnsupportedError('Client instance or filter unavailable');
    }
    return sessions(computer, provider, query, offset);
  }

  Future<List<ProjectOption>> projectsForEntry(
    Computer computer,
    Provider provider,
    String entry,
    String environment,
  ) {
    if (entry.isNotEmpty) throw UnsupportedError('Client instance unavailable');
    return projects(computer, provider, environment);
  }

  Future<HistoryPage> history(SessionRef session, String before);
  Stream<GatewayEvent> watch(SessionRef session, String subscriptionId);
  Future<void> cancelWatch(String computerId, String subscriptionId);
  Future<void> pause();
  Future<Draft> draft(SessionRef session, String account);
  Future<void> saveDraft(SessionRef session, String account, Draft draft);
  Future<List<PendingOperation>> pending(SessionRef session, String account);
  Future<void> markReviewed(SessionRef session, String account, String id);
  Future<List<PendingCreation>> pendingCreations(Computer computer);
  Future<void> reviewCreation(Computer computer, String id, String account);
  Future<OperationOutcome> send(
    SessionSnapshot snapshot,
    String id,
    String text,
    List<String> attachments,
    bool steer,
  );
  Future<OperationOutcome> stop(SessionSnapshot snapshot, String id);
  Future<OperationOutcome> resume(SessionSnapshot snapshot, String id);
  Future<OperationOutcome> respond(
    SessionSnapshot snapshot,
    String id,
    ApprovalRequest request,
    bool accept,
    List<QuestionAnswer> answers,
  );
  Future<List<ModelOption>> models(SessionRef session);
  Future<OperationOutcome> settings(
    SessionSnapshot snapshot,
    String id,
    String model,
    String effort,
  );
  Future<List<ProjectOption>> projects(
    Computer computer,
    Provider provider,
    String environment,
  );
  Future<OperationOutcome> create(
    Computer computer,
    ProjectOption project,
    String title,
    String text,
    String id,
  );
  Future<Attachment> upload(
    SessionSnapshot snapshot,
    String name,
    Uint8List bytes,
  );
  Future<Uint8List> image(SessionRef session, Attachment attachment);
  Future<List<InboxEntry>> inbox(Computer computer);
  Future<NotificationBatch> notificationEvents(Computer computer);
  Future<void> close();
}

abstract class _NativeBridgeState
    implements BridgeRepository, CloudRepository, CloudPushRepository {
  _NativeBridgeState({
    FlutterSecureStorage? secureStorage,
    CloudPreviewStorage? previewStorage,
  }) : _secure =
           secureStorage ??
           const FlutterSecureStorage(
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.first_unlock_this_device,
             ),
           ),
       _previewStorage = previewStorage ?? NativeCloudPreviewStorage();

  final FlutterSecureStorage _secure;
  final CloudPreviewStorage _previewStorage;
  final Set<String> _blocked = {};
  final Set<String> _cloudAllowed = {};
  final Map<String, int> _clientGenerations = {};
  @override
  late final CloudAccountManager cloudAccounts = CloudAccountManager(
    vault: SecureCloudVault(_secure),
    api: NativeCloudApi(),
    onDisabled: _disableCloudAccount,
    onCredentialsChanged: _rotateCloudBindings,
  );
  final Map<String, native.BridgeClient> _clients = {};
  final Map<String, Future<native.BridgeClient>> _opening = {};
  final Map<String, Future<void>> _credentialWrites = {};
  final Set<String> _removing = {};
  final Map<String, String?> _saved = {};
  String? _storageWarning;
  final Set<String> _previewFailures = {};
  bool _closed = false;
  @override
  String? get storageWarning =>
      _storageWarning ??
      (_previewFailures.isEmpty
          ? null
          : 'Cloud notification storage is unavailable; chat remains available');
  late native.LocalDatabase _database;
  late String _databasePath;

  @override
  Future<void> initialize() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    _databasePath = '${directory.path}${Platform.pathSeparator}bridge.sqlite';
    _database = await native.LocalDatabase.open(path: _databasePath);
  }

  @override
  String newId() => native.newId();
  @override
  Future<ConnectionInput> parseConnection(String value) =>
      native.parseConnection(value: value);
  @override
  Future<List<Computer>> computers() => _database.computers();
  @override
  Future<UiPreferences> preferences() => _database.preferences();
  @override
  Future<void> savePreferences(UiPreferences value) =>
      _database.savePreferences(value: value);
  static const _computerNamesKey = 'bridge.computer_names.v1';
  @override
  Future<Map<String, String>> computerNames() async =>
      decodeComputerNames(await _secure.read(key: _computerNamesKey));
  @override
  Future<void> saveComputerNames(Map<String, String> names) =>
      _secure.write(key: _computerNamesKey, value: jsonEncode(names));
  @override
  Future<void> saveComputer(Computer computer) =>
      _database.saveComputer(computer: computer);

  String _credentialKey(String id) => 'bridge.credentials.v1.$id';

  native.BridgeClient _client(String id) =>
      _clients[id] ??
      (throw StateError('Select and authenticate a computer first'));

  Future<native.BridgeClient> _open(
    Computer computer, {
    bool verificationOnly = false,
  });
  Future<void> _saveCredentials(String id, {bool verificationOnly = false});
  Future<void> _savePreview(Computer computer, native.BridgeClient client);
  Future<T> _call<T>(String id, Future<T> Function(native.BridgeClient) work);
  Future<void> _disableCloudAccount(CloudAccountRef account);
  Future<void> _rotateCloudBindings(
    CloudAccountRef account,
    String credentials,
  );

  @override
  Future<void> close() async {
    _closed = true;
    await pause();
  }
}

class NativeBridgeRepository extends _NativeBridgeState
    with _NativeConnections, _NativeSessions, _NativeCloud, _NativeBusiness {
  NativeBridgeRepository({super.secureStorage, super.previewStorage});
}
