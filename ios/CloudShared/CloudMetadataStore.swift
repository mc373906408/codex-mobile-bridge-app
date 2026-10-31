import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct CloudMetadata: Codable, Equatable {
  var format = 1
  var generation: Int64 = 0
  var noticeVersion = ""
  var consent = false
  var permission = false
  var pins: [CloudPin] = []
  var receipts: [CloudReceipt] = []
  var baselines: [String: String] = [:]

  mutating func advance() throws {
    guard generation < Int64.max else { throw CloudFailure.full }
    generation += 1
  }

  func accepted(_ version: String) -> Bool { consent && noticeVersion == version }

  func validate() throws {
    guard format == 1, generation >= 0, noticeVersion.utf8.count <= 128,
      pins.count <= CloudPolicy.pinLimit, receipts.count <= CloudPolicy.receiptLimit,
      baselines.count <= CloudPolicy.pinLimit,
      Set(pins.map(\.computerId)).count == pins.count,
      Set(pins.map(\.bindingId)).count == pins.count,
      Set(pins.map(\.keyTag)).count == pins.count,
      Set(receipts.map(\.identity)).count == receipts.count
    else { throw CloudFailure.invalid }
    for pin in pins { try pin.validate() }
    for receipt in receipts {
      try receipt.validate()
      guard pins.contains(where: { receipt.matches($0) }) else { throw CloudFailure.invalid }
    }
    for (computer, scope) in baselines {
      guard pins.contains(where: { $0.computerId == computer }), CloudPolicy.scope(scope)
      else { throw CloudFailure.invalid }
    }
  }
}

/// No keys or preview text are stored here. A receipt is returned only after fsync.
final class CloudMetadataStore {
  let root: URL
  private let lockTimeout: TimeInterval
  private let directory: Int32

  init(root: URL, lockTimeout: TimeInterval = 0.2) throws {
    guard root.isFileURL, lockTimeout >= 0, lockTimeout <= 1 else { throw CloudFailure.invalid }
    self.root = root
    self.lockTimeout = lockTimeout
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else { throw CloudFailure.unavailable }
    var mutableRoot = root
    var resources = URLResourceValues()
    resources.isExcludedFromBackup = true
    try mutableRoot.setResourceValues(resources)
    #if os(iOS)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
    #endif
    let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw CloudFailure.unavailable }
    directory = fd
  }

  deinit { close(directory) }

  func read() throws -> CloudMetadata { try locked { _ in try load() } }

  func transaction<T>(now: Int64 = CloudPolicy.now, _ update: (inout CloudMetadata) throws -> T) throws -> T {
    try locked { lock in
      var state = try load()
      state.receipts.removeAll { !CloudPolicy.retained($0.expiresAt, now: now) }
      let result = try update(&state)
      try state.validate()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(state)
      guard data.count <= CloudPolicy.storeLimit else { throw CloudFailure.full }
      try checkLock(lock)
      try persist(data)
      return result
    }
  }

  private func checkDirectory() throws {
    var actual = stat()
    var pinned = stat()
    guard lstat(root.path, &actual) == 0, fstat(directory, &pinned) == 0,
      actual.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      actual.st_dev == pinned.st_dev, actual.st_ino == pinned.st_ino
    else { throw CloudFailure.unavailable }
  }

  private func checkLock(_ fd: Int32) throws {
    try checkDirectory()
    var actual = stat()
    var pinned = stat()
    guard fstat(fd, &pinned) == 0,
      fstatat(directory, "metadata.lock", &actual, AT_SYMLINK_NOFOLLOW) == 0,
      actual.st_dev == pinned.st_dev, actual.st_ino == pinned.st_ino,
      actual.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), actual.st_nlink == 1, pinned.st_nlink == 1
    else { throw CloudFailure.unavailable }
  }

  private func locked<T>(_ operation: (Int32) throws -> T) throws -> T {
    try checkDirectory()
    let fd = openat(directory, "metadata.lock", O_CREAT | O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw CloudFailure.unavailable }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1
    else { throw CloudFailure.unavailable }
    // Bound requested sleep without accessing the system-boot clock (a required-reason API).
    var attempts = Int((lockTimeout / 0.002).rounded(.up))
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR,
        attempts > 0
      else { throw CloudFailure.unavailable }
      attempts -= 1
      usleep(2000)
    }
    defer { flock(fd, LOCK_UN) }
    try checkLock(fd)
    let result = try operation(fd)
    try checkLock(fd)
    return result
  }

  private func load() throws -> CloudMetadata {
    let fd = openat(directory, "metadata.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 {
      if errno == ENOENT { return CloudMetadata() }
      throw CloudFailure.unavailable
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
      info.st_size > 0, info.st_size <= Int64(CloudPolicy.storeLimit)
    else { throw CloudFailure.unavailable }
    var data = Data(count: Int(info.st_size))
    try data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
      var offset = 0
      while offset < bytes.count {
        let count = systemRead(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw CloudFailure.unavailable }
        offset += count
      }
    }
    let state = try JSONDecoder().decode(CloudMetadata.self, from: data)
    try state.validate()
    return state
  }

  private func persist(_ data: Data) throws {
    let temporary = ".metadata-\(UUID().uuidString).tmp"
    var fd = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw CloudFailure.unavailable }
    defer {
      if fd >= 0 { close(fd) }
      unlinkat(directory, temporary, 0)
    }
    try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      var offset = 0
      while offset < bytes.count {
        let count = systemWrite(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw CloudFailure.unavailable }
        offset += count
      }
    }
    #if os(iOS)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: root.appendingPathComponent(temporary).path)
    #endif
    guard fsync(fd) == 0 else { throw CloudFailure.unavailable }
    let status = close(fd)
    fd = -1
    guard status == 0, renameat(directory, temporary, directory, "metadata.json") == 0
    else { throw CloudFailure.unavailable }
    guard fsync(directory) == 0 else { throw CloudFailure.unavailable }
  }
}

private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
  #if canImport(Darwin)
  return Darwin.read(fd, buffer, count)
  #else
  return Glibc.read(fd, buffer, count)
  #endif
}

private func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
  #if canImport(Darwin)
  return Darwin.write(fd, buffer, count)
  #else
  return Glibc.write(fd, buffer, count)
  #endif
}
