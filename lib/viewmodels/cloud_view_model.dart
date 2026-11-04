import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/cloud_accounts.dart';
import '../data/cloud_server.dart';
import '../src/rust/api/types.dart';
import 'bridge_view_model.dart';

enum CloudServiceStatus {
  checking,
  signedOut,
  active,
  unavailable,
  selfHosted,
  unknown,
}

class CloudComputerState {
  const CloudComputerState({
    required this.device,
    required this.computer,
    this.pairing,
    this.error,
  });
  final CloudDiscoveredDevice device;
  final Computer computer;
  final RelayPairingState? pairing;
  final Object? error;
  bool get verified => pairing?.safetyCode.isNotEmpty == true;
  bool get allowed =>
      device.status == CloudDeviceStatus.active &&
      pairing?.status == 'active' &&
      verified &&
      error == null;
}

class CloudViewModel extends ChangeNotifier {
  CloudViewModel({required this.accounts, required this.bridge});

  final CloudAccountManager accounts;
  final BridgeViewModel bridge;
  static const _selectionKey = 'bridge.cloud.selection.v1';
  String origin = officialCloudOrigin;
  CloudAccountRef? _selected;
  String? _selectedScope;
  CloudCapabilities? capabilities;
  CloudEntitlement? entitlement;
  Object? operationError, capabilityError, entitlementError, storageError;
  bool initialized = false, loading = false, busy = false;
  bool _disposed = false, _foreground = true;
  bool _selectionLoaded = false;
  int _generation = 0;
  Future<void>? _initializing, _refresh;
  Future<void>? _discovery;
  Timer? _discoveryTimer;
  int _discoveryGeneration = 0, _discoveryFailures = 0;
  bool _syncRequested = false;
  List<CloudComputerState> devices = [];
  Object? discoveryError;
  bool discovering = false;
  final Stopwatch _serviceClock = Stopwatch()..start();
  int _nextServiceRead = 0;

  CloudAccountRef? get account => _selected?.enabled == true ? _selected : null;
  String get savedLogin => _selected?.login ?? '';
  bool get signedIn => account != null;
  bool get official => origin == officialCloudOrigin;
  bool get canManage =>
      initialized &&
      storageError == null &&
      !busy &&
      bridge.initialized &&
      !bridge.busy &&
      !bridge.loading &&
      bridge.foreground;
  bool get canSignIn => canManage && capabilities != null;
  Object? get error =>
      operationError ??
      storageError ??
      capabilityError ??
      entitlementError ??
      discoveryError;

  CloudServiceStatus get serviceStatus {
    if (loading || !initialized) return CloudServiceStatus.checking;
    return _verifiedServiceStatus;
  }

  CloudServiceStatus get _verifiedServiceStatus {
    if (capabilities == null || storageError != null) {
      return CloudServiceStatus.unknown;
    }
    if (!signedIn) return CloudServiceStatus.signedOut;
    final service = entitlement;
    if (service == null) return CloudServiceStatus.unknown;
    if (!const {'hosted', 'selfhost'}.contains(capabilities?.mode)) {
      return CloudServiceStatus.unknown;
    }
    if (!service.required_ &&
        service.active &&
        capabilities?.mode == 'selfhost' &&
        capabilities?.entitlementRequired == false) {
      return CloudServiceStatus.selfHosted;
    }
    if (service.required_ != capabilities?.entitlementRequired) {
      return CloudServiceStatus.unknown;
    }
    return service.active
        ? CloudServiceStatus.active
        : CloudServiceStatus.unavailable;
  }

  String get serviceStatusText => switch (serviceStatus) {
    CloudServiceStatus.checking => 'Checking service status',
    CloudServiceStatus.signedOut => 'Sign in to check service status',
    CloudServiceStatus.active => 'Service active',
    CloudServiceStatus.unavailable => 'Service unavailable',
    CloudServiceStatus.selfHosted => 'No hosted service-day checks',
    CloudServiceStatus.unknown => 'Service status cannot be confirmed',
  };

  DateTime? get expiresAt => entitlement?.expiresAt == null
      ? null
      : DateTime.tryParse(entitlement!.expiresAt!);

  bool matches(Computer computer) =>
      account != null &&
      computer.relay?.origin == account!.origin &&
      computer.relay?.accountId == account!.accountId;

  CloudComputerState? deviceState(Computer computer) => matches(computer)
      ? devices
            .where(
              (state) => state.device.bindingId == computer.relay?.bindingId,
            )
            .firstOrNull
      : null;

  bool authorized(Computer computer) =>
      discoveryError == null && deviceState(computer)?.allowed == true;
  bool canConnect(Computer computer) =>
      _foreground &&
      bridge.foreground &&
      authorized(computer) &&
      deviceState(computer)?.device.gateway.online == true &&
      const {
        CloudServiceStatus.active,
        CloudServiceStatus.selfHosted,
      }.contains(serviceStatus);

  void _invalidateDiscovery({bool clear = true}) {
    ++_discoveryGeneration;
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _syncRequested = false;
    discovering = false;
    if (clear) {
      devices = [];
      discoveryError = null;
    }
    final repository = bridge.repository;
    if (repository is CloudRepository) {
      unawaited((repository as CloudRepository).cancelDiscovery());
    }
  }

  Future<void> syncDevices() {
    if (_disposed ||
        !initialized ||
        !bridge.initialized ||
        busy ||
        !_foreground ||
        !bridge.foreground ||
        account == null) {
      return Future<void>.value();
    }
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    if (_discovery != null) {
      _syncRequested = true;
      return _discovery!;
    }
    final generation = _discoveryGeneration;
    final selected = account!;
    final task = _syncDevices(generation, selected);
    _discovery = task;
    if (_serviceClock.elapsedMilliseconds >= _nextServiceRead &&
        _refresh == null) {
      unawaited(refresh());
    }
    return task.whenComplete(() {
      if (identical(_discovery, task)) _discovery = null;
      if (_disposed || !_foreground || !bridge.foreground || account == null) {
        return;
      }
      final immediate = _syncRequested || generation != _discoveryGeneration;
      _syncRequested = false;
      final seconds = immediate
          ? 0
          : (3 * (1 << _discoveryFailures.clamp(0, 4))).clamp(3, 30);
      _discoveryTimer = Timer(
        Duration(seconds: seconds),
        () => unawaited(syncDevices()),
      );
    });
  }

  Future<void> _syncDevices(int generation, CloudAccountRef selected) async {
    bool current() =>
        !_disposed &&
        generation == _discoveryGeneration &&
        _foreground &&
        bridge.foreground &&
        account?.scope == selected.scope;
    final repository = bridge.repository;
    if (repository is! CloudRepository) return;
    final cloudRepository = repository as CloudRepository;
    discovering = true;
    _notify();
    try {
      final discovered = await accounts.devices(selected);
      if (!current()) return;
      final previous = {
        for (final state in devices) state.device.bindingId: state,
      };
      final identifiers = discovered.map((device) => device.bindingId).toSet();
      for (final old in previous.values.where(
        (state) => !identifiers.contains(state.device.bindingId),
      )) {
        await cloudRepository.suspendRelay(old.computer);
        await bridge.cloudAccessChanged(old.computer, false);
      }
      if (!current()) return;
      final metadata = <CloudComputerState>[];
      for (final device in discovered) {
        final old = previous[device.bindingId];
        if (old != null && device.accessRevision < old.device.accessRevision) {
          metadata.add(old);
          continue;
        }
        final existing = bridge.computers
            .where(
              (computer) =>
                  computer.relay?.origin == selected.origin &&
                  computer.relay?.accountId == selected.accountId &&
                  computer.relay?.bindingId == device.bindingId,
            )
            .firstOrNull;
        final identityChanged =
            existing != null &&
            (existing.relay?.gatewayId != device.gateway.id ||
                existing.relay?.desktopPublicKey !=
                    device.gateway.controlPublicKey);
        metadata.add(
          CloudComputerState(
            device: device,
            computer:
                existing ??
                old?.computer ??
                Computer(
                  id: device.bindingId,
                  name: device.gateway.name,
                  baseUrl: selected.origin,
                  connectionType: ConnectionType.relay,
                  relay: RelayConnection(
                    origin: selected.origin,
                    accountId: selected.accountId,
                    gatewayId: device.gateway.id,
                    bindingId: device.bindingId,
                    desktopPublicKey: device.gateway.controlPublicKey,
                  ),
                ),
            pairing: old?.pairing,
            error: identityChanged
                ? StateError(
                    'Cloud device identity changed. Existing keys are kept',
                  )
                : null,
          ),
        );
      }
      devices = metadata;
      discoveryError = null;
      _notify();
      var failed = false;
      final updated = await Future.wait(
        metadata.map((state) async {
          if (!current()) return state;
          try {
            final computer =
                await cloudRepository.ensureDiscovered(
                  selected,
                  state.device,
                  current: current,
                ) ??
                state.computer;
            if (!current()) return state;
            final savedCode = state.pairing?.safetyCode.isNotEmpty == true
                ? state.pairing!.safetyCode
                : await cloudRepository.savedRelaySafetyCode(computer);
            if (!current()) return state;
            if (state.device.status == CloudDeviceStatus.disabled ||
                state.device.status == CloudDeviceStatus.revoked) {
              if (previous[state.device.bindingId]?.device.status !=
                  state.device.status) {
                await cloudRepository.suspendRelay(computer);
              }
              await bridge.cloudAccessChanged(computer, false);
              return CloudComputerState(
                device: state.device,
                computer: computer,
                pairing: RelayPairingState(
                  status: state.device.status.name,
                  safetyCode: savedCode,
                ),
              );
            }
            if (savedCode.isEmpty) {
              await cloudRepository.resumeRelay(computer, false);
            }
            if (!current()) return state;
            final pairing = !state.device.gateway.online
                ? RelayPairingState(
                    status: state.device.status.name,
                    safetyCode: savedCode,
                  )
                : await cloudRepository.relayPairingState(computer);
            if (!current()) return state;
            final result = CloudComputerState(
              device: state.device,
              computer: computer,
              pairing: pairing,
            );
            final serviceActive = const {
              CloudServiceStatus.active,
              CloudServiceStatus.selfHosted,
            }.contains(_verifiedServiceStatus);
            await cloudRepository.resumeRelay(
              computer,
              result.allowed && serviceActive,
            );
            await bridge.cloudAccessChanged(
              computer,
              result.allowed && serviceActive,
            );
            return result;
          } catch (error) {
            failed = true;
            if (current()) {
              // The account-scoped notification controller also retains disabled devices
              // for withdrawal. Revoke its business/read eligibility on failed discovery.
              try {
                await cloudRepository.suspendRelay(state.computer);
              } catch (_) {
                // Native preview cleanup can fail after the repository fenced authority.
              }
              await bridge.cloudAccessChanged(state.computer, false);
            }
            return CloudComputerState(
              device: state.device,
              computer: state.computer,
              pairing: state.pairing,
              error: error,
            );
          }
        }),
      );
      if (!current()) return;
      devices = updated;
      _discoveryFailures = failed ? _discoveryFailures + 1 : 0;
      await bridge.reloadComputers();
    } catch (error) {
      if (current()) {
        discoveryError = error;
        _discoveryFailures++;
        for (final state in devices) {
          try {
            await cloudRepository.suspendRelay(state.computer);
          } catch (_) {
            // The local client fence precedes optional native cleanup.
          }
          await bridge.cloudAccessChanged(state.computer, false);
        }
      }
    } finally {
      if (current()) {
        discovering = false;
        _notify();
      }
    }
  }

  String canonicalInput(String value) {
    try {
      return accounts.canonicalOrigin(cloudOriginInput(value));
    } catch (_) {
      throw StateError(
        'Invalid cloud server origin. Use a canonical HTTP or HTTPS origin without a path',
      );
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  void _invalidate() {
    ++_generation;
    _refresh = null;
    loading = false;
    capabilities = null;
    entitlement = null;
    capabilityError = null;
    entitlementError = null;
  }

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    try {
      await _restoreSelection();
    } catch (error) {
      if (!_disposed) {
        _selected = null;
        storageError = error;
      }
    } finally {
      if (!_disposed) {
        initialized = true;
        _notify();
      }
    }
    await refresh();
  }

  Future<void> _restoreSelection() async {
    final refs = await accounts.accounts();
    final raw = await accounts.vault.read(_selectionKey);
    if (_disposed) return;
    if (raw == null) {
      _selected =
          refs.where((value) => value.enabled).lastOrNull ?? refs.lastOrNull;
      origin = _selected?.origin ?? officialCloudOrigin;
      _selectedScope = _selected?.scope;
    } else {
      if (raw.length > 4096) {
        throw StateError('Cloud server selection is invalid');
      }
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.length != 2 ||
          value['origin'] is! String ||
          (value['accountId'] != null && value['accountId'] is! String)) {
        throw StateError('Cloud server selection is invalid');
      }
      origin = accounts.canonicalOrigin(value['origin'] as String);
      _selectedScope = value['accountId'] == null
          ? null
          : '$origin\u0000${value['accountId']}';
      _selected = refs.where((ref) => ref.scope == _selectedScope).firstOrNull;
    }
    storageError = null;
    _selectionLoaded = true;
  }

  Future<void> _saveSelection(String origin, CloudAccountRef? account) =>
      accounts.vault.write(
        _selectionKey,
        jsonEncode({'origin': origin, 'accountId': account?.accountId}),
      );

  Future<void> _readAccount() async {
    final refs = await accounts.accounts();
    if (_disposed) return;
    _selected = refs.where((ref) => ref.scope == _selectedScope).firstOrNull;
    storageError = null;
  }

  Future<void> refresh() {
    if (_disposed ||
        !initialized ||
        busy ||
        !_foreground ||
        !bridge.foreground) {
      return Future<void>.value();
    }
    return _refresh ??= _load(++_generation);
  }

  Future<void> _load(int generation) async {
    loading = true;
    _nextServiceRead = _serviceClock.elapsedMilliseconds + 60000;
    capabilityError = null;
    entitlementError = null;
    _notify();
    try {
      // Refresh only the explicitly selected identity, never another saved account.
      if (!_selectionLoaded) await _restoreSelection();
      if (!_current(generation)) return;
      final requestedOrigin = origin;
      final refs = await accounts.accounts();
      if (!_current(generation)) return;
      _selected = refs.where((ref) => ref.scope == _selectedScope).firstOrNull;
      storageError = null;
      final requestedAccount = account;
      await Future.wait([
        () async {
          try {
            final value = await accounts.capabilities(requestedOrigin);
            if (_current(generation)) capabilities = value;
          } catch (error) {
            if (_current(generation)) {
              capabilities = null;
              capabilityError = error;
            }
          }
        }(),
        if (requestedAccount != null)
          () async {
            try {
              final value = await accounts.entitlement(requestedAccount);
              if (_current(generation)) entitlement = value;
            } catch (error) {
              if (_current(generation)) {
                entitlement = null;
                entitlementError = error;
              }
            }
          }(),
      ]);
    } catch (error) {
      if (_current(generation)) {
        _selected = null;
        storageError = error;
      }
    } finally {
      if (_current(generation)) {
        if (capabilityError != null || entitlementError != null) {
          _nextServiceRead = _serviceClock.elapsedMilliseconds + 5000;
        }
        loading = false;
        _refresh = null;
        _notify();
        if (account != null) {
          await syncDevices();
        } else {
          _invalidateDiscovery();
        }
      }
    }
  }

  Future<bool> signIn(String login, String password) async {
    if (!canSignIn) return false;
    if (login.trim().isEmpty || password.isEmpty) {
      operationError = StateError('Enter your cloud account and password');
      _notify();
      return false;
    }
    busy = true;
    operationError = null;
    _invalidateDiscovery();
    _invalidate();
    _notify();
    var success = false;
    try {
      _selected = await bridge.cloudOperation(
        origin,
        () => accounts.signIn(origin, login.trim(), password),
        changesAccount: true,
      );
      if (_disposed) return false;
      _selectedScope = _selected?.scope;
      await _saveSelection(origin, _selected);
      success = true;
    } catch (error) {
      if (!_disposed) operationError = error;
    } finally {
      if (!_disposed) {
        try {
          await _readAccount();
        } catch (error) {
          _selected = null;
          storageError = error;
        }
        busy = false;
        _notify();
        await refresh();
      }
    }
    return success;
  }

  Future<bool> signOut() async {
    final selected = account;
    if (!canManage || selected == null) return false;
    busy = true;
    operationError = null;
    _invalidateDiscovery();
    _invalidate();
    _notify();
    var success = false;
    Object? failure;
    try {
      await bridge.cloudOperation(
        origin,
        () => accounts.signOut(selected),
        changesAccount: true,
      );
      success = true;
    } catch (error) {
      failure = error;
    } finally {
      if (!_disposed) {
        try {
          await _readAccount();
          if (failure != null) {
            operationError = signedIn
                ? failure
                : StateError(
                    'Signed out on this phone. Server logout could not be confirmed',
                  );
          }
        } catch (error) {
          _selected = null;
          storageError = error;
          success = false;
        }
        busy = false;
        _notify();
        await refresh();
      }
    }
    return success;
  }

  Future<bool> switchServer(String input) async {
    if (!canManage) return false;
    if (signedIn) {
      operationError = StateError('Sign out before changing cloud servers');
      _notify();
      return false;
    }
    String next;
    try {
      next = canonicalInput(input);
    } catch (error) {
      operationError = error;
      _notify();
      return false;
    }
    if (next == origin) return true;
    busy = true;
    operationError = null;
    _invalidateDiscovery();
    _invalidate();
    _notify();
    var success = false;
    try {
      await bridge.cloudOperation(origin, () => _saveSelection(next, null));
      if (_disposed) return false;
      origin = next;
      _selected = null;
      _selectedScope = null;
      success = true;
    } catch (error) {
      if (!_disposed) operationError = error;
    } finally {
      if (!_disposed) {
        busy = false;
        _notify();
        await refresh();
      }
    }
    return success;
  }

  void setForeground(bool value) {
    if (_disposed || _foreground == value) return;
    _foreground = value;
    _invalidateDiscovery(clear: false);
    _invalidate();
    _notify();
    if (value) unawaited(refresh());
  }

  void dismissError() {
    operationError = null;
    _notify();
  }

  @override
  void dispose() {
    _invalidateDiscovery();
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}
