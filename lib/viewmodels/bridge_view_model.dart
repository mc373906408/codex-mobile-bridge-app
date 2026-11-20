import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/bridge_repository.dart';
import '../data/chat_attachment_cache.dart';
import '../data/chat_attachment_preparation.dart';
import '../data/chat_preview_cache.dart';
import '../data/computer_names.dart';
import '../data/session_activity.dart';
import '../data/session_time.dart';

part 'bridge_connection.dart';
part 'bridge_computers.dart';
part 'bridge_session_list.dart';
part 'bridge_session_activity.dart';
part 'bridge_model_catalog.dart';
part 'bridge_session_detail.dart';
part 'bridge_session_writes.dart';
part 'bridge_attachments.dart';
part 'bridge_navigation.dart';
part 'bridge_inbox.dart';

typedef _SessionWatch = ({
  StreamSubscription<GatewayEvent>? subscription,
  String? id,
  String? computerId,
});
typedef _ListSnapshotScope = ({
  int connection,
  int list,
  int preview,
  SessionRef session,
});

class BridgeViewModel extends ChangeNotifier {
  BridgeViewModel(this.repository, {this._photoEncoder = encodeChatPhoto});
  final BridgeRepository repository;
  final ChatPhotoEncoder _photoEncoder;
  final _stagedAttachments =
      <_AttachmentDraftScope, List<LocalChatAttachment>>{};
  Future<void>? _photoPreparation;
  bool sendingChatAttachments = false;
  LocalChatAttachment? uploadingChatAttachment;
  final _modelCatalogs = <String, _ModelCatalogEntry>{};
  final _attachmentImages = ChatAttachmentCache();
  final _chatPreviews = ChatPreviewCache();
  ChatPreview? _chatPreview;
  final _listSnapshotReads = <_ListSnapshotScope, Future<SessionSnapshot>>{};
  int _chatPreviewGeneration = 0;
  (int, int, int)? _prefetchBatch;
  final _prefetchAttempts = <SessionRef>{};
  int _unreadPrefetches = 0;
  bool _prefetching = false;
  final _listMessageTimes = <SessionRef, (String, DateTime)>{};
  (int, bool) _attachmentAccess = (0, false);
  int _attachmentScopeGeneration = 0;

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
  ChatPreview? get chatPreview =>
      foreground && authenticated && _chatPreview?.session == selected
      ? _chatPreview
      : null;
  List<ChatMessage> messages = [];
  List<PendingOperation> pending = [];
  List<PendingCreation> pendingCreations = [];
  final Set<String> readInbox = {};
  String theme = 'system';
  String locale = 'zh';
  Map<String, dynamic> presentation = {};
  bool get groupByProject => presentation['groupByProject'] == true;
  bool get notificationsEnabled =>
      presentation['notificationsEnabled'] != false;
  Set<String> get mutedNotificationComputerIds =>
      (presentation['mutedNotificationComputers'] as Map? ?? {}).entries
          .where((entry) => entry.value == true)
          .map((entry) => entry.key.toString())
          .toSet();
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
  final _activityPollInterval = const Duration(seconds: 5);
  Timer? _activityTimer;
  (int, int, Provider, String)? _activityInFlight;
  (int, Provider, String)? _activityContext;
  String? _activityScope;
  SessionActivityTracker _activity = SessionActivityTracker();
  SessionRef? Function()? visibleActivitySession;

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
            verified.session != value ||
            !sessions.any(
              (candidate) =>
                  candidate.session == value &&
                  sessionListRevision(candidate) == sessionListRevision(row),
            )) {
          return;
        }
        _observeSessionIdentity(verified);
        account = verified.accountIdentity;
        if (account.isEmpty) {
          _notify();
          return;
        }
      } catch (error) {
        if (connection == _connectionGeneration) reportError(error);
        return;
      }
    }
    _rememberReadMarker(row, read ? account : null);
    if (read) _markActivityRead(value);
  }

  void _rememberReadMarker(SessionSummary row, String? account) {
    final states = Map<String, dynamic>.from(
      presentation['readSessions'] as Map? ?? {},
    );
    states[sessionKey(row.session)] = account == null
        ? false
        : {'updated': sessionListRevision(row), 'account': account};
    setPresentation('readSessions', states);
  }

  bool isSessionRead(SessionRef value) {
    final row = sessions.where((r) => r.session == value).firstOrNull;
    if (row == null) return false;
    final marker = _readMarkerAccount(row);
    return marker != null && marker == _readAccounts[sessionKey(value)];
  }

  String? _readMarkerAccount(SessionSummary row) {
    final marker =
        (presentation['readSessions'] as Map? ?? {})[sessionKey(row.session)];
    if (marker is! Map || marker['updated'] != sessionListRevision(row)) {
      return null;
    }
    final account = marker['account'];
    return account is String && account.isNotEmpty ? account : null;
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
  bool get steer => sendMode == 'steer';
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
  int? _sessionConnectGeneration;
  bool get connectingSession =>
      _sessionConnectGeneration == _selectionGeneration;
  bool get hasPendingSessionConnection => pending.any(
    (operation) => const {'resume', 'reconnect'}.contains(operation.action),
  );
  bool get canConnectSession =>
      !_disposed &&
      foreground &&
      authenticated &&
      fresh &&
      !busy &&
      snapshot?.connected == false &&
      snapshot?.capabilities.resume == true &&
      snapshot!.accountIdentity.isNotEmpty &&
      snapshot!.controlToken.isNotEmpty &&
      !hasPendingSessionConnection;
  int _listGeneration = 0;
  int _historyRevision = 0;
  int _snapshotGeneration = 0;
  int _lifecycleGeneration = 0;
  Future<void> _preferenceWrites = Future<void>.value();
  bool _disposed = false;
  bool _returningHome = false;
  Timer? _draftTimer;
  Timer? _searchTimer;
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

  AttachmentReadScope? get attachmentReadScope {
    final current = snapshot;
    if (_disposed ||
        !foreground ||
        !authenticated ||
        _returningHome ||
        _attachmentAccess != (_connectionGeneration, authenticated) ||
        current == null ||
        current.session != selected) {
      return null;
    }
    return (
      session: current.session,
      account: current.accountIdentity,
      historyEpoch: current.history.epoch,
      generation: _attachmentScopeGeneration,
    );
  }

  Future<AttachmentImageData> readAttachmentImage(
    AttachmentReadScope scope,
    Attachment attachment, {
    required bool thumbnail,
  }) {
    if (attachmentReadScope != scope) {
      return Future.error(StateError('Image unavailable'));
    }
    return _attachmentImages.read(
      scope,
      attachment,
      thumbnail: thumbnail,
      fetch: (thumbnail) {
        if (attachmentReadScope != scope) {
          throw StateError('Image unavailable');
        }
        return repository.image(
          scope.session,
          attachment,
          thumbnail: thumbnail,
        );
      },
    );
  }

  void clearAttachmentImages() => _attachmentImages.clear();

  void clearChatCaches() {
    clearAttachmentImages();
    final hadDisplayData = _chatPreview != null || _listMessageTimes.isNotEmpty;
    _discardChatPreviews();
    if (hadDisplayData) _notify();
  }

  void _discardChatPreviews() {
    ++_chatPreviewGeneration;
    _chatPreviews.clear();
    _chatPreview = null;
    _listSnapshotReads.clear();
    _listMessageTimes.clear();
  }

  void _resetAttachmentScope() {
    ++_attachmentScopeGeneration;
    clearAttachmentImages();
  }

  String computerName(Computer value) {
    final key = computerNameKey(value);
    final names = presentation['discoveredComputerNames'];
    final discovered = names is Map ? names[key] : null;
    return _computerNames[key] ??
        (discovered is String && discovered.isNotEmpty
            ? discovered
            : value.name);
  }

  bool get draftEditable =>
      !_returningHome && _draftReady && _draftAccount.isNotEmpty;
  int get connectionGeneration => _connectionGeneration;
  int get selectionGeneration => _selectionGeneration;
  bool get canAttach =>
      foreground &&
      authenticated &&
      fresh &&
      draftEditable &&
      !busy &&
      snapshot?.capabilities.attachments == true &&
      _attachmentCount < 10;
  List<Map<String, dynamic>> get fileReferences =>
      (draftOptions['references'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  String get sendMode => draftOptions['mode'] as String? ?? 'send';
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
      draftEditable &&
      !_draftFailed &&
      !busy &&
      snapshot?.capabilities.send == true &&
      (!snapshot!.running ||
          sendMode == 'steer' && snapshot!.capabilities.steer ||
          sendMode == 'queue' && queueAvailable) &&
      (composedText.trim().isNotEmpty ||
          attachments.isNotEmpty ||
          stagedAttachments.isNotEmpty ||
          fileReferences.isNotEmpty) &&
      _attachmentCount <= 10 &&
      (stagedAttachments.isEmpty || snapshot!.capabilities.attachments) &&
      !pending.any(
        (operation) =>
            operation.action == 'send' ||
            operation.action == 'upload' && stagedAttachments.isNotEmpty,
      );

  void _notify() {
    if (_disposed) return;
    final access = (_connectionGeneration, authenticated);
    if (_attachmentAccess != access) {
      _attachmentAccess = access;
      _resetAttachmentScope();
      _discardChatPreviews();
    }
    notifyListeners();
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
    _activityTimer?.cancel();
    unawaited(flushDraft());
    _disposed = true;
    clearAttachmentImages();
    _stagedAttachments.clear();
    _discardChatPreviews();
    ++_selectionGeneration;
    ++_connectionGeneration;
    unawaited(_stopWatch());
    unawaited(repository.close());
    super.dispose();
  }
}
