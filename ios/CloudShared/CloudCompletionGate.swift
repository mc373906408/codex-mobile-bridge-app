import Foundation

/// A late result can complete only its own request; displaced and timed-out requests get a safe fallback.
final class CloudCompletionGate<Value> {
  private let lock = NSLock()
  private let fallback: () -> Value
  private var revision: UInt64 = 0
  private var handler: ((Value) -> Void)?

  init(fallback: @escaping () -> Value) { self.fallback = fallback }

  func begin(_ callback: @escaping (Value) -> Void) -> UInt64 {
    lock.lock()
    let displaced = handler
    revision &+= 1
    let generation = revision
    handler = callback
    lock.unlock()
    displaced?(fallback())
    return generation
  }

  func matches(_ generation: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return revision == generation && handler != nil
  }

  @discardableResult
  func finish(_ value: Value, generation: UInt64) -> Bool {
    lock.lock()
    guard revision == generation, let callback = handler else { lock.unlock(); return false }
    handler = nil
    revision &+= 1
    lock.unlock()
    callback(value)
    return true
  }

  func expire() {
    lock.lock()
    let callback = handler
    handler = nil
    revision &+= 1
    lock.unlock()
    callback?(fallback())
  }
}
