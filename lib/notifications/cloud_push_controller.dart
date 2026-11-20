import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/bridge_types.dart';
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
  final Set<String> _unconfirmed = {};
  Set<String> _mutedComputerIds = const {};
  Future<void> _nativeMuteWrites = Future<void>.value();
  bool _muteDirty = true;
  Timer? _timer;
  bool _polling = false, _disposed = false, _ready = false;
  int _generation = 0;
  String? _accountIdentity;
  bool _foreground = true;
  int _activationAttempts = 0;
  NotificationTap? pendingTap;
  CloudPushState state = const CloudPushState(supported: false);
  bool checked = false, busy = false;
  bool sharedFeed = false;
  String? message;

  bool registeredFor(Computer computer) =>
      !_mutedComputerIds.contains(computer.id) &&
      _registrations[computer.id] == _registrationKey(computer);

  String _registrationKey(Computer computer) =>
      '${state.revision}\u0000${_mutedComputerIds.contains(computer.id)}';

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
      unawaited(resume());
    });
    await resume();
  }

  void configureAccount(String? identity, {required bool foreground}) {
    if (_accountIdentity == identity && _foreground == foreground) return;
    if (_accountIdentity != identity) _activationAttempts = 0;
    _accountIdentity = identity;
    _foreground = foreground;
    ++_generation;
    if (_ready) unawaited(resume());
  }

  void configure(
    List<Computer> computers, {
    Set<String> mutedComputerIds = const {},
  }) {
    final next = computers
        .where((c) => c.connectionType == ConnectionType.relay)
        .toList();
    final nextMuted = Set<String>.of(mutedComputerIds);
    final mutedChanged = !setEquals(_mutedComputerIds, nextMuted);
    if (listEquals(_computers, next) && !mutedChanged) return;
    if (mutedChanged) {
      final changed = _mutedComputerIds
          .union(nextMuted)
          .where(
            (id) => _mutedComputerIds.contains(id) != nextMuted.contains(id),
          );
      for (final id in changed) {
        _registrations.remove(id);
        _attempts.remove(id);
        _unconfirmed.remove(id);
      }
      _mutedComputerIds = nextMuted;
      _muteDirty = true;
    }
    final previous = _computers.map((computer) => computer.id).toSet();
    _computers = next;
    ++_generation;
    final ids = next.map((c) => c.id).toSet();
    final removed = previous.difference(ids);
    _registrations.removeWhere((id, _) => removed.contains(id));
    _attempts.removeWhere((id, _) => removed.contains(id));
    _unconfirmed.removeWhere(removed.contains);
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
      if (_muteDirty) {
        final muted = _mutedComputerIds;
        _nativeMuteWrites = bridge.setMutedComputers(muted);
        try {
          await _nativeMuteWrites;
          if (identical(muted, _mutedComputerIds)) _muteDirty = false;
        } catch (_) {
          message = 'Cloud notification settings could not be saved';
          notifyListeners();
          return;
        }
      }
      if (!_current(generation)) return;
      if (state.consent &&
          message == 'Cloud notification settings could not be saved') {
        message = null;
      }
      checked = true;
      notifyListeners();
      if (!_current(generation)) return;
      // Signing in (including restoring a saved account) enables cloud alerts.
      // Native window/permission checks still decide whether activation can run.
      final account = _accountIdentity;
      if (account != null &&
          _foreground &&
          state.interactive &&
          !state.consent &&
          _activationAttempts < 6) {
        _activationAttempts++;
        try {
          final activated = await bridge.setConsent(true, state.noticeVersion);
          if (_disposed || _accountIdentity != account || !_foreground) return;
          if (activated.consent &&
              !activated.allowed &&
              activated.interactive) {
            await bridge.requestPermission();
          }
          // Saving native state may itself invalidate this polling generation.
          if (!_current(generation)) return;
          state = await bridge.state();
          if (!_current(generation)) return;
          if (message == 'Cloud notification settings could not be saved') {
            message = null;
          }
        } catch (_) {
          if (!_current(generation)) return;
          message = 'Cloud notification settings could not be saved';
        }
      }
      final tap = state.directAllowed ? await bridge.takeTap() : null;
      if (tap != null && !_disposed) {
        pendingTap = tap;
        notifyListeners();
      }
      if (!_current(generation)) return;
      for (final computer in List.of(_computers)) {
        if (!_current(generation)) return;
        try {
          if (!await repository.cloudAccountEnabled(computer)) {
            _registrations.remove(computer.id);
            _attempts.remove(computer.id);
            _unconfirmed.remove(computer.id);
            continue;
          }
          final active = await repository.cloudEnabled(computer);
          final muted = _mutedComputerIds.contains(computer.id);
          final registrationState = muted
              ? CloudPushState(
                  supported: state.supported,
                  configured: state.configured,
                  allowed: state.allowed,
                  consent: state.consent,
                  interactive: state.interactive,
                  noticeVersion: state.noticeVersion,
                  pushStatus: state.pushStatus,
                  platform: state.platform,
                  appId: state.appId,
                )
              : state;
          if (!active && registrationState.enabled) continue;
          if (!_current(generation)) return;
          final registrationKey = _registrationKey(computer);
          if (_registrations[computer.id] != registrationKey) {
            final revisions = _attempts.putIfAbsent(computer.id, () => {});
            revisions.removeWhere((revision, _) => revision != registrationKey);
            final attempts = revisions[registrationKey] ?? 0;
            if (attempts < 6) {
              revisions[registrationKey] = attempts + 1;
              try {
                await repository.registerCloudPush(computer, registrationState);
                if (!_current(generation)) return;
                _registrations[computer.id] = registrationKey;
                _unconfirmed.remove(computer.id);
              } catch (_) {
                _unconfirmed.add(computer.id);
                // Vendor registration failure must not block authenticated direct receipts.
              }
            }
          }
          if (!_current(generation)) return;
          // Extension/JNI receipts already exist durably; never ACK an outer push envelope.
          if (!active) continue;
          await _reconcile(computer, generation);
          if (sharedFeed ||
              !_foreground ||
              !state.directAllowed ||
              !_current(generation)) {
            continue;
          }
          final batch = await repository.notificationEvents(computer);
          if (_current(generation)) await deliverBatch(computer, batch);
        } catch (_) {
          // Offline sources and failed durable writes cannot trigger commands or synthetic alerts.
        }
      }
      if (!_current(generation)) return;
      if (_unconfirmed.isNotEmpty) {
        message = 'Server notification settings could not be confirmed';
      } else if (message ==
          'Server notification settings could not be confirmed') {
        message = null;
      }
      notifyListeners();
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

  Future<void> deliverBatch(Computer computer, NotificationBatch batch) async {
    final generation = _generation;
    if (!_ready ||
        !_current(generation) ||
        !_foreground ||
        !state.directAllowed ||
        !batch.enabled ||
        batch.scope.isEmpty ||
        !_computers.contains(computer)) {
      return;
    }
    await _nativeMuteWrites;
    if (_muteDirty || !_current(generation)) return;
    await bridge.directBatch(computer.id, batch);
    if (!_current(generation)) return;
    await _reconcile(computer, generation);
    if (_current(generation)) {
      await repository.acknowledgeCloudPush(computer, []);
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
