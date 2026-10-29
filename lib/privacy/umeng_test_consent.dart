import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const umengTestNoticeVersion = 'lenovo-upush-test-v2';

class UmengTestConsentState {
  const UmengTestConsentState({
    this.eligible = false,
    this.interactive = false,
    this.decision = 'pending',
    this.pushStatus = 'off',
    this.hasDeviceToken = false,
  });

  final bool eligible;
  final bool interactive;
  final String decision;
  final String pushStatus;
  final bool hasDeviceToken;
  bool get accepted => eligible && decision == 'accepted';
  bool get needsDecision => eligible && decision == 'pending';
  bool get canCopyToken =>
      accepted && interactive && pushStatus == 'registered' && hasDeviceToken;

  String get statusMessage => switch (pushStatus) {
    'registered' when accepted => 'U-Push registered. Real notification delivery still needs a device test.',
    'registering' when accepted => 'Registering this device with U-Push...',
    'error' when accepted =>
      'U-Push registration failed. Review test consent to retry.',
    'disabling' =>
      'Consent withdrawn. Waiting for U-Push to confirm push disabling.',
    'disable_failed' => 'U-Push disabling was not confirmed. Restart the app before another test.',
    _ when accepted => 'Test consent saved. U-Push is waiting to start.',
    _ =>
      'U-Push test notifications are off. Direct notifications are unchanged.',
  };

  factory UmengTestConsentState.fromMap(Map<Object?, Object?> value) {
    // Never accept a native grant for a notice this UI does not know how to show.
    if (value['noticeVersion'] != umengTestNoticeVersion) {
      return const UmengTestConsentState();
    }
    final eligible = value['eligible'] == true;
    final decision = value['decision'];
    final choice =
        eligible && (decision == 'accepted' || decision == 'declined')
        ? decision as String
        : 'pending';
    final status = value['pushStatus'];
    final knownStatus =
        eligible &&
        (status == 'off' ||
            status == 'disabling' ||
            status == 'disable_failed' ||
            (choice == 'accepted' &&
                (status == 'registering' ||
                    status == 'registered' ||
                    status == 'error')));
    return UmengTestConsentState(
      eligible: eligible,
      interactive: eligible && value['interactive'] == true,
      decision: choice,
      pushStatus: knownStatus ? status as String : 'off',
      hasDeviceToken:
          choice == 'accepted' &&
          status == 'registered' &&
          value['hasDeviceToken'] == true,
    );
  }
}

abstract class UmengTestConsentBridge {
  bool get supported;
  void bind(VoidCallback onChanged);
  Future<UmengTestConsentState> state();
  Future<UmengTestConsentState> decide(String decision);
  Future<void> openPrivacyDetails();
  Future<void> copyPushToken();
  void dispose();
}

class AndroidUmengTestConsentBridge implements UmengTestConsentBridge {
  static const _channel = MethodChannel(
    'dev.waken.bridge_mobile/umeng_test_consent',
  );

  @override
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void bind(VoidCallback onChanged) {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') onChanged();
    });
  }

  Future<UmengTestConsentState> _state(
    String method, [
    Object? arguments,
  ]) async => UmengTestConsentState.fromMap(
    await _channel.invokeMapMethod<Object?, Object?>(method, arguments) ?? {},
  );

  @override
  Future<UmengTestConsentState> state() => _state('state');
  @override
  Future<UmengTestConsentState> decide(String decision) => _state('decide', {
    'noticeVersion': umengTestNoticeVersion,
    'decision': decision,
  });
  @override
  Future<void> openPrivacyDetails() =>
      _channel.invokeMethod('openPrivacyDetails');
  @override
  Future<void> copyPushToken() => _channel.invokeMethod('copyPushToken');
  @override
  void dispose() {
    if (supported) _channel.setMethodCallHandler(null);
  }
}

class UmengTestConsentController extends ChangeNotifier {
  UmengTestConsentController(this.bridge);

  final UmengTestConsentBridge bridge;
  UmengTestConsentState state = const UmengTestConsentState();
  bool ready = false;
  bool busy = false;
  String? message;
  bool _disposed = false;
  bool _refreshPending = false;
  int _revision = 0;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (ready || _disposed) return;
    ready = true;
    if (!bridge.supported) return;
    bridge.bind(() => unawaited(refresh()));
    await refresh();
  }

  Future<void> refresh({bool preserveMessage = false}) async {
    if (!ready || _disposed || !bridge.supported) return;
    if (busy) {
      _refreshPending = true;
      return;
    }
    final revision = ++_revision;
    try {
      final next = await bridge.state();
      if (_disposed || revision != _revision) return;
      state = next;
      if (!preserveMessage) message = null;
    } catch (_) {
      if (_disposed || revision != _revision) return;
      state = const UmengTestConsentState();
      message = 'Could not read the test consent. Push status is unavailable.';
    }
    _notify();
  }

  Future<bool> decide({required bool accept}) async {
    if (_disposed || busy || !state.eligible || !state.interactive) {
      return false;
    }
    ++_revision;
    busy = true;
    message = null;
    _notify();
    try {
      final choice = accept ? 'accepted' : 'declined';
      final next = await bridge.decide(choice);
      if (_disposed) return false;
      if (!next.eligible || next.decision != choice) {
        throw StateError('Consent was not confirmed');
      }
      state = next;
      return true;
    } catch (_) {
      if (!_disposed) {
        state = UmengTestConsentState(
          eligible: state.eligible,
          interactive: state.interactive,
        );
        message =
            'Could not save your choice. Review the test status and try again.';
      }
      return false;
    } finally {
      _finishOperation();
    }
  }

  Future<void> openPrivacyDetails() async {
    if (_disposed || busy || !state.eligible || !state.interactive) return;
    try {
      await bridge.openPrivacyDetails();
    } catch (_) {
      message =
          'Could not open the official privacy details. Please try again.';
      _notify();
    }
  }

  Future<bool> copyPushToken() async {
    if (_disposed || busy || !bridge.supported || !state.canCopyToken) {
      return false;
    }
    busy = true;
    ++_revision;
    message = null;
    _notify();
    try {
      await bridge.copyPushToken();
      if (_disposed) return false;
      message = 'Test device token copied. Paste it only into your Umeng test console.';
      return true;
    } catch (_) {
      if (!_disposed) {
        message = 'Could not copy the test device token. Please try again.';
      }
      return false;
    } finally {
      _finishOperation();
    }
  }

  void _finishOperation() {
    busy = false;
    _notify();
    // Native registration can finish while the decision/copy method is still awaiting a reply.
    if (_refreshPending && !_disposed) {
      _refreshPending = false;
      unawaited(refresh(preserveMessage: true));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_revision;
    bridge.dispose();
    super.dispose();
  }
}
