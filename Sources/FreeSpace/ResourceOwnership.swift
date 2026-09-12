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
  var id: Int32 { processID }
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
          let name = URL(fileURLWithPath: path).lastPathComponent
          if name == "claude" { owner = "Claude Code" }
          if name == "codex" { owner = "Codex" }
        }
        guard let parent = records[current.parentProcessID], parent.userID == record.userID else {
          break
        }
        current = parent
      }
      let name = URL(fileURLWithPath: executable).lastPathComponent
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
        isTool: isTool)
    }
  }

  static func groups(_ processes: [ResourceProcess]) -> [ResourceGroup] {
    let grouped = Dictionary(grouping: processes, by: groupID)
    return grouped.compactMap { key, items in
      guard let first = items.first else { return nil }
      return ResourceGroup(
        id: key,
        name: first.name, owner: first.owner,
        project: first.directory.map { URL(fileURLWithPath: $0).lastPathComponent },
        processCount: items.count, memoryBytes: items.compactMap(\.memoryBytes).reduce(0, +),
        unknownMemoryCount: items.filter { $0.memoryBytes == nil }.count)
    }.sorted { $0.memoryBytes > $1.memoryBytes }
  }

  static func groupID(_ process: ResourceProcess) -> String {
    let key = [process.owner, process.directory ?? "", process.name].joined(separator: "\u{1F}")
    return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func appName(_ path: String) -> String? {
    guard let range = path.range(of: ".app/") else { return nil }
    return URL(fileURLWithPath: String(path[..<range.lowerBound])).lastPathComponent
  }
}

@MainActor
enum ResourceSnapshotCache {
  static var groups: [ResourceGroup] = []
  static var scannedAt: Date?

  static var recentGroups: [ResourceGroup]? {
    guard let scannedAt, Date.now.timeIntervalSince(scannedAt) < 30 else { return nil }
    return Array(groups.prefix(32))
  }
}
