import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/bridge_repository.dart';
import '../data/computer_names.dart';

part 'bridge_connection.dart';
part 'bridge_computers.dart';
part 'bridge_session_list.dart';
part 'bridge_session_detail.dart';
part 'bridge_session_writes.dart';
part 'bridge_attachments.dart';
part 'bridge_navigation.dart';
part 'bridge_inbox.dart';

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
  String entry = '';
  String source = 'all';
  bool archived = false;
  Map<String, dynamic> draftOptions = {};
  List<SessionSummary> sessions = [];
  List<EnvironmentIssue> environmentIssues = const [];
  SessionRef? selected;
  SessionSnapshot? snapshot;
  List<ChatMessage> messages = [];
  List<PendingOperation> pending = [];
  List<PendingCreation> pendingCreations = [];
  List<InboxEntry> inbox = [];
  final Set<String> readInbox = {};
  String theme = 'system';
  String locale = 'zh';
  Map<String, dynamic> presentation = {};
  bool get groupByProject => presentation['groupByProject'] == true;
  double get fontScale =>
      ((presentation['fontScale'] as num?)?.toDouble() ?? 1).clamp(.8, 1.6);
  String sessionKey(SessionRef value) => jsonEncode([
    value.computerId,
    value.provider.name,
    value.entry,
    value.environment,
    value.id,
  ]);
  void setPresentation(String key, Object? value) {
    presentation = {...presentation, key: value};
    _savePreferences();
    _notify();
  }

  String viewKey(SessionSnapshot value) =>
      jsonEncode([sessionKey(value.session), value.accountIdentity]);
  void rememberView(String section, String key, Object value) {
    final entries = Map<String, dynamic>.from(
      presentation[section] as Map? ?? {},
    );
    entries.remove(key);
    entries[key] = value;
    while (entries.length > 500) {
      entries.remove(entries.keys.first);
    }
    presentation = {...presentation, section: entries};
    _savePreferences();
  }

  Future<void> saveTerminalHandle(String key, Map<String, dynamic>? handle) {
    final handles = Map<String, dynamic>.from(
      presentation['terminalHandles'] as Map? ?? {},
    );
    if (handle == null) {
      handles.remove(key);
    } else {
      handles[key] = handle;
    }
    presentation = {...presentation, 'terminalHandles': handles};
    final value = UiPreferences(
      theme: theme,
      locale: locale,
      readInbox: readInbox.take(1000).toList(),
      presentation: jsonEncode(presentation),
    );
    final write = _preferenceWrites.then(
      (_) => repository.savePreferences(value),
    );
    _preferenceWrites = write.catchError((Object error) {
      reportError(error);
    });
    return write;
  }

  final Map<String, String> _readAccounts = {};

  Future<void> markSessionRead(SessionRef value, bool read) async {
    final connection = _connectionGeneration;
    final row = sessions.where((r) => r.session == value).firstOrNull;
    if (row == null || !authenticated || !foreground) return;
    String account = '';
    if (read) {
      try {
        final verified = await repository.snapshot(value);
        if (_disposed ||
            !foreground ||
            !authenticated ||
            connection != _connectionGeneration ||
            sessions.where((r) => r.session == value).firstOrNull?.updatedAt !=
                row.updatedAt) {
          return;
        }
        account = verified.accountIdentity;
        if (account.isEmpty) return;
        _readAccounts[sessionKey(value)] = account;
      } catch (error) {
        if (connection == _connectionGeneration) reportError(error);
        return;
      }
    }
    final states = Map<String, dynamic>.from(
      presentation['readSessions'] as Map? ?? {},
    );
    states[sessionKey(value)] = read
        ? {'updated': row.updatedAt, 'account': account}
        : false;
    setPresentation('readSessions', states);
  }

  bool isSessionRead(SessionRef value) {
    final marker =
        (presentation['readSessions'] as Map? ?? {})[sessionKey(value)];
    final row = sessions.where((r) => r.session == value).firstOrNull;
    if (marker is! Map || marker['updated'] != (row?.updatedAt ?? '')) {
      return false;
    }
    return marker['account'] is String &&
        marker['account'] != '' &&
        marker['account'] == _readAccounts[sessionKey(value)];
  }

  String draftText = '';
  List<Map<String, dynamic>> get quotes =>
      (draftOptions['quotes'] as List? ?? [])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
  String get composedText => [
    ...quotes.map(
      (quote) => (quote['text'] as String)
          .split('\n')
          .map((line) => '> $line')
          .join('\n'),
    ),
    if (draftText.isNotEmpty) draftText,
  ].join('\n\n');
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
  List<String> availableSources = const [];
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
  String get historyEpoch => _historyEpoch;
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

  StreamSubscription<GatewayEvent>? _watch;
  String? _subscriptionId;
  String? _subscriptionComputer;
  ({String computerId, String scope, String eventId})? _pendingNotification;

  bool get authenticated => auth?.authenticated == true;
  String computerName(Computer value) =>
      _computerNames[computerNameKey(value)] ?? value.name;

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
      attachments.length + fileReferences.length < 10;
  List<Map<String, dynamic>> get fileReferences =>
      (draftOptions['references'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  String get sendMode =>
      draftOptions['mode'] as String? ?? (steer ? 'steer' : 'send');
  bool get queueAvailable {
    final data = jsonDecode(snapshot?.metadata ?? '{}') as Map;
    final state = data['session'] is Map ? data['session'] as Map : data;
    final caps = data['capabilities'] is Map
        ? data['capabilities'] as Map
        : state['capabilities'] as Map? ?? {};
    return caps['queue'] != false;
  }

  bool get canSend =>
      foreground &&
      authenticated &&
      fresh &&
      _draftReady &&
      !_draftFailed &&
      !busy &&
      snapshot?.capabilities.send == true &&
      (!snapshot!.running ||
          sendMode == 'steer' && snapshot!.capabilities.steer ||
          sendMode == 'queue' && queueAvailable) &&
      (composedText.trim().isNotEmpty ||
          attachments.isNotEmpty ||
          fileReferences.isNotEmpty) &&
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
