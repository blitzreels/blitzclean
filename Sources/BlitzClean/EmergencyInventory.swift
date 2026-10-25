import Darwin
import Foundation

struct EmergencyTarget: Sendable, Identifiable {
  let id: String
  let name: String
  let detail: String
  let identities: [DevProcessIdentity]
  let bytes: UInt64
  let isSharedApp: Bool
  var appName: String? = nil

  var suspended: Bool { !identities.isEmpty && identities.allSatisfy { $0.process.stopped } }
}

enum EmergencyInventory {
  static func read() -> [EmergencyTarget] {
    let tree = LiveProcessTree.read()
    var identities: [Int32: DevProcessIdentity] = [:]
    var records: [RawProcessRecord] = []
    var directories: [Int32: String] = [:]
    var footprints: [Int32: UInt64] = [:]
    for (pid, parent) in tree.parents where pid != getpid() {
      guard let identity = DevProcessIdentity.read(pid),
        !identity.executable.contains("/BlitzClean.app/")
      else { continue }
      identities[pid] = identity
      let name = PathName.last(identity.executable)
      let arguments =
        name == "codex"
        ? AIThreadNames.processArguments(pid).joined(separator: " ") : identity.executable
      records.append(
        .init(
          processID: pid, parentProcessID: parent, userID: Int(getuid()),
          cpuPercent: 0, residentKilobytes: 0, elapsed: "", terminal: nil, arguments: arguments))
      directories[pid] = ProcessWorkingDirectory.read(pid)
      footprints[pid] = ProcessFootprint.bytes(pid)
    }
    let threads = AIThreadGrouping.threads(
      .init(
        records: records, directories: directories,
        footprints: footprints,
        startTimes: identities.mapValues {
          Double($0.process.startSeconds) + Double($0.process.startMicroseconds) / 1_000_000
        }, home: FileManager.default.homeDirectoryForCurrentUser.path,
        stoppedIDs: Set(
          identities.values.filter { $0.process.stopped }.map { $0.process.processID })))
    var targets = threads.map { thread in
      EmergencyTarget(
        id: thread.id, name: thread.displayName,
        detail: thread.tool == .codexDesktop
          ? "Local Codex workers · \(thread.directory ?? "shared")" : thread.identityDetail,
        identities: thread.processIDs.compactMap { identities[$0] }, bytes: thread.memoryBytes,
        isSharedApp: false, appName: thread.tool.appName)
    }
    var claimed = Set(threads.flatMap(\.processIDs))
    let runtimes: Set<String> = [
      "node", "bun", "deno", "pnpm-native", "tsc", "tsgo", "workerd", "esbuild", "ffmpeg",
    ]
    for record in records {
      guard !claimed.contains(record.processID), let identity = identities[record.processID],
        runtimes.contains(PathName.last(identity.executable)),
        !identity.executable.contains(".app/"),
        let directory = directories[record.processID], directory != "/",
        directory != FileManager.default.homeDirectoryForCurrentUser.path
      else { continue }
      var root = record.processID
      var visited: Set<Int32> = []
      while let parent = tree.parents[root], let candidate = identities[parent],
        runtimes.contains(PathName.last(candidate.executable)),
        !claimed.contains(parent), visited.insert(parent).inserted
      { root = parent }
      let ids = tree.descendants([root]).filter { identities[$0] != nil && !claimed.contains($0) }
      guard !ids.isEmpty else { continue }
      claimed.formUnion(ids)
      targets.append(
        .init(
          id: "process-\(root)", name: PathName.last(directory),
          detail: "Local workload · PID \(root)", identities: ids.compactMap { identities[$0] },
          bytes: ids.reduce(0) { $0 + (footprints[$1] ?? 0) }, isSharedApp: false))
    }
    for identity in identities.values
    where
      identity.executable.hasSuffix("/ChatGPT.app/Contents/MacOS/ChatGPT")
      || identity.executable.hasSuffix("/Codex.app/Contents/MacOS/Codex")
    {
      let ids = tree.descendants([identity.process.processID]).filter { identities[$0] != nil }
      targets.append(
        .init(
          id: "shared-\(identity.process.processID)", name: "Codex app — all chats",
          detail: "Shared host and all local workers. Stops every chat in this app.",
          identities: ids.compactMap { identities[$0] },
          bytes: ids.reduce(0) { $0 + (footprints[$1] ?? 0) },
          isSharedApp: true, appName: "Codex"))
    }
    return targets.filter { !$0.identities.isEmpty }.sorted {
      if $0.isSharedApp != $1.isSharedApp { return !$0.isSharedApp }
      return $0.bytes > $1.bytes
    }
  }
}
