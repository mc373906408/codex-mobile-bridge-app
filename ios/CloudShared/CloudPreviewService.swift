import Foundation

struct CloudRuntimeConfiguration {
  let configured: Bool
  let noticeVersion: String
  let store: CloudMetadataStore
  let vault: CloudPreviewVault?

  init(configured: Bool, noticeVersion: String, store: CloudMetadataStore, vault: CloudPreviewVault?) {
    self.configured = configured
    self.noticeVersion = noticeVersion
    self.store = store
    self.vault = vault
  }

  init(bundle: Bundle = .main) throws {
    #if BRIDGE_CLOUD_PUSH
    configured = true
    noticeVersion = "cloud-apns-push-v1"
    guard let group = bundle.object(forInfoDictionaryKey: "BridgeCloudAppGroup") as? String,
      CloudPolicy.field(group), group.hasPrefix("group."), !group.contains("$("),
      let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
      let accessGroup = bundle.object(forInfoDictionaryKey: "BridgePreviewKeychainGroup") as? String
    else { throw CloudFailure.unavailable }
    store = try CloudMetadataStore(root: root.appendingPathComponent("Library/Application Support/BridgeCloud"))
    vault = try CloudKeyVault(accessGroup: accessGroup)
    #else
    configured = false
    noticeVersion = "cloud-notifications-v1"
    let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true)
    store = try CloudMetadataStore(root: root.appendingPathComponent("BridgeCloud"))
    vault = nil
    #endif
  }
}

struct CloudDirectEvent {
  let notificationId: String
  let eventId: String
  let expiresAt: Int64
  let kind: String

  init(object: [String: Any], scope: String, now: Int64) throws {
    guard Set(object.keys) == ["notificationId", "eventId", "expiresAt", "kind"],
      let id = object["notificationId"] as? String, let event = object["eventId"] as? String,
      let kind = object["kind"] as? String, ["request", "completion"].contains(kind),
      CloudPolicy.route(scope: scope, event: event, id: id)
    else { throw CloudFailure.invalid }
    let expires = try CloudPolicy.integer(object["expiresAt"])
    guard expires > 0, now <= Int64.max - 3600, expires <= now + 3600 else { throw CloudFailure.invalid }
    notificationId = id
    eventId = event
    expiresAt = expires
    self.kind = kind
  }
}

/// Shared app/NSE policy. The extension invokes no Flutter, account, control or network API.
final class CloudPreviewService {
  let configuration: CloudRuntimeConfiguration
  private let decrypt: (Data, CloudEnvelope, CloudPin, Int64) throws -> CloudPreview
  private let clock: () -> Int64
  var store: CloudMetadataStore { configuration.store }

  init(configuration: CloudRuntimeConfiguration,
       clock: @escaping () -> Int64 = { CloudPolicy.now },
       decrypt: @escaping (Data, CloudEnvelope, CloudPin, Int64) throws -> CloudPreview = CloudPreviewDecryptor.decrypt) {
    self.configuration = configuration
    self.clock = clock
    self.decrypt = decrypt
  }

  func save(computer: String, data: Data) throws {
    let credentials = try CloudCredentials(computerId: computer, data: data)
    var orphan: String?
    do {
      try store.transaction { state in
        if let saved = state.pins.first(where: { $0.computerId == computer }) {
          guard saved.sameIdentity(as: credentials.pin) else { throw CloudFailure.revoked }
          if let vault = configuration.vault {
            // Compare parsed JSON rather than property order from the control channel.
            if let oldData = try? vault.read(saved.keyTag) {
              let old = try JSONSerialization.jsonObject(with: oldData) as? NSDictionary
              let new = try JSONSerialization.jsonObject(with: data) as? NSDictionary
              guard old == new else { throw CloudFailure.revoked }
            } else {
              // Repair a missing item only from fresh authenticated control credentials; a locked item cannot be overwritten.
              try vault.save(data, tag: saved.keyTag)
              orphan = saved.keyTag
              try state.advance()
            }
          }
          return
        }
        guard state.pins.count < CloudPolicy.pinLimit,
          !state.pins.contains(where: { $0.bindingId == credentials.pin.bindingId })
        else { throw CloudFailure.full }
        if let vault = configuration.vault {
          try vault.save(data, tag: credentials.pin.keyTag)
          orphan = credentials.pin.keyTag
        }
        try state.advance()
        state.pins.append(credentials.pin)
      }
      orphan = nil
    } catch {
      if let tag = orphan { try? configuration.vault?.remove(tag) }
      throw error
    }
  }

  @discardableResult
  func remove(computer: String) throws -> [CloudReceipt] {
    var tag: String?
    let removed: [CloudReceipt]
    do {
      removed = try store.transaction { state -> [CloudReceipt] in
        tag = state.pins.first(where: { $0.computerId == computer })?.keyTag
        let removed = state.receipts.filter { $0.computerId == computer }
        state.pins.removeAll { $0.computerId == computer }
        state.receipts.removeAll { $0.computerId == computer }
        state.baselines.removeValue(forKey: computer)
        try state.advance()
        return removed
      }
    } catch {
      revokeKeysAfterStorageFailure()
      throw error
    }
    // Revoke the routing pin before deleting its preview-only Keychain entry.
    if let tag = tag { try? configuration.vault?.remove(tag) }
    return removed
  }

  func consent(_ enabled: Bool, version: String) throws {
    guard version == configuration.noticeVersion else { throw CloudFailure.invalid }
    do {
      try store.transaction { state in
        state.consent = enabled
        state.noticeVersion = version
        state.baselines.removeAll()
        try state.advance()
      }
    } catch {
      if !enabled { revokeKeysAfterStorageFailure() }
      throw error
    }
  }

  func permission(_ enabled: Bool) throws {
    do {
      if try store.read().permission == enabled { return }
      try store.transaction { state in
        if state.permission != enabled {
          state.permission = enabled
          state.baselines.removeAll()
          try state.advance()
        }
      }
    } catch {
      if !enabled { revokeKeysAfterStorageFailure() }
      throw error
    }
  }

  private func revokeKeysAfterStorageFailure() {
    try? configuration.vault?.removeAll()
  }

  func pending(computer: String, now: Int64 = CloudPolicy.now) throws -> [String] {
    let state = try store.read()
    guard let pin = state.pins.first(where: { $0.computerId == computer }) else { return [] }
    // Previously committed receipts can be ACKed after consent withdrawal.
    return Array(state.receipts.filter {
      $0.matches(pin) && !$0.acknowledged && $0.expiresAt > now
    }.prefix(100).map(\.notificationId))
  }

  func acknowledge(computer: String, ids: [String]) throws {
    guard ids.count <= 100, ids.allSatisfy(CloudPolicy.id) else { throw CloudFailure.invalid }
    try store.transaction { state in
      guard let pin = state.pins.first(where: { $0.computerId == computer }) else { throw CloudFailure.revoked }
      for index in state.receipts.indices where state.receipts[index].matches(pin) && ids.contains(state.receipts[index].notificationId) {
        state.receipts[index].acknowledged = true
      }
    }
  }

  func direct(computer: String, scope: String, events: [[String: Any]],
              current: () -> Bool, now: Int64 = CloudPolicy.now) throws -> [(CloudReceipt, String)] {
    guard CloudPolicy.field(computer), CloudPolicy.scope(scope), events.count <= 200 else { throw CloudFailure.invalid }
    let parsed = try events.map { try CloudDirectEvent(object: $0, scope: scope, now: now) }
    return try store.transaction(now: now) { state in
      guard current(), state.accepted(configuration.noticeVersion), state.permission,
        let pin = state.pins.first(where: { $0.computerId == computer }) else { throw CloudFailure.revoked }
      let baseline = state.baselines[computer] != scope
      var display: [(CloudReceipt, String)] = []
      let commitTime = clock()
      for event in parsed where CloudPolicy.live(event.expiresAt, now: now) &&
          CloudPolicy.live(event.expiresAt, now: commitTime) {
        let receipt = CloudReceipt(computerId: computer, origin: pin.origin, gatewayId: pin.gatewayId,
          bindingId: pin.bindingId, notificationId: event.notificationId, scope: scope,
          eventId: event.eventId, expiresAt: event.expiresAt)
        if let existing = state.receipts.first(where: { $0.identity == receipt.identity }) {
          guard existing.scope == receipt.scope && existing.eventId == receipt.eventId && existing.expiresAt == receipt.expiresAt
          else { throw CloudFailure.invalid }
          continue
        }
        guard state.receipts.count < CloudPolicy.receiptLimit else { throw CloudFailure.full }
        state.receipts.append(receipt)
        if !baseline { display.append((receipt, event.kind)) }
      }
      guard current() else { throw CloudFailure.revoked }
      state.baselines[computer] = scope
      return Array(display.suffix(10))
    }
  }

  func receive(_ envelope: CloudEnvelope, allowed: Bool, current: () -> Bool,
               now: Int64 = CloudPolicy.now) throws -> CloudPreview? {
    let snapshot = try store.read()
    guard allowed, current(), snapshot.permission, snapshot.accepted(configuration.noticeVersion),
      let pin = snapshot.pins.first(where: { $0.bindingId == envelope.bindingId }),
      let vault = configuration.vault else { throw CloudFailure.revoked }
    let credentials = try vault.read(pin.keyTag)
    let parsed = try CloudCredentials(computerId: pin.computerId, data: credentials, keyTag: pin.keyTag)
    guard parsed.pin == pin else { throw CloudFailure.revoked }
    let preview = try decrypt(credentials, envelope, pin, now)
    return try store.transaction(now: now) { state in
      guard current(), state.generation == snapshot.generation, state.permission,
        state.accepted(configuration.noticeVersion), state.pins.contains(pin),
        try vault.read(pin.keyTag) == credentials,
        CloudPolicy.live(envelope.expiresAt, now: clock())
      else { throw CloudFailure.revoked }
      if let existing = state.receipts.first(where: { $0.identity == preview.receipt.identity }) {
        guard existing.scope == preview.receipt.scope, existing.eventId == preview.receipt.eventId,
          existing.expiresAt == preview.receipt.expiresAt else { throw CloudFailure.invalid }
        return nil
      }
      guard state.receipts.count < CloudPolicy.receiptLimit else { throw CloudFailure.full }
      state.receipts.append(preview.receipt)
      return preview
    }
  }

  func authorize(binding: String, id: String, now: Int64 = CloudPolicy.now) throws -> CloudReceipt? {
    guard CloudPolicy.id(binding), CloudPolicy.id(id) else { return nil }
    let state = try store.read()
    guard state.permission, state.accepted(configuration.noticeVersion),
      let pin = state.pins.first(where: { $0.bindingId == binding }) else { return nil }
    return state.receipts.first { $0.matches(pin) && $0.notificationId == id && $0.expiresAt > now }
  }

  static func reference(_ userInfo: [AnyHashable: Any]) -> (String, String)? {
    let value = (userInfo["bridge_receipt"] ?? userInfo["bridge"]) as? [String: Any]
    guard let binding = value?["binding_id"] as? String, let id = value?["notification_id"] as? String,
      CloudPolicy.id(binding), CloudPolicy.id(id) else { return nil }
    return (binding, id)
  }
}
