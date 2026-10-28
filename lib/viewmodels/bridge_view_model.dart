import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/bridge_repository.dart';

class BridgeViewModel extends ChangeNotifier {
  BridgeViewModel(this.repository);
  final BridgeRepository repository;

  List<Computer> computers = [];
  Computer? computer;
  AuthStatus? auth;
  List<ClientInfo> clients = [];
  Provider provider = Provider.codex;
  List<SessionSummary> sessions = [];
  SessionRef? selected;
  SessionSnapshot? snapshot;
  List<ChatMessage> messages = [];
  List<PendingOperation> pending = [];
  List<PendingCreation> pendingCreations = [];
  List<InboxEntry> inbox = [];
  final Set<String> readInbox = {};
  String theme = 'system';
  String locale = 'zh';
  String draftText = '';
  List<Attachment> attachments = [];
  String query = '';
  Object? error;
  String? notice;
  bool loading = false;
  bool loadingHistory = false;
  bool busy = false;
  bool fresh = false;
  bool initialized = false;
  bool foreground = true;
  bool steer = false;
  int? nextOffset;
  String? _before;
  bool hasMoreHistory = false;
  String _historyEpoch = '';
  String _draftAccount = '';
  int _draftRevision = 0;
  bool _draftReady = false;
  bool _draftFailed = false;
  int _connectionGeneration = 0;
  int _selectionGeneration = 0;
  int _listGeneration = 0;
  int _historyRevision = 0;
  int _snapshotGeneration = 0;
  int _lifecycleGeneration = 0;
  Future<void> _preferenceWrites = Future<void>.value();
  bool _disposed = false;
  Timer? _draftTimer;
  Timer? _searchTimer;
  Timer? _inboxTimer;
  StreamSubscription<GatewayEvent>? _watch;
  String? _subscriptionId;
  String? _subscriptionComputer;

  bool get authenticated => auth?.authenticated == true;
  bool get draftEditable => _draftReady && _draftAccount.isNotEmpty;
  int get connectionGeneration => _connectionGeneration;
  bool get canSend =>
      foreground &&
      authenticated &&
      fresh &&
      _draftReady &&
      !_draftFailed &&
      !busy &&
      snapshot?.capabilities.send == true &&
      (!snapshot!.running || steer && snapshot!.capabilities.steer) &&
      (draftText.trim().isNotEmpty || attachments.isNotEmpty) &&
      !pending.any((operation) => operation.action == 'send');
  int get unreadCount =>
      inbox.where((entry) => !readInbox.contains(entry.id)).length;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void dismissError() {
    error = null;
    _notify();
  }

  void reportError(Object value) {
    error = value;
    _notify();
  }

  Future<void> initialize() async {
    loading = true;
    _notify();
    try {
      await repository.initialize();
      computers = await repository.computers();
      final preferences = await repository.preferences();
      theme = preferences.theme;
      locale = preferences.locale;
      readInbox.addAll(preferences.readInbox);
      initialized = true;
    } catch (value) {
      error = value;
    } finally {
      loading = false;
      _notify();
    }
  }

  void setAppearance({String? theme, String? locale}) {
    if (theme != null && ['system', 'light', 'dark'].contains(theme)) {
      this.theme = theme;
    }
    if (locale != null && ['zh', 'en'].contains(locale)) this.locale = locale;
    _savePreferences();
    _notify();
  }

  void _savePreferences() {
    final ids = readInbox.toList();
    final value = UiPreferences(
      theme: theme,
      locale: locale,
      readInbox: ids.length <= 1000 ? ids : ids.sublist(ids.length - 1000),
    );
    _preferenceWrites = _preferenceWrites
        .then((_) => repository.savePreferences(value))
        .catchError((Object value) {
          reportError(value);
        });
  }

  Future<void> addComputer(String name, String address) async {
    if (busy || !foreground) return;
    final input = await repository.parseConnection(address);
    final existing = computers
        .where((value) => value.baseUrl == input.baseUrl)
        .firstOrNull;
    final value = Computer(
      id: existing?.id ?? repository.newId(),
      name: name.trim().isEmpty ? Uri.parse(input.baseUrl).host : name.trim(),
      baseUrl: input.baseUrl,
    );
    await repository.saveComputer(value);
    computers = await repository.computers();
    await selectComputer(value, pairingToken: input.pairingToken);
  }

  Future<void> selectComputer(Computer value, {String? pairingToken}) async {
    if (busy || !foreground) return;
    final generation = ++_connectionGeneration;
    ++_selectionGeneration;
    ++_listGeneration;
    await flushDraft();
    if (_draftFailed) {
      fresh = false;
      _notify();
      return;
    }
    await _stopWatch();
    if (_disposed || generation != _connectionGeneration) return;
    _inboxTimer?.cancel();
    computer = value;
    auth = null;
    selected = null;
    snapshot = null;
    messages = [];
    sessions = [];
    clients = [];
    inbox = [];
    pending = [];
    pendingCreations = [];
    nextOffset = null;
    query = '';
    fresh = false;
    _draftReady = false;
    _draftAccount = '';
    draftText = '';
    attachments = [];
    loading = true;
    error = null;
    notice = null;
    _notify();
    try {
      var status = await repository.connect(value);
      if (_disposed || generation != _connectionGeneration || !foreground) {
        return;
      }
      if (pairingToken != null) {
        status = await repository.pair(value, pairingToken);
      }
      if (_disposed || generation != _connectionGeneration) return;
      auth = status;
      if (status.authenticated) await _loadConnected(generation);
    } catch (value) {
      if (generation == _connectionGeneration) error = value;
    } finally {
      if (generation == _connectionGeneration) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> login(String username, String password) async {
    final target = computer;
    if (target == null || busy || !foreground) return;
    final generation = _connectionGeneration;
    busy = true;
    error = null;
    _notify();
    try {
      final status = await repository.login(target, username, password);
      if (_disposed || generation != _connectionGeneration) return;
      auth = status;
      if (status.authenticated) await _loadConnected(generation);
    } catch (value) {
      if (generation == _connectionGeneration) error = value;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _loadConnected(int generation) async {
    final target = computer!;
    final values = await repository.clients(target);
    if (_disposed || generation != _connectionGeneration || !foreground) return;
    clients = values;
    if (!values.any((value) => value.provider == provider && value.readable)) {
      provider =
          values.where((value) => value.readable).firstOrNull?.provider ??
          Provider.codex;
    }
    await refreshSessions();
    if (_disposed || generation != _connectionGeneration || !foreground) return;
    await refreshPendingCreations();
    unawaited(refreshInbox());
    _inboxTimer?.cancel();
    _inboxTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (foreground && authenticated) unawaited(refreshInbox());
    });
  }

  Future<void> removeComputer(Computer value) async {
    if (busy) return;
    if (computer?.id == value.id) {
      ++_connectionGeneration;
      ++_selectionGeneration;
      ++_listGeneration;
      await flushDraft();
      await _stopWatch();
      computer = null;
      selected = null;
      snapshot = null;
      auth = null;
      sessions = [];
      messages = [];
      pending = [];
      pendingCreations = [];
      inbox = [];
      fresh = false;
      _draftReady = false;
      _inboxTimer?.cancel();
    }
    await repository.removeComputer(value);
    computers = await repository.computers();
    _notify();
  }

  Future<void> selectProvider(Provider value) async {
    if (busy || provider == value) return;
    await backToSessions();
    if (_draftFailed || !foreground) return;
    provider = value;
    query = '';
    nextOffset = null;
    sessions = [];
    await refreshSessions();
  }

  void search(String value) {
    query = value;
    ++_listGeneration;
    _searchTimer?.cancel();
    _searchTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(refreshSessions()),
    );
  }

  Future<void> refreshSessions({bool more = false}) async {
    final target = computer;
    if (target == null || !authenticated || !foreground) return;
    if (more && nextOffset == null) return;
    final generation = ++_listGeneration;
    final connection = _connectionGeneration;
    final selectedProvider = provider;
    loading = true;
    _notify();
    try {
      final page = await repository.sessions(
        target,
        selectedProvider,
        query,
        more ? nextOffset! : 0,
      );
      if (_disposed ||
          generation != _listGeneration ||
          connection != _connectionGeneration ||
          provider != selectedProvider) {
        return;
      }
      sessions = more
          ? {
              for (final value in [...sessions, ...page.sessions])
                value.session: value,
            }.values.toList()
          : page.sessions;
      nextOffset = page.nextOffset;
      notice = page.notice.isEmpty ? null : page.notice;
    } catch (value) {
      if (generation == _listGeneration) error = value;
    } finally {
      if (generation == _listGeneration) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> openSession(SessionRef session) async {
    if (busy ||
        !foreground ||
        !authenticated ||
        session.computerId != computer?.id) {
      return;
    }
    final generation = ++_selectionGeneration;
    await flushDraft();
    if (_draftFailed) {
      fresh = false;
      _notify();
      return;
    }
    await _stopWatch();
    if (_disposed || generation != _selectionGeneration) return;
    selected = session;
    snapshot = null;
    messages = [];
    pending = [];
    attachments = [];
    draftText = '';
    _draftAccount = '';
    _draftReady = false;
    _draftRevision = 0;
    _draftFailed = false;
    fresh = false;
    loadingHistory = true;
    error = null;
    hasMoreHistory = false;
    _historyEpoch = '';
    _notify();
    try {
      final value = await repository.snapshot(session);
      if (!_current(generation, session) || !foreground) return;
      await _applySnapshot(value, generation);
      if (!_current(generation, session) || !foreground) return;
      final id = repository.newId();
      _subscriptionId = id;
      _subscriptionComputer = session.computerId;
      _watch = repository
          .watch(session, id)
          .listen(
            (event) {
              if (!_current(generation, session) ||
                  event.subscriptionId != id ||
                  !foreground) {
                return;
              }
              if (event.snapshot case final value?) {
                unawaited(
                  _applySnapshot(value, generation).catchError((Object value) {
                    if (_current(generation, session)) {
                      fresh = false;
                      reportError(value);
                    }
                  }),
                );
              } else {
                fresh = false;
                error = event.message;
                if (event.authenticationRequired) {
                  auth = null;
                  _inboxTimer?.cancel();
                }
                _notify();
              }
            },
            onError: (Object value) {
              if (_current(generation, session)) {
                fresh = false;
                error = value;
                _notify();
              }
            },
            onDone: () {
              if (_current(generation, session) && _subscriptionId == id) {
                fresh = false;
                _notify();
              }
            },
          );
    } catch (value) {
      if (_current(generation, session)) error = value;
    } finally {
      if (_current(generation, session)) {
        loadingHistory = false;
        _notify();
      }
    }
  }

  bool _current(int generation, SessionRef session) =>
      !_disposed && generation == _selectionGeneration && selected == session;

  Future<void> _applySnapshot(SessionSnapshot value, int generation) async {
    if (!_current(generation, value.session) || !foreground) return;
    final update = ++_snapshotGeneration;
    ++_historyRevision;
    final accountChanged = _draftAccount != value.accountIdentity;
    final incoming = value.history.messages;
    final overlap = incoming.isEmpty
        ? -1
        : messages.indexWhere((message) => message.id == incoming.first.id);
    final preserve =
        !accountChanged &&
        !value.history.reset &&
        _historyEpoch == value.history.epoch &&
        overlap > 0;
    messages = preserve
        ? [...messages.take(overlap), ...incoming]
        : [...incoming];
    if (messages.length > 500) {
      messages = messages.sublist(messages.length - 500);
      _before = value.history.before;
      hasMoreHistory = value.history.hasMore;
    }
    if (!preserve) {
      _before = value.history.before;
      hasMoreHistory = value.history.hasMore;
    }
    _historyEpoch = value.history.epoch;
    snapshot = value;
    fresh = true;
    if (value.notice.isNotEmpty) notice = value.notice;
    if (!value.capabilities.steer) steer = false;
    if (accountChanged && _draftReady) {
      // Persist the old scope before discarding its editor, never migrate across accounts.
      final oldDraft = Draft(
        text: draftText,
        attachments: [...attachments],
        revision: _draftRevision,
      );
      final oldAccount = _draftAccount;
      unawaited(
        repository.saveDraft(value.session, oldAccount, oldDraft).catchError((
          Object value,
        ) {
          reportError(value);
        }),
      );
    }
    if (accountChanged || value.accountIdentity.isEmpty) {
      _draftTimer?.cancel();
      _draftReady = false;
      _draftAccount = value.accountIdentity;
      draftText = '';
      attachments = [];
      _draftRevision = 0;
      pending = [];
      _notify();
    }
    if (value.accountIdentity.isEmpty) return;
    if (!_draftReady) {
      final restored = await repository.draft(
        value.session,
        value.accountIdentity,
      );
      if (!_current(generation, value.session) ||
          update != _snapshotGeneration ||
          _draftAccount != value.accountIdentity) {
        return;
      }
      draftText = restored.text;
      attachments = restored.attachments;
      _draftRevision = restored.revision;
      _draftReady = true;
      _draftFailed = false;
    }
    final unresolved = await repository.pending(
      value.session,
      value.accountIdentity,
    );
    if (!_current(generation, value.session) ||
        update != _snapshotGeneration ||
        _draftAccount != value.accountIdentity) {
      return;
    }
    pending = unresolved;
    _notify();
  }

  Future<void> loadOlder() async {
    final session = selected;
    final cursor = _before;
    if (session == null ||
        cursor == null ||
        !hasMoreHistory ||
        loadingHistory ||
        !foreground) {
      return;
    }
    final generation = _selectionGeneration, revision = _historyRevision;
    loadingHistory = true;
    _notify();
    try {
      final page = await repository.history(session, cursor);
      if (!_current(generation, session) || revision != _historyRevision) {
        return;
      }
      if (page.reset || page.epoch != _historyEpoch) {
        notice = 'History changed; refresh the latest view';
        return;
      }
      final known = messages.map((message) => message.id).toSet();
      messages = [
        ...page.messages.where((message) => !known.contains(message.id)),
        ...messages,
      ];
      _before = page.before;
      hasMoreHistory = page.hasMore;
      if (messages.length > 500) {
        messages = messages.take(500).toList();
        hasMoreHistory = false;
        notice =
            'Memory window reached. Refresh to return to the latest messages';
      }
    } catch (value) {
      if (_current(generation, session)) error = value;
    } finally {
      if (_current(generation, session)) {
        loadingHistory = false;
        _notify();
      }
    }
  }

  void editDraft(String value) {
    if (!_draftReady) return;
    draftText = value;
    ++_draftRevision;
    _draftTimer?.cancel();
    _draftTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(flushDraft()),
    );
    _notify();
  }

  Future<void> flushDraft() async {
    _draftTimer?.cancel();
    final session = selected, account = _draftAccount;
    if (session == null || account.isEmpty || !_draftReady) return;
    final draft = Draft(
      text: draftText,
      attachments: [...attachments],
      revision: _draftRevision,
    );
    try {
      await repository.saveDraft(session, account, draft);
      if (selected == session &&
          _draftAccount == account &&
          _draftRevision == draft.revision) {
        _draftFailed = false;
        _notify();
      }
    } catch (value) {
      if (selected == session && _draftAccount == account) {
        _draftFailed = true;
        error = value;
        _notify();
      }
    }
  }

  Future<void> send() async {
    if (!canSend) return;
    busy = true;
    error = null;
    _notify();
    final current = snapshot!, revision = _draftRevision;
    final text = draftText, files = attachments.map((item) => item.id).toList();
    final generation = _selectionGeneration;
    try {
      await flushDraft();
      if (_draftFailed ||
          !foreground ||
          !fresh ||
          !_current(generation, current.session)) {
        return;
      }
      final result = await repository.send(
        current,
        repository.newId(),
        text,
        files,
        steer,
      );
      // A background transition invalidates read generations, not an acknowledged write.
      if (selected != current.session ||
          _draftAccount != current.accountIdentity) {
        return;
      }
      if (result.kind == OutcomeKind.accepted && _draftRevision == revision) {
        draftText = '';
        attachments = [];
        ++_draftRevision;
        await flushDraft();
      }
      if (result.kind != OutcomeKind.accepted) error = result.message;
      if (repository.storageWarning case final warning?) notice = warning;
    } catch (value) {
      if (selected == current.session) error = value;
    } finally {
      await _reloadPending(current);
      busy = false;
      _notify();
      await _resumeAfterWrite(current.session);
    }
  }

  Future<void> _reloadPending(SessionSnapshot current) async {
    try {
      final values = await repository.pending(
        current.session,
        current.accountIdentity,
      );
      if (!_disposed &&
          selected == current.session &&
          _draftAccount == current.accountIdentity) {
        pending = values;
      }
    } catch (value) {
      if (selected == current.session) {
        _draftFailed = true;
        error = value;
      }
    }
  }

  Future<void> _resumeAfterWrite(SessionRef session) async {
    if (!_disposed &&
        foreground &&
        authenticated &&
        selected == session &&
        !fresh) {
      await openSession(session);
    }
  }

  Future<void> perform(
    Future<OperationOutcome> Function(SessionSnapshot value, String id) action,
  ) async {
    if (busy || !foreground || !authenticated || !fresh || snapshot == null) {
      return;
    }
    final current = snapshot!, generation = _selectionGeneration;
    busy = true;
    error = null;
    _notify();
    try {
      final result = await action(current, repository.newId());
      if (!_current(generation, current.session)) return;
      if (result.kind != OutcomeKind.accepted) error = result.message;
      await _applySnapshot(
        await repository.snapshot(current.session),
        generation,
      );
    } catch (value) {
      if (_current(generation, current.session)) error = value;
    } finally {
      await _reloadPending(current);
      busy = false;
      _notify();
      await _resumeAfterWrite(current.session);
    }
  }

  Future<void> markReviewed(
    PendingOperation operation, {
    SessionSnapshot? authority,
  }) async {
    final current = authority ?? snapshot;
    if (current == null || busy) return;
    await repository.markReviewed(
      current.session,
      current.accountIdentity,
      operation.id,
    );
    await _reloadPending(current);
    _notify();
  }

  Future<void> attach(String name, Uint8List bytes) async {
    final current = snapshot;
    if (current == null ||
        !foreground ||
        !draftEditable ||
        !fresh ||
        busy ||
        !current.capabilities.attachments ||
        attachments.length >= 8) {
      return;
    }
    final generation = _selectionGeneration;
    busy = true;
    _notify();
    try {
      final attachment = await repository.upload(current, name, bytes);
      if (!_current(generation, current.session) ||
          _draftAccount != current.accountIdentity) {
        return;
      }
      attachments = [...attachments, attachment];
      ++_draftRevision;
      await flushDraft();
    } catch (value) {
      if (_current(generation, current.session)) error = value;
    } finally {
      busy = false;
      _notify();
    }
  }

  void removeAttachment(Attachment value) {
    if (busy || !draftEditable) return;
    attachments = attachments.where((item) => item.id != value.id).toList();
    ++_draftRevision;
    unawaited(flushDraft());
    _notify();
  }

  void setSteer(bool value) {
    steer = value && snapshot?.capabilities.steer == true;
    _notify();
  }

  Future<void> createChat(
    ProjectOption project,
    String title,
    String text, {
    int? expectedConnection,
  }) async {
    final target = computer;
    if (target == null || busy || !foreground || !authenticated) return;
    if ((expectedConnection != null &&
            expectedConnection != _connectionGeneration) ||
        project.provider != provider) {
      reportError('Connection changed; reopen the new chat dialog');
      return;
    }
    final generation = _connectionGeneration;
    busy = true;
    _notify();
    try {
      final result = await repository.create(
        target,
        project,
        title,
        text,
        repository.newId(),
      );
      if (_disposed || generation != _connectionGeneration || !foreground) {
        return;
      }
      if (result.kind != OutcomeKind.accepted) {
        error = result.message;
        return;
      }
      await refreshSessions();
      busy = false;
      if (result.createdSession case final session?) await openSession(session);
    } catch (value) {
      if (computer?.id == target.id) error = value;
    } finally {
      await refreshPendingCreations();
      busy = false;
      _notify();
    }
  }

  Future<void> refreshPendingCreations() async {
    final target = computer;
    if (target == null) return;
    final generation = _connectionGeneration;
    try {
      final values = await repository.pendingCreations(target);
      if (!_disposed && generation == _connectionGeneration) {
        pendingCreations = values;
      }
    } catch (value) {
      if (generation == _connectionGeneration) reportError(value);
    }
  }

  Future<void> reviewCreation(Computer target, PendingCreation value) async {
    await repository.reviewCreation(target, value.operation.id);
    await refreshPendingCreations();
    _notify();
  }

  Future<void> backToSessions() async {
    if (busy) return;
    ++_selectionGeneration;
    await flushDraft();
    if (_draftFailed) {
      fresh = false;
      _notify();
      return;
    }
    await _stopWatch();
    selected = null;
    snapshot = null;
    fresh = false;
    _draftReady = false;
    messages = [];
    pending = [];
    _notify();
  }

  Future<void> _stopWatch() async {
    final id = _subscriptionId, pc = _subscriptionComputer;
    final watch = _watch;
    _watch = null;
    _subscriptionId = null;
    _subscriptionComputer = null;
    await Future.wait([
      if (id != null && pc != null) repository.cancelWatch(pc, id),
      if (watch != null) watch.cancel(),
    ]);
  }

  Future<void> setForeground(bool value) async {
    if (foreground == value) return;
    foreground = value;
    final lifecycle = ++_lifecycleGeneration;
    final generation = ++_connectionGeneration;
    ++_listGeneration;
    ++_selectionGeneration;
    if (!value) {
      fresh = false;
      loading = false;
      loadingHistory = false;
      _inboxTimer?.cancel();
      _notify();
      await Future.wait([flushDraft(), _stopWatch(), repository.pause()]);
      return;
    }
    final target = computer, session = selected;
    if (target == null) return;
    try {
      final status = await repository.connect(target);
      if (_disposed ||
          lifecycle != _lifecycleGeneration ||
          generation != _connectionGeneration ||
          !foreground) {
        return;
      }
      auth = status;
      if (!authenticated) {
        fresh = false;
        _notify();
        return;
      }
      await _loadConnected(generation);
      if (_disposed ||
          lifecycle != _lifecycleGeneration ||
          generation != _connectionGeneration ||
          !foreground) {
        return;
      }
      if (session != null && !busy) await openSession(session);
    } catch (value) {
      if (generation == _connectionGeneration) {
        fresh = false;
        error = value;
        _notify();
      }
    }
  }

  Future<void> refreshInbox() async {
    final target = computer, generation = _connectionGeneration;
    if (target == null || !authenticated || !foreground) return;
    try {
      final values = await repository.inbox(target);
      if (_disposed || generation != _connectionGeneration || !foreground) {
        return;
      }
      inbox = values;
      _notify();
    } catch (_) {
      /* An optional inbox failure does not invalidate chat state. */
    }
  }

  void markInboxRead() {
    readInbox.addAll(inbox.map((entry) => entry.id));
    _savePreferences();
    _notify();
  }

  Future<void> openInboxEntry(InboxEntry entry) async {
    var session = entry.session;
    final target = computer,
        generation = _connectionGeneration,
        selection = _selectionGeneration;
    if (session == null || target == null || busy || !foreground) return;
    try {
      if (session.provider != Provider.codex) {
        SessionRef? resolved;
        int? offset = 0;
        for (var pageIndex = 0; offset != null && pageIndex < 20; pageIndex++) {
          final page = await repository.sessions(
            target,
            session.provider,
            '',
            offset,
          );
          resolved = page.sessions
              .where((row) => row.session.id == session!.id)
              .firstOrNull
              ?.session;
          if (resolved != null) break;
          offset = page.nextOffset;
        }
        if (resolved == null) {
          throw StateError(
            'Conversation unavailable; find it on the original computer',
          );
        }
        session = resolved;
      }
      if (_disposed ||
          generation != _connectionGeneration ||
          selection != _selectionGeneration ||
          !foreground) {
        return;
      }
      await selectProvider(session.provider);
      await openSession(session);
    } catch (value) {
      if (generation == _connectionGeneration) reportError(value);
    }
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _searchTimer?.cancel();
    _inboxTimer?.cancel();
    unawaited(flushDraft());
    _disposed = true;
    ++_selectionGeneration;
    ++_connectionGeneration;
    unawaited(_stopWatch());
    unawaited(repository.close());
    super.dispose();
  }
}
