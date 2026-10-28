import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../src/rust/api/client.dart' as native;
import '../src/rust/api/types.dart';

export '../src/rust/api/types.dart';

abstract class BridgeRepository {
  Future<void> initialize();
  String? get storageWarning => null;
  Future<UiPreferences> preferences();
  Future<void> savePreferences(UiPreferences value);
  String newId();
  Future<ConnectionInput> parseConnection(String value);
  Future<List<Computer>> computers();
  Future<void> saveComputer(Computer computer);
  Future<void> removeComputer(Computer computer);
  Future<AuthStatus> connect(Computer computer);
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
  Future<HistoryPage> history(SessionRef session, String before);
  Stream<GatewayEvent> watch(SessionRef session, String subscriptionId);
  Future<void> cancelWatch(String computerId, String subscriptionId);
  Future<void> pause();
  Future<Draft> draft(SessionRef session, String account);
  Future<void> saveDraft(SessionRef session, String account, Draft draft);
  Future<List<PendingOperation>> pending(SessionRef session, String account);
  Future<void> markReviewed(SessionRef session, String account, String id);
  Future<List<PendingCreation>> pendingCreations(Computer computer);
  Future<void> reviewCreation(Computer computer, String id);
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
  Future<void> close();
}

class NativeBridgeRepository implements BridgeRepository {
  NativeBridgeRepository({FlutterSecureStorage? secureStorage})
    : _secure =
          secureStorage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  final FlutterSecureStorage _secure;
  final Map<String, native.BridgeClient> _clients = {};
  final Map<String, Future<native.BridgeClient>> _opening = {};
  final Map<String, Future<void>> _credentialWrites = {};
  final Set<String> _removing = {};
  final Map<String, String?> _saved = {};
  String? _storageWarning;
  bool _closed = false;
  @override
  String? get storageWarning => _storageWarning;
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
  @override
  Future<void> saveComputer(Computer computer) =>
      _database.saveComputer(computer: computer);

  String _credentialKey(String id) => 'bridge.credentials.v1.$id';

  Future<native.BridgeClient> _open(Computer computer) async {
    if (_closed || _removing.contains(computer.id)) {
      throw StateError('Connection is closed');
    }
    if (_clients[computer.id] case final client?) return client;
    if (_opening[computer.id] case final opening?) return opening;
    final opening = _openOnce(computer);
    _opening[computer.id] = opening;
    try {
      return await opening;
    } finally {
      _opening.remove(computer.id);
    }
  }

  Future<native.BridgeClient> _openOnce(Computer computer) async {
    final credentials = await _secure.read(key: _credentialKey(computer.id));
    final client = await native.BridgeClient.open(
      computer: computer,
      databasePath: _databasePath,
      platform: Platform.isIOS ? 'iOS' : 'Android',
      credentials: credentials,
    );
    if (_closed || _removing.contains(computer.id)) {
      await client.pause();
      throw StateError('Connection is closed');
    }
    _clients[computer.id] = client;
    _saved[computer.id] = credentials;
    return client;
  }

  native.BridgeClient _client(String id) =>
      _clients[id] ??
      (throw StateError('Select and authenticate a computer first'));

  Future<void> _saveCredentials(String id) {
    final previous = _credentialWrites[id] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      final client = _clients[id];
      if (client == null || _removing.contains(id)) return;
      // Read inside the queue, never persist a credential snapshot captured before a logout.
      final value = await client.credentials();
      if (_saved[id] == value) return;
      if (value == null) {
        await _secure.delete(key: _credentialKey(id));
      } else {
        await _secure.write(key: _credentialKey(id), value: value);
      }
      _saved[id] = value;
      _storageWarning = null;
    });
    _credentialWrites[id] = next;
    return next;
  }

  Future<T> _call<T>(
    String id,
    Future<T> Function(native.BridgeClient) work,
  ) async {
    if (_closed || _removing.contains(id)) {
      throw StateError('Connection is closed');
    }
    T result;
    try {
      result = await work(_client(id));
    } catch (_) {
      try {
        await _saveCredentials(id);
      } catch (_) {
        _storageWarning = 'Secure credential storage is unavailable';
      }
      rethrow;
    }
    try {
      await _saveCredentials(id);
    } catch (_) {
      _storageWarning = 'Secure credential storage is unavailable; sign in again after restarting';
      // Do not turn an acknowledged submission into a retryable storage error.
      if (result is! OperationOutcome) rethrow;
    }
    return result;
  }

  @override
  Future<AuthStatus> connect(Computer computer) async {
    await _open(computer);
    return _call(computer.id, (client) => client.authenticate());
  }

  @override
  Future<AuthStatus> login(
    Computer computer,
    String username,
    String password,
  ) => _call(
    computer.id,
    (client) => client.login(username: username, password: password),
  );
  @override
  Future<AuthStatus> pair(Computer computer, String token) =>
      _call(computer.id, (client) => client.pair(token: token));
  @override
  Future<List<ClientInfo>> clients(Computer computer) =>
      _call(computer.id, (client) => client.clients());
  @override
  Future<SessionPage> sessions(
    Computer computer,
    Provider provider,
    String query,
    int offset,
  ) => _call(
    computer.id,
    (client) =>
        client.sessions(provider: provider, query: query, offset: offset),
  );
  @override
  Future<SessionSnapshot> snapshot(SessionRef session) =>
      _call(session.computerId, (client) => client.snapshot(session: session));
  @override
  Future<HistoryPage> history(SessionRef session, String before) => _call(
    session.computerId,
    (client) => client.history(session: session, before: before),
  );
  @override
  Stream<GatewayEvent> watch(SessionRef session, String subscriptionId) =>
      _client(session.computerId)
          .watchSession(session: session, subscriptionId: subscriptionId)
          .asyncMap((event) async {
            await _saveCredentials(session.computerId);
            return event;
          });
  @override
  Future<void> cancelWatch(String computerId, String subscriptionId) async {
    await _clients[computerId]?.cancelWatch(subscriptionId: subscriptionId);
  }

  @override
  Future<void> pause() async {
    await Future.wait(_clients.values.map((client) => client.pause()));
  }

  @override
  Future<void> removeComputer(Computer computer) async {
    final id = computer.id;
    _removing.add(id);
    try {
      try {
        await _opening[id];
      } catch (_) {
        /* A cancelled opening must not recreate credentials. */
      }
      final client = _clients[id];
      if (client != null) {
        await client.pause();
        try {
          await client.logout();
        } catch (_) {
          /* Local removal still succeeds offline. */
        }
      }
      try {
        await _credentialWrites[id];
      } catch (_) {
        /* Deletion is still attempted. */
      }
      await _secure.delete(key: _credentialKey(id));
      await _database.removeComputer(id: id);
      _clients.remove(id);
      _saved.remove(id);
      _credentialWrites.remove(id);
    } finally {
      _removing.remove(id);
    }
  }

  @override
  Future<Draft> draft(SessionRef session, String account) =>
      _database.draft(session: session, account: account);
  @override
  Future<void> saveDraft(SessionRef session, String account, Draft draft) =>
      _database.saveDraft(session: session, account: account, draft: draft);
  @override
  Future<List<PendingOperation>> pending(SessionRef session, String account) =>
      _database.pending(session: session, account: account);
  @override
  Future<void> markReviewed(SessionRef session, String account, String id) =>
      _database.markReviewed(
        session: session,
        account: account,
        id: id,
        confirmed: true,
      );
  @override
  Future<List<PendingCreation>> pendingCreations(Computer computer) =>
      _database.pendingCreations(computer: computer.id);
  @override
  Future<void> reviewCreation(Computer computer, String id) =>
      _database.reviewCreation(computer: computer.id, id: id, confirmed: true);
  @override
  Future<OperationOutcome> send(
    SessionSnapshot snapshot,
    String id,
    String text,
    List<String> attachments,
    bool steer,
  ) => _call(
    snapshot.session.computerId,
    (client) => client.send(
      session: snapshot.session,
      token: snapshot.controlToken,
      id: id,
      text: text,
      attachments: attachments,
      steer: steer,
    ),
  );
  @override
  Future<OperationOutcome> stop(SessionSnapshot snapshot, String id) => _call(
    snapshot.session.computerId,
    (client) => client.stop(
      session: snapshot.session,
      token: snapshot.controlToken,
      id: id,
    ),
  );
  @override
  Future<OperationOutcome> resume(SessionSnapshot snapshot, String id) => _call(
    snapshot.session.computerId,
    (client) => client.resume(
      session: snapshot.session,
      token: snapshot.controlToken,
      id: id,
    ),
  );
  @override
  Future<OperationOutcome> respond(
    SessionSnapshot snapshot,
    String id,
    ApprovalRequest request,
    bool accept,
    List<QuestionAnswer> answers,
  ) => _call(
    snapshot.session.computerId,
    (client) => client.respond(
      session: snapshot.session,
      token: snapshot.controlToken,
      id: id,
      requestId: request.id,
      accept: accept,
      answers: answers,
    ),
  );
  @override
  Future<List<ModelOption>> models(SessionRef session) =>
      _call(session.computerId, (client) => client.models(session: session));
  @override
  Future<OperationOutcome> settings(
    SessionSnapshot snapshot,
    String id,
    String model,
    String effort,
  ) => _call(
    snapshot.session.computerId,
    (client) => client.settings(
      session: snapshot.session,
      token: snapshot.controlToken,
      id: id,
      model: model,
      effort: effort,
    ),
  );
  @override
  Future<List<ProjectOption>> projects(
    Computer computer,
    Provider provider,
    String environment,
  ) => _call(
    computer.id,
    (client) => client.projects(provider: provider, environment: environment),
  );
  @override
  Future<OperationOutcome> create(
    Computer computer,
    ProjectOption project,
    String title,
    String text,
    String id,
  ) => _call(
    computer.id,
    (client) =>
        client.create(project: project, title: title, text: text, id: id),
  );
  @override
  Future<Attachment> upload(
    SessionSnapshot snapshot,
    String name,
    Uint8List bytes,
  ) => _call(
    snapshot.session.computerId,
    (client) => client.upload(
      session: snapshot.session,
      token: snapshot.controlToken,
      id: newId(),
      name: name,
      bytes: bytes,
    ),
  );
  @override
  Future<Uint8List> image(SessionRef session, Attachment attachment) => _call(
    session.computerId,
    (client) => client.image(session: session, attachment: attachment),
  );
  @override
  Future<List<InboxEntry>> inbox(Computer computer) =>
      _call(computer.id, (client) => client.inbox());
  @override
  Future<void> close() async {
    _closed = true;
    await pause();
  }
}
