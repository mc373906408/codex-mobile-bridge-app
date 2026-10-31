import Foundation

/// Shared by the app's async operations and the extension's timeout callback.
final class CloudFence {
  private let lock = NSLock()
  private var revision: UInt64 = 0

  var generation: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return revision
  }

  func advance() {
    lock.lock()
    defer { lock.unlock() }
    revision &+= 1
  }

  func matches(_ generation: UInt64) -> Bool { self.generation == generation }
}
