import 'dart:async';

import 'package:flutter/foundation.dart';

import '../src/rust/api/types.dart';
import 'cloud_push_bridge.dart';
import 'notification_bridge.dart';

/// Only passive authenticated reads and idempotent endpoint/receipt operations.
class CloudPushController extends ChangeNotifier {
  CloudPushController(
    this.repository,
    this.bridge, {
    this.interval = const Duration(seconds: 15),
  });
  final CloudPushRepository repository;
  final CloudPushBridge bridge;
  final Duration? interval;
  List<Computer> _computers = [];
  final Map<String, String> _registrations = {};
  final Map<String, Map<String, int>> _attempts = {};
  Timer? _timer;
  bool _polling = false, _disposed = false, _ready = false;
  int _generation = 0;
  NotificationTap? pendingTap;
  CloudPushState state = const CloudPushState(supported: false);
  bool checked = false, busy = false;
  String? message;

  String get statusText {
    if (!checked) return 'Checking cloud notification settings';
    if (!state.consent) return 'Cloud notifications are off';
    if (!state.allowed) return 'System notification permission is required';
    if (!state.configured) {
      return 'Direct cloud updates only; remote push is not configured';
    }
    if (state.enabled) return 'Encrypted cloud notifications are enabled';
    return 'Waiting for private push registration';
  }

  Future<void> setConsent(bool enabled, String noticeVersion) async {
    if (_disposed || busy) return;
    busy = true;
    message = null;
    pendingTap = null;
    ++_generation;
    notifyListeners();
    try {
      state = await bridge.setConsent(enabled, noticeVersion);
      if (_disposed) return;
      if (enabled && state.consent && !state.allowed) {
        await bridge.requestPermission();
      }
    } catch (_) {
      message = 'Cloud notification settings could not be saved';
    } finally {
      if (!_disposed) {
        ++_generation;
        busy = false;
        notifyListeners();
        await resume();
      }
    }
  }

  Future<void> requestPermission() async {
    if (_disposed || busy || !state.consent) return;
    busy = true;
    ++_generation;
    notifyListeners();
    try {
      await bridge.requestPermission();
    } catch (_) {
      message = 'System notification permission is required';
    } finally {
      if (!_disposed) {
        ++_generation;
        busy = false;
        notifyListeners();
        await resume();
      }
    }
  }

  Future<void> initialize() async {
    if (_ready || _disposed || !bridge.supported) return;
    _ready = true;
    bridge.bind(() {
      ++_generation;
      pendingTap = null;
      unawaited(resume());
    });
    await resume();
  }

  void configure(List<Computer> computers) {
    final next = computers
        .where((c) => c.connectionType == ConnectionType.relay)
        .toList();
    if (listEquals(_computers, next)) return;
    _computers = next;
    ++_generation;
    final ids = next.map((c) => c.id).toSet();
    _registrations.removeWhere((id, _) => !ids.contains(id));
    _attempts.removeWhere((id, _) => !ids.contains(id));
    if (_ready) unawaited(resume());
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  Future<void> resume() async {
    if (!_ready || _disposed || _polling) return;
    _timer?.cancel();
    _polling = true;
    final generation = _generation;
    try {
      final nextState = await bridge.state();
      if (!_current(generation)) return;
      state = nextState;
      checked = true;
      notifyListeners();
      for (final computer in List.of(_computers)) {
        if (!_current(generation)) return;
        try {
          if (!await repository.cloudEnabled(computer)) {
            _registrations.remove(computer.id);
            _attempts.remove(computer.id);
            continue;
          }
          if (!_current(generation)) return;
          if (_registrations[computer.id] != state.revision) {
            final revisions = _attempts.putIfAbsent(computer.id, () => {});
            revisions.removeWhere((revision, _) => revision != state.revision);
            final attempts = revisions[state.revision] ?? 0;
            if (attempts < 6) {
              revisions[state.revision] = attempts + 1;
              try {
                await repository.registerCloudPush(computer, state);
                if (!_current(generation)) return;
                _registrations[computer.id] = state.revision;
              } catch (_) {
                // Vendor registration failure must not block authenticated direct receipts.
              }
            }
          }
          if (!_current(generation)) return;
          // Extension/JNI receipts already exist durably; never ACK an outer push envelope.
          await _reconcile(computer, generation);
          if (!state.directAllowed || !_current(generation)) continue;
          final batch = await repository.notificationEvents(computer);
          if (!batch.enabled || batch.scope.isEmpty || !_current(generation)) {
            continue;
          }
          await bridge.directBatch(computer.id, batch);
          if (!_current(generation)) return;
          await _reconcile(computer, generation);
          if (!_current(generation)) return;
          // Heartbeats renew the 45-second direct lease only after the quiet baseline/receipts commit.
          await repository.acknowledgeCloudPush(computer, []);
        } catch (_) {
          // Offline sources and failed durable writes cannot trigger commands or synthetic alerts.
        }
      }
      if (!_current(generation)) return;
      final tap = state.directAllowed ? await bridge.takeTap() : null;
      if (tap != null && _current(generation)) {
        pendingTap = tap;
        notifyListeners();
      }
    } catch (_) {
      // Native storage can be unavailable before the device's first unlock.
    } finally {
      _polling = false;
      if (_ready && !_disposed && generation != _generation) {
        unawaited(resume());
      } else if (!_disposed && interval != null) {
        _timer = Timer(interval!, () {
          unawaited(resume());
        });
      }
    }
  }

  Future<void> _reconcile(Computer computer, int generation) async {
    final ids = await bridge.pendingReceipts(computer.id);
    if (ids.isEmpty || !_current(generation)) return;
    await repository.acknowledgeCloudPush(computer, ids.take(100).toList());
    if (_current(generation)) {
      await bridge.markAcknowledged(computer.id, ids.take(100).toList());
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
