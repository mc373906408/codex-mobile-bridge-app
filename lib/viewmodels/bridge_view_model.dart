import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/bridge_repository.dart';
import '../data/computer_names.dart';

class BridgeViewModel extends ChangeNotifier {
  BridgeViewModel(this.repository);
  final BridgeRepository repository;

  List<Computer> computers = [];
  Map<String, String> _computerNames = {};
  bool _computerNamesLoaded = false;
  bool renamingComputer = false;
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
  Object? _error;
  int _errorRevision = 0;
  int? _sessionListErrorRevision, _watchErrorRevision;
  int? _connectionReadErrorRevision, _creationReadErrorRevision;
  Object? get error => _error;
  set error(Object? value) {
    _error = value;
    ++_errorRevision;
  }

  String? notice;
  String? _snapshotNotice;
  Computer? _cloudRecoveryComputer;
  bool _recoveringCloud = false;
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
  final Set<VoidCallback> _attachmentWaiters = {};
  bool _disposed = false;
  bool _returningHome = false;
  Timer? _draftTimer;
  Timer? _searchTimer;
  Timer? _inboxTimer;
  StreamSubscription<String>? _connectionWatch;
  String relayState = 'disconnected';
  bool get relayRecovering =>
      computer?.relay != null &&
      foreground &&
      const {
        'connecting',
        'reconnecting',
        'gateway_offline',
        'unavailable',
        'capacity',
      }.contains(relayState);
  bool get showError =>
      error != null &&
      !(relayRecovering &&
          [
            _watchErrorRevision,
            _connectionReadErrorRevision,
            _sessionListErrorRevision,
          ].contains(_errorRevision));

  Future<void> _observeConnection(Computer target) async {
    await _connectionWatch?.cancel();
    _connectionWatch = null;
    if (target.relay == null || !foreground || _disposed) return;
    var interrupted = false;
    _connectionWatch = repository
        .connectionStates(target)
        .listen(
          (state) {
            if (_disposed || computer != target || !foreground) return;
            relayState = state;
            if (state != 'connected') fresh = false;
            if (const {
              'reconnecting',
              'gateway_offline',
              'capacity',
              'unavailable',
            }.contains(state)) {
              interrupted = true;
            }
            if (const {
              'login_required',
              'entitlement_required',
              'access_denied',
              'protocol_upgrade_required',
              'certificate',
            }.contains(state)) {
              auth = null;
              _inboxTimer?.cancel();
              unawaited(_stopWatch());
              error = 'Relay connection: $state';
              _connectionReadErrorRevision = _errorRevision;
            } else if (state == 'connected' &&
                interrupted &&
                !loading &&
                !busy) {
              interrupted = false;
              unawaited(_restoreRelayRead(target));
            }
            _notify();
          },
          onError: (Object value) {
            if (!_disposed && computer == target && foreground) {
              relayState = 'reconnecting';
              _notify();
            }
          },
        );
  }

  Future<void> _restoreRelayRead(Computer target) async {
    final generation = _connectionGeneration;
    final currentSession = selected;
    try {
      final status = await repository.connect(target);
      if (_disposed ||
          !foreground ||
          generation != _connectionGeneration ||
          computer != target) {
        return;
      }
      auth = status;
      if (!status.authenticated) return;
      await _loadConnected(generation);
      if (generation == _connectionGeneration &&
          foreground &&
          currentSession == selected &&
          currentSession != null) {
        await openSession(currentSession);
      }
    } catch (value) {
      if (generation == _connectionGeneration) {
        error = value;
        _connectionReadErrorRevision = _errorRevision;
        _notify();
      }
    }
  }

  StreamSubscription<GatewayEvent>? _watch;
  String? _subscriptionId;
  String? _subscriptionComputer;
  ({String computerId, String scope, String eventId})? _pendingNotification;

  bool get authenticated => auth?.authenticated == true;
  String computerName(Computer value) =>
      _computerNames[computerNameKey(value)] ?? value.name;

  Future<bool> renameComputer(Computer value, String name) async {
    if (_disposed || !foreground || busy || renamingComputer) return false;
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Enter a device name');
    }
    renamingComputer = true;
    _notify();
    try {
      if (!_computerNamesLoaded) {
        _computerNames = await repository.computerNames();
        _computerNamesLoaded = true;
      }
      final next = {..._computerNames, computerNameKey(value): trimmed};
      await repository.saveComputerNames(next);
      _computerNames = next;
      return true;
    } finally {
      renamingComputer = false;
      _notify();
    }
  }

  bool get draftEditable =>
      !_returningHome && _draftReady && _draftAccount.isNotEmpty;
  int get connectionGeneration => _connectionGeneration;
  bool get canAttach =>
      foreground &&
      authenticated &&
      fresh &&
      draftEditable &&
      !busy &&
      snapshot?.capabilities.attachments == true &&
      attachments.length < 8;
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

  void _clearRecoveredReadError(int? revision) {
    if (revision != null && revision == _errorRevision) error = null;
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
      _computerNames = await repository.computerNames();
      _computerNamesLoaded = true;
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
        .where(
          (value) =>
              value.connectionType == ConnectionType.direct &&
              value.baseUrl == input.baseUrl,
        )
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

  Future<void> selectPreparedRelay(Computer value) async {
    if (busy || !foreground) return;
    computers = await repository.computers();
    await selectComputer(value);
  }

  Future<void> reloadComputers() async {
    final values = await repository.computers();
    if (_disposed) return;
    computers = values;
    _notify();
  }

  Future<void> cloudAccessChanged(
    Computer value,
    bool allowed, {
    bool transientFailure = false,
  }) async {
    if (_disposed || computer?.id != value.id || value.relay == null) {
      return;
    }
    if (allowed) {
      if (_cloudRecoveryComputer != value ||
          _recoveringCloud ||
          busy ||
          loading ||
          !foreground ||
          _returningHome) {
        return;
      }
      if (authenticated) {
        _cloudRecoveryComputer = null;
        return;
      }
      final generation = _connectionGeneration;
      final selection = _selectionGeneration;
      final session = selected;
      bool current() =>
          !_disposed &&
          foreground &&
          !_returningHome &&
          computer == value &&
          _cloudRecoveryComputer == value &&
          generation == _connectionGeneration &&
          selection == _selectionGeneration;
      _recoveringCloud = true;
      loading = true;
      _notify();
      try {
        final status = await repository.connect(value);
        await _observeConnection(value);
        if (!current()) return;
        auth = status;
        if (!status.authenticated) return;
        await _loadConnected(generation);
        if (!current()) return;
        _cloudRecoveryComputer = null;
        if (session != null) await openSession(session);
      } catch (failure) {
        if (current() &&
            (error == null || _connectionReadErrorRevision == _errorRevision)) {
          error = failure;
          _connectionReadErrorRevision = _errorRevision;
        }
      } finally {
        _recoveringCloud = false;
        if (generation == _connectionGeneration) loading = false;
        _notify();
      }
      return;
    }
    _cloudRecoveryComputer =
        transientFailure && (authenticated || _cloudRecoveryComputer == value)
        ? value
        : null;
    fresh = false;
    auth = null;
    loading = false;
    ++_connectionGeneration;
    ++_selectionGeneration;
    ++_listGeneration;
    _inboxTimer?.cancel();
    _searchTimer?.cancel();
    _notify();
    await _stopWatch();
  }

  Future<T> cloudOperation<T>(
    String origin,
    Future<T> Function() work, {
    bool changesAccount = false,
  }) async {
    if (_disposed || !initialized || busy || loading || !foreground) {
      throw StateError(
        'Wait until the app is ready before changing cloud state',
      );
    }
    busy = true;
    final affected = changesAccount && computer?.relay?.origin == origin;
    final previousAuth = auth;
    if (affected) {
      _returningHome = true;
      fresh = false;
      auth = null;
      ++_connectionGeneration;
      ++_selectionGeneration;
      ++_listGeneration;
      _inboxTimer?.cancel();
      _searchTimer?.cancel();
    }
    _notify();
    try {
      if (affected) {
        try {
          await Future.wait([flushDraft(), _stopWatch()]);
          if (_draftFailed) {
            throw StateError(
              'Save the current draft before changing cloud accounts',
            );
          }
        } catch (_) {
          // No account mutation happened: keep the unsaved editor, but not live controls.
          if (!_disposed) auth = previousAuth;
          rethrow;
        }
        if (!_disposed) _clearConnectionState();
      }
      if (_disposed || !foreground) {
        throw StateError('Keep the app in the foreground for this operation');
      }
      return await work();
    } finally {
      _returningHome = false;
      busy = false;
      _notify();
    }
  }

  Future<void> selectComputer(
    Computer value, {
    String? pairingToken,
    Future<void> Function()? prepareConnection,
  }) async {
    if (busy || !foreground) return;
    _pendingNotification = null;
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
    _cloudRecoveryComputer = null;
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
      if (prepareConnection != null) await prepareConnection();
      if (_disposed || generation != _connectionGeneration || !foreground) {
        return;
      }
      await _observeConnection(value);
      var status = await repository.connect(value);
      if (repository.storageWarning case final warning?) notice = warning;
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
      if (generation == _connectionGeneration) {
        error = value;
        _connectionReadErrorRevision = _errorRevision;
      }
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
      if (generation == _connectionGeneration) await _resolveNotification();
    }
  }

  Future<void> _loadConnected(int generation) async {
    final previousError = _connectionReadErrorRevision;
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
    if (_disposed || generation != _connectionGeneration || !foreground) return;
    unawaited(refreshInbox());
    _inboxTimer?.cancel();
    _inboxTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (foreground && authenticated) unawaited(refreshInbox());
    });
    _clearRecoveredReadError(previousError);
    if (_connectionReadErrorRevision == previousError) {
      _connectionReadErrorRevision = null;
    }
    _notify();
  }

  Future<void> removeComputer(Computer value) async {
    if (_disposed ||
        value.connectionType == ConnectionType.relay ||
        busy ||
        renamingComputer ||
        !foreground ||
        !computers.any((computer) => computer.id == value.id)) {
      return;
    }
    final active = computer?.id == value.id;
    busy = true;
    error = null;
    _notify();
    try {
      if (active) {
        ++_connectionGeneration;
        ++_selectionGeneration;
        ++_listGeneration;
        fresh = false;
        loading = false;
        loadingHistory = false;
        _inboxTimer?.cancel();
        _searchTimer?.cancel();
        await flushDraft();
        await _stopWatch();
        // Detach before cleanup so a foreground transition cannot reconnect it.
        _clearConnectionState();
      }
      await repository.removeComputer(value);
      computers = computers
          .where((computer) => computer.id != value.id)
          .toList();
      if (_computerNames.containsKey(computerNameKey(value))) {
        final names = {..._computerNames}..remove(computerNameKey(value));
        await repository.saveComputerNames(names);
        _computerNames = names;
      }
    } finally {
      busy = false;
      _notify();
    }
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
    final previousError = _sessionListErrorRevision;
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
      _clearRecoveredReadError(previousError);
      _sessionListErrorRevision = null;
    } catch (value) {
      if (generation == _listGeneration) {
        error = value;
        _sessionListErrorRevision = _errorRevision;
      }
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
    _clearSnapshotNotice();
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
                _watchErrorRevision = _errorRevision;
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
                _watchErrorRevision = _errorRevision;
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
    final previousError = _watchErrorRevision;
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
    if (value.notice.isNotEmpty) {
      notice = value.notice;
      _snapshotNotice = value.notice;
    } else {
      _clearSnapshotNotice();
    }
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
    if (value.accountIdentity.isEmpty) {
      _clearRecoveredReadError(previousError);
      if (_watchErrorRevision == previousError) _watchErrorRevision = null;
      _notify();
      return;
    }
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
    _clearRecoveredReadError(previousError);
    if (_watchErrorRevision == previousError) _watchErrorRevision = null;
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
    if (!_draftReady || _returningHome) return;
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

  Future<bool> _waitForAttachmentTarget(SessionSnapshot target) async {
    bool? ready() {
      if (_disposed || selected != target.session) return false;
      final current = snapshot;
      if (current != null &&
          current.accountIdentity != target.accountIdentity) {
        return false;
      }
      if (foreground && authenticated && fresh && draftEditable) return true;
      return null;
    }

    if (ready() case final bool value) return value;
    final completion = Completer<bool>();
    void changed() {
      if (ready() case final bool value) {
        if (!completion.isCompleted) completion.complete(value);
      }
    }

    // Android may return the selected file before resume/authentication finishes.
    // Wait for the original scope, without queuing or replaying a gateway write.
    addListener(changed);
    _attachmentWaiters.add(changed);
    try {
      return await completion.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw StateError(
          'Connection is not ready. Reconnect and select the attachment again.',
        ),
      );
    } finally {
      _attachmentWaiters.remove(changed);
      removeListener(changed);
    }
  }

  Future<void> attach(
    String name,
    Uint8List bytes, {
    SessionSnapshot? pickedFor,
  }) async {
    if (pickedFor != null) {
      try {
        if (!await _waitForAttachmentTarget(pickedFor)) return;
      } catch (value) {
        if (!_disposed && selected == pickedFor.session) reportError(value);
        return;
      }
    }
    final current = snapshot;
    if (_disposed ||
        current == null ||
        !canAttach ||
        (pickedFor != null &&
            (selected != pickedFor.session ||
                current.accountIdentity != pickedFor.accountIdentity))) {
      return;
    }
    busy = true;
    error = null;
    _notify();
    try {
      final attachment = await repository.upload(current, name, bytes);
      // Acknowledged uploads still belong in the draft after backgrounding.
      if (_disposed ||
          selected != current.session ||
          _draftAccount != current.accountIdentity) {
        return;
      }
      attachments = [...attachments, attachment];
      ++_draftRevision;
      await flushDraft();
    } catch (value) {
      if (selected == current.session &&
          _draftAccount == current.accountIdentity) {
        error = value;
      }
    } finally {
      if (!_disposed) await _reloadPending(current);
      busy = false;
      _notify();
      await _resumeAfterWrite(current.session);
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
    final previousError = _creationReadErrorRevision;
    try {
      final values = await repository.pendingCreations(target);
      if (!_disposed && generation == _connectionGeneration) {
        pendingCreations = values;
        _clearRecoveredReadError(previousError);
        if (_creationReadErrorRevision == previousError) {
          _creationReadErrorRevision = null;
        }
        _notify();
      }
    } catch (value) {
      if (generation == _connectionGeneration) {
        error = value;
        _creationReadErrorRevision = _errorRevision;
        _notify();
      }
    }
  }

  Future<void> reviewCreation(Computer target, PendingCreation value) async {
    await repository.reviewCreation(
      target,
      value.operation.id,
      value.accountIdentity,
    );
    await refreshPendingCreations();
    _notify();
  }

  Future<void> backToComputers() async {
    if (_disposed || busy || !foreground || computer == null) return;
    busy = true;
    _returningHome = true;
    fresh = false;
    loading = false;
    loadingHistory = false;
    error = null;
    ++_connectionGeneration;
    ++_selectionGeneration;
    ++_listGeneration;
    _inboxTimer?.cancel();
    _searchTimer?.cancel();
    _notify();
    try {
      await Future.wait([flushDraft(), _stopWatch()]);
      if (_disposed || _draftFailed) return;
      _clearConnectionState();
    } catch (value) {
      error = value;
    } finally {
      _returningHome = false;
      busy = false;
      _notify();
    }
  }

  void _clearConnectionState() {
    unawaited(_connectionWatch?.cancel());
    _connectionWatch = null;
    _cloudRecoveryComputer = null;
    _snapshotNotice = null;
    // Invalidate reads started before or during draft persistence.
    ++_connectionGeneration;
    ++_selectionGeneration;
    ++_listGeneration;
    _pendingNotification = null;
    _draftTimer?.cancel();
    _searchTimer?.cancel();
    _inboxTimer?.cancel();
    computer = null;
    selected = null;
    snapshot = null;
    auth = null;
    clients = [];
    sessions = [];
    messages = [];
    pending = [];
    pendingCreations = [];
    inbox = [];
    draftText = '';
    attachments = [];
    _draftReady = false;
    _draftFailed = false;
    _draftAccount = '';
    _draftRevision = 0;
    nextOffset = null;
    hasMoreHistory = false;
    _before = null;
    _historyEpoch = '';
    query = '';
    notice = null;
    error = null;
    fresh = false;
    loading = false;
    loadingHistory = false;
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
    _clearRecoveredReadError(_watchErrorRevision);
    _watchErrorRevision = null;
    _clearSnapshotNotice();
    selected = null;
    snapshot = null;
    fresh = false;
    _draftReady = false;
    messages = [];
    pending = [];
    _notify();
  }

  void _clearSnapshotNotice() {
    if (_snapshotNotice != null && notice == _snapshotNotice) notice = null;
    _snapshotNotice = null;
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
      await _connectionWatch?.cancel();
      _connectionWatch = null;
      fresh = false;
      loading = false;
      loadingHistory = false;
      _inboxTimer?.cancel();
      _notify();
      await Future.wait([flushDraft(), _stopWatch(), repository.pause()]);
      return;
    }
    final target = computer, session = selected;
    // Refresh foreground controls even when no gateway needs reconnecting.
    _notify();
    if (target == null || _returningHome) return;
    try {
      await _observeConnection(target);
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
      await _resolveNotification();
    } catch (value) {
      if (generation == _connectionGeneration) {
        fresh = false;
        error = value;
        _connectionReadErrorRevision = _errorRevision;
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

  Future<void> openNotification({
    required String computerId,
    required String scope,
    required String eventId,
  }) async {
    if (_disposed || busy || !foreground) return;
    final target = computers
        .where((value) => value.id == computerId)
        .firstOrNull;
    if (target == null) {
      notice = 'This notification has expired; check the inbox.';
      _notify();
      return;
    }
    final generation = _connectionGeneration + 1;
    await selectComputer(target);
    if (_disposed ||
        generation != _connectionGeneration ||
        computer?.id != target.id ||
        !foreground) {
      return;
    }
    _pendingNotification = (
      computerId: computerId,
      scope: scope,
      eventId: eventId,
    );
    await _resolveNotification();
  }

  Future<void> _resolveNotification() async {
    final route = _pendingNotification;
    final target = computer;
    if (route == null ||
        target?.id != route.computerId ||
        !authenticated ||
        busy ||
        !foreground) {
      return;
    }
    _pendingNotification = null;
    final generation = _connectionGeneration;
    try {
      final batch = await repository.notificationEvents(target!);
      if (_disposed || generation != _connectionGeneration || !foreground) {
        return;
      }
      final event = batch.enabled && batch.scope == route.scope
          ? batch.events.where((event) => event.id == route.eventId).firstOrNull
          : null;
      if (event?.session == null) {
        notice = 'This notification has expired; check the inbox.';
        _notify();
        return;
      }
      await openInboxEntry(
        InboxEntry(id: event!.id, title: '', body: '', session: event.session),
      );
      if (selected?.computerId == event.session?.computerId &&
          selected?.provider == event.session?.provider &&
          selected?.id == event.session?.id) {
        readInbox.add(event.id);
        _savePreferences();
        _notify();
      }
    } catch (value) {
      if (generation == _connectionGeneration) reportError(value);
    }
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
    unawaited(_connectionWatch?.cancel());
    _draftTimer?.cancel();
    _searchTimer?.cancel();
    _inboxTimer?.cancel();
    unawaited(flushDraft());
    _disposed = true;
    for (final changed in _attachmentWaiters.toList()) {
      changed();
    }
    ++_selectionGeneration;
    ++_connectionGeneration;
    unawaited(_stopWatch());
    unawaited(repository.close());
    super.dispose();
  }
}
