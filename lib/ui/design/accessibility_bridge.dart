import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// UI-only accessibility signal; never shares a channel with credentials/push.
class AccessibilityBridge extends ChangeNotifier with WidgetsBindingObserver {
  AccessibilityBridge({TargetPlatform? platform, MethodChannel? channel})
    : _ios = (platform ?? defaultTargetPlatform) == TargetPlatform.iOS,
      _channel =
          channel ??
          const MethodChannel('dev.waken.bridge_mobile/accessibility');
  final bool _ios;
  final MethodChannel _channel;
  bool _disposed = false;
  bool _initialized = false;
  bool _reduceTransparency = true;
  bool _nativeGlass = false;
  bool get reduceTransparency => _ios && _reduceTransparency;
  bool get nativeGlass => _ios && _nativeGlass;

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    if (!_ios) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') await refresh();
    });
    await refresh();
  }

  Future<void> refresh() async {
    if (!_ios || _disposed) return;
    var reduce = true;
    var nativeGlass = false;
    try {
      reduce = await _channel.invokeMethod<bool>('reduceTransparency') ?? true;
      nativeGlass =
          await _channel.invokeMethod<bool>('supportsLiquidGlass') ?? false;
    } on PlatformException {
      // Fail closed to a readable, opaque surface.
    } on MissingPluginException {
      // Widget tests and older hosts have no native bridge.
    }
    if (_disposed ||
        (reduce == _reduceTransparency && nativeGlass == _nativeGlass)) {
      return;
    }
    _reduceTransparency = reduce;
    _nativeGlass = nativeGlass;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    if (_initialized) WidgetsBinding.instance.removeObserver(this);
    if (_ios && _initialized) _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
