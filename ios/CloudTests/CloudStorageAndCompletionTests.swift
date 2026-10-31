import Foundation
import XCTest
import Darwin
@testable import BridgeCloudPolicy

final class CloudStorageAndCompletionTests: XCTestCase {
  func testThrownTransactionRollsBackAndReopens() throws {
    let h = try CloudTestHarness()
    try h.activate()
    let before = try h.store.read()
    XCTAssertThrowsError(try h.store.transaction { state in
      state.consent = false
      try state.advance()
      throw CloudFailure.invalid
    })
    XCTAssertEqual(try CloudMetadataStore(root: h.store.root).read(), before)
  }

  func testMetadataLimitsAndDuplicateIdentities() throws {
    let h = try CloudTestHarness()
    try h.activate()
    let pin = try XCTUnwrap(h.store.read().pins.first)
    XCTAssertThrowsError(try h.store.transaction { $0.pins.append(pin) })
    XCTAssertThrowsError(try h.store.transaction { $0.format = 2 })
    XCTAssertThrowsError(try h.store.transaction { $0.baselines["unknown-computer"] = CloudTestHarness.scope })
    XCTAssertThrowsError(try h.store.transaction { $0.noticeVersion = String(repeating: "x", count: 129) })
    try h.store.transaction { $0.generation = Int64.max }
    XCTAssertThrowsError(try h.store.transaction { try $0.advance() })
  }

  func testFullReceiptStoreDoesNotEvictUnacknowledgedLiveReceipts() throws {
    let h = try CloudTestHarness()
    try h.activate()
    let pin = try XCTUnwrap(h.store.read().pins.first)
    try h.store.transaction(now: h.now) { state in
      state.receipts = (0..<CloudPolicy.receiptLimit).map { _ in
        let id = UUID().uuidString.lowercased()
        return CloudReceipt(computerId: pin.computerId, origin: pin.origin, gatewayId: pin.gatewayId,
          bindingId: pin.bindingId, notificationId: id, scope: CloudTestHarness.scope,
          eventId: "cloud:\(id)", expiresAt: h.now + 600)
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      XCTAssertLessThan(try encoder.encode(state).count, CloudPolicy.storeLimit)
    }
    XCTAssertThrowsError(try h.receive(h.envelope()))
    XCTAssertEqual(try h.store.read().receipts.count, CloudPolicy.receiptLimit)
    XCTAssertEqual(try h.service.pending(computer: h.computer, now: h.now).count, 100)
  }

  func testSymlinksHardLinksAndFifosAreRejectedWithoutFollowingOrBlocking() throws {
    for name in ["metadata.json", "metadata.lock"] {
      for kind in ["symlink", "hardlink", "fifo"] {
        let h = try CloudTestHarness(lockTimeout: 0.01)
        let target = h.parent.appendingPathComponent("outside.json")
        let marker = Data("outside-must-not-change".utf8)
        try marker.write(to: target)
        let path = h.store.root.appendingPathComponent(name).path
        switch kind {
        case "symlink": XCTAssertEqual(symlink(target.path, path), 0)
        case "hardlink": XCTAssertEqual(link(target.path, path), 0)
        default: XCTAssertEqual(mkfifo(path, 0o600), 0)
        }
        let start = Date()
        XCTAssertThrowsError(try h.store.read(), "\(name): \(kind)")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(try Data(contentsOf: target), marker)
      }
    }
  }

  func testOversizedAndInvalidMetadataCannotBecomeAnEmptyStore() throws {
    for data in [Data("{}".utf8), Data("[]".utf8), Data(), Data(repeating: 32, count: CloudPolicy.storeLimit + 1)] {
      let h = try CloudTestHarness()
      try data.write(to: h.store.root.appendingPathComponent("metadata.json"))
      XCTAssertThrowsError(try h.store.read())
      XCTAssertThrowsError(try h.store.transaction { $0.permission = true })
      XCTAssertEqual(try Data(contentsOf: h.store.root.appendingPathComponent("metadata.json")), data)
    }
  }

  func testDirectoryReplacementBeforeAndDuringTransactionIsRejected() throws {
    for during in [false, true] {
      let h = try CloudTestHarness()
      try h.activate()
      let replace = {
        try FileManager.default.moveItem(at: h.store.root, to: h.parent.appendingPathComponent("old-store"))
        try FileManager.default.createDirectory(at: h.store.root, withIntermediateDirectories: false)
      }
      if during {
        XCTAssertThrowsError(try h.store.transaction { state in
          state.consent = false
          try replace()
        })
      } else {
        try replace()
        XCTAssertThrowsError(try h.store.read())
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: h.store.root.appendingPathComponent("metadata.json").path))
    }
  }

  func testLockContentionHasABoundedFailure() throws {
    let h = try CloudTestHarness(lockTimeout: 0.02)
    let fd = open(h.store.root.appendingPathComponent("metadata.lock").path, O_CREAT | O_RDWR, 0o600)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { flock(fd, LOCK_UN); close(fd) }
    XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    let start = Date()
    XCTAssertThrowsError(try h.store.read())
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
  }

  func testReplacingAnAcquiredLockCannotCommitWithoutSerialization() throws {
    let h = try CloudTestHarness()
    try h.activate()
    let before = try h.store.read()
    XCTAssertThrowsError(try h.store.transaction { state in
      state.consent = false
      let path = h.store.root.appendingPathComponent("metadata.lock").path
      XCTAssertEqual(unlink(path), 0)
      let replacement = open(path, O_CREAT | O_EXCL | O_RDWR, 0o600)
      XCTAssertGreaterThanOrEqual(replacement, 0)
      if replacement >= 0 { close(replacement) }
    })
    XCTAssertEqual(try h.store.read(), before)
  }

  func testIndependentStoresSerializeDurableUpdates() throws {
    let h = try CloudTestHarness(lockTimeout: 1)
    let other = try CloudMetadataStore(root: h.store.root, lockTimeout: 1)
    let lock = NSLock()
    var failures = 0
    DispatchQueue.concurrentPerform(iterations: 2) { worker in
      for _ in 0..<20 {
        do { try (worker == 0 ? h.store : other).transaction { try $0.advance() } }
        catch { lock.lock(); failures += 1; lock.unlock() }
      }
    }
    XCTAssertEqual(failures, 0)
    XCTAssertEqual(try h.store.read().generation, 40)
  }

  func testCompletionRejectsDisplacedAndLateGenerations() {
    let gate = CloudCompletionGate<String>(fallback: { "generic" })
    var first: [String] = []
    var second: [String] = []
    let old = gate.begin { first.append($0) }
    let current = gate.begin { second.append($0) }
    XCTAssertEqual(first, ["generic"])
    XCTAssertFalse(gate.matches(old))
    XCTAssertFalse(gate.finish("private-old", generation: old))
    XCTAssertTrue(gate.finish("private-current", generation: current))
    gate.expire()
    XCTAssertEqual(second, ["private-current"])
    XCTAssertFalse(gate.finish("duplicate", generation: current))
  }

  func testTimeoutAndCompletionRaceInvokesTheHandlerExactlyOnce() {
    for _ in 0..<100 {
      let gate = CloudCompletionGate<String>(fallback: { "generic" })
      let lock = NSLock()
      var received: [String] = []
      let generation = gate.begin { value in lock.lock(); received.append(value); lock.unlock() }
      DispatchQueue.concurrentPerform(iterations: 2) { worker in
        if worker == 0 { gate.expire() } else { gate.finish("private", generation: generation) }
      }
      XCTAssertEqual(received.count, 1)
      XCTAssertTrue(["generic", "private"].contains(received[0]))
      XCTAssertFalse(gate.matches(generation))
    }
  }

  func testCompletionCallbackCanReenterWithoutHoldingTheLock() {
    let gate = CloudCompletionGate<String>(fallback: { "generic" })
    var next: UInt64 = 0
    var received: [String] = []
    let generation = gate.begin { _ in next = gate.begin { received.append($0) } }
    XCTAssertTrue(gate.finish("first", generation: generation))
    XCTAssertTrue(gate.finish("second", generation: next))
    XCTAssertEqual(received, ["second"])
    let fence = CloudFence()
    let old = fence.generation
    fence.advance()
    XCTAssertFalse(fence.matches(old))
    XCTAssertTrue(fence.matches(fence.generation))
  }
}
