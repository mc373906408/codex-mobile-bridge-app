import Foundation
@testable import BridgeCloudPolicy

final class FakePreviewVault: CloudPreviewVault {
  var entries: [String: Data] = [:]
  var locked = false
  var failSave = false
  var failRemove = false
  var removals = 0
  var onSave: (() throws -> Void)?

  func read(_ tag: String) throws -> Data {
    guard !locked, let data = entries[tag] else { throw CloudFailure.unavailable }
    return data
  }

  func save(_ data: Data, tag: String) throws {
    guard !locked, !failSave else { throw CloudFailure.unavailable }
    if let old = entries[tag], old != data { throw CloudFailure.revoked }
    entries[tag] = data
    try onSave?()
  }

  func remove(_ tag: String) throws {
    guard !failRemove else { throw CloudFailure.unavailable }
    entries.removeValue(forKey: tag)
  }

  func removeAll() throws {
    removals += 1
    guard !failRemove else { throw CloudFailure.unavailable }
    entries.removeAll()
  }
}

final class CloudTestHarness {
  static let gateway = "00000000-0000-4000-8000-000000000001"
  static let binding = "00000000-0000-4000-8000-000000000002"
  static let notification = "00000000-0000-4000-8000-000000000003"
  static let scope = String(repeating: "a", count: 64)
  let computer = "computer-a"
  let notice = "test-notice-v1"
  let parent: URL
  let store: CloudMetadataStore
  let vault = FakePreviewVault()
  var now: Int64 = 2_000_000_000
  var decryptions = 0
  var onDecrypt: (() throws -> Void)?
  var previewScope = CloudTestHarness.scope

  lazy var service = CloudPreviewService(
    configuration: CloudRuntimeConfiguration(configured: true, noticeVersion: notice, store: store, vault: vault),
    clock: { [unowned self] in self.now },
    decrypt: { [unowned self] _, envelope, pin, time in
      self.decryptions += 1
      try self.onDecrypt?()
      let data = try JSONSerialization.data(withJSONObject: [
        "origin": pin.origin, "gateway_id": pin.gatewayId, "binding_id": pin.bindingId,
        "notification_id": envelope.notificationId, "expires_at": envelope.expiresAt,
        "scope": self.previewScope, "event_id": "cloud:\(envelope.notificationId)",
        "title": "Private test title", "body": "Private test body",
      ])
      return try CloudPreview(data: data, pin: pin, envelope: envelope, now: time)
    })

  init(lockTimeout: TimeInterval = 0.2) throws {
    parent = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-cloud-test-\(UUID().uuidString)")
    store = try CloudMetadataStore(root: parent.appendingPathComponent("store"), lockTimeout: lockTimeout)
  }

  deinit { try? FileManager.default.removeItem(at: parent) }

  func credentials(binding: String = CloudTestHarness.binding, origin: String = "https://relay.example",
                   privateByte: UInt8 = 7, desktopByte: UInt8 = 9) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "origin": origin, "gateway_id": Self.gateway, "binding_id": binding,
      "private_key": Data(repeating: privateByte, count: 32).base64EncodedString(),
      "desktop_public_key": Data(repeating: desktopByte, count: 32).base64EncodedString(),
    ], options: [.sortedKeys])
  }

  func activate() throws {
    try service.save(computer: computer, data: credentials())
    try service.consent(true, version: notice)
    try service.permission(true)
  }

  func envelope(id: String = CloudTestHarness.notification, expires: Int64? = nil) throws -> CloudEnvelope {
    try CloudEnvelope(object: [
      "v": 1, "notification_id": id, "binding_id": Self.binding,
      "expires_at": expires ?? now + 600,
      "ciphertext": Data(repeating: 1, count: 64).base64EncodedString(),
    ], now: now)
  }

  func event(id: String = CloudTestHarness.notification, expires: Int64? = nil) -> [String: Any] {
    ["notificationId": id, "eventId": "cloud:\(id)", "expiresAt": expires ?? now + 600, "kind": "completion"]
  }

  func direct(_ events: [[String: Any]], scope: String = CloudTestHarness.scope,
              current: () -> Bool = { true }) throws -> [(CloudReceipt, String)] {
    try service.direct(computer: computer, scope: scope, events: events, current: current, now: now)
  }

  func receive(_ envelope: CloudEnvelope, allowed: Bool = true,
               current: () -> Bool = { true }) throws -> CloudPreview? {
    try service.receive(envelope, allowed: allowed, current: current, now: now)
  }
}
