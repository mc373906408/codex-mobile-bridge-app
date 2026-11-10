part of 'bridge_view_model.dart';

extension BridgeComputers on BridgeViewModel {
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

  Future<void> initialize() async {
    loading = true;
    _notify();
    try {
      await repository.initialize();
      computers = await repository.computers();
      final preferences = await repository.preferences();
      theme = preferences.theme;
      locale = preferences.locale;
      if (preferences.presentation.isNotEmpty) {
        presentation = Map<String, dynamic>.from(
          jsonDecode(preferences.presentation) as Map,
        );
      }
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
      presentation: jsonEncode(presentation),
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
    environmentIssues = const [];
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
    if (!values.any(
      (value) =>
          value.provider == provider && value.entry == entry && value.readable,
    )) {
      provider =
          values.where((value) => value.readable).firstOrNull?.provider ??
          Provider.codex;
      entry = values.where((value) => value.readable).firstOrNull?.entry ?? '';
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
}
