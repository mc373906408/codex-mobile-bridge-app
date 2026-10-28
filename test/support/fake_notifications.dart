import 'package:bridge_mobile/notifications/notification_bridge.dart';
import 'package:flutter/foundation.dart';

class FakeNotificationBridge implements NotificationBridge {
  @override
  bool supported = true;
  NotificationState current = const NotificationState(allowed: true);
  bool permission = true;
  bool permissionRequested = false;
  bool foreground = true;
  bool deliver = true;
  int tests = 0;
  int ensureRequests = 0;
  int permissionRequests = 0;
  Object? startError;
  String? ledger;
  List<String> computers = [];
  String locale = '';
  final List<String> shown = [];
  final List<String> cleared = [];
  VoidCallback? onChanged;
  VoidCallback? onTap;
  NotificationTap? tap;

  @override
  void bind({required VoidCallback onChanged, required VoidCallback onTap}) {
    this.onChanged = onChanged;
    this.onTap = onTap;
  }

  @override
  Future<NotificationState> state() async => current;
  @override
  Future<void> ensureListening() async {
    ensureRequests++;
    if (!foreground) return;
    if (startError case final error?) throw error;
    if (!current.allowed && !permissionRequested) await requestPermission();
    current = NotificationState(
      allowed: current.allowed,
      running: current.allowed,
      batteryOptimized: current.batteryOptimized,
    );
  }

  @override
  Future<bool> requestPermission() async {
    if (!foreground) return false;
    permissionRequests++;
    permissionRequested = true;
    current = NotificationState(
      allowed: permission,
      running: current.running && permission,
      batteryOptimized: current.batteryOptimized,
    );
    return permission;
  }

  @override
  Future<void> configure(List<String> computers, String locale) async {
    this.computers = computers;
    this.locale = locale;
  }

  @override
  Future<String?> readLedger() async => ledger;
  @override
  Future<void> writeLedger(String value) async {
    ledger = value;
  }

  @override
  Future<void> clearComputer(String computerId) async {
    cleared.add(computerId);
  }

  @override
  Future<bool> showEvent({
    required String computerId,
    required String computerName,
    required String scope,
    required String eventId,
    required String kind,
  }) async {
    if (deliver) shown.add(eventId);
    return deliver;
  }

  @override
  Future<void> updateStatus(int online, int total) async {}
  @override
  Future<bool> testNotification() async {
    tests++;
    return current.allowed;
  }

  @override
  Future<void> openSettings({bool battery = false}) async {}
  @override
  Future<NotificationTap?> takeTap() async {
    final value = tap;
    tap = null;
    return value;
  }

  @override
  void dispose() {
    onChanged = null;
    onTap = null;
  }
}
