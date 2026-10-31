import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/bridge_repository.dart';
import 'notification_bridge.dart';

class NotificationController extends ChangeNotifier {
  NotificationController(
    this.repository,
    this.bridge, {
    this.pollInterval = const Duration(seconds: 12),
  });

  final BridgeRepository repository;
  final NotificationBridge bridge;
  final Duration? pollInterval;
  NotificationState state = const NotificationState(supported: false);
  bool ready = false;
  bool busy = false;
  int online = 0;
  bool checked = false;
  String? message;
  NotificationTap? pendingTap;
  List<Computer> _computers = [];
  String _locale = 'zh';
  final Map<String, _Cursor> _ledger = {};
  Future<void> _writes = Future.value();
  Future<void> _configuration = Future.value();
  Timer? _timer;
  int _generation = 0;
  int _stateRevision = 0;
  bool _polling = false;
  bool _disposed = false;

  bool get _canPoll => ready && !_disposed && state.allowed && state.running;
  int get total => _computers.length;
  String get statusText {
    if (!state.allowed) return 'Allow notifications in Android settings';
    if (!state.running) return 'Open the app to restart background listening';
    if (_computers.isEmpty) return 'Add a gateway to receive notifications';
    if (!checked) return 'Connecting to gateways...';
    if (online == 0) {
      return 'No gateway is reachable or notifications are disabled';
    }
    return 'Listening to saved gateways';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (ready || _disposed) return;
    state = NotificationState(supported: bridge.supported);
    if (!bridge.supported) {
      ready = true;
      _notify();
      return;
    }
    bridge.bind(
      onChanged: () => unawaited(refreshState()),
      onTap: () => unawaited(_takeTap()),
    );
    try {
      final saved = await bridge.readLedger();
      if (saved != null) {
        try {
          final value = jsonDecode(saved);
          if (value is Map) {
            for (final entry in value.entries.take(100)) {
              final cursor = _Cursor.parse(entry.value);
              if (entry.key is String && cursor != null) {
                _ledger[entry.key as String] = cursor;
              }
            }
          }
        } on FormatException {
          // Corrupt local cursors establish a fresh baseline, never replay history.
        }
      }
      await refreshState();
      ready = true;
      _configuration = _configure();
      await _configuration;
      await resume();
      await _takeTap();
      _schedule(immediate: true);
    } catch (_) {
      ready = true;
      message = 'Notification setup failed. Reopen the app and try again.';
    }
    _notify();
  }

  Future<void> updateConfiguration(List<Computer> computers, String locale) {
    computers = computers
        .where((c) => c.connectionType == ConnectionType.direct)
        .toList();
    if (listEquals(_computers, computers) && _locale == locale) {
      return _configuration;
    }
    _computers = List.of(computers);
    _locale = locale;
    ++_generation;
    checked = false;
    if (ready && bridge.supported) {
      _configuration = _configure().catchError((Object _) {
        message = 'Notification setup failed. Reopen the app and try again.';
        _notify();
      });
      _schedule(immediate: true);
    }
    return _configuration;
  }

  Future<void> _configure() async {
    final ids = _computers.map((computer) => computer.id).toSet();
    _ledger.removeWhere((id, _) => !ids.contains(id));
    await bridge.configure(ids.toList(), _locale);
    await _persist();
  }

  Future<void> _persist() {
    final value = jsonEncode({
      for (final entry in _ledger.entries) entry.key: entry.value.toJson(),
    });
    return _writes = _writes
        .catchError((Object _) {})
        .then((_) => bridge.writeLedger(value));
  }

  Future<void> refreshState() async {
    if (_disposed || !bridge.supported) return;
    final revision = ++_stateRevision;
    try {
      final next = await bridge.state();
      if (_disposed || revision != _stateRevision) return;
      final changed =
          next.allowed != state.allowed || next.running != state.running;
      state = next;
      if ((next.allowed &&
              message == 'Allow notifications in Android settings') ||
          (next.running &&
              message ==
                  'Could not start notifications. Check Android permissions and try again.')) {
        message = null;
      }
      if (changed) {
        ++_generation;
        checked = false;
      }
      if (_disposed || revision != _stateRevision) return;
      _schedule(immediate: true);
      await _takeTap();
      _notify();
    } catch (_) {
      message = 'Notification setup failed. Reopen the app and try again.';
      _notify();
    }
  }

  Future<void> resume() async {
    if (!ready || _disposed || !bridge.supported) return;
    try {
      await _configuration;
      if (_disposed) return;
      // Native code starts only from a visible Activity and prompts automatically at most once.
      await bridge.ensureListening();
      await refreshState();
    } catch (_) {
      message = 'Could not start notifications. Check Android permissions and try again.';
      _notify();
    }
  }

  void _schedule({bool immediate = false}) {
    _timer?.cancel();
    if (!_canPoll || _polling || pollInterval == null) return;
    _timer = Timer(
      immediate ? Duration.zero : pollInterval!,
      () => unawaited(pollNow()),
    );
  }

  Future<void> pollNow() async {
    if (!_canPoll || _polling) return;
    _timer?.cancel();
    _polling = true;
    final generation = _generation;
    final computers = List.of(_computers);
    try {
      await _configuration;
      var count = 0;
      // Bound simultaneous requests; one offline gateway cannot block the others.
      for (var offset = 0; offset < computers.length; offset += 4) {
        if (!_current(generation)) return;
        final results = await Future.wait(
          computers
              .skip(offset)
              .take(4)
              .map((computer) => _pollComputer(computer, generation)),
        );
        count += results.where((value) => value).length;
      }
      if (!_current(generation)) return;
      await _persist();
      if (!_current(generation)) return;
      online = count;
      checked = true;
      await bridge.updateStatus(online, computers.length);
      _notify();
    } catch (_) {
      if (_current(generation)) {
        message =
            'Notification state could not be saved. Check device storage.';
        _notify();
      }
    } finally {
      _polling = false;
      _schedule();
    }
  }

  bool _current(int generation) => _canPoll && generation == _generation;

  Future<bool> _pollComputer(Computer computer, int generation) async {
    try {
      final batch = await repository.notificationEvents(computer);
      if (!_current(generation)) return false;
      if (!batch.enabled || batch.scope.isEmpty) {
        _ledger.remove(computer.id);
        await bridge.clearComputer(computer.id);
        return false;
      }
      final previous = _ledger[computer.id];
      if (previous == null || previous.scope != batch.scope) {
        await bridge.clearComputer(computer.id);
        if (!_current(generation)) return false;
        _ledger[computer.id] = _Cursor(
          batch.scope,
          batch.events.map((event) => event.id).take(200).toSet(),
        );
        return true;
      }
      final unseen =
          batch.events
              .where((event) => !previous.seen.contains(event.id))
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      // Catch up with at most ten recent alerts, rather than flooding the shade after an outage.
      for (final event in unseen.take(10).toList().reversed) {
        if (!_current(generation)) return false;
        final delivered = await bridge.showEvent(
          computerId: computer.id,
          computerName: computer.name,
          scope: batch.scope,
          eventId: event.id,
          kind: event.kind,
        );
        if (!delivered || !_current(generation)) return false;
      }
      _ledger[computer.id] = _Cursor(
        batch.scope,
        {
          ...batch.events.map((event) => event.id),
          ...previous.seen,
        }.take(200).toSet(),
      );
      return true;
    } catch (_) {
      // Never turn a failed background read into a write, login prompt, or a synthetic alert.
      return false;
    }
  }

  Future<void> sendTest() async {
    if (busy || !bridge.supported) return;
    busy = true;
    _notify();
    try {
      final allowed = await bridge.requestPermission();
      message = allowed && await bridge.testNotification()
          ? 'Test notification sent. Check the notification shade.'
          : 'Allow notifications in Android settings';
      await resume();
    } catch (_) {
      message = 'Could not start notifications. Check Android permissions and try again.';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> openSettings({bool battery = false}) async {
    try {
      await bridge.openSettings(battery: battery);
    } catch (_) {
      message = 'Open Bridge permissions from Android app settings.';
      _notify();
    }
  }

  Future<void> _takeTap() async {
    try {
      final tap = await bridge.takeTap();
      if (tap != null && !_disposed) {
        pendingTap = tap;
        _notify();
      }
    } catch (_) {
      message = 'Notification setup failed. Reopen the app and try again.';
      _notify();
    }
  }

  NotificationTap? consumeTap() {
    final tap = pendingTap;
    pendingTap = null;
    return tap;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _timer?.cancel();
    bridge.dispose();
    super.dispose();
  }
}

class _Cursor {
  _Cursor(this.scope, this.seen);
  final String scope;
  final Set<String> seen;

  static _Cursor? parse(Object? value) {
    if (value is! Map || value['scope'] is! String || value['seen'] is! List) {
      return null;
    }
    final scope = value['scope'] as String;
    if (scope.isEmpty || scope.length > 256) return null;
    return _Cursor(
      scope,
      (value['seen'] as List)
          .whereType<String>()
          .where((id) => id.isNotEmpty && id.length <= 256)
          .take(200)
          .toSet(),
    );
  }

  Map<String, Object> toJson() => {'scope': scope, 'seen': seen.toList()};
}
