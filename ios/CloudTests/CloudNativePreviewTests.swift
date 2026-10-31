#if BRIDGE_CLOUD_PUSH
import Foundation
import XCTest
import BridgePreviewFFI
@testable import BridgeCloudPolicy

private struct NativePreviewFixture {
  let keys: Data
  let envelope: CloudEnvelope
  let object: [String: Any]
  let expected: [String: Any]
  let pin: CloudPin
  let now: Int64

  init() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let value = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: root.appendingPathComponent("rust/tests/cloud_preview.json"))) as? [String: Any])
    XCTAssertEqual(try CloudPolicy.integer(value["format"]), 1)
    now = try CloudPolicy.integer(value["now"])
    keys = try JSONSerialization.data(withJSONObject: XCTUnwrap(value["credentials"]), options: [.sortedKeys])
    object = try XCTUnwrap(value["envelope"] as? [String: Any])
    expected = try XCTUnwrap(value["expected"] as? [String: Any])
    envelope = try CloudEnvelope(object: object, now: now)
    pin = try CloudCredentials(computerId: "native-fixture", data: keys).pin
  }

  func service(_ harness: CloudTestHarness) throws -> CloudPreviewService {
    harness.now = now
    let service = CloudPreviewService(configuration: CloudRuntimeConfiguration(
      configured: true, noticeVersion: harness.notice, store: harness.store, vault: harness.vault),
      clock: { harness.now })
    try service.save(computer: harness.computer, data: keys)
    try service.consent(true, version: harness.notice)
    try service.permission(true)
    return service
  }

  var scope: String { expected["scope"] as! String }
  var event: [String: Any] {
    ["notificationId": envelope.notificationId, "eventId": "cloud:\(envelope.notificationId)",
     "expiresAt": envelope.expiresAt, "kind": "completion"]
  }
}

final class CloudNativePreviewTests: XCTestCase {
  private func abi(_ keys: Data, _ payload: Data, now: Int64) -> Data? {
    var count = 99
    let output = keys.withUnsafeBytes { (credentials: UnsafeRawBufferPointer) in
      payload.withUnsafeBytes { (envelope: UnsafeRawBufferPointer) in
        bridge_preview_decrypt(credentials.bindMemory(to: UInt8.self).baseAddress, credentials.count,
          envelope.bindMemory(to: UInt8.self).baseAddress, envelope.count, now, &count)
      }
    }
    guard let output = output else {
      XCTAssertEqual(count, 0)
      return nil
    }
    defer { bridge_preview_free(output, count) }
    guard (1...4096).contains(count) else {
      XCTFail("C ABI returned an unbounded preview")
      return nil
    }
    return Data(bytes: output, count: count)
  }

  func testPythonProductionVectorCrossesRealSwiftRustABI() throws {
    let fixture = try NativePreviewFixture()
    for _ in 0..<32 {
      let output = try XCTUnwrap(abi(fixture.keys, fixture.envelope.data, now: fixture.now))
      let value = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? NSDictionary)
      XCTAssertEqual(value, fixture.expected as NSDictionary)
    }
    let preview = try CloudPreviewDecryptor.decrypt(credentials: fixture.keys, envelope: fixture.envelope,
                                                    pin: fixture.pin, now: fixture.now)
    XCTAssertEqual(preview.title, fixture.expected["title"] as? String)
    XCTAssertEqual(preview.body, fixture.expected["body"] as? String)
    XCTAssertEqual(preview.receipt.scope, fixture.scope)
    XCTAssertEqual(preview.receipt.eventId, "cloud:\(fixture.envelope.notificationId)")
  }

  func testCABIRejectsNullEmptyOversizedAndMalformedBuffers() throws {
    let fixture = try NativePreviewFixture()
    var count = 99
    XCTAssertNil(bridge_preview_decrypt(nil, 0, nil, 0, fixture.now, &count))
    XCTAssertEqual(count, 0)
    XCTAssertNil(bridge_preview_decrypt(nil, 0, nil, 0, fixture.now, nil))
    bridge_preview_free(nil, 0)
    for invalid in [Data(), Data([0xff]), Data("{}".utf8), Data(repeating: 32, count: 4097)] {
      XCTAssertNil(abi(invalid, fixture.envelope.data, now: fixture.now))
      XCTAssertNil(abi(fixture.keys, invalid, now: fixture.now))
    }
    XCTAssertNil(abi(fixture.keys, fixture.envelope.data, now: fixture.envelope.expiresAt))
    XCTAssertNil(abi(fixture.keys, fixture.envelope.data, now: fixture.now - 3601))
  }

  func testAuthenticatedEnvelopeFieldsAndCiphertextCannotBeChanged() throws {
    let fixture = try NativePreviewFixture()
    var variants: [[String: Any]] = []
    for field in ["notification_id", "binding_id"] {
      var object = fixture.object
      object[field] = UUID().uuidString.lowercased()
      variants.append(object)
    }
    var expiry = fixture.object
    expiry["expires_at"] = fixture.envelope.expiresAt + 1
    variants.append(expiry)
    var ciphertext = try XCTUnwrap(Data(base64Encoded: fixture.object["ciphertext"] as! String))
    ciphertext[ciphertext.startIndex] ^= 1
    var tampered = fixture.object
    tampered["ciphertext"] = ciphertext.base64EncodedString()
    variants.append(tampered)
    for object in variants {
      let envelope = try CloudEnvelope(object: object, now: fixture.now)
      XCTAssertThrowsError(try CloudPreviewDecryptor.decrypt(credentials: fixture.keys, envelope: envelope,
                                                            pin: fixture.pin, now: fixture.now))
    }
  }

  func testServerOriginGatewayAndPreviewPinsCannotBeReplaced() throws {
    let fixture = try NativePreviewFixture()
    let original = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.keys) as? [String: Any])
    for field in ["origin", "gateway_id", "binding_id", "private_key", "desktop_public_key", "control_private"] {
      var keys = original
      switch field {
      case "origin": keys[field] = "https://other.example.test"
      case "gateway_id", "binding_id": keys[field] = UUID().uuidString.lowercased()
      default: keys[field] = Data(repeating: 7, count: 32).base64EncodedString()
      }
      XCTAssertNil(abi(try JSONSerialization.data(withJSONObject: keys), fixture.envelope.data, now: fixture.now))
    }
  }

  func testNativeDirectPushOrdersShareOnlyADurableReceipt() throws {
    for pushFirst in [true, false] {
      let fixture = try NativePreviewFixture()
      let h = try CloudTestHarness()
      let service = try fixture.service(h)
      _ = try service.direct(computer: h.computer, scope: fixture.scope, events: [], current: { true }, now: h.now)
      if !pushFirst {
        XCTAssertEqual(try service.direct(computer: h.computer, scope: fixture.scope, events: [fixture.event],
                                          current: { true }, now: h.now).count, 1)
      }
      let preview = try service.receive(fixture.envelope, allowed: true, current: { true }, now: h.now)
      XCTAssertEqual(preview != nil, pushFirst)
      XCTAssertTrue(try service.direct(computer: h.computer, scope: fixture.scope, events: [fixture.event],
                                       current: { true }, now: h.now).isEmpty)
      XCTAssertNil(try service.receive(fixture.envelope, allowed: true, current: { true }, now: h.now))
      let reopened = try CloudMetadataStore(root: h.store.root)
      XCTAssertEqual(try reopened.read().receipts.count, 1)
      XCTAssertEqual(try service.pending(computer: h.computer, now: h.now), [fixture.envelope.notificationId])
      let disk = try String(contentsOf: h.store.root.appendingPathComponent("metadata.json"), encoding: .utf8)
      for plaintext in [fixture.expected["title"] as! String, fixture.expected["body"] as! String,
                        "private_key", "control_private", "ciphertext"] {
        XCTAssertFalse(disk.contains(plaintext))
      }
      try service.acknowledge(computer: h.computer, ids: [fixture.envelope.notificationId])
      XCTAssertTrue(try service.pending(computer: h.computer, now: h.now).isEmpty)
      XCTAssertNotNil(try service.authorize(binding: fixture.envelope.bindingId,
                                            id: fixture.envelope.notificationId, now: h.now))
    }
  }

  func testUnavailableKeysAndConsentCannotCreateReceiptOrTap() throws {
    for reason in 0..<3 {
      let fixture = try NativePreviewFixture()
      let h = try CloudTestHarness()
      let service = try fixture.service(h)
      switch reason {
      case 0: h.vault.locked = true
      case 1: try service.consent(false, version: h.notice)
      default: try service.permission(false)
      }
      XCTAssertThrowsError(try service.receive(fixture.envelope, allowed: true, current: { true }, now: h.now))
      XCTAssertTrue(try h.store.read().receipts.isEmpty)
      XCTAssertTrue(try service.pending(computer: h.computer, now: h.now).isEmpty)
      XCTAssertNil(try service.authorize(binding: fixture.envelope.bindingId,
                                         id: fixture.envelope.notificationId, now: h.now))
    }
  }
}
#endif
