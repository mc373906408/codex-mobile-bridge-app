import 'package:bridge_mobile/privacy/umeng_test_consent.dart';
import 'package:flutter/foundation.dart';

class FakeUmengTestConsentBridge implements UmengTestConsentBridge {
  @override
  bool supported = true;
  UmengTestConsentState current = const UmengTestConsentState(
    eligible: true,
    interactive: true,
  );
  VoidCallback? onChanged;
  Object? readError;
  Object? writeError;
  Object? detailsError;
  Object? copyError;
  Future<UmengTestConsentState> Function()? onRead;
  Future<UmengTestConsentState> Function(String)? onWrite;
  final List<String> choices = [];
  int binds = 0;
  int reads = 0;
  int details = 0;
  int copies = 0;

  @override
  void bind(VoidCallback onChanged) {
    binds++;
    this.onChanged = onChanged;
  }

  @override
  Future<UmengTestConsentState> state() async {
    reads++;
    if (readError case final error?) throw error;
    return onRead == null ? current : onRead!();
  }

  @override
  Future<UmengTestConsentState> decide(String decision) async {
    choices.add(decision);
    if (writeError case final error?) throw error;
    if (onWrite != null) return onWrite!(decision);
    current = UmengTestConsentState(
      eligible: current.eligible,
      interactive: current.interactive,
      decision: decision,
    );
    return current;
  }

  @override
  Future<void> openPrivacyDetails() async {
    details++;
    if (detailsError case final error?) throw error;
  }

  @override
  Future<void> copyPushToken() async {
    copies++;
    if (copyError case final error?) throw error;
  }

  @override
  void dispose() => onChanged = null;
}
