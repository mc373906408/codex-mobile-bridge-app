part of 'bridge_view_model.dart';

extension BridgeSessionActivity on BridgeViewModel {
  void _startActivityPolling() {
    _activityTimer ??= Timer.periodic(_activityPollInterval, (_) {
      unawaited(refreshSessionActivity());
    });
    unawaited(refreshSessionActivity());
  }

  Future<void> refreshSessionActivity() async {
    final target = computer;
    if (_disposed ||
        target == null ||
        !foreground ||
        !authenticated ||
        loading ||
        sessions.isEmpty) {
      return;
    }
    final context = (_connectionGeneration, _listGeneration, provider, entry);
    if (_activityInFlight == context) return;
    _activityInFlight = context;
    bool current() =>
        !_disposed &&
        foreground &&
        authenticated &&
        context == (_connectionGeneration, _listGeneration, provider, entry);
    final hosts = <String, List<String>>{};
    for (final row in sessions) {
      if (!hosts.containsKey(row.session.environment) && hosts.length >= 20) {
        continue;
      }
      final ids = hosts.putIfAbsent(row.session.environment, () => []);
      if (ids.length < 500) ids.add(row.session.id);
    }
    try {
      final value = await repository.gatewayResource(
        target,
        provider,
        entry,
        GatewayResource.sessionActivity,
        {'hosts': hosts},
      );
      if (!current()) return;
      final data = jsonDecode(value.data) as Map<String, dynamic>;
      final updates = (data['sessions'] as List)
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .where((row) => hosts[row['host']]?.contains(row['id']) == true);
      final scope = jsonEncode([
        target.id,
        provider.name,
        entry,
        value.identity,
      ]);
      final stored = presentation['sessionActivity'];
      final tracker = SessionActivityTracker(
        stored is Map ? stored[scope] : null,
      );
      final visible = visibleActivitySession?.call();
      final changed = tracker.update(
        updates,
        visible: fresh && visible != null
            ? activityKey(visible.environment, visible.id)
            : null,
      );
      _activityScope = scope;
      _activityContext = (_connectionGeneration, provider, entry);
      _activity = tracker;
      if (changed) _saveActivity();
      _notify();
    } on UnsupportedError {
      // Older repository implementations need not provide activity tracking.
    } catch (_) {
      if (current() &&
          _activityContext == (_connectionGeneration, provider, entry)) {
        final changed = _activity.update([
          for (final host in hosts.entries)
            for (final id in host.value)
              {'host': host.key, 'id': id, 'connected': false},
        ]);
        if (changed) {
          _saveActivity();
          _notify();
        }
      }
    } finally {
      if (_activityInFlight == context) _activityInFlight = null;
    }
  }

  SessionActivityKind? sessionActivity(SessionRef session) {
    if (presentation['showActivity'] == false ||
        session.computerId != computer?.id ||
        _activityContext !=
            (_connectionGeneration, session.provider, session.entry)) {
      return null;
    }
    final indicator = _activity.indicator(
      activityKey(session.environment, session.id),
    );
    return indicator != null && relayRecovering
        ? SessionActivityKind.unknown
        : indicator;
  }

  void acknowledgeVisibleActivity() {
    final session = visibleActivitySession?.call();
    if (session != null &&
        session == selected &&
        foreground &&
        authenticated &&
        fresh) {
      _markActivityRead(session);
    }
  }

  void _markActivityRead(SessionRef session) {
    if (_activityContext ==
            (_connectionGeneration, session.provider, session.entry) &&
        _activity.read(activityKey(session.environment, session.id))) {
      _saveActivity();
      _notify();
    }
  }

  void _saveActivity() {
    final scope = _activityScope;
    if (scope == null) return;
    final stored = Map<String, dynamic>.from(
      presentation['sessionActivity'] as Map? ?? {},
    );
    stored.remove(scope);
    stored[scope] = _activity.rows;
    while (stored.length > 20) {
      stored.remove(stored.keys.first);
    }
    presentation = {...presentation, 'sessionActivity': stored};
    _savePreferences();
  }
}
