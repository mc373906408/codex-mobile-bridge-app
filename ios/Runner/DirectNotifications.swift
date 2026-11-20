import Flutter
import UIKit
import UserNotifications

/// Foreground direct-gateway alerts use the ordinary app container, including in the cloud build.
final class DirectNotifications {
  private let center = UNUserNotificationCenter.current()
  private let defaults = UserDefaults.standard
  private var channel: FlutterMethodChannel?
  private var pendingTap: [String: String]?
  private var requesting = false

  func bind(_ messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.waken.bridge_mobile/notifications", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }

  private func handles(_ computer: String) -> Bool {
    (defaults.stringArray(forKey: "direct.computers") ?? []).contains(computer) &&
      !(defaults.stringArray(forKey: "direct.muted") ?? []).contains(computer)
  }

  private func configured(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any], let computers = args["computers"] as? [String],
      let muted = args["mutedComputers"] as? [String] else { result(false); return }
    defaults.set(computers, forKey: "direct.computers")
    defaults.set(muted, forKey: "direct.muted")
    defaults.set(args["locale"] as? String, forKey: "direct.locale")
    result(nil)
  }

  private func permission(ensure: Bool, result: @escaping FlutterResult) {
    center.getNotificationSettings { settings in
      DispatchQueue.main.async {
        guard settings.authorizationStatus == .notDetermined, !self.requesting,
          UIApplication.shared.applicationState == .active else {
          result(CloudPushBridge.allowed(settings)); return
        }
        if ensure && !(self.defaults.stringArray(forKey: "direct.computers") ?? []).contains(where: self.handles) {
          result(false); return
        }
        self.requesting = true
        self.center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
          DispatchQueue.main.async {
            self.requesting = false
            result(granted)
            self.channel?.invokeMethod("changed", arguments: nil)
          }
        }
      }
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "state":
      center.getNotificationSettings { settings in
        let allowed = CloudPushBridge.allowed(settings)
        DispatchQueue.main.async { result(["allowed": allowed, "running": allowed]) }
      }
    case "configure": configured(call, result)
    case "ensureListening", "requestPermission": permission(ensure: call.method == "ensureListening", result: result)
    case "readLedger": result(defaults.string(forKey: "direct.ledger"))
    case "writeLedger":
      guard let value = call.arguments as? String, value.utf8.count <= 2_000_000 else { result(false); return }
      defaults.set(value, forKey: "direct.ledger")
      result(nil)
    case "takeTap":
      result(pendingTap)
      pendingTap = nil
    case "clearComputer":
      let computer = call.arguments as? String
      center.getDeliveredNotifications { notes in
        let ids = notes.filter { self.route($0.request)?["computerId"] == computer }.map { $0.request.identifier }
        self.center.removeDeliveredNotifications(withIdentifiers: ids)
        DispatchQueue.main.async { result(nil) }
      }
    case "showEvent", "test":
      let args = call.arguments as? [String: String] ?? [:]
      let test = call.method == "test"
      let chinese = defaults.string(forKey: "direct.locale") != "en"
      let content = UNMutableNotificationContent()
      var identifier = "bridge-direct-test"
      if test {
        content.title = chinese ? "Bridge 测试通知" : "Bridge test notification"
      } else {
        guard let computer = args["computerId"], handles(computer), let scope = args["scope"],
          let event = args["eventId"], let kind = args["kind"], ["completion", "request"].contains(kind),
          [computer, scope, event].allSatisfy(CloudPolicy.field),
          UIApplication.shared.applicationState == .active else { result(false); return }
        let route = ["computerId": computer, "scope": scope, "eventId": event]
        content.userInfo = ["bridge_direct": route]
        identifier = "bridge-direct:" + computer + ":" + scope + ":" + event
        content.title = kind == "request" ? (chinese ? "需要你的确认" : "Bridge needs your input")
          : (chinese ? "任务已完成" : "Bridge task completed")
        content.body = args["computerName"] ?? "Bridge"
      }
      content.sound = .default
      center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
        DispatchQueue.main.async { result(error == nil) }
      }
    case "settings":
      if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
      result(nil)
    case "updateStatus": result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func route(_ request: UNNotificationRequest) -> [String: String]? {
    guard request.trigger == nil, request.identifier.hasPrefix("bridge-direct:"),
      let info = request.content.userInfo["bridge_direct"] as? [String: String],
      Set(info.keys) == ["computerId", "scope", "eventId"], info.values.allSatisfy(CloudPolicy.field)
    else { return nil }
    return info
  }

  func presentation(_ request: UNNotificationRequest) -> UNNotificationPresentationOptions? {
    if request.trigger == nil && request.identifier == "bridge-direct-test" { return [.banner, .list, .sound] }
    guard let info = route(request), let computer = info["computerId"] else { return nil }
    return handles(computer) ? [.banner, .list, .sound] : []
  }

  func opened(_ response: UNNotificationResponse) -> Bool {
    guard let info = route(response.notification.request) else { return false }
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
      pendingTap = info
      channel?.invokeMethod("tap", arguments: nil)
    }
    return true
  }
}
