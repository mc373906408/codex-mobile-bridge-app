import 'dart:async';

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
