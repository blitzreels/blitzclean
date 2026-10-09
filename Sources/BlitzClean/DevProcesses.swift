import AppKit
import Darwin
import Foundation

enum DevProcessKind: String, Equatable, Sendable, CaseIterable {
  case claudeCode
  case codex
  case aiAgent
  case devServer
  case listener
  case simulator
  case shell

  var title: String {
    switch self {
    case .claudeCode:
      "Claude Code"
    case .codex:
      "Codex"
    case .aiAgent:
      "AI agent"
    case .devServer:
      "Dev server"
    case .listener:
      "Listening"
    case .simulator:
      "Simulator"
    case .shell:
      "Shell"
    }
  }

  var systemImage: String {
    switch self {
    case .claudeCode:
      "sparkles.rectangle.stack"
    case .codex:
      "terminal.fill"
    case .aiAgent:
      "brain"
    case .devServer:
      "server.rack"
    case .listener:
      "network"
    case .simulator:
      "iphone"
    case .shell:
      "apple.terminal"
    }
  }

  var group: DevProcessGroup {
    switch self {
    case .claudeCode, .codex, .aiAgent:
      .agents
    case .devServer, .listener, .simulator:
      .servers
    case .shell:
      .shells
    }
  }
}

enum DevProcessGroup: String, CaseIterable, Identifiable, Sendable {
  case agents = "AI agents"
  case servers = "Servers & ports"
  case shells = "Terminal shells"

  var id: Self {
    self
  }
}

struct DevProcess: Identifiable, Equatable, Sendable {
  let processID: Int32
  let parentProcessID: Int32
  let kind: DevProcessKind
  let name: String
  let detail: String
  let workingDirectory: String?
  let listeningPorts: [Int]
  let cpuPercent: Double
  let memoryBytes: UInt64
  let elapsed: String
  let terminal: String?

  var id: Int32 {
    processID
  }

  var projectName: String? {
    guard let workingDirectory else {
      return nil
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if workingDirectory == home {
      return "~"
    }

    return URL(fileURLWithPath: workingDirectory).lastPathComponent
  }
}

struct RawProcessRecord: Equatable, Sendable {
  let processID: Int32
  let parentProcessID: Int32
  let userID: Int
  let cpuPercent: Double
  let residentKilobytes: UInt64
  let elapsed: String
  let terminal: String?
  let arguments: String
}

struct DevProcessClassificationInput: Sendable {
  let record: RawProcessRecord
  let listeningPorts: [Int]
  let workingDirectory: String?
  let memoryBytes: UInt64?
}

enum DevProcessClassifier {
  private static let agentExecutables: Set<String> = [
    "cursor-agent", "gemini", "aider", "droid", "opencode", "amp", "copilot",
    "coderabbit", "cr", "goose", "cline", "kiro", "jules",
  ]
  private static let runtimeExecutables: Set<String> = [
    "node", "bun", "deno", "npm", "pnpm", "yarn", "npx", "python", "python3", "ruby",
    "java", "go", "cargo", "php", "dotnet", "uvicorn", "gunicorn", "flask", "rails",
    "vite", "next", "next-server", "nuxt", "astro", "remix", "webpack", "turbo", "tsx",
    "ts-node", "nodemon", "live-server", "http-server", "serve", "wrangler", "vercel",
  ]
  private static let shellExecutables: Set<String> = ["zsh", "bash", "fish", "sh", "nu"]
  private static let genericRuntimes: Set<String> = [
    "node", "bun", "deno", "python", "python3", "ruby", "java", "npx", "tsx", "ts-node", "php",
    "dotnet",
  ]
  private static let genericScriptNames: Set<String> = [
    "cli", "cli.js", "index.js", "index.mjs", "main.js", "server.js", "start.js", "bin", "dist",
    "lib",
    ".bin", "node_modules", "src", "build", "out",
  ]

  static func classify(_ input: DevProcessClassificationInput) -> DevProcess? {
    let record = input.record
    let tokens = argumentTokens(record.arguments)
    guard let executable = tokens.first else {
      return nil
    }

    let executableName = URL(fileURLWithPath: executable).lastPathComponent
    let memoryBytes = input.memoryBytes ?? record.residentKilobytes * 1_024

    func make(_ kind: DevProcessKind, name: String, detail: String) -> DevProcess {
      DevProcess(
        processID: record.processID,
        parentProcessID: record.parentProcessID,
        kind: kind,
        name: name,
        detail: detail,
        workingDirectory: input.workingDirectory,
        listeningPorts: input.listeningPorts,
        cpuPercent: record.cpuPercent,
        memoryBytes: memoryBytes,
        elapsed: record.elapsed,
        terminal: record.terminal
      )
    }

    if executableName == "claude" {
      if tokens.contains("--chrome-native-host") {
        return nil
      }

      let session = value(after: "--session-id", in: tokens).map { id in
        String(id.prefix(8))
      }
      let mode = tokens.contains("--output-format") ? "headless" : "interactive"
      let detail = [session.map { "session \($0)" }, mode].compactMap { $0 }.joined(
        separator: " · ")
      return make(.claudeCode, name: "Claude Code", detail: detail)
    }

    if executableName == "codex" {
      if tokens.contains("app-server") {
        let isHost = tokens.contains("--listen") == false
        return make(
          .codex,
          name: isHost ? "Codex app" : "Codex thread",
          detail: isHost ? "ChatGPT desktop host" : "app-server"
        )
      }

      let subcommand =
        tokens.dropFirst().first { token in
          !token.hasPrefix("-")
        } ?? "interactive"
      return make(.codex, name: "Codex CLI", detail: subcommand)
    }

    if agentExecutables.contains(executableName) {
      return make(.aiAgent, name: executableName, detail: summarize(tokens.dropFirst()))
    }

    if executableName == "launchd_sim" {
      return make(.simulator, name: "iOS Simulator", detail: "launchd_sim")
    }

    if runtimeExecutables.contains(executableName) {
      let summary = summarize(tokens.dropFirst())
      if !input.listeningPorts.isEmpty {
        let name =
          genericRuntimes.contains(executableName)
          ? (scriptName(tokens) ?? executableName)
          : executableName
        return make(.devServer, name: name, detail: summary)
      }

      if executableName == "npm" || executableName == "pnpm" || executableName == "yarn"
        || executableName == "bun",
        tokens.dropFirst().first == "run" || tokens.dropFirst().first == "dev"
      {
        return make(.devServer, name: "\(executableName) \(summary)", detail: "task")
      }

      return nil
    }

    if !input.listeningPorts.isEmpty, record.userID != 0,
      !executable.hasPrefix("/System/"), !executable.hasPrefix("/usr/libexec/"),
      !record.arguments.contains(".app/"), !record.arguments.contains("Application Support/")
    {
      return make(.listener, name: executableName, detail: summarize(tokens.dropFirst()))
    }

    if shellExecutables.contains(
      executableName.trimmingCharacters(in: CharacterSet(charactersIn: "-"))),
      let terminal = record.terminal, terminal != "??",
      tokens.count == 1
    {
      return make(.shell, name: executableName, detail: terminal)
    }

    return nil
  }

  static func argumentTokens(_ arguments: String) -> [String] {
    arguments.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
  }

  private static func value(after flag: String, in tokens: [String]) -> String? {
    guard let index = tokens.firstIndex(of: flag), index + 1 < tokens.count else {
      return nil
    }

    return tokens[index + 1]
  }

  private static func scriptName(_ tokens: [String]) -> String? {
    if URL(fileURLWithPath: tokens[0]).lastPathComponent == "java" {
      return javaMainName(tokens)
    }

    var index = 1
    while index < tokens.count, tokens[index].hasPrefix("-") {
      index += tokens[index].contains("=") ? 1 : 2
    }

    guard index < tokens.count else {
      return nil
    }

    let script = tokens[index]
    let components = script.split(separator: "/").map(String.init).reversed()
    for component in components where !genericScriptNames.contains(component) && !component.isEmpty
    {
      return component.replacingOccurrences(of: ".js", with: "").replacingOccurrences(
        of: ".mjs", with: "")
    }

    return nil
  }

  private static func javaMainName(_ tokens: [String]) -> String? {
    if let jarIndex = tokens.firstIndex(of: "-jar"), jarIndex + 1 < tokens.count {
      return URL(fileURLWithPath: tokens[jarIndex + 1]).deletingPathExtension().lastPathComponent
    }

    let mainClass = tokens.dropFirst().first { token in
      !token.hasPrefix("-") && !token.contains("/") && token.contains(".") && !token.hasPrefix("*")
    }
    return mainClass?.split(separator: ".").first.map(String.init)
  }

  private static func summarize(_ tokens: ArraySlice<String>) -> String {
    let visible = Set(["dev", "start", "build", "test", "run", "serve", "watch", "preview", "mcp"])
    return tokens.prefix(4).filter { visible.contains($0) }.joined(separator: " ")
  }
}

enum RawProcessParser {
  static func records(_ output: String) -> [RawProcessRecord] {
    output.split(separator: "\n").compactMap { line in
      let columns = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
      guard columns.count == 8,
        let processID = Int32(columns[0]),
        let parentProcessID = Int32(columns[1]),
        let userID = Int(columns[2]),
        let cpuPercent = Double(columns[3].replacingOccurrences(of: ",", with: ".")),
        let residentKilobytes = UInt64(columns[4])
      else {
        return nil
      }

      let terminal = String(columns[6])
      return RawProcessRecord(
        processID: processID,
        parentProcessID: parentProcessID,
        userID: userID,
        cpuPercent: cpuPercent,
        residentKilobytes: residentKilobytes,
        elapsed: String(columns[5]),
        terminal: terminal == "??" ? nil : terminal,
        arguments: String(columns[7]).trimmingCharacters(in: .whitespaces)
      )
    }
  }
}

struct DevProcessScanner: Sendable {
  func scan() -> [DevProcess] {
    snapshot().processes
  }

  func snapshot() -> DevProcessSnapshot {
    let startedAt = Date().timeIntervalSince1970
    let currentUserID = Int(getuid())
    let recordResult = DeveloperCommand.run(
      .init(
        executable: "/bin/ps", arguments: ["-axo", "pid=,ppid=,uid=,pcpu=,rss=,etime=,tty=,args="],
        timeout: 3, maximumBytes: 4 * 1_024 * 1_024))
    let records = RawProcessParser.records(recordResult.output).filter {
      $0.userID == currentUserID && $0.processID != getpid()
    }
    let portResult = DeveloperCommand.run(
      .init(
        executable: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"],
        timeout: 3, maximumBytes: 4 * 1_024 * 1_024))
    let portsByProcess = ProjectProcessParser.listeningPorts(portResult.output)
    let workingDirectories = Dictionary(
      uniqueKeysWithValues: records.compactMap { record in
        ProcessWorkingDirectory.read(record.processID).map { (record.processID, $0) }
      })

    let footprints = Dictionary(
      uniqueKeysWithValues: records.compactMap { record in
        ProcessFootprint.bytes(record.processID).map { (record.processID, $0) }
      })
    let executables = Dictionary(
      uniqueKeysWithValues: records.compactMap { record in
        ProcessExecutable.path(record.processID).map { (record.processID, $0) }
      })
    var processes: [DevProcess] = []
    for record in records {
      let classified = DevProcessClassifier.classify(
        DevProcessClassificationInput(
          record: record,
          listeningPorts: portsByProcess[record.processID, default: []],
          workingDirectory: workingDirectories[record.processID],
          memoryBytes: footprints[record.processID]
        )
      )
      if let classified {
        processes.append(classified)
      }
    }

    let sorted = dedupeListeners(processes).sorted { left, right in
      if left.kind.group != right.kind.group {
        return left.kind.group.rawValue < right.kind.group.rawValue
      }

      if left.kind != right.kind {
        return left.kind.rawValue < right.kind.rawValue
      }

      return left.memoryBytes > right.memoryBytes
    }
    let cpuRecords = records.map { record in
      RawProcessRecord(
        processID: record.processID, parentProcessID: record.parentProcessID, userID: record.userID,
        cpuPercent: record.cpuPercent, residentKilobytes: record.residentKilobytes,
        elapsed: record.elapsed, terminal: record.terminal,
        arguments: executables[record.processID] ?? "Process")
    }
    let identities = Dictionary(
      uniqueKeysWithValues: records.compactMap { process -> (Int32, DevProcessIdentity)? in
        guard let identity = DevProcessIdentity.read(process.processID),
          Double(identity.process.startSeconds) + Double(identity.process.startMicroseconds)
            / 1_000_000 < startedAt
        else { return nil }
        return (process.processID, identity)
      })
    let startTimes = identities.mapValues {
      Double($0.process.startSeconds) + Double($0.process.startMicroseconds) / 1_000_000
    }
    let threads = AIThreadGrouping.threads(
      AIThreadInput(
        records: records, directories: workingDirectories, footprints: footprints,
        startTimes: startTimes,
        home: FileManager.default.homeDirectoryForCurrentUser.path,
        stoppedIDs: Set(identities.compactMap { $0.value.process.stopped ? $0.key : nil })))
    let leftovers = LeftoverProcessFinder.find(
      .init(
        records: records, executables: executables, directories: workingDirectories,
        footprints: footprints, identities: identities, apps: .current(),
        excludedIDs: Set(threads.flatMap(\.processIDs)),
        keptRunningRoots: WorkspacePreferences.load().filter(\.keepRunning).map(\.directory)))
    let resources = ResourceOwnership.processes(
      .init(
        records: records, directories: workingDirectories, footprints: footprints,
        executables: executables))
    let roots = WorkspaceCatalog.resolveRoots(
      .init(resources: resources, processes: sorted, preferences: []))
    return DevProcessSnapshot(
      processes: sorted,
      cpuProcesses: CPUProcessRanking.ranked(
        .init(records: cpuRecords, workingDirectories: workingDirectories)),
      identities: identities,
      threads: AIThreadNames.enrich(
        .init(
          threads: threads, records: records,
          startTimes: startTimes, home: FileManager.default.homeDirectoryForCurrentUser)),
      resources: resources, workspaceRoots: roots, leftovers: leftovers ?? [],
      incomplete: recordResult.status != 0 || portResult.status < 0 || leftovers == nil)
  }

  private func dedupeListeners(_ processes: [DevProcess]) -> [DevProcess] {
    let byID = Dictionary(
      processes.map { ($0.processID, $0) }, uniquingKeysWith: { first, _ in first })
    return processes.filter { process in
      guard process.kind == .listener || process.kind == .devServer else {
        return true
      }

      if let parent = byID[process.parentProcessID],
        parent.listeningPorts == process.listeningPorts, !parent.listeningPorts.isEmpty
      {
        return false
      }

      return true
    }
  }

  private func commandOutput(_ request: ProcessCommandRequest) -> String {
    DeveloperCommand.run(
      .init(
        executable: request.executable, arguments: request.arguments,
        timeout: 3, maximumBytes: 4 * 1_024 * 1_024)
    ).output
  }
}

enum ProcessFootprint {
  static func bytes(_ processID: Int32) -> UInt64? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      proc_pid_rusage(
        processID,
        RUSAGE_INFO_V4,
        UnsafeMutableRawPointer(pointer)
          .assumingMemoryBound(to: Optional<UnsafeMutableRawPointer>.self)
      )
    }

    guard result == 0 else {
      return nil
    }

    return usage.ri_phys_footprint
  }
}

enum ProcessExecutable {
  static func path(_ processID: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}

struct DevProcessSummary: Equatable, Sendable {
  let claudeCount: Int
  let codexCount: Int
  let agentCount: Int
  let serverCount: Int
  let shellCount: Int
  let ports: [Int]

  init(processes: [DevProcess]) {
    claudeCount = processes.filter { process in process.kind == .claudeCode }.count
    codexCount = processes.filter { process in process.kind == .codex }.count
    agentCount = processes.filter { process in process.kind == .aiAgent }.count
    serverCount = processes.filter { process in process.kind.group == .servers }.count
    shellCount = processes.filter { process in process.kind == .shell }.count
    ports = Array(Set(processes.flatMap(\.listeningPorts))).sorted()
  }
}

@MainActor
final class DevProcessModel: ObservableObject {
  @Published private(set) var processes: [DevProcess] = []
  @Published private(set) var cpuProcesses: [CPUProcess] = []
  @Published private(set) var resources: [ResourceProcess] = []
  @Published private(set) var workspaceRoots: [Int32: String] = [:]
  @Published private(set) var threads: [AIThread] = []
  @Published private(set) var stoppingThreads: Set<String> = []
  @Published private(set) var threadMessage: String?
  @Published private(set) var stoppingIDs: Set<Int32> = []
  private var identities: [Int32: DevProcessIdentity] = [:]
  @Published private(set) var isRefreshing = false
  @Published private(set) var scannedAt: Date?
  @Published private(set) var statusMessage: String?
  @Published private(set) var probes: [Int: PortProbe] = [:]

  @Published private(set) var pressure = PressureAssessment.checking
  @Published private(set) var autoPauseDirectories = Set(
    UserDefaults.standard.stringArray(forKey: ProjectPausePolicy.key) ?? [])
  @Published private(set) var projectTargets: [String: ProjectPauseTarget] = [:]
  @Published private(set) var projectAction: String?
  @Published private(set) var actingProjects: Set<String> = []
  @Published private(set) var projectMessages: [String: String] = [:]
  @Published private(set) var scanDuration: TimeInterval = 0
  @Published private(set) var leftovers: [LeftoverProcess] = []
  @Published private(set) var stoppingLeftovers: Set<Int32> = []
  @Published private(set) var leftoverMessage: String?
  @Published private(set) var hiddenLeftoverNames =
    UserDefaults.standard.stringArray(forKey: LeftoverProcessFinder.hiddenKey) ?? []
  private let sentinel = PressureSentinel()
  private let scanner = DevProcessScanner()
  private let prober = PortProber()
  private var timer: Timer?
  private var probing: Set<Int> = []
  private var portOwners: [Int: Set<Int32>] = [:]

  init() {
    sentinel.start { [weak self] update in
      Task { @MainActor [weak self] in
        self?.pressure = update.assessment
        ResourceSnapshotCache.pressure = update.assessment
        if let action = update.action {
          self?.projectAction = action
          self?.refresh()
        }
      }
    }
    startAutoRefresh()
    refresh()
  }

  var summary: DevProcessSummary {
    DevProcessSummary(processes: processes)
  }

  func startAutoRefresh() {
    guard timer == nil else {
      return
    }

    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in
        if NSApp?.isActive == true { self?.refresh() } else { self?.refreshIfStale() }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func refreshIfStale() {
    if let scannedAt, Date().timeIntervalSince(scannedAt) < (NSApp?.isActive == true ? 2 : 8) {
      return
    }

    refresh()
  }

  func refresh() {
    guard !isRefreshing else {
      return
    }

    isRefreshing = true
    let scanner = scanner
    let started = Date.now

    Task { [weak self] in
      let scanned = await Task.detached(priority: .utility) {
        scanner.snapshot()
      }.value

      guard let self else {
        return
      }

      processes = scanned.processes
      cpuProcesses = scanned.cpuProcesses
      resources = scanned.resources
      workspaceRoots = scanned.workspaceRoots
      threads = scanned.threads
      leftovers = scanned.leftovers
      ResourceSnapshotCache.groups = ResourceOwnership.groups(scanned.resources)
      ResourceSnapshotCache.scannedAt = .now
      identities = scanned.identities
      scannedAt = .now
      isRefreshing = false
      scanDuration = Date.now.timeIntervalSince(started)
      statusMessage =
        scanned.incomplete
        ? "Process scan incomplete; some processes or ports could not be read." : nil
      updateProjectTargets()
      if pressure.risk < .warning { probeStalePorts() }
    }
  }

  private struct ProjectCacheKey: Equatable {
    let scannedAt: Date?
    let preferences: [WorkspacePreference]
  }

  private var projectCache: (key: ProjectCacheKey, projects: [WorkspaceProject])?

  /// Resolved projects for the latest scan, reused until a new scan or preference change.
  func projects(_ preferences: [WorkspacePreference]) -> [WorkspaceProject] {
    let key = ProjectCacheKey(scannedAt: scannedAt, preferences: preferences)
    if let projectCache, projectCache.key == key { return projectCache.projects }
    let projects = WorkspaceCatalog.resolvedProjects(
      .init(
        input: .init(resources: resources, processes: processes, preferences: preferences),
        roots: workspaceRoots))
    projectCache = (key, projects)
    return projects
  }

  func updateProjectTargets() {
    let projects = WorkspaceCatalog.resolvedProjects(
      .init(
        input: .init(
          resources: resources, processes: processes, preferences: WorkspacePreferences.load()),
        roots: workspaceRoots))
    let excluded = Set(threads.flatMap(\.processIDs))
    projectTargets = Dictionary(
      uniqueKeysWithValues: projects.compactMap { project in
        ProjectPausePolicy.target(
          .init(
            project: project, identities: identities, excludedIDs: excluded,
            date: scannedAt ?? .distantPast)
        )
        .map { (project.directory, $0) }
      })
    sentinel.update(projectTargets.values.filter { !actingProjects.contains($0.directory) })
  }

  struct AutoPauseRequest {
    let directory: String
    let enabled: Bool
  }

  func setAutoPause(_ request: AutoPauseRequest) {
    if request.enabled {
      autoPauseDirectories.insert(request.directory)
    } else {
      autoPauseDirectories.remove(request.directory)
    }
    UserDefaults.standard.set(Array(autoPauseDirectories), forKey: ProjectPausePolicy.key)
    updateProjectTargets()
  }

  func pauseProject(_ target: ProjectPauseTarget) {
    guard actingProjects.insert(target.directory).inserted else { return }
    projectMessages[target.directory] = nil
    sentinel.update(projectTargets.values.filter { !actingProjects.contains($0.directory) })
    let request = ProjectPausePolicy.SignalRequest(target: target, resume: target.isPaused)
    Task { [weak self] in
      let count = await Task.detached(priority: .userInitiated) {
        ProjectPausePolicy.signal(request)
      }.value
      self?.projectMessages[target.directory] =
        count > 0
        ? "\(target.name): \(count) processes \(request.resume ? "resumed" : "paused; RAM is still held")."
        : "The processes changed or are protected. Refresh before trying again."
      self?.actingProjects.remove(target.directory)
      self?.refresh()
    }
  }

  func stopProjectWorkers(_ target: ProjectPauseTarget) {
    guard actingProjects.insert(target.directory).inserted else { return }
    projectAction = nil
    projectMessages[target.directory] = nil
    sentinel.update(projectTargets.values.filter { !actingProjects.contains($0.directory) })
    Task { [weak self] in
      let message = await Task.detached(priority: .userInitiated) {
        let count = ProjectPausePolicy.stop(target)
        guard count > 0 else { return "Processes changed or are protected. Refresh to try again." }
        for _ in 0..<12 {
          if ProjectPausePolicy.remaining(target) == 0 {
            return "Stopped \(count) development processes."
          }
          try? await Task.sleep(for: .milliseconds(150))
        }
        return
          "Stop requested; \(ProjectPausePolicy.remaining(target)) processes are still finishing."
      }.value
      if message.hasPrefix("Stopped ") {
        self?.projectAction = "\(target.name): \(message)"
      } else {
        self?.projectMessages[target.directory] = message
      }
      self?.actingProjects.remove(target.directory)
      self?.refresh()
    }
  }

  func probe(_ probeFor: DevProcess) -> PortProbe? {
    probeFor.listeningPorts.lazy.compactMap { port in self.probes[port] }.first { probe in
      probe.kind != .silent
    }
  }

  private func probeStalePorts() {
    var owners: [Int: Set<Int32>] = [:]
    for process in processes {
      for port in process.listeningPorts {
        owners[port, default: []].insert(process.processID)
      }
    }
    let livePorts = Set(owners.keys)
    probes = probes.filter { port, _ in
      livePorts.contains(port) && portOwners[port] == owners[port]
    }
    portOwners = owners
    let stale = livePorts.filter { port in
      guard !probing.contains(port) else {
        return false
      }

      guard let existing = probes[port] else {
        return true
      }

      let maxAge: TimeInterval = existing.kind == .silent ? 15 * 60 : 5 * 60
      return Date().timeIntervalSince(existing.probedAt) > maxAge
    }.sorted()

    guard !stale.isEmpty else {
      return
    }

    probing.formUnion(stale)
    let prober = prober
    let expectedOwners = owners
    Task { [weak self] in
      await withTaskGroup(of: PortProbe.self) { group in
        var nextIndex = 0
        while nextIndex < min(6, stale.count) {
          let port = stale[nextIndex]
          nextIndex += 1
          group.addTask {
            await prober.probe(port: port)
          }
        }

        for await probe in group {
          if self?.portOwners[probe.port] == expectedOwners[probe.port] {
            self?.probes[probe.port] = probe
          }
          self?.probing.remove(probe.port)
          if nextIndex < stale.count {
            let port = stale[nextIndex]
            nextIndex += 1
            group.addTask {
              await prober.probe(port: port)
            }
          }
        }
      }
    }
  }

  func stop(_ request: DevStopRequest) {
    guard !WorkspacePreferences.isKeptRunning(request.process.workingDirectory) else {
      statusMessage =
        "This project is set to Keep running. Change it in Projects before stopping a process."
      return
    }
    guard stoppingIDs.insert(request.process.processID).inserted else { return }
    statusMessage = DevProcessStopper.stop(request)
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(800))
      self?.stoppingIDs.remove(request.process.processID)
      self?.refresh()
    }
  }

  func pauseThread(_ thread: AIThread) {
    signalThread(thread, .pause)
  }

  func resumeThread(_ thread: AIThread) {
    signalThread(thread, .resume)
  }

  func stopThread(_ thread: AIThread, force: Bool) {
    signalThread(thread, force ? .forceQuit : .quit)
  }

  private func signalThread(_ thread: AIThread, _ signal: AIThreadSignal) {
    guard stoppingThreads.insert(thread.id).inserted else { return }
    let request = AIThreadStopRequest(
      thread: thread, expected: identities.filter { thread.processIDs.contains($0.key) },
      force: signal == .forceQuit)
    let label = thread.displayName
    Task { [weak self] in
      let outcome = await Task.detached(priority: .userInitiated) { () async -> String? in
        guard AIThreadStopper.signal(request, signal) > 0 else { return nil }
        switch signal {
        case .pause:
          for _ in 0..<8 {
            if AIThreadStopper.paused(request) { return "paused" }
            try? await Task.sleep(for: .milliseconds(50))
          }
          return "pause-pending"
        case .resume:
          for _ in 0..<8 {
            if !AIThreadStopper.paused(request), AIThreadStopper.running(request) {
              return "resumed"
            }
            try? await Task.sleep(for: .milliseconds(50))
          }
          return "resume-pending"
        case .quit, .forceQuit:
          for _ in 0..<12 {
            guard AIThreadStopper.running(request) else { return "quit" }
            try? await Task.sleep(for: .milliseconds(250))
          }
          return "still-running"
        }
      }.value
      guard let self else { return }
      threadMessage =
        switch (signal, outcome) {
        case (_, nil): "\(label) already exited or changed. The list is refreshed."
        case (.pause, "paused"):
          "\(label) paused · CPU stopped, \(ByteText.full(thread.memoryBytes)) RAM still held. Resume when you want it back."
        case (.pause, "pause-pending"):
          "Pause requested for \(label). Some local processes have not stopped yet."
        case (.resume, "resumed"): "\(label) resumed"
        case (.resume, "resume-pending"):
          "Resume requested for \(label). Checking the local processes."
        case (.forceQuit, "quit"):
          "\(label) force quit · it was using \(ByteText.full(thread.memoryBytes))"
        case (.quit, "quit"):
          "\(label) quit · it was using \(ByteText.full(thread.memoryBytes))"
        case (.quit, "still-running"), (.forceQuit, "still-running"):
          "\(label) is still running. Use Force Quit to end it now."
        default: nil
        }
      stoppingThreads.remove(thread.id)
      refresh()
    }
  }

  var visibleLeftovers: [LeftoverProcess] {
    let hidden = Set(hiddenLeftoverNames)
    return leftovers.filter { !hidden.contains($0.executableName) }
  }

  struct LeftoverVisibility {
    let name: String
    let hidden: Bool
  }

  func setLeftoverName(_ input: LeftoverVisibility) {
    let name = input.name
    hiddenLeftoverNames.removeAll { $0 == name }
    if input.hidden { hiddenLeftoverNames.append(name) }
    UserDefaults.standard.set(hiddenLeftoverNames, forKey: LeftoverProcessFinder.hiddenKey)
  }

  func showHiddenLeftovers() {
    hiddenLeftoverNames = []
    UserDefaults.standard.removeObject(forKey: LeftoverProcessFinder.hiddenKey)
  }

  struct LeftoverQuit {
    let targets: [LeftoverProcess]
    let force: Bool
  }

  func quitLeftovers(_ input: LeftoverQuit) {
    let requests = input.targets.compactMap { process -> LeftoverStopRequest? in
      guard !stoppingLeftovers.contains(process.processID) else { return nil }
      return LeftoverStopRequest(process: process, force: input.force)
    }
    guard !requests.isEmpty else { return }
    let ids = requests.map(\.process.processID)
    stoppingLeftovers.formUnion(ids)
    leftoverMessage = nil
    Task { [weak self] in
      let outcome = await Task.detached(priority: .userInitiated) {
        () async -> (signaled: [LeftoverStopRequest], running: Int) in
        let signaled = LeftoverProcessStopper.signals(requests)
        for _ in 0..<12 {
          if !signaled.contains(where: LeftoverProcessStopper.isCurrent) { break }
          try? await Task.sleep(for: .milliseconds(250))
        }
        return (signaled, signaled.filter(LeftoverProcessStopper.isCurrent).count)
      }.value
      guard let self else { return }
      leftoverMessage = Self.leftoverMessage(
        .init(requested: requests, signaled: outcome.signaled, running: outcome.running))
      stoppingLeftovers.subtract(ids)
      refresh()
    }
  }

  struct LeftoverOutcome {
    let requested: [LeftoverStopRequest]
    let signaled: [LeftoverStopRequest]
    let running: Int
  }

  nonisolated static func leftoverMessage(_ outcome: LeftoverOutcome) -> String {
    let skipped = outcome.requested.count - outcome.signaled.count
    let ended = outcome.signaled.count - outcome.running
    let force = outcome.requested.first?.force == true
    guard outcome.requested.count > 1 else {
      let title = outcome.requested.first?.process.title ?? "The process"
      if skipped > 0 {
        return "\(title) was not quit: it exited, changed, or is protected. The list is refreshed."
      }
      if outcome.running > 0 { return "\(title) is still running. Use Force Quit to end it now." }
      let memory = outcome.requested.first?.process.memoryBytes.map {
        " · it was using \(ByteText.full($0))"
      }
      return "\(title) \(force ? "force quit" : "quit")\(memory ?? "")"
    }
    var parts = ["Quit \(ended) of \(outcome.requested.count) leftover processes"]
    if outcome.running > 0 { parts.append("\(outcome.running) still running") }
    if skipped > 0 { parts.append("\(skipped) exited, changed, or protected") }
    return parts.joined(separator: " · ")
  }

  func stopRequest(_ process: DevProcess) -> DevStopRequest {
    DevStopRequest(
      process: process, expected: identities[process.processID], force: false)
  }

  func stopProject(_ requests: [DevStopRequest]) {
    guard
      !requests.contains(where: { WorkspacePreferences.isKeptRunning($0.process.workingDirectory) })
    else {
      statusMessage =
        "This project is set to Keep running. Change it in Projects before stopping servers."
      return
    }
    let candidates = requests.filter {
      $0.process.canStopWithProject && !stoppingIDs.contains($0.process.processID)
    }
    guard !candidates.isEmpty else { return }
    stoppingIDs.formUnion(candidates.map { $0.process.processID })
    Task { [weak self] in
      let messages = await Task.detached(priority: .userInitiated) {
        candidates.map { DevProcessStopper.stop($0) }
      }.value
      guard let self else { return }
      statusMessage = messages.joined(separator: " · ")
      try? await Task.sleep(for: .milliseconds(800))
      stoppingIDs.subtract(candidates.map { $0.process.processID })
      refresh()
    }
  }

  func openPort(_ port: Int) {
    guard let url = URL(string: "http://localhost:\(port)") else {
      return
    }

    NSWorkspace.shared.open(url)
  }
}
