import CryptoKit
import Darwin
import Foundation

struct CacheRule: Sendable {
  let title: String
  let path: String
  let recipe: String
  let owners: Set<String>

  static var standard: [Self] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
      .init(
        title: "npm downloads", path: home + "/.npm/_cacache",
        recipe: "npm downloads packages again when needed.", owners: ["npm", "pnpm", "npx"]),
      .init(
        title: "Homebrew downloads", path: home + "/Library/Caches/Homebrew/downloads",
        recipe: "Homebrew downloads installers again when needed.", owners: ["brew", "ruby"]),
      .init(
        title: "pip cache", path: home + "/Library/Caches/pip",
        recipe: "pip downloads and builds packages again.", owners: ["pip", "pip3"]),
      .init(
        title: "pip downloads", path: home + "/.cache/pip",
        recipe: "pip downloads and builds packages again.", owners: ["pip", "pip3"]),
      .init(
        title: "Yarn cache", path: home + "/Library/Caches/Yarn",
        recipe: "Yarn downloads packages again.", owners: ["yarn"]),
      .init(
        title: "Xcode build data", path: home + "/Library/Developer/Xcode/DerivedData",
        recipe: "Xcode rebuilds indexes and intermediates. The next build takes longer.",
        owners: ["Xcode", "xcodebuild", "swift", "swift-frontend", "clang"]),
    ]
  }
}

struct CacheTree: Equatable, Sendable {
  let fingerprint: String
  let bytes: UInt64
  let newest: Date
}

struct CacheCandidate: Identifiable, Sendable {
  let path: String
  let rule: CacheRule
  let tree: CacheTree
  var id: String { path }
  var name: String { URL(fileURLWithPath: path).lastPathComponent }
  var displayName: String {
    let parts = name.split(separator: "--", maxSplits: 1)
    if parts.count == 2, parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit) {
      return String(parts[1])
    }
    return name
  }
}

struct CacheScanRequest: Sendable {
  let rules: [CacheRule]
  let date: Date
}

struct CacheScanResult: Sendable {
  let candidates: [CacheCandidate]
  let notes: [String]
}

enum CacheCleanError: LocalizedError {
  case outsideRoot, changed, recent, busy, unverified, limit
  var errorDescription: String? {
    switch self {
    case .outsideRoot: "This item is outside the supported caches or is a symbolic link."
    case .changed: "This cache changed after the scan. Scan again to review it."
    case .recent: "This cache was used within the last seven days. It stays on your Mac."
    case .busy: "A process is using this cache or its package manager. Close it and scan again."
    case .unverified: "Activity or disk checks could not be completed. This cache was kept."
    case .limit: "This cache exceeds the scan limit. Review it in Finder."
    }
  }
}

enum CacheCleaner {
  struct TreeRequest {
    let path: String
    let deadline: Date
  }

  static func tree(_ request: TreeRequest) throws -> CacheTree {
    var queue = [request.path]
    var cursor = 0
    var bytes: UInt64 = 0
    var newest = Date.distantPast
    var hasher = SHA256()
    while cursor < queue.count {
      guard cursor < 60_000, Date.now < request.deadline else { throw CacheCleanError.limit }
      let path = queue[cursor]
      cursor += 1
      var info = stat()
      guard lstat(path, &info) == 0 else { throw CacheCleanError.unverified }
      let type = info.st_mode & S_IFMT
      guard type == S_IFREG || type == S_IFDIR else { throw CacheCleanError.outsideRoot }
      bytes += UInt64(max(0, info.st_blocks)) * 512
      newest = max(newest, Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)))
      let identity =
        "\(path)|\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)|\(info.st_mode)\n"
      hasher.update(data: Data(identity.utf8))
      if type == S_IFDIR {
        let children = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        guard queue.count + children.count <= 60_000 else { throw CacheCleanError.limit }
        queue.append(contentsOf: children.map { path + "/" + $0 })
      }
    }
    return CacheTree(
      fingerprint: hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes,
      newest: newest)
  }

  static func validateLocation(_ candidate: CacheCandidate) throws {
    let root = candidate.rule.path
    guard ReviewFile.canonicalPath(root) == root,
      ReviewFile.canonicalPath(candidate.path) == candidate.path,
      URL(fileURLWithPath: candidate.path).deletingLastPathComponent().path == root,
      CleanupVolume.read(candidate.path)?.isInternal == true
    else { throw CacheCleanError.outsideRoot }
  }

  static func processes() throws -> Set<String> {
    let result = CleanupActivity.runCommand(
      .init(executable: "/bin/ps", arguments: ["-axo", "comm="], timeout: 5))
    guard result.status == 0, !result.output.isEmpty else { throw CacheCleanError.unverified }
    return Set(
      result.output.split(separator: "\n").map {
        URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)).lastPathComponent
      })
  }

  static func scan(_ request: CacheScanRequest) -> CacheScanResult {
    var candidates: [CacheCandidate] = []
    var notes: [String] = []
    let deadline = Date.now.addingTimeInterval(45)
    guard let owners = try? processes() else {
      return .init(candidates: [], notes: [CacheCleanError.unverified.localizedDescription])
    }
    for rule in request.rules {
      guard FileManager.default.fileExists(atPath: rule.path) else { continue }
      guard Date.now < deadline else {
        notes.append("Scan time limit reached. Some caches were not measured.")
        break
      }
      guard owners.isDisjoint(with: rule.owners) else {
        notes.append("\(rule.title): its tools are running; kept.")
        continue
      }
      guard ReviewFile.canonicalPath(rule.path) == rule.path,
        let children = try? FileManager.default.contentsOfDirectory(atPath: rule.path)
      else {
        notes.append("\(rule.title): folder could not be read or is a link.")
        continue
      }
      for child in children.sorted() {
        let path = rule.path + "/" + child
        do {
          let contents = try tree(
            .init(path: path, deadline: min(deadline, .now.addingTimeInterval(8))))
          let candidate = CacheCandidate(path: path, rule: rule, tree: contents)
          try validateLocation(candidate)
          guard contents.newest < request.date.addingTimeInterval(-7 * 86_400), contents.bytes > 0
          else { continue }
          candidates.append(candidate)
        } catch {
          notes.append("\(rule.title) / \(child): \(error.localizedDescription)")
        }
        if Date.now >= deadline { break }
      }
    }
    return .init(candidates: candidates.sorted { $0.tree.bytes > $1.tree.bytes }, notes: notes)
  }

  static func delete(_ candidate: CacheCandidate) throws -> CleanupWin {
    try validateLocation(candidate)
    let owners = try processes()
    guard owners.isDisjoint(with: candidate.rule.owners) else { throw CacheCleanError.busy }
    var isDirectory: ObjCBool = false
    _ = FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
    let activity = CleanupActivity.command(
      isDirectory.boolValue ? ["-nP", "+D", candidate.path] : ["-nP", "--", candidate.path])
    if activity.status == 0 { throw CacheCleanError.busy }
    guard activity.status == 1, activity.output.isEmpty else { throw CacheCleanError.unverified }
    let current = try tree(.init(path: candidate.path, deadline: .now.addingTimeInterval(15)))
    guard current == candidate.tree else { throw CacheCleanError.changed }
    guard current.newest < Date.now.addingTimeInterval(-7 * 86_400) else {
      throw CacheCleanError.recent
    }
    try validateLocation(candidate)
    let before = CleanupVolume.read(candidate.path)
    try FileManager.default.removeItem(atPath: candidate.path)
    return .init(
      id: UUID().uuidString, date: .now, title: "Cleaned \(candidate.rule.title)",
      paths: [candidate.path],
      before: before, after: before.flatMap { CleanupVolume.read($0.path) })
  }
}

@MainActor
final class QuickCleanModel: ObservableObject {
  @Published private(set) var candidates: [CacheCandidate] = []
  @Published private(set) var notes: [String] = []
  @Published private(set) var isScanning = false
  @Published private(set) var isCleaning = false
  @Published private(set) var scannedAt: Date?
  @Published private(set) var status: String?
  @Published private(set) var completed = 0
  @Published var selected: Set<String> = []

  var selectedItems: [CacheCandidate] { candidates.filter { selected.contains($0.path) } }
  var selectedBytes: UInt64 { selectedItems.reduce(0) { $0 + $1.tree.bytes } }
  var totalBytes: UInt64 { candidates.reduce(0) { $0 + $1.tree.bytes } }

  func scan() {
    guard !isScanning, !isCleaning else { return }
    isScanning = true
    Task {
      let result = await Task.detached(priority: .utility) {
        CacheCleaner.scan(.init(rules: CacheRule.standard, date: .now))
      }.value
      candidates = result.candidates
      notes = result.notes
      selected.formIntersection(candidates.map(\.path))
      scannedAt = .now
      isScanning = false
    }
  }

  func clean(history: CleanupOverviewModel) {
    guard !isCleaning, !isScanning, !selectedItems.isEmpty else { return }
    let items = selectedItems
    isCleaning = true
    completed = 0
    status = "Checking activity before cleanup…"
    Task {
      var failures: [String] = []
      var removed: Set<String> = []
      let before = CleanupVolume.read(FileManager.default.homeDirectoryForCurrentUser.path)
      for item in items {
        do {
          let win = try await Task.detached(priority: .utility) { try CacheCleaner.delete(item) }
            .value
          history.record(win)
          removed.insert(item.path)
        } catch {
          failures.append("\(item.rule.title) / \(item.name): \(error.localizedDescription)")
        }
        completed += 1
        status = "Reviewed \(completed) of \(items.count) caches"
      }
      let after = before.flatMap { CleanupVolume.read($0.path) }
      let gain = before.flatMap { old in
        after.map { $0.available > old.available ? $0.available - old.available : 0 }
      }
      candidates.removeAll { removed.contains($0.path) }
      selected.subtract(removed)
      notes = failures
      status =
        "Cleaned \(removed.count) caches · \(gain.map(ByteText.full) ?? "unmeasured") more disk space available.\(failures.isEmpty ? "" : " \(failures.count) kept; see details.") Other disk activity affects this measurement."
      isCleaning = false
    }
  }
}
