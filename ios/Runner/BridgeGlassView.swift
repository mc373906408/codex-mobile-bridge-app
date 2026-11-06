import Flutter
import UIKit

/// Decoration only: Flutter retains all text, semantics and control actions.
final class BridgeGlassViewFactory: NSObject, FlutterPlatformViewFactory {
  static var supported: Bool {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) { return true }
    #endif
    return false
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    BridgeGlassView(frame: frame, arguments: args as? [String: Any] ?? [:])
  }
}

final class BridgeGlassView: NSObject, FlutterPlatformView {
  let effectView: UIVisualEffectView

  init(frame: CGRect, arguments: [String: Any]) {
    let effect: UIVisualEffect
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      // Never lower UIVisualEffectView.alpha: the system owns translucency.
      effect = UIGlassEffect(style: .clear)
    } else {
      effect = UIBlurEffect(style: .systemUltraThinMaterial)
    }
    #else
    effect = UIBlurEffect(style: .systemUltraThinMaterial)
    #endif
    effectView = UIVisualEffectView(effect: effect)
    effectView.frame = frame
    super.init()
    let requestedRadius = (arguments["radius"] as? NSNumber)?.doubleValue ?? 24
    let radius = requestedRadius.isFinite ? max(0, min(200, requestedRadius)) : 24
    effectView.layer.cornerRadius = CGFloat(radius)
    effectView.layer.cornerCurve = .continuous
    effectView.clipsToBounds = true
    effectView.backgroundColor = .clear
    effectView.isUserInteractionEnabled = false
    effectView.isAccessibilityElement = false
    effectView.accessibilityElementsHidden = true
    effectView.overrideUserInterfaceStyle = (arguments["dark"] as? Bool ?? false) ? .dark : .light
  }

  func view() -> UIView { effectView }
}
