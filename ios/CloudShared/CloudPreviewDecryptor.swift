import Foundation
#if SWIFT_PACKAGE && BRIDGE_CLOUD_PUSH
import BridgePreviewFFI
#endif

enum CloudPreviewDecryptor {
  static func decrypt(credentials: Data, envelope: CloudEnvelope, pin: CloudPin, now: Int64) throws -> CloudPreview {
    #if BRIDGE_CLOUD_PUSH
    guard (1...CloudPolicy.inputLimit).contains(credentials.count) else { throw CloudFailure.invalid }
    var count = 0
    let output = credentials.withUnsafeBytes { (keys: UnsafeRawBufferPointer) in
      envelope.data.withUnsafeBytes { (payload: UnsafeRawBufferPointer) in
        bridge_preview_decrypt(keys.bindMemory(to: UInt8.self).baseAddress, keys.count,
          payload.bindMemory(to: UInt8.self).baseAddress, payload.count, now, &count)
      }
    }
    guard let output = output else { throw CloudFailure.unavailable }
    defer { bridge_preview_free(output, count) }
    guard (1...4096).contains(count) else { throw CloudFailure.invalid }
    return try CloudPreview(data: Data(bytes: output, count: count), pin: pin, envelope: envelope, now: now)
    #else
    // The ordinary build contains neither a preview private key nor this Rust library.
    throw CloudFailure.unavailable
    #endif
  }
}
