import CoreFoundation
import Foundation

enum CloudFailure: Error {
  case invalid, unavailable, revoked, full
}

enum CloudPolicy {
  static let receiptLimit = 4096
  static let pinLimit = 200
  static let inputLimit = 4096
  static let storeLimit = 2 * 1024 * 1024

  static func id(_ value: String) -> Bool {
    UUID(uuidString: value)?.uuidString.lowercased() == value
  }

  static func field(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
      $0.value >= 33 && $0.value <= 126
    }
  }

  static func scope(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  static func origin(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 2048,
      value.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }),
      let url = URLComponents(string: value), url.scheme == "https",
      let host = url.percentEncodedHost, !host.isEmpty, host == host.lowercased(),
      !host.contains("%"), url.user == nil, url.password == nil,
      url.path.isEmpty, url.query == nil, url.fragment == nil,
      url.port == nil || ((1...65535).contains(url.port!) && url.port != 443)
    else { return false }
    let authority = host + (url.port.map { ":\($0)" } ?? "")
    return value == "https://" + authority && url.url != nil
  }

  static func key(_ value: String) -> Bool {
    guard let data = Data(base64Encoded: value), data.count == 32,
      data.base64EncodedString() == value
    else { return false }
    return data.contains { $0 != 0 }
  }

  static func integer(_ raw: Any?) throws -> Int64 {
    guard let number = raw as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
      number.doubleValue >= 0, number.doubleValue < Double(Int64.max),
      NSNumber(value: number.int64Value) == number
    else { throw CloudFailure.invalid }
    return number.int64Value
  }

  static func live(_ expires: Int64, now: Int64) -> Bool {
    now >= 0 && now <= Int64.max - 3600 && expires > now && expires <= now + 3600
  }

  static func retained(_ expires: Int64, now: Int64) -> Bool {
    expires > 0 && expires <= Int64.max - 3600 && expires + 3600 > now
  }

  static func route(scope: String, event: String, id: String) -> Bool {
    self.scope(scope) && self.id(id) && event == "cloud:\(id)"
  }

  static var now: Int64 { Int64(Date().timeIntervalSince1970) }
}

struct CloudPin: Codable, Equatable {
  let computerId: String
  let origin: String
  let gatewayId: String
  let bindingId: String
  let desktopPublicKey: String
  let keyTag: String

  func validate() throws {
    guard CloudPolicy.field(computerId), CloudPolicy.origin(origin), CloudPolicy.id(gatewayId),
      CloudPolicy.id(bindingId), CloudPolicy.key(desktopPublicKey), CloudPolicy.id(keyTag)
    else { throw CloudFailure.invalid }
  }

  func sameIdentity(as other: CloudPin) -> Bool {
    computerId == other.computerId && origin == other.origin && gatewayId == other.gatewayId &&
      bindingId == other.bindingId && desktopPublicKey == other.desktopPublicKey
  }
}

struct CloudCredentials {
  let pin: CloudPin
  let data: Data

  init(computerId: String, data: Data, keyTag: String = UUID().uuidString.lowercased()) throws {
    guard (1...CloudPolicy.inputLimit).contains(data.count),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == ["origin", "gateway_id", "binding_id", "private_key", "desktop_public_key"],
      let origin = object["origin"] as? String, let gateway = object["gateway_id"] as? String,
      let binding = object["binding_id"] as? String, let desktop = object["desktop_public_key"] as? String,
      let privateKey = object["private_key"] as? String, CloudPolicy.key(privateKey)
    else { throw CloudFailure.invalid }
    let candidate = CloudPin(computerId: computerId, origin: origin, gatewayId: gateway, bindingId: binding,
                             desktopPublicKey: desktop, keyTag: keyTag)
    try candidate.validate()
    pin = candidate
    self.data = data
  }
}

struct CloudEnvelope {
  let notificationId: String
  let bindingId: String
  let expiresAt: Int64
  let data: Data

  init(object: [String: Any], now: Int64) throws {
    guard Set(object.keys) == ["v", "notification_id", "binding_id", "expires_at", "ciphertext"],
      try CloudPolicy.integer(object["v"]) == 1,
      let id = object["notification_id"] as? String, CloudPolicy.id(id),
      let binding = object["binding_id"] as? String, CloudPolicy.id(binding),
      let ciphertext = object["ciphertext"] as? String,
      let bytes = Data(base64Encoded: ciphertext), (48...1072).contains(bytes.count),
      bytes.base64EncodedString() == ciphertext
    else { throw CloudFailure.invalid }
    let expires = try CloudPolicy.integer(object["expires_at"])
    guard CloudPolicy.live(expires, now: now) else { throw CloudFailure.invalid }
    let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard encoded.count <= CloudPolicy.inputLimit else { throw CloudFailure.invalid }
    data = encoded
    notificationId = id
    bindingId = binding
    expiresAt = expires
  }
}

struct CloudReceipt: Codable, Equatable {
  let computerId: String
  let origin: String
  let gatewayId: String
  let bindingId: String
  let notificationId: String
  let scope: String
  let eventId: String
  let expiresAt: Int64
  var acknowledged = false

  var identity: String { "\(bindingId):\(notificationId)" }

  func matches(_ pin: CloudPin) -> Bool {
    computerId == pin.computerId && origin == pin.origin && gatewayId == pin.gatewayId && bindingId == pin.bindingId
  }

  func validate() throws {
    guard CloudPolicy.field(computerId), CloudPolicy.origin(origin), CloudPolicy.id(gatewayId),
      CloudPolicy.id(bindingId), CloudPolicy.route(scope: scope, event: eventId, id: notificationId),
      expiresAt > 0, expiresAt <= Int64.max - 3600
    else { throw CloudFailure.invalid }
  }

  var tap: [String: String] { ["computerId": computerId, "scope": scope, "eventId": eventId] }
  var reference: [String: String] { ["binding_id": bindingId, "notification_id": notificationId] }
}

struct CloudPreview {
  let receipt: CloudReceipt
  let title: String
  let body: String

  init(data: Data, pin: CloudPin, envelope: CloudEnvelope, now: Int64) throws {
    guard data.count <= 4096, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      value["origin"] as? String == pin.origin, value["gateway_id"] as? String == pin.gatewayId,
      value["binding_id"] as? String == pin.bindingId,
      value["notification_id"] as? String == envelope.notificationId,
      try CloudPolicy.integer(value["expires_at"]) == envelope.expiresAt,
      let title = value["title"] as? String, !title.isEmpty, title.unicodeScalars.count <= 200,
      let body = value["body"] as? String, body.unicodeScalars.count <= 600,
      let scope = value["scope"] as? String, let event = value["event_id"] as? String,
      CloudPolicy.route(scope: scope, event: event, id: envelope.notificationId),
      CloudPolicy.live(envelope.expiresAt, now: now)
    else { throw CloudFailure.invalid }
    self.title = title
    self.body = body
    receipt = CloudReceipt(computerId: pin.computerId, origin: pin.origin, gatewayId: pin.gatewayId,
      bindingId: pin.bindingId, notificationId: envelope.notificationId, scope: scope,
      eventId: event, expiresAt: envelope.expiresAt)
  }
}
