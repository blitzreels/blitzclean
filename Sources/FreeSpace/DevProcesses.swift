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
    let records = RawProcessParser.records(
      commandOutput(
        ProcessCommandRequest(
          executable: "/bin/ps",
          arguments: ["-axo", "pid=,ppid=,uid=,pcpu=,rss=,etime=,tty=,args="]
        )
      )
    ).filter { record in
      record.userID == currentUserID
        && record.processID != ProcessInfo.processInfo.processIdentifier
    }

    let portsByProcess = ProjectProcessParser.listeningPorts(
      commandOutput(
        ProcessCommandRequest(
          executable: "/usr/sbin/lsof",
          arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]
        )
      )
    )
    let workingDirectories = ProjectProcessParser.workingDirectories(
      commandOutput(
        ProcessCommandRequest(
          executable: "/usr/sbin/lsof",
          arguments: ["-a", "-d", "cwd", "-u", String(currentUserID), "-Fpn"]
        )
      )
    )

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
    let cpuRecords = RawProcessParser.records(
      commandOutput(
        ProcessCommandRequest(
          executable: "/bin/ps",
          arguments: ["-axo", "pid=,ppid=,uid=,pcpu=,rss=,etime=,tty=,comm="])))
    let identities = Dictionary(
      uniqueKeysWithValues: records.compactMap { process -> (Int32, DevProcessIdentity)? in
        guard let identity = DevProcessIdentity.read(process.processID),
          Double(identity.process.startSeconds) + Double(identity.process.startMicroseconds)
            / 1_000_000 < startedAt
        else { return nil }
        return (process.processID, identity)
      })
    return DevProcessSnapshot(
      processes: sorted,
      cpuProcesses: CPUProcessRanking.ranked(
        .init(records: cpuRecords, workingDirectories: workingDirectories)),
      identities: identities,
      resources: ResourceOwnership.processes(
        .init(
          records: records, directories: workingDirectories,
          footprints: footprints, executables: executables)))
  }

  private func dedupeListeners(_ processes: [DevProcess]) -> [DevProcess] {
    let ids = Set(processes.map(\.processID))
    return processes.filter { process in
      guard process.kind == .listener || process.kind == .devServer else {
        return true
      }

      if let parent = processes.first(where: { candidate in
        candidate.processID == process.parentProcessID
      }),
        parent.listeningPorts == process.listeningPorts, !parent.listeningPorts.isEmpty,
        ids.contains(parent.processID)
      {
        return false
      }

      return true
    }
  }

  private func commandOutput(_ request: ProcessCommandRequest) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: request.executable)
    process.arguments = request.arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    guard (try? process.run()) != nil else {
      return ""
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
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
  @Published private(set) var keptTools = WorkspacePreferences.keptTools
  private var toolResources: [String: [ResourceProcess]] = [:]
  @Published private(set) var stoppingIDs: Set<Int32> = []
  private var identities: [Int32: DevProcessIdentity] = [:]
  @Published private(set) var isRefreshing = false
  @Published private(set) var scannedAt: Date?
  @Published private(set) var statusMessage: String?
  @Published private(set) var probes: [Int: PortProbe] = [:]

  private let scanner = DevProcessScanner()
  private let prober = PortProber()
  private var timer: Timer?
  private var probing: Set<Int> = []
  private var portOwners: [Int: Set<Int32>] = [:]

  init() {
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

    let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.refresh()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func refreshIfStale() {
    if let scannedAt, Date().timeIntervalSince(scannedAt) < 8 {
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
      toolResources = Dictionary(
        grouping: scanned.resources.filter(\.isTool), by: ResourceOwnership.groupID)
      ResourceSnapshotCache.groups = ResourceOwnership.groups(scanned.resources)
      ResourceSnapshotCache.scannedAt = .now
      identities = scanned.identities
      scannedAt = .now
      isRefreshing = false
      probeStalePorts()
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

  func stopRequest(_ process: DevProcess) -> DevStopRequest {
    DevStopRequest(
      process: process, expected: identities[process.processID], force: false,
      toolGroupID: resources.first { $0.id == process.id && $0.isTool }.map(
        ResourceOwnership.groupID))
  }

  struct ToolPolicyChange {
    let groupID: String
    let keep: Bool
  }

  func keepTools(_ change: ToolPolicyChange) {
    if change.keep { keptTools.insert(change.groupID) } else { keptTools.remove(change.groupID) }
    UserDefaults.standard.set(Array(keptTools), forKey: WorkspacePreferences.toolKey)
  }

  func toolStopRequests(_ groupID: String) -> [DevStopRequest] {
    toolResources[groupID, default: []].map { resource in
      let process = DevProcess(
        processID: resource.id, parentProcessID: resource.parentProcessID,
        kind: .listener, name: resource.name, detail: "Tool service",
        workingDirectory: resource.directory,
        listeningPorts: [], cpuPercent: resource.cpuPercent, memoryBytes: resource.memoryBytes ?? 0,
        elapsed: "", terminal: nil)
      return DevStopRequest(
        process: process, expected: identities[resource.id], force: false, toolGroupID: groupID)
    }
  }

  func stopTools(_ requests: [DevStopRequest]) {
    let candidates = requests.filter { request in
      !request.force && request.toolGroupID != nil
        && resources.contains {
          $0.id == request.process.id && $0.isTool
            && ResourceOwnership.groupID($0) == request.toolGroupID
        }
    }
    guard !candidates.isEmpty else { return }
    stoppingIDs.formUnion(candidates.map { $0.process.id })
    statusMessage = candidates.map { DevProcessStopper.stop($0) }.joined(separator: " · ")
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      self?.stoppingIDs.subtract(candidates.map { $0.process.id })
      self?.refresh()
    }
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
