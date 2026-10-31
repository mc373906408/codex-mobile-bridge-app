import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../src/rust/api/types.dart';
import 'notification_bridge.dart';

abstract interface class CloudPreviewStorage {
  Future<void> save(String computerId, String credentials);
  Future<void> remove(String computerId);
}

class CloudPushState {
  const CloudPushState({
    this.supported = true,
    this.configured = false,
    this.allowed = false,
    this.consent = false,
    this.interactive = false,
    this.noticeVersion = 'cloud-notifications-v1',
    this.pushStatus = 'off',
    this.platform = '',
    this.appId = '',
    this.token = '',
  });
  final bool supported, configured, allowed, consent, interactive;
  final String platform, appId, token, noticeVersion, pushStatus;
  bool get directAllowed => supported && allowed && consent;
  bool get enabled =>
      supported && configured && allowed && consent && token.isNotEmpty;
  String get revision =>
      '$supported\u0000$configured\u0000$allowed\u0000$consent\u0000$noticeVersion\u0000$platform\u0000$appId\u0000$token';
  factory CloudPushState.parse(Map<Object?, Object?> value) => CloudPushState(
    supported: value['supported'] == true,
    configured: value['configured'] == true,
    allowed: value['allowed'] == true,
    consent: value['consent'] == true,
    interactive: value['interactive'] == true,
    noticeVersion: value['noticeVersion'] as String? ?? '',
    pushStatus: value['pushStatus'] as String? ?? 'off',
    platform: value['platform'] as String? ?? '',
    appId: value['appId'] as String? ?? '',
    token: value['token'] as String? ?? '',
  );
}

abstract interface class CloudPushBridge {
  bool get supported;
  void bind(VoidCallback changed);
  Future<CloudPushState> state();
  Future<bool> requestPermission();
  Future<CloudPushState> setConsent(bool enabled, String noticeVersion);
  Future<void> directBatch(String computerId, NotificationBatch batch);
  Future<List<String>> pendingReceipts(String computerId);
  Future<void> markAcknowledged(String computerId, List<String> ids);
  Future<NotificationTap?> takeTap();
  void dispose();
}

abstract interface class CloudPushRepository {
  Future<bool> cloudEnabled(Computer computer);
  Future<NotificationBatch> notificationEvents(Computer computer);
  Future<void> registerCloudPush(Computer computer, CloudPushState state);
  Future<void> acknowledgeCloudPush(Computer computer, List<String> ids);
}

class NativeCloudPreviewStorage
    implements CloudPreviewStorage, CloudPushBridge {
  static const channel = MethodChannel('dev.waken.bridge_mobile/cloud_push');
  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  @override
  void bind(VoidCallback changed) {
    if (supported) {
      channel.setMethodCallHandler((_) async {
        changed();
      });
    }
  }

  @override
  Future<CloudPushState> state() async => supported
      ? CloudPushState.parse(
          await channel.invokeMapMethod<Object?, Object?>('state') ?? {},
        )
      : const CloudPushState(supported: false);
  @override
  Future<bool> requestPermission() async =>
      supported &&
      (await channel.invokeMethod<bool>('requestPermission') ?? false);
  @override
  Future<CloudPushState> setConsent(bool enabled, String noticeVersion) async =>
      CloudPushState.parse(
        await channel.invokeMapMethod<Object?, Object?>('setConsent', {
              'enabled': enabled,
              'noticeVersion': noticeVersion,
            }) ??
            {},
      );
  @override
  Future<void> directBatch(String computerId, NotificationBatch batch) =>
      channel.invokeMethod('directBatch', {
        'computerId': computerId,
        'scope': batch.scope,
        'events': [
          for (final event in batch.events)
            if (event.notificationId != null && event.expiresAt != null)
              {
                'notificationId': event.notificationId!,
                'eventId': event.id,
                'expiresAt': event.expiresAt!,
                'kind': event.kind,
              },
        ],
      });
  @override
  Future<List<String>> pendingReceipts(String computerId) async =>
      await channel.invokeListMethod<String>('pendingReceipts', {
        'computerId': computerId,
      }) ??
      [];
  @override
  Future<void> markAcknowledged(String computerId, List<String> ids) => channel
      .invokeMethod('markAcknowledged', {'computerId': computerId, 'ids': ids});
  @override
  Future<NotificationTap?> takeTap() async =>
      NotificationTap.parse(await channel.invokeMethod<Object?>('takeTap'));
  @override
  void dispose() {
    if (supported) channel.setMethodCallHandler(null);
  }

  @override
  Future<void> save(String computerId, String credentials) async {
    if (supported) {
      await channel.invokeMethod<void>('savePreview', {
        'computerId': computerId,
        'credentials': credentials,
      });
    }
  }

  @override
  Future<void> remove(String computerId) async {
    if (supported) {
      await channel.invokeMethod<void>('removePreview', {
        'computerId': computerId,
      });
    }
  }
}
