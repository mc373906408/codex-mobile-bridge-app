part of 'bridge_view_model.dart';

class _ModelCatalogEntry {
  Map<String, dynamic>? value;
  Future<Map<String, dynamic>>? pending;
  DateTime? loadedAt, attemptedAt;
}

extension BridgeModelCatalog on BridgeViewModel {
  String _modelCatalogKey(SessionSnapshot target) {
    final metadata = jsonDecode(target.metadata) as Map;
    final state = metadata['session'] is Map
        ? metadata['session'] as Map
        : metadata;
    return jsonEncode([
      _connectionGeneration,
      viewKey(target),
      target.cwd,
      metadata['modelCatalogIdentity'] ?? state['modelCatalogIdentity'],
      state['provider'],
    ]);
  }

  void _checkModelCatalog(SessionSnapshot target, int connection) {
    if (_disposed ||
        !foreground ||
        !authenticated ||
        connection != _connectionGeneration ||
        computer?.id != target.session.computerId) {
      throw StateError('Connection changed; reopen this page');
    }
    if (selected == target.session &&
        snapshot != null &&
        _modelCatalogKey(snapshot!) != _modelCatalogKey(target)) {
      throw StateError('Model account changed; reopen settings');
    }
  }

  Map<String, dynamic>? cachedModelCatalog(SessionSnapshot target) {
    _checkModelCatalog(target, _connectionGeneration);
    return _modelCatalogs[_modelCatalogKey(target)]?.value;
  }

  Future<Map<String, dynamic>> loadModelCatalog(
    SessionSnapshot target, {
    bool refresh = false,
  }) {
    final connection = _connectionGeneration;
    _checkModelCatalog(target, connection);
    final key = _modelCatalogKey(target);
    final entry = _modelCatalogs.putIfAbsent(key, _ModelCatalogEntry.new);
    if (entry.pending case final pending?) return pending;
    if (!refresh &&
        entry.value != null &&
        entry.loadedAt != null &&
        DateTime.now().difference(entry.loadedAt!) <
            const Duration(minutes: 5)) {
      return Future.value(entry.value!);
    }
    entry.attemptedAt = DateTime.now();
    final task = _readModelCatalog(target, connection, refresh)
        .then((value) {
          _checkModelCatalog(target, connection);
          entry.value = value;
          entry.loadedAt = DateTime.now();
          return value;
        })
        .whenComplete(() => entry.pending = null);
    entry.pending = task;
    // Entries from old connections cannot be reused. Keep memory bounded.
    while (_modelCatalogs.length > 8) {
      _modelCatalogs.remove(_modelCatalogs.keys.first);
    }
    return task;
  }

  Future<Map<String, dynamic>> _readModelCatalog(
    SessionSnapshot target,
    int connection,
    bool refresh,
  ) async {
    Future<void> verify() async {
      final current = await repository.snapshot(target.session);
      _checkModelCatalog(target, connection);
      if (_modelCatalogKey(current) != _modelCatalogKey(target)) {
        throw StateError('Model account changed; reopen settings');
      }
    }

    // The visible chat already has an authenticated snapshot. Other entry
    // points still establish authority before reading the directory.
    if (selected != target.session || !fresh || snapshot == null) {
      await verify();
    }
    final raw = await repository.sessionResource(
      target.session,
      SessionResource.catalog,
      {'kind': 'models', 'refresh': refresh},
    );
    _checkModelCatalog(target, connection);
    final value = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final metadata = jsonDecode(target.metadata) as Map;
    final state = metadata['session'] is Map
        ? metadata['session'] as Map
        : metadata;
    final expected =
        metadata['modelCatalogIdentity'] ?? state['modelCatalogIdentity'];
    if (expected is String &&
        expected.isNotEmpty &&
        (value['cache'] as Map?)?['identity'] != expected) {
      throw StateError('Model account changed; reopen settings');
    }
    if (value['models'] is! List) {
      throw StateError(
        'The gateway response is incompatible. Check the app and gateway versions.',
      );
    }
    await verify();
    return value;
  }

  void _prefetchModelCatalog(SessionSnapshot value) {
    if (!value.connected ||
        !value.capabilities.models ||
        value.accountIdentity.isEmpty) {
      return;
    }
    final previous = _modelCatalogs[_modelCatalogKey(value)];
    if (previous?.attemptedAt != null &&
        DateTime.now().difference(previous!.attemptedAt!) <
            const Duration(minutes: 5)) {
      return;
    }
    unawaited(
      loadModelCatalog(value).then<void>((_) {}, onError: (Object _) {}),
    );
  }
}
