import Foundation

/// One checkout's Git state: which repository it belongs to, its branch and how far it is from upstream.
struct GitCheckout: Equatable, Sendable {
  let path: String
  /// The shared `.git` folder; every worktree of one repository reports the same one.
  let commonDirectory: String
  let branch: String?
  let changes: Int
  let ahead: Int
  let behind: Int
}

enum GitCheckoutReader {
  /// Reads `git status --porcelain=v1 --branch` output, whose first line names the branch and upstream.
  struct StatusInput {
    let path: String
    let commonDirectory: String
    let status: String
  }

  /// Nil unless the first line is the `## ` branch header and every other line is an `XY path` entry.
  static func parse(_ input: StatusInput) -> GitCheckout? {
    let lines = input.status.split(separator: "\n", omittingEmptySubsequences: true)
    guard let header = lines.first, header.hasPrefix("## "),
      lines.dropFirst().allSatisfy({ $0.count > 3 && $0.dropFirst(2).first == " " })
    else { return nil }
    var branch: String?
    var ahead = 0
    var behind = 0
    do {
      let text = header.dropFirst(3)
      let name = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
      let local = name.components(separatedBy: "...").first ?? name
      if text.hasPrefix("No commits yet on ") {
        branch = String(text.dropFirst(18))
      } else if !local.hasPrefix("HEAD"), !local.isEmpty {
        branch = local
      }
      if let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close {
        for part in text[text.index(after: open)..<close].split(separator: ",") {
          let words = part.split(separator: " ")
          guard words.count == 2, let count = Int(words[1]) else { continue }
          if words[0] == "ahead" { ahead = count }
          if words[0] == "behind" { behind = count }
        }
      }
    }
    return GitCheckout(
      path: input.path, commonDirectory: input.commonDirectory, branch: branch,
      changes: lines.filter { !$0.hasPrefix("## ") }.count, ahead: ahead, behind: behind)
  }

  static func read(_ path: String) -> Result<GitCheckout, CommandReadError> {
    let common = DeveloperCommand.git(
      .init(
        directory: path, arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"])
    ).read { output in
      let directory = output.trimmingCharacters(in: .whitespacesAndNewlines)
      return directory.hasPrefix("/") && !directory.contains("\n") ? directory : nil
    }
    return common.flatMap { commonDirectory in
      DeveloperCommand.git(
        .init(
          directory: path,
          arguments: [
            "status", "--porcelain=v1", "--branch", "--untracked-files=normal",
            "--ignore-submodules=all",
          ])
      ).read { parse(.init(path: path, commonDirectory: commonDirectory, status: $0)) }
    }
  }
}

/// A worktree with the work running in it right now.
struct RepoWorktree: Identifiable, Sendable {
  let path: String
  let checkout: GitCheckout?
  let isPrimary: Bool
  let project: WorkspaceProject?
  let agents: [AIThread]
  var id: String { path }

  /// Every process in the folder, agents included; agents alone when no other process runs there.
  var memoryBytes: UInt64 {
    max(project?.memoryBytes ?? 0, agents.reduce(0) { $0 + $1.memoryBytes })
  }
  var processCount: Int { project?.resources.count ?? 0 }
  var ports: [Int] { (project?.servers ?? []).flatMap(\.listeningPorts) }
}

/// One repository and the worktrees where something runs; the rest are listed by name only.
struct RepoGroup: Identifiable, Sendable {
  let commonDirectory: String
  let name: String
  let primaryPath: String
  let active: [RepoWorktree]
  let idle: [GitWorktreeRecord]
  var id: String { commonDirectory }
  var memoryBytes: UInt64 { active.reduce(0) { $0 + $1.memoryBytes } }
  var agentCount: Int { active.reduce(0) { $0 + $1.agents.count } }
}

enum RepoGrouping {
  struct Input {
    let projects: [WorkspaceProject]
    let agents: [AIThread]
    let checkouts: [String: GitCheckout]
    let worktrees: [String: [GitWorktreeRecord]]
  }

  struct Output {
    let repos: [RepoGroup]
    /// Running folders outside any Git repository, such as Homebrew or a Docker-only project.
    let others: [WorkspaceProject]
  }

  static func group(_ input: Input) -> Output {
    let running = input.projects.filter(\.isRunning)
    var folders = Set(running.map(\.directory))
    for agent in input.agents {
      if let directory = agent.directory, owner(of: directory, among: folders) == nil,
        let checkout = input.checkouts.values.first(where: {
          directory == $0.path || directory.hasPrefix($0.path + "/")
        })
      {
        folders.insert(checkout.path)
      }
    }
    var agentsByFolder: [String: [AIThread]] = [:]
    for agent in input.agents {
      guard let directory = agent.directory, let folder = owner(of: directory, among: folders)
      else { continue }
      agentsByFolder[folder, default: []].append(agent)
    }
    let projects = Dictionary(running.map { ($0.directory, $0) }, uniquingKeysWith: { a, _ in a })
    var byRepo: [String: [RepoWorktree]] = [:]
    var others: [WorkspaceProject] = []
    for folder in folders {
      guard let checkout = input.checkouts[folder] else {
        if let project = projects[folder] { others.append(project) }
        continue
      }
      let records = input.worktrees[checkout.commonDirectory] ?? []
      byRepo[checkout.commonDirectory, default: []].append(
        RepoWorktree(
          path: folder, checkout: checkout,
          isPrimary: records.first?.path == folder
            || (records.isEmpty && checkout.commonDirectory == folder + "/.git"),
          project: projects[folder], agents: agentsByFolder[folder] ?? []))
    }
    let repos = byRepo.map { common, active -> RepoGroup in
      let records = input.worktrees[common] ?? []
      let primary =
        records.first?.path
        ?? (common.hasSuffix("/.git") ? String(common.dropLast(5)) : active[0].path)
      let activePaths = Set(active.map(\.path))
      return RepoGroup(
        commonDirectory: common, name: PathName.last(primary),
        primaryPath: primary,
        active: active.sorted {
          if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
          return $0.memoryBytes > $1.memoryBytes
        },
        idle: records.filter { !$0.bare && !activePaths.contains($0.path) })
    }.sorted {
      if $0.agentCount != $1.agentCount { return $0.agentCount > $1.agentCount }
      return $0.memoryBytes > $1.memoryBytes
    }
    return Output(repos: repos, others: others.sorted { $0.memoryBytes > $1.memoryBytes })
  }

  /// The deepest running folder that contains `directory`.
  static func owner(of directory: String, among folders: Set<String>) -> String? {
    folders.filter { directory == $0 || directory.hasPrefix($0 + "/") }
      .max { $0.count < $1.count }
  }
}

/// How many more agent sessions fit in memory before macOS starts swapping.
struct AgentBudget: Equatable, Sendable {
  let sessions: Int
  let memoryBytes: UInt64
  /// About how many more sessions of the usual size fit; zero means the next one pushes memory to disk.
  let room: Int
  let typicalBytes: UInt64
  /// Sessions per tool, largest first, such as "Claude Code ×9".
  let mix: [String]

  struct Input {
    let agents: [AIThread]
    let availableBytes: UInt64
    /// Free memory overstates the room while macOS is already swapping, so pressure caps it.
    let pressure: MemoryRisk
  }

  /// Memory kept free for the apps and builds that run beside the agents.
  static let reserve: UInt64 = 4 * 1_073_741_824
  /// A Claude Code or Codex session with its tool servers, before one has been measured.
  static let usualSession: UInt64 = 1_610_612_736

  static func make(_ input: Input) -> Self {
    let sizes = input.agents.map(\.memoryBytes).filter { $0 > 0 }.sorted()
    let typical = sizes.isEmpty ? usualSession : max(sizes[sizes.count / 2], usualSession / 2)
    let spare = input.availableBytes > reserve ? input.availableBytes - reserve : 0
    return AgentBudget(
      sessions: input.agents.count, memoryBytes: input.agents.reduce(0) { $0 + $1.memoryBytes },
      room: input.pressure >= .warning ? 0 : Int(spare / typical), typicalBytes: typical,
      mix: Dictionary(grouping: input.agents, by: \.tool.title)
        .sorted { $0.value.count > $1.value.count }
        .map { $0.value.count == 1 ? $0.key : "\($0.key) ×\($0.value.count)" })
  }
}

/// Decides when to warn that a new agent session no longer fits: only when the count grows while there is
/// no room left, and at most every 15 minutes.
struct AgentGuardGate: Equatable, Sendable {
  private(set) var sessions = 0
  private(set) var lastSent = Date.distantPast

  static let quietPeriod: TimeInterval = 15 * 60

  struct Reading {
    let budget: AgentBudget
    let date: Date
  }

  /// Records the reading and says whether to notify.
  mutating func shouldSend(_ reading: Reading) -> Bool {
    defer { sessions = reading.budget.sessions }
    guard reading.budget.sessions > sessions, sessions > 0, reading.budget.room == 0,
      reading.date.timeIntervalSince(lastSent) >= Self.quietPeriod
    else { return false }
    lastSent = reading.date
    return true
  }
}

/// Reads Git state for the folders where work runs, at most every 30 seconds per folder.
@MainActor
final class RepoWorkspaceModel: ObservableObject {
  @Published private(set) var checkouts: [String: GitCheckout] = [:]
  @Published private(set) var worktrees: [String: [GitWorktreeRecord]] = [:]
  /// "Couldn't read Git state for X: reason." from the latest read; nil when every folder was read.
  @Published private(set) var message: String?
  private var readAt: [String: Date] = [:]
  private var isReading = false

  static let freshInterval: TimeInterval = 30

  func update(_ folders: [String]) {
    guard !isReading else { return }
    let stale = Set(folders).filter {
      Date.now.timeIntervalSince(readAt[$0] ?? .distantPast) > Self.freshInterval
    }
    guard !stale.isEmpty else { return }
    isReading = true
    Task {
      let result = await Task.detached(priority: .utility) { Self.read(Array(stale)) }.value
      for folder in stale { readAt[folder] = .now }
      var checkouts = self.checkouts
      // A folder Git could not read keeps its last known checkout instead of dropping out of its repository.
      for folder in stale where result.failures[folder] == nil {
        checkouts[folder] = result.checkouts[folder]
      }
      let failure = result.failures.sorted { $0.key < $1.key }.first.map {
        "Couldn't read Git state for \(PathName.last($0.key)): \($0.value)."
      }
      if failure != message { message = failure }
      if checkouts != self.checkouts { self.checkouts = checkouts }
      var worktrees = self.worktrees
      worktrees.merge(result.worktrees) { _, new in new }
      if worktrees != self.worktrees { self.worktrees = worktrees }
      isReading = false
    }
  }

  private struct ReadOutput: Sendable {
    let checkouts: [String: GitCheckout]
    let worktrees: [String: [GitWorktreeRecord]]
    /// Why Git could not be read, by folder.
    let failures: [String: String]
  }

  nonisolated private static func read(_ folders: [String]) -> ReadOutput {
    var checkouts: [String: GitCheckout] = [:]
    var worktrees: [String: [GitWorktreeRecord]] = [:]
    var failures: [String: String] = [:]
    for folder in folders {
      guard FileManager.default.fileExists(atPath: folder + "/.git") else { continue }
      let checkout: GitCheckout
      switch GitCheckoutReader.read(folder) {
      case .success(let value): checkout = value
      case .failure(let error):
        failures[folder] = error.reason
        continue
      }
      checkouts[folder] = checkout
      if worktrees[checkout.commonDirectory] == nil {
        switch GitWorktrees.list(folder) {
        case .success(let records): worktrees[checkout.commonDirectory] = records
        case .failure(let error): failures[folder] = error.reason
        }
      }
    }
    return ReadOutput(checkouts: checkouts, worktrees: worktrees, failures: failures)
  }
}
