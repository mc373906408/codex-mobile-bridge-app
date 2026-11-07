import '../data/bridge_types.dart';
import 'cloud_push_bridge.dart';

class CloudNotificationStatus {
  const CloudNotificationStatus({
    required this.capabilities,
    required this.state,
    required this.checked,
    required this.signedIn,
    this.registered = false,
    this.serviceActive,
    this.hasComputer = true,
  });
  final CloudCapabilities? capabilities;
  final CloudPushState state;
  final bool checked, signedIn, registered;
  final bool? serviceActive;
  final bool hasComputer;

  String get directText {
    if (!checked) return 'Checking cloud notification settings';
    if (!state.supported) {
      return 'Cloud notifications are unavailable on this device';
    }
    if (!state.consent) return 'Not enabled; your consent is required';
    if (!state.allowed) return 'System notification permission is required';
    if (!signedIn) {
      return 'Sign in and pair a computer to receive notifications';
    }
    if (!hasComputer) return 'Pair a computer to receive notifications';
    if (serviceActive != true) {
      return serviceActive == false
          ? 'Service unavailable'
          : 'Notification availability cannot be confirmed';
    }
    return 'Available while the app can run';
  }

  String get backgroundText {
    final server = capabilities;
    if (server == null) return 'Background push cannot be confirmed';
    final configured = switch (state.platform) {
      'umeng' => server.umeng,
      'apns' => server.apns,
      _ => server.umeng || server.apns,
    };
    if (!configured) return 'Background push is not configured on this server';
    if (!checked) return 'Checking cloud notification settings';
    if (!state.supported || !state.configured || state.platform.isEmpty) {
      return 'Background push is not configured in this build';
    }
    if (!state.consent) return 'Not enabled; your consent is required';
    if (!state.allowed) return 'System notification permission is required';
    if (!signedIn) {
      return 'Sign in and pair a computer to receive notifications';
    }
    if (!hasComputer) return 'Pair a computer to receive notifications';
    if (serviceActive != true) {
      return serviceActive == false
          ? 'Service unavailable'
          : 'Notification availability cannot be confirmed';
    }
    final appId = state.platform == 'umeng'
        ? server.umengAppId
        : server.apnsAppId;
    if (appId.isEmpty || appId != state.appId) {
      return 'Push app configuration does not match this server';
    }
    if (!state.enabled || !registered) {
      return 'Waiting for private push registration';
    }
    return 'Background push is enabled';
  }
}
