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
    let framed = arguments["framed"] as? Bool ?? true
    #if compiler(>=6.2)
    if !framed {
      // Full-width bars use a continuous material without a floating lens rim.
      effect = UIBlurEffect(style: .systemMaterial)
    } else if #available(iOS 26.0, *) {
      // Never lower UIVisualEffectView.alpha: the system owns translucency.
      effect = UIGlassEffect(style: arguments["style"] as? String == "regular" ? .regular : .clear)
    } else {
      effect = UIBlurEffect(style: .systemUltraThinMaterial)
    }
    #else
    effect = UIBlurEffect(style: framed ? .systemUltraThinMaterial : .systemMaterial)
    #endif
    effectView = UIVisualEffectView(effect: effect)
    effectView.frame = frame
    super.init()
    let requestedRadius = (arguments["radius"] as? NSNumber)?.doubleValue ?? 24
    let radius = requestedRadius.isFinite ? max(0, min(200, requestedRadius)) : 24
    effectView.layer.cornerRadius = framed ? CGFloat(radius) : 0
    effectView.layer.cornerCurve = .continuous
    effectView.clipsToBounds = true
    effectView.backgroundColor = .clear
    if !framed {
      // Match the surrounding themed chrome instead of keeping UIKit's gray
      // material tint. The effect still samples the backdrop at full alpha.
      let argb = (arguments["surfaceColor"] as? NSNumber)?.uint32Value ?? 0xFFFFFFFF
      effectView.contentView.backgroundColor = UIColor(
        red: CGFloat((argb >> 16) & 0xFF) / 255,
        green: CGFloat((argb >> 8) & 0xFF) / 255,
        blue: CGFloat(argb & 0xFF) / 255,
        alpha: (arguments["dark"] as? Bool ?? false) ? 0.88 : 0.90)
    }
    effectView.isUserInteractionEnabled = false
    effectView.isAccessibilityElement = false
    effectView.accessibilityElementsHidden = true
    effectView.overrideUserInterfaceStyle = (arguments["dark"] as? Bool ?? false) ? .dark : .light
  }

  func view() -> UIView { effectView }
}
