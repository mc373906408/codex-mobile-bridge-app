import Flutter
import UIKit
import UserNotifications

final class CloudPushBridge: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private let queue = DispatchQueue(label: "dev.waken.bridge.cloud-preview", qos: .userInitiated)
  private let fence = CloudFence()
  private let service: CloudPreviewService?
  private var channel: FlutterMethodChannel?
  private weak var previousDelegate: UNUserNotificationCenterDelegate?
  private var observers: [NSObjectProtocol] = []
  private var token = ""
  private var registrationPending = false
  private var permissionPending = false
  private var privacyFault = false
  private var pendingTap: (String, String)?

  private var configured: Bool {
    #if BRIDGE_CLOUD_PUSH
    return true
    #else
    return false
    #endif
  }

  private var noticeVersion: String { configured ? "cloud-apns-push-v1" : "cloud-notifications-v1" }
  private var interactive: Bool {
    !permissionPending && UIApplication.shared.applicationState == .active &&
      UIApplication.shared.connectedScenes.contains {
        guard let scene = $0 as? UIWindowScene else { return false }
        return scene.activationState == .foregroundActive && scene.windows.contains(where: \.isKeyWindow)
      }
  }

  override init() {
    service = try? CloudPreviewService(configuration: CloudRuntimeConfiguration())
    super.init()
    privacyFault = service == nil
    previousDelegate = center.delegate
    center.delegate = self
    for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                 UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.changed()
      })
    }
  }

  deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

  func bind(_ messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.waken.bridge_mobile/cloud_push", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func changed(clearTap: Bool = false) {
    fence.advance()
    if clearTap { pendingTap = nil }
    channel?.invokeMethod("changed", arguments: nil)
  }

  static func allowed(_ settings: UNNotificationSettings) -> Bool {
    [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) && settings.alertSetting == .enabled
  }

  private func state(_ result: @escaping FlutterResult) {
    let generation = fence.generation
    center.getNotificationSettings { [weak self] settings in
      guard let self = self else { return }
      self.queue.async {
        var consent = false
        do {
          guard let service = self.service else { throw CloudFailure.unavailable }
          try service.permission(Self.allowed(settings))
          consent = try service.store.read().accepted(self.noticeVersion)
        } catch {
          DispatchQueue.main.async { self.privacyFault = true }
        }
        let accepted = consent
        DispatchQueue.main.async {
          let current = self.fence.matches(generation)
          let enabled = accepted && !self.privacyFault && current
          let allowed = Self.allowed(settings)
          if current { self.synchronizeRemote(consent: enabled, allowed: allowed) }
          result([
            "supported": true, "configured": self.configured, "allowed": allowed, "consent": enabled,
            "interactive": self.interactive && current, "noticeVersion": self.noticeVersion,
            "pushStatus": !enabled ? "off" : !allowed ? "permission_required" :
              !self.configured ? "direct_only" : self.token.isEmpty ? "registering" : "registered",
            "platform": "apns", "appId": Bundle.main.bundleIdentifier ?? "",
            "token": enabled && allowed ? self.token : "",
          ])
        }
      }
    }
  }

  private func synchronizeRemote(consent: Bool, allowed: Bool) {
    if !configured || !consent || !allowed {
      token = ""
      registrationPending = false
      if configured { UIApplication.shared.unregisterForRemoteNotifications() }
      if !consent || !allowed { clearNotifications() }
    } else if token.isEmpty && !registrationPending {
      registrationPending = true
      UIApplication.shared.registerForRemoteNotifications()
    }
  }

  func registered(_ data: Data) {
    guard configured else { return }
    registrationPending = false
    let value = data.map { String(format: "%02x", $0) }.joined()
    guard data.count >= 16, data.count <= 128 else { failedRegistration(); return }
    let generation = fence.generation
    center.getNotificationSettings { settings in
      self.queue.async {
        let state = try? self.service?.store.read()
        let accepted = state?.accepted(self.noticeVersion) == true && state?.permission == true
        DispatchQueue.main.async {
          guard self.fence.matches(generation) else { return }
          guard accepted, Self.allowed(settings), !self.privacyFault else {
            self.synchronizeRemote(consent: false, allowed: false)
            return
          }
          if self.token != value { self.token = value; self.changed() }
        }
      }
    }
  }

  func failedRegistration() {
    registrationPending = false
    if !token.isEmpty { token = ""; changed() }
    // Do not log OS errors, device tokens, payloads or decrypted previews.
  }

  private func requestPermission(_ result: @escaping FlutterResult) {
    guard interactive, !privacyFault else { result(false); return }
    queue.async {
      let accepted = (try? self.service?.store.read().accepted(self.noticeVersion)) == true
      DispatchQueue.main.async {
        guard accepted, self.interactive else { result(false); return }
        self.permissionPending = true
        self.changed()
        self.center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
          DispatchQueue.main.async {
            self.permissionPending = false
            self.changed()
            self.state { value in result((value as? [String: Any])?["allowed"] as? Bool ?? false) }
          }
        }
      }
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "state" { state(result); return }
    if call.method == "requestPermission" { requestPermission(result); return }
    guard let arguments = call.arguments as? [String: Any] ?? (call.method == "takeTap" ? [:] : nil)
    else { fail(result); return }
    if call.method == "setConsent" {
      guard interactive, Set(arguments.keys) == ["enabled", "noticeVersion"],
        let enabled = arguments["enabled"] as? Bool,
        let version = arguments["noticeVersion"] as? String, version == noticeVersion
      else { fail(result); return }
      // Immediately fence queued work, even if the durable withdrawal later fails.
      privacyFault = true
      changed(clearTap: true)
      if !enabled { synchronizeRemote(consent: false, allowed: false) }
      queue.async {
        do {
          guard let service = self.service else { throw CloudFailure.unavailable }
          try service.consent(enabled, version: version)
          DispatchQueue.main.async { self.privacyFault = false; self.changed(); self.state(result) }
        } catch { DispatchQueue.main.async { self.changed(); self.fail(result) } }
      }
      return
    }
    if call.method == "removePreview" { fence.advance() }
    let generation = fence.generation
    let tap = pendingTap
    queue.async {
      do {
        guard let service = self.service else { throw CloudFailure.unavailable }
        let computer = arguments["computerId"] as? String ?? ""
        if call.method != "takeTap" && !CloudPolicy.field(computer) { throw CloudFailure.invalid }
        var value: Any?
        var display: [(CloudReceipt, String)] = []
        var removed: [CloudReceipt] = []
        switch call.method {
        case "savePreview":
          guard let raw = arguments["credentials"] as? String else { throw CloudFailure.invalid }
          try service.save(computer: computer, data: Data(raw.utf8))
        case "removePreview":
          removed = try service.remove(computer: computer)
        case "pendingReceipts": value = try service.pending(computer: computer)
        case "markAcknowledged":
          guard let ids = arguments["ids"] as? [String] else { throw CloudFailure.invalid }
          try service.acknowledge(computer: computer, ids: ids)
        case "directBatch":
          guard let scope = arguments["scope"] as? String,
            let events = arguments["events"] as? [[String: Any]] else { throw CloudFailure.invalid }
          display = try service.direct(computer: computer, scope: scope, events: events,
            current: { self.fence.matches(generation) })
        case "takeTap":
          if let (binding, id) = tap { value = try service.authorize(binding: binding, id: id)?.tap }
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          return
        }
        let output = value
        let alerts = display
        let cleared = removed
        DispatchQueue.main.async {
          if !cleared.isEmpty { self.clearNotifications(receipts: cleared) }
          guard self.fence.matches(generation) else { self.fail(result); return }
          if call.method == "takeTap" {
            guard self.pendingTap?.0 == tap?.0, self.pendingTap?.1 == tap?.1 else { result(nil); return }
            self.pendingTap = nil
          }
          if !self.privacyFault {
            for (receipt, kind) in alerts {
              self.show(receipt, title: kind == "request" ? "Bridge needs your input" : "Bridge task completed",
                        body: "Open Bridge to view the update.")
            }
            result(output)
          } else if call.method == "pendingReceipts" || call.method == "markAcknowledged" ||
              call.method == "removePreview" || call.method == "savePreview" {
            result(output)
          } else { self.fail(result) }
        }
      } catch { DispatchQueue.main.async { self.fail(result) } }
    }
  }

  private func fail(_ result: FlutterResult) {
    result(FlutterError(code: "cloud_preview_unavailable", message: "Private notification storage is unavailable", details: nil))
  }

  private func show(_ receipt: CloudReceipt, title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.userInfo = ["bridge_receipt": receipt.reference]
    center.add(UNNotificationRequest(identifier: "bridge-cloud:\(receipt.identity)", content: content, trigger: nil))
  }

  private func clearNotifications(receipts: [CloudReceipt]? = nil) {
    let identities = receipts.map { Set($0.map(\.identity)) }
    center.getDeliveredNotifications { notifications in
      let ids = notifications.compactMap { notification -> String? in
        guard let (binding, id) = CloudPreviewService.reference(notification.request.content.userInfo) else { return nil }
        return identities == nil || identities!.contains("\(binding):\(id)") ? notification.request.identifier : nil
      }
      self.center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    center.getPendingNotificationRequests { requests in
      let ids = requests.compactMap { request -> String? in
        guard let (binding, id) = CloudPreviewService.reference(request.content.userInfo) else { return nil }
        return identities == nil || identities!.contains("\(binding):\(id)") ? request.identifier : nil
      }
      self.center.removePendingNotificationRequests(withIdentifiers: ids)
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    let info = notification.request.content.userInfo
    guard info["bridge"] != nil || info["bridge_receipt"] != nil else {
      if let previous = previousDelegate,
        previous.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))) {
        previous.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
      } else { completionHandler([]) }
      return
    }
    let generation = fence.generation
    center.getNotificationSettings { settings in
      self.queue.async {
        do {
          guard let service = self.service, Self.allowed(settings), self.fence.matches(generation)
          else { throw CloudFailure.revoked }
          if let outer = info["bridge"] as? [String: Any] {
            let envelope = try CloudEnvelope(object: outer, now: CloudPolicy.now)
            let preview = try service.receive(envelope, allowed: true, current: { self.fence.matches(generation) })
            DispatchQueue.main.async {
              // Never present the provider's original foreground title/body.
              completionHandler([])
              if let preview = preview, !self.privacyFault, self.fence.matches(generation) {
                self.show(preview.receipt, title: preview.title, body: preview.body)
                self.changed()
              }
            }
          } else if let (binding, id) = CloudPreviewService.reference(info),
              try service.authorize(binding: binding, id: id) != nil {
            DispatchQueue.main.async {
              completionHandler(!self.privacyFault && self.fence.matches(generation) ? [.banner, .list, .sound] : [])
            }
          } else { throw CloudFailure.revoked }
        } catch { DispatchQueue.main.async { completionHandler([]) } }
      }
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    let info = response.notification.request.content.userInfo
    guard info["bridge"] != nil || info["bridge_receipt"] != nil else {
      if let previous = previousDelegate,
        previous.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))) {
        previous.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
      } else { completionHandler() }
      return
    }
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let (binding, id) = CloudPreviewService.reference(info) else { completionHandler(); return }
    let generation = fence.generation
    center.getNotificationSettings { settings in
      self.queue.async {
        let receipt = Self.allowed(settings) ? try? self.service?.authorize(binding: binding, id: id) : nil
        DispatchQueue.main.async {
          if receipt != nil, !self.privacyFault, self.fence.matches(generation) {
            self.fence.advance()
            self.pendingTap = (binding, id)
            self.channel?.invokeMethod("changed", arguments: nil)
          }
          completionHandler()
        }
      }
    }
  }
}
