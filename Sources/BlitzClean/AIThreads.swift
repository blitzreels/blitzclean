import Darwin
import Foundation

enum AITool: String, Equatable, Sendable {
  case claudeCode
  case codexCLI
  case codexDesktop
  case cursorAgent
  case otherAgent

  var title: String {
    switch self {
    case .claudeCode: "Claude Code"
    case .codexCLI: "Codex CLI"
    case .codexDesktop: "Codex workers"
    case .cursorAgent: "Cursor agent"
    case .otherAgent: "AI agent"
    }
  }

  var appName: String? {
    switch self {
    case .claudeCode: "Claude"
    case .codexCLI, .codexDesktop: "ChatGPT"
    case .cursorAgent: "Cursor"
    case .otherAgent: nil
    }
  }
}

struct AIThread: Identifiable, Equatable, Sendable {
  let id: String
  let tool: AITool
  let name: String
  let directory: String?
  let terminal: String?
  let startedAt: Date?
  let processIDs: [Int32]
  let memoryBytes: UInt64
  let cpuPercent: Double
  /// Every live process is SIGSTOP'd. CPU yields; RAM stays until Quit.
  let isPaused: Bool
  /// The process that launched this thread has exited; nothing will close it.
  let isDetached: Bool
  var sessionTitle: String? = nil
  var sessionID: String? = nil
  var hostName: String? = nil
  var delegatedTools: [String] = []

  var project: String? { directory.map { URL(fileURLWithPath: $0).lastPathComponent } }

  var displayName: String {
    sessionTitle ?? project ?? name
  }

  var identityDetail: String {
    var parts = displayName == tool.title ? [] : [tool.title]
    if sessionTitle != nil, let project { parts.append(project) }
    if !delegatedTools.isEmpty {
      parts.append("includes \(delegatedTools.joined(separator: ", "))")
    }
    if let hostName { parts.append(hostName) }
    if let processID = processIDs.first { parts.append("PID \(processID)") }
    return parts.joined(separator: " · ")
  }

  func matches(_ query: String) -> Bool {
    query.isEmpty
      || [displayName, identityDetail, directory ?? "", sessionID ?? ""]
        .contains { $0.localizedCaseInsensitiveContains(query) }
  }
}

struct AIThreadInput: Sendable {
  let records: [RawProcessRecord]
  let directories: [Int32: String]
  let footprints: [Int32: UInt64]
  let startTimes: [Int32: TimeInterval]
  let home: String
  var stoppedIDs: Set<Int32> = []
}

enum AIThreadGrouping {
  static let clusterGap: TimeInterval = 10
  private static let agentNames: Set<String> = [
    "gemini", "aider", "droid", "opencode", "amp", "copilot", "goose", "cline", "kiro", "jules",
    "qwen", "crush",
  ]

  /// argv[0]'s file name. Absolute paths may contain spaces, so they end at the first flag or path argument.
  static func executableName(_ arguments: String) -> String {
    guard arguments.hasPrefix("/") else {
      let first = arguments.split(separator: " ").first.map(String.init) ?? arguments
      return first.split(separator: "/").last.map(String.init) ?? first
    }
    var end = arguments.endIndex
    for marker in [" -", " /"] {
      if let range = arguments.range(of: marker), range.lowerBound < end { end = range.lowerBound }
    }
    let path = String(arguments[..<end])
    let last = path.split(separator: "/").last.map(String.init) ?? path
    return last.split(separator: " ").first.map(String.init) ?? last
  }

  /// "pnpm app:dev" for `bash -c "…; PATH=… pnpm app:dev > log 2>&1"`.
  static func shellCommand(_ arguments: String) -> String? {
    guard ["bash", "zsh", "sh"].contains(executableName(arguments)),
      let flag = arguments.range(of: " -c ")
    else { return nil }
    let statements = arguments[flag.upperBound...].components(separatedBy: ";")
      .flatMap { $0.components(separatedBy: "&&") }
    guard var last = statements.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    else { return nil }
    if let redirect = last.range(of: " >") ?? last.range(of: " 2>") {
      last = String(last[..<redirect.lowerBound])
    }
    let words = last.split(separator: " ").drop { $0.contains("=") }.prefix(2)
    return words.isEmpty ? nil : words.joined(separator: " ")
  }

  private enum Role {
    case root(AITool)
    case desktopHost
    case ignored

    var claimsDescendants: Bool {
      if case .ignored = self { return false }
      return true
    }
  }

  private static func role(_ record: RawProcessRecord) -> Role? {
    let name = executableName(record.arguments)
    let arguments = record.arguments
    switch name {
    case "claude":
      return arguments.contains("--chrome-native-host") ? .ignored : .root(.claudeCode)
    case "codex":
      if arguments.contains(" app-server") {
        return arguments.contains("--listen") ? nil : .desktopHost
      }
      return arguments.contains(" exec-server") ? .ignored : .root(.codexCLI)
    case "cursor-agent":
      return .root(.cursorAgent)
    default:
      return agentNames.contains(name) ? .root(.otherAgent) : nil
    }
  }

  static func threads(_ input: AIThreadInput) -> [AIThread] {
    let records = Dictionary(
      input.records.map { ($0.processID, $0) }, uniquingKeysWith: { first, _ in first })
    var children: [Int32: [Int32]] = [:]
    for record in input.records {
      children[record.parentProcessID, default: []].append(record.processID)
    }
    let roles = records.compactMapValues(role)

    func claimed(_ processID: Int32) -> Bool {
      var visited: Set<Int32> = [processID]
      var current = records[processID]?.parentProcessID
      while let parent = current, visited.insert(parent).inserted {
        if roles[parent]?.claimsDescendants == true { return true }
        current = records[parent]?.parentProcessID
      }
      return false
    }

    func subtree(_ processID: Int32) -> [Int32] {
      var result: [Int32] = []
      var pending = [processID]
      var visited: Set<Int32> = []
      while let next = pending.popLast() {
        guard visited.insert(next).inserted, records[next] != nil else { continue }
        result.append(next)
        pending.append(contentsOf: children[next, default: []])
      }
      return result
    }

    func directory(_ processIDs: [Int32]) -> String? {
      let preferred =
        processIDs.filter {
          records[$0].map { executableName($0.arguments) == "node_repl" } ?? false
        } + processIDs
      return preferred.lazy.compactMap { input.directories[$0] }.first {
        $0 != "/" && $0 != input.home && !$0.hasPrefix(input.home + "/.")
          && !$0.hasPrefix("/private/")
          && !$0.hasPrefix("/tmp/")
      }
    }

    func start(_ processIDs: [Int32]) -> Date? {
      processIDs.compactMap { input.startTimes[$0] }.min().map(Date.init(timeIntervalSince1970:))
    }

    func make(
      _ key: String, _ tool: AITool, _ name: String, _ root: RawProcessRecord?, _ ids: [Int32]
    )
      -> AIThread
    {
      var thread = AIThread(
        id: key, tool: tool, name: name, directory: directory(ids), terminal: root?.terminal,
        startedAt: start(ids), processIDs: ids,
        memoryBytes: ids.reduce(0) { $0 + (input.footprints[$1] ?? 0) },
        cpuPercent: ids.reduce(0) { $0 + (records[$1]?.cpuPercent ?? 0) },
        isPaused: !ids.isEmpty && Set(ids).isSubset(of: input.stoppedIDs),
        isDetached: root.map { $0.parentProcessID == 1 && $0.terminal == nil } ?? false)
      thread.delegatedTools = Array(
        Set(
          ids.compactMap { pid -> String? in
            switch roles[pid] {
            case .root(let childTool) where childTool != tool:
              return childTool.title
            case .desktopHost where tool != .codexDesktop:
              return "Codex"
            default:
              return nil
            }
          })
      ).sorted()
      var ancestor = root?.parentProcessID
      var visited: Set<Int32> = []
      while let pid = ancestor, visited.insert(pid).inserted, let parent = records[pid] {
        let executable = executableName(parent.arguments).lowercased()
        if executable == "cmux" || parent.arguments.contains("/cmux.app/") {
          thread.hostName = "cmux"
          break
        }
        ancestor = parent.parentProcessID
      }
      return thread
    }

    var threads: [AIThread] = []
    for (processID, processRole) in roles {
      guard let record = records[processID] else { continue }
      switch processRole {
      case .root(let tool):
        guard !claimed(processID) else { continue }
        let ids = subtree(processID)
        let start = input.startTimes[processID].map { Int($0) } ?? 0
        let name = tool == .otherAgent ? executableName(record.arguments) : tool.title
        threads.append(make("\(tool.rawValue)-\(processID)-\(start)", tool, name, record, ids))
      case .desktopHost:
        guard !claimed(processID) else { continue }
        let kids = children[processID, default: []].compactMap { records[$0] }.sorted {
          (input.startTimes[$0.processID] ?? 0) < (input.startTimes[$1.processID] ?? 0)
        }
        var clusters: [[RawProcessRecord]] = []
        var last: TimeInterval?
        for kid in kids {
          let time = input.startTimes[kid.processID] ?? 0
          if let last, time - last <= clusterGap, !clusters.isEmpty {
            clusters[clusters.count - 1].append(kid)
          } else {
            clusters.append([kid])
          }
          last = time
        }
        for cluster in clusters {
          guard let first = cluster.first else { continue }
          let ids = cluster.flatMap { subtree($0.processID) }
          let name =
            cluster.count >= 3
            ? AITool.codexDesktop.title
            : "Codex · \(shellCommand(first.arguments) ?? executableName(first.arguments))"
          let start = input.startTimes[first.processID].map { Int($0) } ?? 0
          threads.append(make("codex-\(processID)-\(start)", .codexDesktop, name, nil, ids))
        }
      case .ignored:
        continue
      }
    }
    return threads.sorted {
      $0.memoryBytes == $1.memoryBytes ? $0.id < $1.id : $0.memoryBytes > $1.memoryBytes
    }
  }
}

struct AIThreadStopRequest: Sendable {
  let thread: AIThread
  let expected: [Int32: DevProcessIdentity]
  let force: Bool
}

enum AIThreadSignal: Equatable, Sendable {
  case pause
  case resume
  case quit
  case forceQuit

  var value: Int32 {
    switch self {
    case .pause: SIGSTOP
    case .resume: SIGCONT
    case .quit: SIGTERM
    case .forceQuit: SIGKILL
    }
  }
}

enum AIThreadStopper {
  /// Signals the thread's processes that still match the scanned identity. Returns how many were signaled.
  static func signal(_ request: AIThreadStopRequest, _ signal: AIThreadSignal) -> Int {
    var signaled = 0
    for processID in request.thread.processIDs {
      guard processID > 1, processID != getpid(), let expected = request.expected[processID],
        let current = DevProcessIdentity.read(processID), expected.matches(current),
        current.process.owner == getuid()
      else { continue }
      guard Darwin.kill(processID, signal.value) == 0 else { continue }
      signaled += 1
      if signal == .quit, current.process.stopped,
        let latest = DevProcessIdentity.read(processID), expected.matches(latest)
      {
        _ = Darwin.kill(processID, SIGCONT)
      }
    }
    return signaled
  }

  static func stop(_ request: AIThreadStopRequest) -> Int {
    signal(request, request.force ? .forceQuit : .quit)
  }

  static func running(_ request: AIThreadStopRequest) -> Bool {
    request.thread.processIDs.contains { processID in
      guard let expected = request.expected[processID],
        let current = DevProcessIdentity.read(processID)
      else { return false }
      return expected.matches(current) && !current.process.exited
    }
  }

  static func paused(_ request: AIThreadStopRequest) -> Bool {
    let live = request.thread.processIDs.compactMap { processID -> RecoveryProcess? in
      guard let expected = request.expected[processID],
        let current = DevProcessIdentity.read(processID), expected.matches(current),
        !current.process.exited
      else { return nil }
      return current.process
    }
    return !live.isEmpty && live.allSatisfy(\.stopped)
  }
}
