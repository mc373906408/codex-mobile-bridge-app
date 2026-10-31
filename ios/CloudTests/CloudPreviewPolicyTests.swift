import Foundation
import XCTest
@testable import BridgeCloudPolicy

final class CloudPreviewPolicyTests: XCTestCase {
  func testCanonicalInputsAndRoutes() throws {
    XCTAssertTrue(CloudPolicy.origin("https://relay.example:8443"))
    for origin in ["http://relay.example", "https://Relay.example", "https://relay.example/",
                   "https://relay.example:443", "https://user@relay.example", "https://relay.example?q=1",
                   "https://relay.example#x", "https://relay.example:0", "https://relay.example:65536"] {
      XCTAssertFalse(CloudPolicy.origin(origin), origin)
    }
    XCTAssertFalse(CloudPolicy.key(Data(repeating: 0, count: 32).base64EncodedString()))
    XCTAssertFalse(CloudPolicy.scope(String(repeating: "A", count: 64)))
    XCTAssertFalse(CloudPolicy.id(CloudTestHarness.notification.uppercased().replacingOccurrences(of: "000003", with: "ABCDEF")))
    XCTAssertThrowsError(try CloudPolicy.integer(true))
    XCTAssertThrowsError(try CloudPolicy.integer(1.5))
    XCTAssertThrowsError(try CloudPolicy.integer(-1))
    XCTAssertThrowsError(try CloudPolicy.integer(Double.infinity))
    XCTAssertEqual(try CloudPolicy.integer(NSNumber(value: Int64(123))), 123)
    XCTAssertFalse(CloudPolicy.live(Int64.max, now: Int64.max - 1))
    XCTAssertTrue(CloudPolicy.route(scope: CloudTestHarness.scope, event: "cloud:\(CloudTestHarness.notification)",
                                  id: CloudTestHarness.notification))
    XCTAssertFalse(CloudPolicy.route(scope: CloudTestHarness.scope, event: "execute:task", id: CloudTestHarness.notification))
  }

  func testEnvelopeRejectsExtraFieldsBooleanVersionAndExpiry() throws {
    let h = try CloudTestHarness()
    let valid = try h.envelope()
    var value = try XCTUnwrap(JSONSerialization.jsonObject(with: valid.data) as? [String: Any])
    value["title"] = "Provider plaintext"
    XCTAssertThrowsError(try CloudEnvelope(object: value, now: h.now))
    value.removeValue(forKey: "title")
    value["v"] = true
    XCTAssertThrowsError(try CloudEnvelope(object: value, now: h.now))
    value["v"] = 1
    value["expires_at"] = h.now
    XCTAssertThrowsError(try CloudEnvelope(object: value, now: h.now))
    value["expires_at"] = h.now + 3601
    XCTAssertThrowsError(try CloudEnvelope(object: value, now: h.now))
    value["expires_at"] = h.now + 600
    value["ciphertext"] = Data(repeating: 1, count: 1073).base64EncodedString()
    XCTAssertThrowsError(try CloudEnvelope(object: value, now: h.now))
  }

  #if !BRIDGE_CLOUD_PUSH
  func testOrdinaryBuildCannotDecrypt() throws {
    let h = try CloudTestHarness()
    try h.activate()
    let pin = try XCTUnwrap(h.store.read().pins.first)
    XCTAssertThrowsError(try CloudPreviewDecryptor.decrypt(credentials: h.credentials(), envelope: h.envelope(),
                                                          pin: pin, now: h.now))
  }
  #endif

  func testQuietBaselineAndDurableAcknowledgement() throws {
    let h = try CloudTestHarness()
    try h.activate()
    XCTAssertTrue(try h.direct([h.event()]).isEmpty)
    let reopened = try CloudMetadataStore(root: h.store.root)
    XCTAssertEqual(try reopened.read().receipts.count, 1)
    XCTAssertEqual(try h.service.pending(computer: h.computer, now: h.now), [CloudTestHarness.notification])
    XCTAssertTrue(try h.direct([h.event()]).isEmpty)
    try h.service.acknowledge(computer: h.computer, ids: [CloudTestHarness.notification])
    XCTAssertTrue(try h.service.pending(computer: h.computer, now: h.now).isEmpty)
    XCTAssertNotNil(try h.service.authorize(binding: CloudTestHarness.binding, id: CloudTestHarness.notification, now: h.now))
    let disk = try String(contentsOf: h.store.root.appendingPathComponent("metadata.json"), encoding: .utf8)
    XCTAssertFalse(disk.contains("Private test"))
    XCTAssertFalse(disk.contains("private_key"))
    XCTAssertFalse(disk.contains("ciphertext"))
  }

  func testDirectPushRaceSharesOneReceipt() throws {
    let h = try CloudTestHarness()
    try h.activate()
    XCTAssertTrue(try h.direct([]).isEmpty)
    XCTAssertEqual(try h.direct([h.event()]).count, 1)
    XCTAssertNil(try h.receive(h.envelope()))
    XCTAssertEqual(try h.store.read().receipts.count, 1)
    let second = UUID().uuidString.lowercased()
    XCTAssertNotNil(try h.receive(h.envelope(id: second)))
    XCTAssertTrue(try h.direct([h.event(id: second)]).isEmpty)
    XCTAssertEqual(try h.store.read().receipts.count, 2)
  }

  func testDuplicateRouteAndExpiryConflictsRollback() throws {
    let h = try CloudTestHarness()
    try h.activate()
    _ = try h.direct([h.event()])
    let before = try h.store.read()
    XCTAssertThrowsError(try h.direct([h.event(expires: h.now + 601)]))
    XCTAssertThrowsError(try h.direct([h.event()], scope: String(repeating: "b", count: 64)))
    h.previewScope = String(repeating: "b", count: 64)
    XCTAssertThrowsError(try h.receive(h.envelope()))
    XCTAssertEqual(try h.store.read(), before)
  }

  func testWithdrawalBlocksPreviewAndTapsButRetainsPendingReceipts() throws {
    for consent in [true, false] {
      let h = try CloudTestHarness()
      try h.activate()
      _ = try h.direct([h.event()])
      if consent { try h.service.consent(false, version: h.notice) } else { try h.service.permission(false) }
      XCTAssertTrue(try h.store.read().baselines.isEmpty)
      XCTAssertThrowsError(try h.direct([]))
      XCTAssertThrowsError(try h.receive(h.envelope()))
      XCTAssertNil(try h.service.authorize(binding: CloudTestHarness.binding, id: CloudTestHarness.notification, now: h.now))
      XCTAssertEqual(try h.service.pending(computer: h.computer, now: h.now).count, 1)
      try h.service.acknowledge(computer: h.computer, ids: [CloudTestHarness.notification])
      XCTAssertTrue(try h.service.pending(computer: h.computer, now: h.now).isEmpty)
      try h.service.consent(true, version: h.notice)
      try h.service.permission(true)
      XCTAssertTrue(try h.direct([h.event(id: UUID().uuidString.lowercased())]).isEmpty)
    }
  }

  func testPinAndPrivateKeyCannotBeSilentlyReplaced() throws {
    let h = try CloudTestHarness()
    try h.activate()
    let saved = try h.store.read()
    let data = try h.credentials()
    let object = try JSONSerialization.jsonObject(with: data)
    try h.service.save(computer: h.computer, data: JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]))
    XCTAssertEqual(try h.store.read(), saved)
    XCTAssertThrowsError(try h.service.save(computer: h.computer, data: h.credentials(privateByte: 8)))
    XCTAssertThrowsError(try h.service.save(computer: h.computer, data: h.credentials(desktopByte: 8)))
    XCTAssertThrowsError(try h.service.save(computer: h.computer, data: h.credentials(origin: "https://other.example")))
    XCTAssertThrowsError(try h.service.save(computer: "computer-b", data: h.credentials()))
    _ = try h.direct([h.event()])
    let tag = try XCTUnwrap(h.store.read().pins.first?.keyTag)
    _ = try h.service.remove(computer: h.computer)
    XCTAssertNil(h.vault.entries[tag])
    XCTAssertTrue(try h.store.read().receipts.isEmpty)
    try h.service.save(computer: h.computer, data: h.credentials(binding: UUID().uuidString.lowercased(), privateByte: 8))
    XCTAssertNil(try h.service.authorize(binding: CloudTestHarness.binding, id: CloudTestHarness.notification, now: h.now))
  }

  func testMissingKeyRepairRequiresAuthenticatedMatchingIdentity() throws {
    let h = try CloudTestHarness()
    try h.activate()
    let pin = try XCTUnwrap(h.store.read().pins.first)
    h.vault.entries.removeAll()
    XCTAssertThrowsError(try h.receive(h.envelope()))
    try h.service.save(computer: h.computer, data: h.credentials())
    XCTAssertEqual(try h.store.read().pins.first, pin)
    XCTAssertNotNil(try h.receive(h.envelope()))
    h.vault.locked = true
    XCTAssertThrowsError(try h.service.save(computer: h.computer, data: h.credentials()))
  }

  func testRevocationAndExpiryDuringDecryptionDoNotCommit() throws {
    for action in 0..<5 {
      let h = try CloudTestHarness()
      try h.activate()
      var current = true
      h.onDecrypt = {
        switch action {
        case 0: try h.service.consent(false, version: h.notice)
        case 1: try h.service.permission(false)
        case 2: _ = try h.service.remove(computer: h.computer)
        case 3: current = false
        default: h.now += 601
        }
      }
      XCTAssertThrowsError(try h.receive(h.envelope(), current: { current }))
      XCTAssertTrue(try h.store.read().receipts.isEmpty)
      h.onDecrypt = nil
    }
  }

  func testPermissionAndGenerationGateRunBeforeDecrypt() throws {
    let h = try CloudTestHarness()
    try h.activate()
    XCTAssertThrowsError(try h.receive(h.envelope(), allowed: false))
    XCTAssertThrowsError(try h.receive(h.envelope(), current: { false }))
    h.vault.locked = true
    XCTAssertThrowsError(try h.receive(h.envelope()))
    XCTAssertEqual(h.decryptions, 0)
  }

  func testExpiredDirectBatchAndStaleCommitAreSilent() throws {
    let h = try CloudTestHarness()
    try h.activate()
    _ = try h.direct([])
    XCTAssertTrue(try h.direct([h.event(expires: h.now)]).isEmpty)
    var checks = 0
    XCTAssertThrowsError(try h.direct([h.event()], current: { checks += 1; return checks == 1 }))
    XCTAssertTrue(try h.store.read().receipts.isEmpty)
  }

  func testReceiptRetentionAndBatchBounds() throws {
    let h = try CloudTestHarness()
    try h.activate()
    let expired = h.event(expires: h.now + 1)
    _ = try h.direct([expired])
    h.now += 2
    XCTAssertTrue(try h.service.pending(computer: h.computer, now: h.now).isEmpty)
    XCTAssertEqual(try h.store.read().receipts.count, 1)
    h.now += 3600
    _ = try h.direct([])
    XCTAssertTrue(try h.store.read().receipts.isEmpty)
    XCTAssertThrowsError(try h.direct(Array(repeating: h.event(), count: 201)))
    XCTAssertThrowsError(try h.service.acknowledge(computer: h.computer, ids: Array(repeating: CloudTestHarness.notification, count: 101)))
    XCTAssertThrowsError(try h.service.acknowledge(computer: h.computer, ids: ["not-a-uuid"]))
  }

  func testCorruptMetadataWithdrawalDeletesOnlyPreviewVault() throws {
    for operation in 0..<3 {
      let h = try CloudTestHarness()
      try h.activate()
      try Data("not-json".utf8).write(to: h.store.root.appendingPathComponent("metadata.json"))
      switch operation {
      case 0: XCTAssertThrowsError(try h.service.consent(false, version: h.notice))
      case 1: XCTAssertThrowsError(try h.service.permission(false))
      default: XCTAssertThrowsError(try h.service.remove(computer: h.computer))
      }
      XCTAssertEqual(h.vault.removals, 1)
      XCTAssertTrue(h.vault.entries.isEmpty)
      XCTAssertThrowsError(try h.receive(h.envelope()))
    }
  }

  func testFailedMetadataCommitCleansUpNewKey() throws {
    let h = try CloudTestHarness()
    h.vault.onSave = {
      try FileManager.default.createDirectory(at: h.store.root.appendingPathComponent("metadata.json"),
                                             withIntermediateDirectories: false)
    }
    XCTAssertThrowsError(try h.service.save(computer: h.computer, data: h.credentials()))
    XCTAssertTrue(h.vault.entries.isEmpty)
    let files = try FileManager.default.contentsOfDirectory(atPath: h.store.root.path)
    XCTAssertFalse(files.contains { $0.hasPrefix(".metadata-") })
    h.vault.onSave = nil
  }

  func testTapReferenceNeverContainsAnExecutableRoute() {
    XCTAssertNil(CloudPreviewService.reference(["bridge_receipt": ["binding_id": "bad", "notification_id": "bad"]]))
    let reference = ["binding_id": CloudTestHarness.binding, "notification_id": CloudTestHarness.notification]
    XCTAssertNotNil(CloudPreviewService.reference(["bridge_receipt": reference]))
    XCTAssertNotNil(CloudPreviewService.reference(["bridge": reference]))
  }
}
