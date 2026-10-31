import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
  private let completion = CloudCompletionGate<UNNotificationContent>(fallback: { NotificationService.generic() })
  private let queue = DispatchQueue(label: "dev.waken.bridge.notification-service", qos: .userInitiated)

  private static func generic(passive: Bool = false) -> UNMutableNotificationContent {
    // Build from scratch: provider text, attachments, badges, categories and routes are untrusted.
    let content = UNMutableNotificationContent()
    content.title = "Bridge update"
    content.body = "Open Bridge to view the update."
    content.sound = passive ? nil : .default
    if passive { content.interruptionLevel = .passive }
    return content
  }

  override func didReceive(_ request: UNNotificationRequest,
                           withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
    let generation = completion.begin(contentHandler)
    guard let outer = request.content.userInfo["bridge"] as? [String: Any],
      let envelope = try? CloudEnvelope(object: outer, now: CloudPolicy.now)
    else { completion.finish(Self.generic(), generation: generation); return }
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      self.queue.async {
        do {
          let service = try CloudPreviewService(configuration: CloudRuntimeConfiguration())
          if !Self.allowed(settings) { try service.permission(false) }
          let preview = try service.receive(envelope, allowed: Self.allowed(settings),
            current: { self.completion.matches(generation) })
          UNUserNotificationCenter.current().getNotificationSettings { latest in
            self.queue.async {
              do {
                if !Self.allowed(latest) { try service.permission(false) }
                guard Self.allowed(latest), self.completion.matches(generation),
                  let receipt = try service.authorize(binding: envelope.bindingId, id: envelope.notificationId)
                else { throw CloudFailure.revoked }
                let content = Self.generic(passive: preview == nil)
                content.userInfo = ["bridge_receipt": receipt.reference]
                if let preview = preview { content.title = preview.title; content.body = preview.body }
                self.completion.finish(content, generation: generation)
              } catch { self.completion.finish(Self.generic(), generation: generation) }
            }
          }
        } catch { self.completion.finish(Self.generic(), generation: generation) }
      }
    }
  }

  private static func allowed(_ settings: UNNotificationSettings) -> Bool {
    [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) && settings.alertSetting == .enabled
  }

  override func serviceExtensionTimeWillExpire() { completion.expire() }
}
