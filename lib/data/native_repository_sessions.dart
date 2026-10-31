part of 'bridge_repository.dart';

mixin _NativeSessions on _NativeBridgeState {
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
  Future<NotificationBatch> notificationEvents(Computer computer) async {
    await _open(computer);
    return _call(computer.id, (client) => client.notificationEvents());
  }
}
