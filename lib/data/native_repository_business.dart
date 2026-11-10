part of 'bridge_repository.dart';

mixin _NativeBusiness on _NativeBridgeState {
  @override
  Future<OperationOutcome> createWithOptions(
    Computer computer,
    ProjectOption project,
    String title,
    String text,
    String id,
    Map<String, Object?> options,
  ) => _call(
    computer.id,
    (client) => client.createWithOptions(
      project: project,
      title: title,
      text: text,
      id: id,
      options: jsonEncode(options),
    ),
  );
  @override
  Future<BusinessReply> uploadWorkspace(
    SessionSnapshot snapshot,
    String id,
    String path,
    Uint8List bytes,
  ) => _call(
    snapshot.session.computerId,
    (client) => client.uploadWorkspace(
      session: snapshot.session,
      account: snapshot.accountIdentity,
      id: id,
      path: path,
      bytes: bytes,
    ),
  );
  @override
  Future<SessionPage> sessionsForEntry(
    Computer computer,
    Provider provider,
    String entry,
    String query,
    int offset,
    String source,
    bool archived,
  ) => _call(
    computer.id,
    (client) => client.sessionsForEntry(
      provider: provider,
      entry: entry,
      query: query,
      offset: offset,
      source: source,
      archived: archived,
    ),
  );
  @override
  Future<List<ProjectOption>> projectsForEntry(
    Computer computer,
    Provider provider,
    String entry,
    String environment,
  ) => _call(
    computer.id,
    (client) => client.projectsForEntry(
      provider: provider,
      entry: entry,
      environment: environment,
    ),
  );
  @override
  Future<String> sessionResource(
    SessionRef session,
    SessionResource resource,
    Map<String, Object?> parameters,
  ) => _call(
    session.computerId,
    (client) => client.sessionResource(
      session: session,
      resource: resource,
      parameters: jsonEncode(parameters),
    ),
  );
  @override
  Future<BusinessReply> sessionCommand(
    SessionSnapshot snapshot,
    String id,
    SessionCommand command,
    Map<String, Object?> parameters,
  ) => _call(
    snapshot.session.computerId,
    (client) => client.sessionCommand(
      session: snapshot.session,
      account: snapshot.accountIdentity,
      token: snapshot.controlToken,
      id: id,
      command: command,
      parameters: jsonEncode(parameters),
    ),
  );
  @override
  Future<GatewayState> gatewayResource(
    Computer computer,
    Provider provider,
    String entry,
    GatewayResource resource,
    Map<String, Object?> parameters,
  ) => _call(
    computer.id,
    (client) => client.gatewayResource(
      provider: provider,
      entry: entry,
      resource: resource,
      parameters: jsonEncode(parameters),
    ),
  );
  @override
  Future<BusinessReply> gatewayCommand(
    Computer computer,
    Provider provider,
    String entry,
    String identity,
    String id,
    GatewayCommand command,
    Map<String, Object?> parameters,
  ) => _call(
    computer.id,
    (client) => client.gatewayCommand(
      provider: provider,
      entry: entry,
      identity: identity,
      id: id,
      command: command,
      parameters: jsonEncode(parameters),
    ),
  );
  @override
  Future<DownloadChunk> downloadChunk(
    SessionSnapshot snapshot,
    String path,
    bool archive,
    int offset,
    String etag,
  ) => _call(
    snapshot.session.computerId,
    (client) => client.downloadChunk(
      session: snapshot.session,
      account: snapshot.accountIdentity,
      path: path,
      archive: archive,
      offset: offset,
      etag: etag,
    ),
  );
}
