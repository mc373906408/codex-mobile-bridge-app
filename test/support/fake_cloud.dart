import 'dart:async';
import 'dart:convert';

import 'package:bridge_mobile/data/cloud_accounts.dart';
import 'package:bridge_mobile/data/cloud_server.dart';
import 'package:bridge_mobile/notifications/cloud_push_bridge.dart';
import 'package:bridge_mobile/notifications/notification_bridge.dart';
import 'package:bridge_mobile/src/rust/api/types.dart';
import 'package:flutter/foundation.dart';

import 'fake_repository.dart';

const cloudAccountId = '00000000-0000-4000-8000-000000000001';
const alternateCloudAccountId = '00000000-0000-4000-8000-000000000002';
const selfhostOrigin = 'https://private.example:8787';
const hostedCapabilities = CloudCapabilities(
  mode: 'hosted',
  login: 'email',
  registration: true,
  entitlementRequired: true,
  umeng: false,
  apns: false,
  umengAppId: '',
  apnsAppId: '',
  automaticDiscovery: true,
);
const selfhostCapabilities = CloudCapabilities(
  mode: 'selfhost',
  login: 'username',
  registration: false,
  entitlementRequired: false,
  umeng: false,
  apns: false,
  umengAppId: '',
  apnsAppId: '',
  automaticDiscovery: true,
);
const activeEntitlement = CloudEntitlement(
  active: true,
  required_: true,
  expiresAt: '2030-01-02T03:04:00Z',
);
const selfhostEntitlement = CloudEntitlement(
  active: true,
  required_: false,
  expiresAt: null,
);

Computer cloudComputer({
  String origin = officialCloudOrigin,
  String accountId = cloudAccountId,
  String id = 'cloud-computer',
  String name = 'Cloud studio',
}) => Computer(
  id: id,
  name: name,
  baseUrl: origin,
  connectionType: ConnectionType.relay,
  relay: RelayConnection(
    origin: origin,
    accountId: accountId,
    gatewayId: 'gateway',
    bindingId: id,
    desktopPublicKey: 'desktop-key',
  ),
);

CloudGateway cloudGateway(String origin) => CloudGateway(
  origin: origin,
  id: 'gateway-original',
  name: 'Cloud studio',
  controlPublicKey: 'desktop-control-key',
  online: true,
);

class FakeCloudVault implements CloudVault {
  final values = <String, String>{};
  final reads = <String>[];
  final writes = <String>[];
  bool Function(String key)? failWrite, failRead;
  Future<void> Function(String key)? beforeWrite;
  @override
  Future<String?> read(String key) async {
    reads.add(key);
    if (failRead?.call(key) == true) {
      throw StateError('Secure credential storage is unavailable');
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    await beforeWrite?.call(key);
    if (failWrite?.call(key) == true) {
      throw StateError('Secure credential storage is unavailable');
    }
    values[key] = value;
  }
}

class FakeCloudApi implements CloudApi {
  final capabilityOrigins = <String>[];
  final credentialOrigins = <String>[];
  final loginOrigins = <String>[];
  final logoutOrigins = <String>[];
  Future<CloudCapabilities> Function(String)? onCapabilities;
  Future<CloudEntitlement> Function(String)? onEntitlement;
  Future<CloudLogin> Function(String, String, String)? onLogin;
  Future<void> Function(String)? onLogout;
  Future<List<CloudDiscoveredDevice>> Function(String, String)? onDevices;
  int deviceReads = 0, discoveryPreparations = 0;
  final Set<Completer<List<CloudDiscoveredDevice>>> _deviceReadCancellations =
      {};
  int entitlements = 0;

  @override
  String canonicalOrigin(String value) {
    if (!RegExp(r'^https?://[a-z0-9.-]+(?::[1-9][0-9]*)?$').hasMatch(value) ||
        (value.startsWith('https://') && value.endsWith(':443')) ||
        (value.startsWith('http://') && value.endsWith(':80'))) {
      throw StateError('invalid origin');
    }
    return value;
  }

  @override
  Future<CloudCapabilities> capabilities(String origin) async {
    capabilityOrigins.add(origin);
    if (onCapabilities != null) return onCapabilities!(origin);
    return origin == officialCloudOrigin
        ? hostedCapabilities
        : selfhostCapabilities;
  }

  String credentials(String origin, String accountId, String login) =>
      jsonEncode({
        'origin': origin,
        'accountId': accountId,
        'login': login,
        'token': 'opaque-token',
      });

  @override
  Future<CloudLogin> login(
    String origin,
    String login,
    String password,
    String? saved,
  ) async {
    loginOrigins.add(origin);
    if (onLogin != null) return onLogin!(origin, login, password);
    final id = login.startsWith('alternate')
        ? alternateCloudAccountId
        : cloudAccountId;
    return CloudLogin(
      accountId: id,
      login: login,
      credentials: credentials(origin, id, login),
    );
  }

  @override
  Future<CloudCredentialState> credentialState(
    String raw,
    String origin,
    String accountId,
  ) async {
    credentialOrigins.add(origin);
    final data = jsonDecode(raw);
    if (data['origin'] != origin || data['accountId'] != accountId) {
      throw StateError('cross-server credentials');
    }
    return CloudCredentialState(
      origin: origin,
      accountId: accountId,
      login: data['login'],
      consumedCredentials: null,
    );
  }

  @override
  Future<String> refresh(String raw, String origin, String accountId) async =>
      throw StateError('unexpected refresh');
  @override
  Future<String> signedOut(String raw, String origin, String accountId) async {
    final data = jsonDecode(raw);
    return jsonEncode({...data, 'token': ''});
  }

  @override
  Future<void> logout(String raw, String origin, String accountId) async {
    logoutOrigins.add(origin);
    await onLogout?.call(origin);
  }

  @override
  Future<CloudEntitlement> entitlement(
    String raw,
    String origin,
    String accountId,
  ) async {
    entitlements++;
    if (onEntitlement != null) return onEntitlement!(origin);
    return origin == officialCloudOrigin
        ? activeEntitlement
        : selfhostEntitlement;
  }

  @override
  Future<List<CloudDiscoveredDevice>> devices(
    String raw,
    String origin,
    String accountId,
  ) async {
    deviceReads++;
    final cancellation = Completer<List<CloudDiscoveredDevice>>();
    _deviceReadCancellations.add(cancellation);
    try {
      return await Future.any([
        onDevices == null
            ? Future.value(<CloudDiscoveredDevice>[])
            : onDevices!(origin, accountId),
        cancellation.future,
      ]);
    } finally {
      _deviceReadCancellations.remove(cancellation);
    }
  }

  @override
  Future<void> cancelDeviceReads() async {
    for (final cancellation in _deviceReadCancellations.toList()) {
      if (!cancellation.isCompleted) {
        cancellation.completeError(StateError('Operation cancelled'));
      }
    }
  }

  @override
  Future<RelayEnrollment> prepareDiscovered(
    CloudDiscoveredDevice device,
    String raw,
    String deviceName,
  ) async {
    discoveryPreparations++;
    final data = jsonDecode(raw);
    return RelayEnrollment(
      computer: Computer(
        id: device.bindingId,
        name: device.gateway.name,
        baseUrl: device.gateway.origin,
        connectionType: ConnectionType.relay,
        relay: RelayConnection(
          origin: device.gateway.origin,
          accountId: data['accountId'],
          gatewayId: device.gateway.id,
          bindingId: device.bindingId,
          desktopPublicKey: device.gateway.controlPublicKey,
        ),
      ),
      accountCredentials: raw,
      bindingCredentials: 'opaque-discovered-binding',
      mobileControlPublicKey: 'phone-control-key',
      mobilePreviewPublicKey: 'phone-preview-key',
    );
  }
}

class FakeCloudRepository extends FakeRepository
    implements CloudRepository, CloudPushRepository {
  FakeCloudRepository() {
    cloudAccounts = CloudAccountManager(
      vault: vault,
      api: api,
      onDisabled: (account) async => disabledScopes.add(account.scope),
    );
  }
  final vault = FakeCloudVault();
  final api = FakeCloudApi();
  final disabledScopes = <String>[];
  @override
  late final CloudAccountManager cloudAccounts;
  int discoveryCancellations = 0;
  final suspendedRelays = <String>[];
  final relayAccess = <String, bool>{};
  final savedSafetyCodes = <String, String>{};
  Future<Computer?> Function(
    CloudAccountRef,
    CloudDiscoveredDevice,
    bool Function(),
  )?
  onEnsureDiscovered;
  @override
  Future<Computer?> ensureDiscovered(
    CloudAccountRef account,
    CloudDiscoveredDevice device, {
    required bool Function() current,
  }) async {
    if (onEnsureDiscovered != null) {
      return onEnsureDiscovered!(account, device, current);
    }
    if (!current()) return null;
    final existing = savedComputers
        .where(
          (computer) =>
              computer.relay?.origin == account.origin &&
              computer.relay?.accountId == account.accountId &&
              computer.relay?.bindingId == device.bindingId,
        )
        .firstOrNull;
    if (existing != null) {
      if (existing.relay?.gatewayId != device.gateway.id ||
          existing.relay?.desktopPublicKey != device.gateway.controlPublicKey) {
        throw StateError(
          'Cloud device identity changed. Existing keys are kept',
        );
      }
      return existing;
    }
    if (device.status == CloudDeviceStatus.revoked) return null;
    final enrollment = await cloudAccounts.prepareDiscovered(
      account,
      device,
      'Test phone',
    );
    if (!current()) return null;
    await saveComputer(enrollment.computer);
    return enrollment.computer;
  }

  @override
  Future<void> suspendRelay(Computer computer) async {
    suspendedRelays.add(computer.id);
    relayAccess[computer.id] = false;
  }

  @override
  Future<void> resumeRelay(Computer computer, bool allowed) async {
    relayAccess[computer.id] = allowed;
  }

  @override
  Future<void> cancelDiscovery() async {
    discoveryCancellations++;
    await cloudAccounts.cancelDeviceReads();
  }

  @override
  Future<String> savedRelaySafetyCode(Computer computer) async =>
      savedSafetyCodes[computer.id] ?? '';

  int pairingChecks = 0;
  String pairingStatus = 'pending';
  @override
  Future<RelayPairingState> relayPairingState(Computer computer) async {
    pairingChecks++;
    savedSafetyCodes[computer.id] = '12345678 ABCDEF90 12345678 ABCDEF90 12345678 ABCDEF90 12345678 ABCDEF90';
    return RelayPairingState(
      status: pairingStatus,
      safetyCode: '12345678 ABCDEF90 12345678 ABCDEF90 12345678 ABCDEF90 12345678 ABCDEF90',
    );
  }

  @override
  Future<bool> cloudAccountEnabled(Computer computer) => cloudEnabled(computer);

  @override
  Future<bool> cloudEnabled(Computer computer) async =>
      computer.relay != null &&
      await cloudAccounts.enabled(
        computer.relay!.origin,
        computer.relay!.accountId,
      );
  @override
  Future<void> registerCloudPush(
    Computer computer,
    CloudPushState state,
  ) async {}
  @override
  Future<void> acknowledgeCloudPush(
    Computer computer,
    List<String> ids,
  ) async {}
}

class FakeCloudPushBridge implements CloudPushBridge {
  CloudPushState current = const CloudPushState(interactive: true);
  int consentWrites = 0, permissionRequests = 0;
  @override
  bool get supported => true;
  @override
  void bind(VoidCallback changed) {}
  @override
  Future<CloudPushState> state() async => current;
  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<CloudPushState> setConsent(bool enabled, String noticeVersion) async {
    consentWrites++;
    return current;
  }

  @override
  Future<void> directBatch(String computerId, NotificationBatch batch) async {}
  @override
  Future<List<String>> pendingReceipts(String computerId) async => [];
  @override
  Future<void> markAcknowledged(String computerId, List<String> ids) async {}
  @override
  Future<NotificationTap?> takeTap() async => null;
  @override
  void dispose() {}
}
