import 'dart:async';
import 'dart:typed_data';

import 'package:bridge_mobile/data/bridge_repository.dart';

const computerA = Computer(
  id: 'computer-a',
  name: 'Studio',
  baseUrl: 'https://studio.example',
);
const computerB = Computer(
  id: 'computer-b',
  name: 'Workshop',
  baseUrl: 'https://workshop.example',
);
const sessionA = SessionRef(
  computerId: 'computer-a',
  provider: Provider.codex,
  environment: 'local',
  id: '11111111-1111-4111-8111-111111111111',
);
const sessionB = SessionRef(
  computerId: 'computer-a',
  provider: Provider.claude,
  environment: 'ssh:lab',
  id: 'opaque-claude-session',
);
const authenticatedStatus = AuthStatus(
  authenticated: true,
  computerName: 'Studio',
  platform: 'Windows',
  passwordless: false,
  notifications: true,
  transport: 'poll',
);
const writable = CapabilitySet(
  send: true,
  steer: false,
  stop: false,
  approve: true,
  resume: false,
  models: true,
  attachments: true,
  arbitraryFiles: true,
);

ChatMessage message(String id, String text, {String role = 'assistant'}) =>
    ChatMessage(
      id: id,
      role: role,
      title: '',
      text: text,
      output: '',
      truncated: false,
      attachments: const [],
    );

SessionSnapshot snapshotFor(
  SessionRef session, {
  String account = 'account-a',
  String token = 'control-a',
  List<ChatMessage>? messages,
  CapabilitySet capabilities = writable,
  bool running = false,
  bool reset = false,
}) => SessionSnapshot(
  session: session,
  title: 'A quieter workspace',
  cwd: '/work/bridge',
  connected: true,
  running: running,
  status: running ? 'active' : 'idle',
  model: 'model-a',
  effort: 'high',
  capabilities: capabilities,
  approvals: const [],
  history: HistoryPage(
    messages:
        messages ??
        [
          message('user-a', 'Review the connection flow.', role: 'user'),
          message(
            'answer-a',
            'The client keeps your computer and execution environment together.\n\n```rust\nlet connection = gateway.connect().await?;\n```',
          ),
        ],
    before: 'older',
    hasMore: true,
    epoch: 'epoch-a',
    reset: reset,
  ),
  controlToken: token,
  accountIdentity: account,
  sequence: 1,
  notice: '',
);

class FakeRepository extends BridgeRepository {
  List<Computer> savedComputers = [computerA, computerB];
  UiPreferences savedPreferences = const UiPreferences(
    theme: 'system',
    locale: 'en',
    readInbox: [],
  );
  final Map<String, Draft> drafts = {};
  final Map<String, StreamController<GatewayEvent>> streams = {};
  final Map<String, SessionRef> watched = {};
  final Map<String, List<PendingOperation>> operations = {};
  List<PendingCreation> creations = [];
  Future<AuthStatus> Function(Computer)? onConnect;
  Future<SessionSnapshot> Function(SessionRef)? onSnapshot;
  Future<HistoryPage> Function(SessionRef, String)? onHistory;
  Future<Draft> Function(SessionRef, String)? onDraft;
  Future<void> Function(SessionRef, String, Draft)? onSaveDraft;
  Future<OperationOutcome> Function(SessionSnapshot, String)? onSend;
  Future<SessionPage> Function(Computer, Provider, String, int)? onSessions;
  int sends = 0, stops = 0, pauses = 0, cancels = 0, creates = 0, connects = 0;
  int _id = 0;
  String scope(SessionRef session, String account) =>
      '${session.computerId}/${session.provider.name}/${session.environment}/${session.id}/$account';

  @override
  Future<void> initialize() async {}
  @override
  String newId() => 'operation-${++_id}';
  @override
  Future<UiPreferences> preferences() async => savedPreferences;
  @override
  Future<void> savePreferences(UiPreferences value) async {
    savedPreferences = value;
  }

  @override
  Future<ConnectionInput> parseConnection(String value) async =>
      ConnectionInput(baseUrl: value, pairingToken: null);
  @override
  Future<List<Computer>> computers() async => savedComputers;
  @override
  Future<void> saveComputer(Computer computer) async {
    savedComputers = [
      ...savedComputers.where((value) => value.id != computer.id),
      computer,
    ];
  }

  @override
  Future<void> removeComputer(Computer computer) async {
    savedComputers = savedComputers
        .where((value) => value.id != computer.id)
        .toList();
  }

  @override
  Future<AuthStatus> connect(Computer computer) async {
    connects++;
    return onConnect == null ? authenticatedStatus : onConnect!(computer);
  }

  @override
  Future<AuthStatus> login(
    Computer computer,
    String username,
    String password,
  ) async => authenticatedStatus;
  @override
  Future<AuthStatus> pair(Computer computer, String token) async =>
      authenticatedStatus;
  @override
  Future<List<ClientInfo>> clients(Computer computer) async => [
    for (final value in Provider.values)
      ClientInfo(
        provider: value,
        enabled: true,
        connected: true,
        readable: true,
        reason: '',
      ),
  ];
  @override
  Future<SessionPage> sessions(
    Computer computer,
    Provider provider,
    String query,
    int offset,
  ) async {
    if (onSessions != null) {
      return onSessions!(computer, provider, query, offset);
    }
    final session = provider == Provider.claude ? sessionB : sessionA;
    return SessionPage(
      sessions: [
        SessionSummary(
          session: session,
          title: 'A quieter workspace',
          cwd: '/work/bridge',
          updatedAt: '2026-10-28',
          status: 'idle',
          backend: 'desktop',
        ),
      ],
      notice: '',
      nextOffset: null,
    );
  }

  @override
  Future<SessionSnapshot> snapshot(SessionRef session) async =>
      onSnapshot == null ? snapshotFor(session) : onSnapshot!(session);
  @override
  Future<HistoryPage> history(SessionRef session, String before) async =>
      onHistory == null
      ? HistoryPage(
          messages: [message('older-a', 'Earlier context')],
          before: null,
          hasMore: false,
          epoch: 'epoch-a',
          reset: false,
        )
      : onHistory!(session, before);
  @override
  Stream<GatewayEvent> watch(SessionRef session, String subscriptionId) {
    final controller = StreamController<GatewayEvent>.broadcast();
    streams[subscriptionId] = controller;
    watched[subscriptionId] = session;
    return controller.stream;
  }

  void emit(SessionSnapshot value) {
    for (final entry in streams.entries) {
      if (!entry.value.isClosed && watched[entry.key] == value.session) {
        entry.value.add(
          GatewayEvent(
            subscriptionId: entry.key,
            snapshot: value,
            authenticationRequired: false,
            message: '',
          ),
        );
      }
    }
  }

  @override
  Future<void> cancelWatch(String computerId, String subscriptionId) async {
    cancels++;
    await streams[subscriptionId]?.close();
  }

  @override
  Future<void> pause() async {
    pauses++;
    for (final controller in streams.values) {
      await controller.close();
    }
  }

  @override
  Future<Draft> draft(SessionRef session, String account) async =>
      onDraft == null
      ? drafts[scope(session, account)] ??
            const Draft(text: '', attachments: [], revision: 0)
      : onDraft!(session, account);
  @override
  Future<void> saveDraft(
    SessionRef session,
    String account,
    Draft draft,
  ) async {
    if (onSaveDraft != null) await onSaveDraft!(session, account, draft);
    final key = scope(session, account);
    if ((drafts[key]?.revision ?? -1) <= draft.revision) drafts[key] = draft;
  }

  @override
  Future<List<PendingOperation>> pending(
    SessionRef session,
    String account,
  ) async => operations[scope(session, account)] ?? [];
  @override
  Future<void> markReviewed(
    SessionRef session,
    String account,
    String id,
  ) async {
    operations[scope(session, account)]?.removeWhere((value) => value.id == id);
  }

  @override
  Future<List<PendingCreation>> pendingCreations(Computer computer) async =>
      creations;
  @override
  Future<void> reviewCreation(Computer computer, String id) async {
    creations.removeWhere((value) => value.operation.id == id);
  }

  @override
  Future<OperationOutcome> send(
    SessionSnapshot snapshot,
    String id,
    String text,
    List<String> attachments,
    bool steer,
  ) async {
    sends++;
    final result = onSend == null
        ? OperationOutcome(
            id: id,
            kind: OutcomeKind.accepted,
            message: '',
            createdSession: null,
          )
        : await onSend!(snapshot, id);
    if (result.kind == OutcomeKind.unknown) {
      operations[scope(snapshot.session, snapshot.accountIdentity)] = [
        PendingOperation(
          id: id,
          action: 'send',
          createdAt: 0,
          message: result.message,
        ),
      ];
    }
    return result;
  }

  OperationOutcome accepted(String id) => OperationOutcome(
    id: id,
    kind: OutcomeKind.accepted,
    message: '',
    createdSession: null,
  );
  @override
  Future<OperationOutcome> stop(SessionSnapshot snapshot, String id) async {
    stops++;
    return accepted(id);
  }

  @override
  Future<OperationOutcome> resume(SessionSnapshot snapshot, String id) async =>
      accepted(id);
  @override
  Future<OperationOutcome> respond(
    SessionSnapshot snapshot,
    String id,
    ApprovalRequest request,
    bool accept,
    List<QuestionAnswer> answers,
  ) async => accepted(id);
  @override
  Future<List<ModelOption>> models(SessionRef session) async => const [
    ModelOption(
      id: 'model-a',
      name: 'Model A',
      efforts: ['high'],
      defaultEffort: 'high',
    ),
  ];
  @override
  Future<OperationOutcome> settings(
    SessionSnapshot snapshot,
    String id,
    String model,
    String effort,
  ) async => accepted(id);
  @override
  Future<List<ProjectOption>> projects(
    Computer computer,
    Provider provider,
    String environment,
  ) async => [
    ProjectOption(
      key: 'project-a',
      name: 'Bridge',
      cwd: '/work/bridge',
      environment: 'local',
      requiresMessage: false,
      provider: provider,
    ),
  ];
  @override
  Future<OperationOutcome> create(
    Computer computer,
    ProjectOption project,
    String title,
    String text,
    String id,
  ) async {
    creates++;
    return accepted(id);
  }

  @override
  Future<Attachment> upload(
    SessionSnapshot snapshot,
    String name,
    Uint8List bytes,
  ) async =>
      Attachment(id: newId(), name: name, image: false, source: 'upload');
  @override
  Future<Uint8List> image(SessionRef session, Attachment attachment) async =>
      Uint8List(0);
  @override
  Future<List<InboxEntry>> inbox(Computer computer) async => [];
  @override
  Future<void> close() => pause();
}
