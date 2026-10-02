import Darwin
import Foundation

struct CleanupVolume: Codable, Equatable, Sendable {
  let path: String
  let available: UInt64
  let isInternal: Bool

  static func read(_ path: String) -> Self? {
    var capacity = statfs()
    var internalCapacity = statfs()
    guard statfs(path, &capacity) == 0,
      statfs("/System/Volumes/Data", &internalCapacity) == 0
    else { return nil }
    let mount = withUnsafeBytes(of: capacity.f_mntonname) {
      String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
    }
    return Self(
      path: mount, available: capacity.f_bavail * UInt64(capacity.f_bsize),
      isInternal: capacity.f_fsid.val.0 == internalCapacity.f_fsid.val.0
        && capacity.f_fsid.val.1 == internalCapacity.f_fsid.val.1)
  }
}

struct CleanupWin: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let date: Date
  let title: String
  let paths: [String]
  let before: CleanupVolume?
  let after: CleanupVolume?
  /// Folder size measured before removal, when known.
  var bytes: UInt64? = nil

  var measuredGain: UInt64? {
    guard let before, let after, before.path == after.path else { return nil }
    return after.available > before.available ? after.available - before.available : 0
  }
}

struct CleanupLedger: Codable, Equatable, Sendable {
  var wins: [CleanupWin] = []

  mutating func record(_ win: CleanupWin) {
    guard !win.paths.isEmpty, !wins.contains(where: { $0.id == win.id }) else { return }
    wins.append(win)
    wins.sort { $0.date > $1.date }
    wins = Array(wins.prefix(1_000))
  }

  var internalGains: UInt64 {
    wins.filter { $0.after?.isInternal == true }.reduce(0) { $0 + ($1.measuredGain ?? 0) }
  }

  var latestInternal: CleanupWin? {
    wins.first { $0.after?.isInternal == true }
  }
}

struct CleanupHistoryStore: Sendable {
  let url: URL

  static var application: Self {
    Self(
      url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FreeSpace/cleanup-history.json"))
  }

  func load() throws -> CleanupLedger {
    guard FileManager.default.fileExists(atPath: url.path) else { return CleanupLedger() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CleanupLedger.self, from: Data(contentsOf: url))
  }

  func save(_ ledger: CleanupLedger) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(ledger).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  func merge(_ incoming: CleanupLedger) throws -> CleanupLedger {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let descriptor = open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw POSIXError(.EACCES) }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EWOULDBLOCK) }
    defer { flock(descriptor, LOCK_UN) }
    var latest = try load()
    for win in incoming.wins { latest.record(win) }
    try save(latest)
    return latest
  }
}
