import Combine
import Darwin
import Foundation

enum RegrowRecipe: String, Codable, Sendable {
  case folder
  case dependencies
  case pnpmPrune
}

/// A folder that was removed before and that tools rebuild on their own.
struct RegrowTarget: Identifiable, Equatable, Sendable {
  let path: String
  let title: String
  let recipe: RegrowRecipe
  /// Shared caches are kept while one of these tools runs. Empty means project activity decides.
  let owners: Set<String>
  var id: String { path }
}

struct RemovedEntry: Identifiable, Equatable, Sendable {
  let target: RegrowTarget
  let removals: Int
  let lastRemovedAt: Date
  let freedBytes: UInt64
  var id: String { target.path }
}

enum RegrowCatalog {
  private static let projectFolders: [String: String] = [
    ".next": "Next.js build", ".turbo": "Turborepo cache", ".nuxt": "Nuxt build",
    ".svelte-kit": "SvelteKit build", ".parcel-cache": "Parcel cache", ".angular": "Angular cache",
    ".expo": "Expo cache", "node_modules": "Dependencies",
  ]
  private static let xcode: Set<String> = ["Xcode", "xcodebuild"]

  static func target(for path: String, home: String) -> RegrowTarget? {
    guard path.hasPrefix(home + "/"), !path.contains("/.Trash/") else { return nil }
    let parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
    func prefix(_ count: Int) -> String { home + "/" + parts.prefix(count).joined(separator: "/") }
    if parts.starts(with: ["Library", "pnpm", "store"]) {
      return .init(path: prefix(3), title: "pnpm store", recipe: .pnpmPrune, owners: ["pnpm"])
    }
    if parts.starts(with: [".npm", "_cacache"]) {
      return .init(path: prefix(2), title: "npm cache", recipe: .folder, owners: ["npm", "npx"])
    }
    if parts.starts(with: ["Library", "Caches", "Homebrew", "downloads"]) {
      return .init(path: prefix(4), title: "Homebrew downloads", recipe: .folder, owners: ["brew"])
    }
    if parts.starts(with: ["Library", "Developer", "Xcode", "DerivedData"]) {
      return .init(
        path: prefix(min(parts.count, 5)), title: "Xcode build data", recipe: .folder, owners: xcode
      )
    }
    for (index, part) in parts.enumerated() {
      if part == "DerivedData" {
        return .init(
          path: prefix(index + 1), title: "Xcode build data", recipe: .folder, owners: xcode)
      }
      if part == "tmp", index > 0, parts[index - 1] == ".trigger" {
        return .init(
          path: prefix(index + 1), title: "Trigger.dev builds", recipe: .folder, owners: [])
      }
      if let title = projectFolders[part] {
        return .init(
          path: prefix(index + 1), title: title,
          recipe: part == "node_modules" ? .dependencies : .folder, owners: [])
      }
    }
    return nil
  }

  static func entries(_ ledger: CleanupLedger, home: String) -> [RemovedEntry] {
    var grouped: [String: RemovedEntry] = [:]
    for win in ledger.wins {
      let targets = Dictionary(
        win.paths.compactMap { target(for: $0, home: home) }.map { ($0.path, $0) },
        uniquingKeysWith: { first, _ in first })
      let freed = targets.count == 1 ? win.bytes ?? win.measuredGain ?? 0 : 0
      for target in targets.values {
        let previous = grouped[target.path]
        grouped[target.path] = RemovedEntry(
          target: target, removals: (previous?.removals ?? 0) + 1,
          lastRemovedAt: max(previous?.lastRemovedAt ?? .distantPast, win.date),
          freedBytes: (previous?.freedBytes ?? 0) + freed)
      }
    }
    return grouped.values.sorted { $0.lastRemovedAt > $1.lastRemovedAt }
  }

  /// The repository that owns a project folder, or the folder's parent outside a repository.
  static func projectRoot(_ target: RegrowTarget, home: String) -> String? {
    guard target.owners.isEmpty else { return nil }
    var url = URL(fileURLWithPath: target.path).deletingLastPathComponent()
    while url.path.hasPrefix(home + "/") {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
        return url.path
      }
      url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: target.path).deletingLastPathComponent().path
  }
}

struct RegrowActivity: Sendable {
  struct Process: Sendable {
    let arguments: String
    let directory: String?
    var name: String { AIThreadGrouping.executableName(arguments) }
  }

  let processes: [Process]

  private static let buildTools: Set<String> = [
    "next-server", "esbuild", "turbo", "vite", "webpack", "tsc", "metro", "workerd", "wrangler",
    "xcodebuild", "swift-build", "swift-frontend", "gradle", "cargo", "pnpm-native", "nodemon",
  ]
  private static let taskWords: Set<String> = ["dev", "start", "build", "watch", "preview"]
  /// Agents run builds as child processes; the agent process alone does not use build output.
  private static let agents: Set<String> = [
    "cursor-agent", "claude", "codex", "gemini", "opencode",
  ]

  static func read() -> Self? {
    let listing = CleanupActivity.runCommand(
      .init(executable: "/bin/ps", arguments: ["-axwwo", "pid=,args="], timeout: 8))
    let directories = CleanupActivity.command(["-nP", "-d", "cwd", "-Fpn"])
    guard listing.status == 0, directories.status == 0 else { return nil }
    let cwd = ProjectProcessParser.workingDirectories(directories.output)
    return Self(
      processes: listing.output.split(separator: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]),
          pid != getpid()
        else { return nil }
        return Process(
          arguments: String(trimmed[space...]).trimmingCharacters(in: .whitespaces),
          directory: cwd[pid])
      })
  }

  /// Why the target must stay, or nil when nothing is building from it.
  func blocker(_ target: RegrowTarget, projectRoot: String?) -> String? {
    if !target.owners.isEmpty {
      return processes.first { target.owners.contains($0.name) }.map { "\($0.name) is running" }
    }
    guard let root = projectRoot else { return nil }
    let running = processes.first { process in
      guard let directory = process.directory, directory == root || directory.hasPrefix(root + "/")
      else { return false }
      return Self.isBuilding(process, root: root)
    }
    return running.map {
      "\($0.name) is running in \(URL(fileURLWithPath: root).lastPathComponent)"
    }
  }

  static func isBuilding(_ process: Process, root: String) -> Bool {
    if buildTools.contains(process.name) { return true }
    guard !agents.contains(process.name) else { return false }
    let arguments = process.arguments
    guard !arguments.localizedCaseInsensitiveContains("mcp") else { return false }
    if arguments.contains(root + "/") { return true }
    let tokens = arguments.split(separator: " ")
    guard !tokens.contains("exec") else { return false }
    return tokens.contains { token in
      taskWords.contains(String(token))
        || ["dev", "build", "start"].contains { token.hasSuffix(":\($0)") }
    }
  }
}

enum RegrowCleanError: LocalizedError, Equatable {
  case moved
  case busy(String)
  case unverified
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .moved: "It moved, became a link, or is on another disk. Nothing was removed."
    case .busy(let reason): "\(reason). Stop it first; nothing was removed."
    case .unverified: "Running processes could not be checked. Nothing was removed."
    case .failed(let reason): reason
    }
  }
}

enum RegrowCleaner {
  static func size(_ path: String) -> UInt64? {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
    let result = CleanupActivity.runCommand(
      .init(executable: "/usr/bin/du", arguments: ["-sk", path], timeout: 60))
    guard
      let kilobytes = result.output.split(whereSeparator: \.isWhitespace).first.flatMap({
        UInt64($0)
      })
    else { return nil }
    return kilobytes * 1_024
  }

  /// Repeat removal must not bypass the cache review's freshness and identity checks.
  static func reviewedTree(_ target: RegrowTarget) throws -> CacheTree {
    let tree = try CacheCleaner.tree(
      .init(path: target.path, deadline: .now.addingTimeInterval(15)))
    guard tree.newest < Date.now.addingTimeInterval(-7 * 86_400) else {
      throw CacheCleanError.recent
    }
    let directory = URL(fileURLWithPath: target.path).deletingLastPathComponent().path
    let repository = DeveloperCommand.git(
      .init(directory: directory, arguments: ["rev-parse", "--show-toplevel"]))
    if repository.status == 0 {
      let tracked = DeveloperCommand.git(
        .init(directory: directory, arguments: ["ls-files", "-z", "--", target.path]))
      guard tracked.status == 0, tracked.output.isEmpty else {
        throw RegrowCleanError.busy("Folder contains tracked files or Git could not verify them")
      }
    } else {
      // A failed Git check is only safe outside a repository, not inside a broken one.
      var ancestor = URL(fileURLWithPath: directory)
      while ancestor.path != "/" {
        if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
          throw RegrowCleanError.unverified
        }
        ancestor.deleteLastPathComponent()
      }
    }
    let handles = CleanupActivity.command(["-nP", "-Fpcn", "+D", target.path])
    guard handles.status == 1, handles.output.isEmpty else { throw RegrowCleanError.unverified }
    return tree
  }

  static func remove(_ target: RegrowTarget, home: String) throws -> CleanupWin {
    guard RegrowCatalog.target(for: target.path, home: home) == target,
      ReviewFile.canonicalPath(target.path) == target.path,
      CleanupVolume.read(target.path)?.isInternal == true,
      let bytes = size(target.path)
    else { throw RegrowCleanError.moved }
    guard let activity = RegrowActivity.read() else { throw RegrowCleanError.unverified }
    if let reason = activity.blocker(
      target, projectRoot: RegrowCatalog.projectRoot(target, home: home))
    {
      throw RegrowCleanError.busy(reason)
    }
    guard !WorkspacePreferences.isKeptRunning(RegrowCatalog.projectRoot(target, home: home)) else {
      throw RegrowCleanError.busy("Keep running is enabled")
    }
    let before = CleanupVolume.read(target.path)
    switch target.recipe {
    case .folder, .dependencies:
      let reviewed = try reviewedTree(target)
      guard ReviewFile.canonicalPath(target.path) == target.path,
        try CacheCleaner.tree(.init(path: target.path, deadline: .now.addingTimeInterval(15)))
          == reviewed
      else { throw CacheCleanError.changed }
      try FileManager.default.removeItem(atPath: target.path)
    case .pnpmPrune:
      guard let pnpm = pnpmExecutable(home: home) else {
        throw RegrowCleanError.failed("pnpm was not found. Run pnpm store prune in Terminal.")
      }
      let result = CleanupActivity.runCommand(
        .init(executable: pnpm, arguments: ["store", "prune"], timeout: 600))
      guard result.status == 0 else {
        throw RegrowCleanError.failed(
          "pnpm store prune failed: \(result.output.suffix(200).trimmingCharacters(in: .whitespacesAndNewlines))"
        )
      }
    }
    return CleanupWin(
      id: UUID().uuidString, date: .now, title: "Removed again: \(target.title)",
      paths: [target.path], before: before, after: before.flatMap { CleanupVolume.read($0.path) },
      bytes: target.recipe == .pnpmPrune ? nil : bytes)
  }

  private static func pnpmExecutable(home: String) -> String? {
    ["/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm", home + "/Library/pnpm/pnpm"].first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
  }
}

/// Cleanup reports written outside the app, such as an agent-run cleanup, in the same JSON shape.
enum CleanupReportImporter {
  private struct Report: Decodable {
    struct Started: Decodable { let at: Double? }
    struct Removed: Decodable {
      let path: String
      let allocatedBytes: UInt64?
      let freeBefore: UInt64?
      let freeAfter: UInt64?
      let time: Double?
    }
    let started: Started?
    let removed: [Removed]?
  }

  static func wins(_ url: URL) -> [CleanupWin] {
    guard let data = try? Data(contentsOf: url),
      let report = try? JSONDecoder().decode(Report.self, from: data)
    else { return [] }
    let fallback =
      (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .now
    return (report.removed ?? []).enumerated().map { index, item in
      let internalDisk = !item.path.hasPrefix("/Volumes/")
      let volume = { (free: UInt64?) in
        free.map {
          CleanupVolume(path: "/System/Volumes/Data", available: $0, isInternal: internalDisk)
        }
      }
      return CleanupWin(
        id: "report:\(url.lastPathComponent):\(index)",
        date: (item.time ?? report.started?.at).map(Date.init(timeIntervalSince1970:)) ?? fallback,
        title: "Removed \(URL(fileURLWithPath: item.path).lastPathComponent)",
        paths: [item.path], before: volume(item.freeBefore), after: volume(item.freeAfter),
        bytes: item.allocatedBytes)
    }
  }
}

struct RegrowStatus: Equatable, Sendable {
  /// Nil when the folder has not come back.
  let bytes: UInt64?
  let blocker: String?
}

@MainActor
final class RepeatCleanupModel: ObservableObject {
  @Published private(set) var entries: [RemovedEntry] = []
  @Published private(set) var statuses: [String: RegrowStatus] = [:]
  @Published private(set) var isChecking = false
  @Published private(set) var removing: Set<String> = []
  @Published private(set) var message: String?
  @Published private(set) var failures: [String: String] = [:]
  private let history: CleanupOverviewModel
  private let home: String
  private var ledgerUpdates: AnyCancellable?
  private var checkedAt: Date?

  static let backThreshold: UInt64 = 1_024 * 1_024

  init(history: CleanupOverviewModel, home: String = NSHomeDirectory()) {
    self.history = history
    self.home = home
    ledgerUpdates = history.$ledger.sink { [weak self] ledger in
      guard let self else { return }
      entries = RegrowCatalog.entries(ledger, home: home)
    }
  }

  func isBack(_ entry: RemovedEntry) -> Bool {
    (statuses[entry.id]?.bytes ?? 0) >= Self.backThreshold
  }

  /// Every derived list in one pass, so a render reads statuses once.
  struct Summary {
    let regrown: [RemovedEntry]
    let ready: [RemovedEntry]
    let regrownBytes: UInt64
    let ordered: [RemovedEntry]
  }

  var summary: Summary {
    var regrown: [RemovedEntry] = []
    var rest: [RemovedEntry] = []
    for entry in entries {
      if isBack(entry) { regrown.append(entry) } else { rest.append(entry) }
    }
    regrown.sort { (statuses[$0.id]?.bytes ?? 0) > (statuses[$1.id]?.bytes ?? 0) }
    return Summary(
      regrown: regrown, ready: regrown.filter { statuses[$0.id]?.blocker == nil },
      regrownBytes: regrown.reduce(0) { $0 + (statuses[$1.id]?.bytes ?? 0) },
      ordered: regrown + rest)
  }

  var ready: [RemovedEntry] { summary.ready }

  /// Re-measures every entry, publishing each row as its size arrives.
  func check(force: Bool = false) {
    guard !isChecking else { return }
    if !force, let checkedAt, Date.now.timeIntervalSince(checkedAt) < 120 { return }
    isChecking = true
    let targets = entries.map(\.target)
    let home = home
    Task {
      let activity = await Task.detached(priority: .utility) { RegrowActivity.read() }.value
      await withTaskGroup(of: (String, RegrowStatus).self) { group in
        var next = 0
        func add(_ target: RegrowTarget) {
          group.addTask(priority: .utility) {
            let bytes = RegrowCleaner.size(target.path)
            let blocker =
              bytes == nil
              ? nil
              : activity.map {
                $0.blocker(target, projectRoot: RegrowCatalog.projectRoot(target, home: home))
              } ?? "Running processes could not be checked"
            return (target.path, RegrowStatus(bytes: bytes, blocker: blocker))
          }
        }
        while next < min(6, targets.count) {
          add(targets[next])
          next += 1
        }
        for await (path, status) in group {
          statuses[path] = status
          if next < targets.count {
            add(targets[next])
            next += 1
          }
        }
      }
      checkedAt = .now
      isChecking = false
    }
  }

  func remove(_ selection: [RemovedEntry]) {
    let targets = selection.map(\.target).filter { !removing.contains($0.path) }
    guard !targets.isEmpty else { return }
    removing.formUnion(targets.map(\.path))
    message = nil
    let home = home
    Task {
      var freed: UInt64 = 0
      var removed = 0
      for target in targets {
        failures[target.path] = nil
        do {
          let win = try await Task.detached(priority: .utility) {
            try RegrowCleaner.remove(target, home: home)
          }.value
          history.record(win)
          freed += win.measuredGain ?? win.bytes ?? 0
          removed += 1
          if target.recipe != .pnpmPrune {
            statuses[target.path] = RegrowStatus(bytes: nil, blocker: nil)
          }
        } catch {
          failures[target.path] = error.localizedDescription
        }
        removing.remove(target.path)
      }
      let kept = targets.count - removed
      message =
        "Removed \(removed) of \(targets.count) · \(ByteText.full(freed)) freed"
        + (kept > 0 ? ". \(kept) kept; see the rows for why." : "")
      check(force: true)
    }
  }
}
