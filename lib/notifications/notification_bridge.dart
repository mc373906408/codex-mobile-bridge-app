import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NotificationState {
  const NotificationState({
    this.supported = true,
    this.allowed = false,
    this.running = false,
    this.batteryOptimized = true,
  });

  final bool supported;
  final bool allowed;
  final bool running;
  final bool batteryOptimized;

  factory NotificationState.fromMap(Map<Object?, Object?> value) =>
      NotificationState(
        allowed: value['allowed'] == true,
        running: value['running'] == true,
        batteryOptimized: value['batteryOptimized'] == true,
      );
}

class NotificationTap {
  const NotificationTap(this.computerId, this.scope, this.eventId);

  final String computerId;
  final String scope;
  final String eventId;

  static NotificationTap? parse(Object? value) {
    if (value is! Map) return null;
    final fields = [
      'computerId',
      'scope',
      'eventId',
    ].map((key) => value[key]).toList();
    if (fields.any(
      (field) => field is! String || field.isEmpty || field.length > 256,
    )) {
      return null;
    }
    return NotificationTap(
      fields[0] as String,
      fields[1] as String,
      fields[2] as String,
    );
  }
}

abstract class NotificationBridge {
  bool get supported;
  void bind({required VoidCallback onChanged, required VoidCallback onTap});
  Future<NotificationState> state();
  Future<void> ensureListening();
  Future<bool> requestPermission();
  Future<void> configure(List<String> computers, String locale);
  Future<String?> readLedger();
  Future<void> writeLedger(String value);
  Future<void> clearComputer(String computerId);
  Future<bool> showEvent({
    required String computerId,
    required String computerName,
    required String scope,
    required String eventId,
    required String kind,
  });
  Future<void> updateStatus(int online, int total);
  Future<bool> testNotification();
  Future<void> openSettings({bool battery = false});
  Future<NotificationTap?> takeTap();
  void dispose();
}

class AndroidNotificationBridge implements NotificationBridge {
  static const _channel = MethodChannel(
    'dev.waken.bridge_mobile/notifications',
  );

  @override
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void bind({required VoidCallback onChanged, required VoidCallback onTap}) {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') onChanged();
      if (call.method == 'tap') onTap();
    });
  }

  Future<NotificationState> _state(String method, [Object? arguments]) async =>
      NotificationState.fromMap(
        await _channel.invokeMapMethod<Object?, Object?>(method, arguments) ??
            {},
      );

  @override
  Future<NotificationState> state() => supported
      ? _state('state')
      : Future.value(const NotificationState(supported: false));
  @override
  Future<void> ensureListening() => _channel.invokeMethod('ensureListening');
  @override
  Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestPermission') ?? false;
  @override
  Future<void> configure(List<String> computers, String locale) => _channel
      .invokeMethod('configure', {'computers': computers, 'locale': locale});
  @override
  Future<String?> readLedger() => _channel.invokeMethod<String>('readLedger');
  @override
  Future<void> writeLedger(String value) =>
      _channel.invokeMethod('writeLedger', value);
  @override
  Future<void> clearComputer(String computerId) =>
      _channel.invokeMethod('clearComputer', computerId);
  @override
  Future<bool> showEvent({
    required String computerId,
    required String computerName,
    required String scope,
    required String eventId,
    required String kind,
  }) async =>
      await _channel.invokeMethod<bool>('showEvent', {
        'computerId': computerId,
        'computerName': computerName,
        'scope': scope,
        'eventId': eventId,
        'kind': kind,
      }) ??
      false;
  @override
  Future<void> updateStatus(int online, int total) =>
      _channel.invokeMethod('updateStatus', {'online': online, 'total': total});
  @override
  Future<bool> testNotification() async =>
      await _channel.invokeMethod<bool>('test') ?? false;
  @override
  Future<void> openSettings({bool battery = false}) =>
      _channel.invokeMethod('settings', {'battery': battery});
  @override
  Future<NotificationTap?> takeTap() async =>
      NotificationTap.parse(await _channel.invokeMethod<Object?>('takeTap'));
  @override
  void dispose() {
    if (supported) _channel.setMethodCallHandler(null);
  }
}
