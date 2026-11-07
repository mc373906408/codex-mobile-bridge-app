import 'package:bridge_mobile/notifications/cloud_notification_status.dart';
import 'package:bridge_mobile/notifications/cloud_push_bridge.dart';
import 'package:bridge_mobile/data/bridge_types.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_cloud.dart';

const enabledPush = CloudPushState(
  configured: true,
  allowed: true,
  consent: true,
  interactive: true,
  platform: 'umeng',
  appId: 'matching-app',
  token: 'opaque-token',
);
const pushCapabilities = CloudCapabilities(
  mode: 'hosted',
  login: 'email',
  registration: true,
  entitlementRequired: true,
  umeng: true,
  apns: false,
  umengAppId: 'matching-app',
  apnsAppId: '',
);

void main() {
  CloudNotificationStatus status({
    CloudCapabilities? server = hostedCapabilities,
    CloudPushState state = enabledPush,
    bool checked = true,
    bool signedIn = true,
    bool registered = true,
  }) => CloudNotificationStatus(
    capabilities: server,
    state: state,
    checked: checked,
    signedIn: signedIn,
    registered: registered,
    serviceActive: true,
  );

  test('device push configuration cannot override disabled server push', () {
    expect(
      status().backgroundText,
      'Background push is not configured on this server',
    );
    expect(status().directText, 'Available while the app can run');
  });
  test('unknown capabilities do not claim push is enabled', () {
    expect(
      status(server: null).backgroundText,
      'Background push cannot be confirmed',
    );
  });
  test('consent, permission, login, matching app and registration are all required', () {
    expect(
      status(
        server: pushCapabilities,
        state: const CloudPushState(),
      ).directText,
      'Not enabled; your consent is required',
    );
    expect(
      status(
        server: pushCapabilities,
        state: const CloudPushState(consent: true),
      ).directText,
      'System notification permission is required',
    );
    expect(
      status(server: pushCapabilities, signedIn: false).backgroundText,
      'Sign in and pair a computer to receive notifications',
    );
    expect(
      status(server: pushCapabilities, registered: false).backgroundText,
      'Waiting for private push registration',
    );
    expect(
      status(
        server: pushCapabilities,
        state: const CloudPushState(
          configured: true,
          allowed: true,
          consent: true,
          platform: 'umeng',
          appId: 'different-app',
          token: 'token',
        ),
      ).backgroundText,
      'Push app configuration does not match this server',
    );
    expect(
      status(server: pushCapabilities).backgroundText,
      'Background push is enabled',
    );
  });
  test('SDK-free builds describe direct updates separately', () {
    final sdkFree = status(
      server: pushCapabilities,
      state: const CloudPushState(allowed: true, consent: true),
    );
    expect(sdkFree.directText, 'Available while the app can run');
    expect(
      sdkFree.backgroundText,
      'Background push is not configured in this build',
    );
  });
  test(
    'expired or unconfirmed service does not claim notification availability',
    () {
      final expired = CloudNotificationStatus(
        capabilities: pushCapabilities,
        state: enabledPush,
        checked: true,
        signedIn: true,
        registered: true,
        serviceActive: false,
      );
      final unknown = CloudNotificationStatus(
        capabilities: pushCapabilities,
        state: enabledPush,
        checked: true,
        signedIn: true,
        registered: true,
      );
      final noComputer = CloudNotificationStatus(
        capabilities: pushCapabilities,
        state: enabledPush,
        checked: true,
        signedIn: true,
        registered: true,
        serviceActive: true,
        hasComputer: false,
      );
      expect(expired.directText, 'Service unavailable');
      expect(expired.backgroundText, 'Service unavailable');
      expect(
        unknown.backgroundText,
        'Notification availability cannot be confirmed',
      );
      expect(noComputer.directText, 'Pair a computer to receive notifications');
      expect(
        noComputer.backgroundText,
        'Pair a computer to receive notifications',
      );
    },
  );
}
