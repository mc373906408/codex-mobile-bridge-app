import 'package:bridge_mobile/l10n/strings.dart';
import 'package:bridge_mobile/notifications/cloud_push_bridge.dart';
import 'package:bridge_mobile/notifications/cloud_push_controller.dart';
import 'package:bridge_mobile/notifications/notification_bridge.dart';
import 'package:bridge_mobile/src/rust/api/types.dart';
import 'package:bridge_mobile/ui/cloud_notification_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge implements CloudPushBridge {
  bool consent = false;
  final decisions = <String>[];
  @override
  bool get supported => true;
  @override
  void bind(VoidCallback changed) {}
  @override
  Future<CloudPushState> state() async => CloudPushState(
    allowed: true,
    consent: consent,
    interactive: true,
    noticeVersion: 'cloud-umeng-push-v1',
    platform: 'umeng',
    configured: true,
  );
  @override
  Future<CloudPushState> setConsent(bool enabled, String noticeVersion) async {
    decisions.add('$enabled:$noticeVersion');
    consent = enabled;
    return state();
  }

  @override
  Future<bool> requestPermission() async => true;
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

class _Repository implements CloudPushRepository {
  @override
  Future<bool> cloudEnabled(Computer computer) async => true;
  @override
  Future<NotificationBatch> notificationEvents(Computer computer) async =>
      NotificationBatch(scope: '', enabled: false, events: const []);
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

void main() {
  testWidgets('production consent requires a disclosure and can be withdrawn', (
    tester,
  ) async {
    final bridge = _Bridge();
    final controller = CloudPushController(
      _Repository(),
      bridge,
      interval: null,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CloudNotificationSettings(
            controller: controller,
            strings: const Strings(Locale('en')),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('cloud-notification-consent')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Umeng receives a device token'),
      findsOneWidget,
    );
    expect(bridge.decisions, isEmpty);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(bridge.decisions, isEmpty);
    await tester.tap(find.byKey(const Key('cloud-notification-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('accept-cloud-notifications')));
    await tester.pumpAndSettle();
    expect(bridge.decisions, ['true:cloud-umeng-push-v1']);
    await tester.tap(find.byKey(const Key('cloud-notification-consent')));
    await tester.pumpAndSettle();
    expect(bridge.decisions.last, 'false:cloud-umeng-push-v1');
  });
}
