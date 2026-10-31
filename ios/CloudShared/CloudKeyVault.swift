import Foundation
import Security

protocol CloudPreviewVault {
  func read(_ tag: String) throws -> Data
  func save(_ data: Data, tag: String) throws
  func remove(_ tag: String) throws
  func removeAll() throws
}

/// The extension is entitled to this preview-only group, never the app's control group.
final class CloudKeyVault: CloudPreviewVault {
  private let accessGroup: String

  init(accessGroup: String) throws {
    guard CloudPolicy.field(accessGroup), !accessGroup.contains("$(") else { throw CloudFailure.unavailable }
    self.accessGroup = accessGroup
  }

  private func query(_ tag: String) throws -> [String: Any] {
    guard CloudPolicy.id(tag) else { throw CloudFailure.invalid }
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "bridge.cloud.preview.v1",
      kSecAttrAccount as String: tag,
      kSecAttrAccessGroup as String: accessGroup,
      kSecAttrSynchronizable as String: false,
    ]
  }

  func read(_ tag: String) throws -> Data {
    var attributes = try query(tag)
    attributes[kSecReturnData as String] = true
    attributes[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data, (1...CloudPolicy.inputLimit).contains(data.count)
    else { throw CloudFailure.unavailable }
    return data
  }

  func save(_ data: Data, tag: String) throws {
    guard (1...CloudPolicy.inputLimit).contains(data.count) else { throw CloudFailure.invalid }
    var attributes = try query(tag)
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    attributes[kSecValueData as String] = data
    let status = SecItemAdd(attributes as CFDictionary, nil)
    if status == errSecDuplicateItem {
      guard try read(tag) == data else { throw CloudFailure.revoked }
    } else if status != errSecSuccess {
      throw CloudFailure.unavailable
    }
  }

  func remove(_ tag: String) throws {
    let status = SecItemDelete(try query(tag) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudFailure.unavailable }
  }

  func removeAll() throws {
    // This service and access group contain only disposable preview credentials.
    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "bridge.cloud.preview.v1",
      kSecAttrAccessGroup as String: accessGroup,
      kSecAttrSynchronizable as String: false,
    ]
    let status = SecItemDelete(attributes as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudFailure.unavailable }
  }
}
