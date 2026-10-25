import CryptoKit
import Foundation

struct ResourceProcess: Identifiable, Equatable, Sendable {
  let processID: Int32
  let parentProcessID: Int32
  let name: String
  let owner: String
  let directory: String?
  let memoryBytes: UInt64?
  let cpuPercent: Double
  let isTool: Bool
  /// Absolute path of the process's own executable.
  let executable: String
  var id: Int32 { processID }

  /// The app bundle this process ships inside, such as a browser helper; nil for tools started from a terminal.
  var bundleApp: String? { ResourceOwnership.appName(executable) }

  /// A macOS daemon; commands in /usr/bin such as `python3` or `yes` count as the user's own work.
  var isSystem: Bool {
    bundleApp == nil
      && ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
        .contains { executable.hasPrefix($0) }
  }
}

struct ResourceGroup: Identifiable, Codable, Equatable, Sendable {
  let id: String
  let name: String
  let owner: String
  let project: String?
  let processCount: Int
  let memoryBytes: UInt64
  let unknownMemoryCount: Int
}

enum ResourceOwnership {
  struct Input {
    let records: [RawProcessRecord]
    let directories: [Int32: String]
    let footprints: [Int32: UInt64]
    let executables: [Int32: String]
  }

  static func processes(_ input: Input) -> [ResourceProcess] {
    let records = Dictionary(
      input.records.map { ($0.processID, $0) }, uniquingKeysWith: { a, _ in a })
    return input.records.compactMap { record in
      guard let executable = input.executables[record.processID] else { return nil }
      var current = record
      var visited: Set<Int32> = []
      var owner: String?
      var directory: String?
      while visited.insert(current.processID).inserted {
        if directory == nil, let candidate = input.directories[current.processID],
          candidate != "/", candidate != FileManager.default.homeDirectoryForCurrentUser.path
        {
          directory = candidate
        }
        if let path = input.executables[current.processID], let app = appName(path) {
          owner = app
        }
        if owner == nil, let path = input.executables[current.processID] {
          let name = PathName.last(path)
          if name == "claude" { owner = "Claude Code" }
          if name == "codex" { owner = "Codex" }
        }
        guard let parent = records[current.parentProcessID], parent.userID == record.userID else {
          break
        }
        current = parent
      }
      let name = ResourceOwnership.label(executable)
      let arguments = record.arguments.lowercased()
      let runtime =
        ["node", "bun", "deno", "java", "uv", "npx"].contains(name)
        || name.lowercased().hasPrefix("python") || name.lowercased().contains("mcp")
      let isTool =
        (runtime && (arguments.contains("mcp") || arguments.contains("modelcontextprotocol")))
        || name == "node_repl" || name == "codex-code-mode-host"
      let label: String
      if isTool && arguments.contains("maestro") {
        label = "Maestro tools"
      } else if isTool && arguments.contains("studio") && arguments.contains("algomax") {
        label = "Algomax Studios tools"
      } else if isTool && arguments.contains("playwright") {
        label = "Playwright tools"
      } else if isTool && arguments.contains("chrome-devtools") {
        label = "Chrome DevTools"
      } else if isTool && name == "node" {
        label = "Node tool services"
      } else if isTool && (name.lowercased().contains("python") || name == "uv") {
        label = "Python tool services"
      } else {
        label = name
      }
      return ResourceProcess(
        processID: record.processID, parentProcessID: record.parentProcessID,
        name: label, owner: owner ?? "Background service", directory: directory,
        memoryBytes: input.footprints[record.processID], cpuPercent: record.cpuPercent,
        isTool: isTool, executable: executable)
    }
  }

  static func groups(_ processes: [ResourceProcess]) -> [ResourceGroup] {
    let grouped = Dictionary(grouping: processes, by: groupID)
    return grouped.compactMap { key, items in
      guard let first = items.first else { return nil }
      return ResourceGroup(
        id: key,
        name: first.name, owner: first.owner,
        project: first.directory.map { PathName.last($0) },
        processCount: items.count, memoryBytes: items.compactMap(\.memoryBytes).reduce(0, +),
        unknownMemoryCount: items.filter { $0.memoryBytes == nil }.count)
    }.sorted { $0.memoryBytes > $1.memoryBytes }
  }

  static func groupID(_ process: ResourceProcess) -> String {
    let key = [process.owner, process.directory ?? "", process.name].joined(separator: "\u{1F}")
    return GroupIDCache.shared.id(key)
  }

  /// The executable's name, except tools installed under a version folder, such as Claude Code's `versions/2.1.302`.
  static func label(_ executable: String) -> String {
    let url = URL(filePath: executable, directoryHint: .notDirectory)
    let name = url.lastPathComponent
    let parent = url.deletingLastPathComponent()
    guard parent.lastPathComponent == "versions", name.first?.isNumber == true else { return name }
    return parent.deletingLastPathComponent().lastPathComponent
  }

  static func appName(_ path: String) -> String? {
    appBundle(path).map { PathName.last(String($0.dropLast(4))) }
  }

  /// The outermost `.app` bundle that contains `path`, such as `/Applications/Chrome.app`.
  static func appBundle(_ path: String) -> String? {
    guard let range = path.range(of: ".app/") else { return nil }
    return String(path[..<range.lowerBound]) + ".app"
  }
}

@MainActor
enum ResourceSnapshotCache {
  static var groups: [ResourceGroup] = []
  static var pressure = PressureAssessment.checking
  static var scannedAt: Date?

  static var recentGroups: [ResourceGroup]? {
    guard let scannedAt, Date.now.timeIntervalSince(scannedAt) < 30 else { return nil }
    return Array(groups.prefix(32))
  }
}

/// Every scan hashes each process's owner, folder and name; the same few hundred keys repeat, so each is
/// hashed once.
final class GroupIDCache: @unchecked Sendable {
  static let shared = GroupIDCache()
  private let lock = NSLock()
  private var ids: [String: String] = [:]

  func id(_ key: String) -> String {
    lock.lock()
    defer { lock.unlock() }
    if let id = ids[key] { return id }
    if ids.count > 4_096 { ids.removeAll() }
    let id = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    ids[key] = id
    return id
  }
}
