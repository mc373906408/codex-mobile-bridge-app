import 'dart:async';

import 'package:bridge_mobile/privacy/umeng_test_consent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_umeng_consent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unknown versions and non-test devices cannot supply consent', () {
    for (final version in [null, 'lenovo-upush-test-v1', 'older-notice', '']) {
      final state = UmengTestConsentState.fromMap({
        'eligible': true,
        'interactive': true,
        'noticeVersion': version,
        'decision': 'accepted',
      });
      expect(state.accepted, isFalse);
      expect(state.eligible, isFalse);
    }
    final state = UmengTestConsentState.fromMap({
      'eligible': false,
      'interactive': true,
      'noticeVersion': umengTestNoticeVersion,
      'decision': 'accepted',
    });
    expect(state.accepted, isFalse);
    expect(state.interactive, isFalse);
  });

  test('unknown stored decisions are pending, never accepted', () {
    final state = UmengTestConsentState.fromMap({
      'eligible': true,
      'interactive': true,
      'noticeVersion': umengTestNoticeVersion,
      'decision': true,
    });
    expect(state.accepted, isFalse);
    expect(state.needsDecision, isTrue);
  });

  test('a token is copyable only after registration and current consent', () {
    for (final decision in ['pending', 'declined', 'accepted']) {
      for (final status in ['off', 'registering', 'registered', 'unknown']) {
        final state = UmengTestConsentState.fromMap({
          'eligible': true,
          'interactive': true,
          'noticeVersion': umengTestNoticeVersion,
          'decision': decision,
          'pushStatus': status,
          'hasDeviceToken': true,
          'deviceToken': 'must-not-cross-the-state-contract',
        });
        expect(
          state.canCopyToken,
          decision == 'accepted' && status == 'registered',
        );
        if (decision != 'accepted') expect(state.pushStatus, 'off');
      }
    }
  });

  test(
    'token copy is foreground-only and never returns a token to Dart',
    () async {
      final bridge = FakeUmengTestConsentBridge();
      final controller = UmengTestConsentController(bridge);
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(await controller.copyPushToken(), isFalse);
      expect(bridge.copies, 0);
      bridge.current = const UmengTestConsentState(
        eligible: true,
        interactive: true,
        decision: 'accepted',
        pushStatus: 'registered',
        hasDeviceToken: true,
      );
      await controller.refresh();
      expect(await controller.copyPushToken(), isTrue);
      expect(bridge.copies, 1);
      bridge.copyError = StateError('PRIVATE-TOKEN');
      expect(await controller.copyPushToken(), isFalse);
      expect(controller.message, isNot(contains('PRIVATE-TOKEN')));
      bridge.current = const UmengTestConsentState(
        eligible: true,
        decision: 'accepted',
        pushStatus: 'registered',
        hasDeviceToken: true,
      );
      await controller.refresh();
      expect(await controller.copyPushToken(), isFalse);
      expect(bridge.copies, 2);
    },
  );

  test(
    'initialization reads only and does not choose on behalf of the user',
    () async {
      final bridge = FakeUmengTestConsentBridge();
      final controller = UmengTestConsentController(bridge);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.initialize();
      expect(bridge.binds, 1);
      expect(bridge.choices, isEmpty);
      expect(controller.state.needsDecision, isTrue);
    },
  );

  test('unsupported platforms do not call a native channel', () async {
    final bridge = FakeUmengTestConsentBridge()..supported = false;
    final controller = UmengTestConsentController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.refresh();
    expect(await controller.decide(accept: true), isFalse);
    expect(bridge.binds + bridge.reads + bridge.choices.length, 0);
  });

  test('only an explicit successful write records a choice', () async {
    final bridge = FakeUmengTestConsentBridge();
    final controller = UmengTestConsentController(bridge);
    await controller.initialize();
    expect(await controller.decide(accept: true), isTrue);
    expect(controller.state.accepted, isTrue);
    controller.dispose();
    final restored = UmengTestConsentController(bridge);
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.state.accepted, isTrue);
    expect(await restored.decide(accept: false), isTrue);
    expect(restored.state.decision, 'declined');
    expect(bridge.choices, ['accepted', 'declined']);
  });

  test(
    'failed saves do not present a grant or expose a native error',
    () async {
      final bridge = FakeUmengTestConsentBridge()
        ..writeError = StateError('PRIVATE');
      final controller = UmengTestConsentController(bridge);
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(await controller.decide(accept: true), isFalse);
      expect(controller.state.accepted, isFalse);
      expect(controller.message, isNot(contains('PRIVATE')));
      expect(controller.busy, isFalse);
    },
  );

  test('failed reads discard a stale in-memory grant', () async {
    final bridge = FakeUmengTestConsentBridge();
    final controller = UmengTestConsentController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.decide(accept: true);
    bridge.readError = StateError('PRIVATE');
    await controller.refresh();
    expect(controller.state.accepted, isFalse);
    expect(controller.message, isNot(contains('PRIVATE')));
  });

  test('a delayed old read cannot undo a newer withdrawal', () async {
    final bridge = FakeUmengTestConsentBridge();
    final controller = UmengTestConsentController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    final gate = Completer<UmengTestConsentState>();
    bridge.onRead = () => gate.future;
    final reading = controller.refresh();
    await controller.decide(accept: false);
    gate.complete(
      const UmengTestConsentState(
        eligible: true,
        interactive: true,
        decision: 'accepted',
      ),
    );
    await reading;
    expect(controller.state.decision, 'declined');
  });

  test(
    'native changes during a decision are refreshed after the reply',
    () async {
      final bridge = FakeUmengTestConsentBridge();
      final controller = UmengTestConsentController(bridge);
      addTearDown(controller.dispose);
      await controller.initialize();
      final gate = Completer<UmengTestConsentState>();
      bridge.onWrite = (_) => gate.future;
      final saving = controller.decide(accept: true);
      bridge.current = const UmengTestConsentState(
        eligible: true,
        interactive: true,
        decision: 'accepted',
        pushStatus: 'registered',
        hasDeviceToken: true,
      );
      bridge.onChanged!();
      gate.complete(
        const UmengTestConsentState(
          eligible: true,
          interactive: true,
          decision: 'accepted',
          pushStatus: 'registering',
        ),
      );
      expect(await saving, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.canCopyToken, isTrue);
      expect(bridge.reads, 2);
    },
  );

  test('background and ineligible contexts cannot record a decision', () async {
    for (final state in [
      const UmengTestConsentState(eligible: true),
      const UmengTestConsentState(interactive: true),
    ]) {
      final bridge = FakeUmengTestConsentBridge()..current = state;
      final controller = UmengTestConsentController(bridge);
      await controller.initialize();
      expect(await controller.decide(accept: true), isFalse);
      expect(bridge.choices, isEmpty);
      controller.dispose();
    }
  });

  test(
    'concurrent clicks record only one decision and disposal is safe',
    () async {
      final bridge = FakeUmengTestConsentBridge();
      final controller = UmengTestConsentController(bridge);
      await controller.initialize();
      final gate = Completer<UmengTestConsentState>();
      bridge.onWrite = (_) => gate.future;
      final writing = controller.decide(accept: true);
      expect(await controller.decide(accept: false), isFalse);
      controller.dispose();
      gate.complete(
        const UmengTestConsentState(
          eligible: true,
          interactive: true,
          decision: 'accepted',
        ),
      );
      expect(await writing, isFalse);
      expect(bridge.choices, ['accepted']);
    },
  );

  test(
    'the native contract sends only the notice and explicit decision',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel(
        'dev.waken.bridge_mobile/umeng_test_consent',
      );
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {
          'eligible': true,
          'interactive': true,
          'noticeVersion': umengTestNoticeVersion,
          'decision': call.method == 'decide'
              ? (call.arguments as Map)['decision']
              : 'pending',
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final bridge = AndroidUmengTestConsentBridge();
      await bridge.state();
      expect((await bridge.decide('accepted')).accepted, isTrue);
      expect(calls.map((call) => call.method), ['state', 'decide']);
      expect(calls.last.arguments, {
        'noticeVersion': umengTestNoticeVersion,
        'decision': 'accepted',
      });
      await bridge.copyPushToken();
      expect(calls.last.method, 'copyPushToken');
      expect(calls.last.arguments, isNull);
    },
  );
}
