import AppKit
import Darwin
import Foundation

/// Load nobody started on purpose: login services, virtual machines, tool servers every agent session starts
/// again, jobs that keep failing, memory cleaners and apps macOS flagged for heavy disk writes. On October 25
/// these held several GB beside the builds that restarted this Mac, and none of them showed up as a project.
struct BackgroundFinding: Identifiable, Equatable, Sendable {
  enum Kind: Int, Comparable, Sendable {
    case memoryCleaner, virtualMachine, loginService, failingJob, agentTools, diskWriter

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var symbol: String {
      switch self {
      case .memoryCleaner: "wand.and.stars"
      case .virtualMachine: "shippingbox"
      case .loginService: "arrow.clockwise.circle"
      case .failingJob: "exclamationmark.arrow.circlepath"
      case .agentTools: "square.stack.3d.up"
      case .diskWriter: "internaldrive"
      }
    }
  }

  enum Action: Equatable, Sendable {
    case turnOff(LaunchService)
    case quit(Int32)
    case reveal(String)
  }

  let id: String
  let kind: Kind
  let title: String
  let detail: String
  let value: String?
  let bytes: UInt64
  let action: Action?
}

struct LaunchService: Equatable, Sendable {
  let label: String
  let plist: String
  let command: String
  let keepAlive: Bool
  let runAtLoad: Bool
  let interval: TimeInterval?
  let calendar: Bool

  static func read(_ path: String) -> Self? {
    guard let data = FileManager.default.contents(atPath: path),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let label = plist["Label"] as? String
    else { return nil }
    let arguments = plist["ProgramArguments"] as? [String] ?? []
    let program = plist["Program"] as? String
    let keepAlive = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
    return Self(
      label: label, plist: path, command: LaunchService.command(program.map { [$0] } ?? arguments),
      keepAlive: keepAlive, runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
      interval: (plist["StartInterval"] as? Int).map(TimeInterval.init),
      calendar: plist["StartCalendarInterval"] != nil)
  }

  /// The script or binary a person recognizes, past `/bin/zsh -lc` style wrappers.
  static func command(_ arguments: [String]) -> String {
    let shells = Set(["bash", "zsh", "sh"])
    let meaningful = arguments.drop { argument in
      shells.contains(PathName.last(argument)) || argument.hasPrefix("-")
    }
    guard let first = meaningful.first ?? arguments.first else { return "" }
    return URL(fileURLWithPath: first.components(separatedBy: " ").first ?? first)
      .lastPathComponent
  }
}

struct LaunchState: Equatable, Sendable {
  let processID: Int32?
  let status: Int32
}

enum BackgroundLoadParser {
  /// Rows of `launchctl list`: PID or `-`, last exit status, label.
  static func launchStates(_ output: String) -> [String: LaunchState] {
    var states: [String: LaunchState] = [:]
    for line in output.split(separator: "\n").dropFirst() {
      let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard columns.count == 3, let status = Int32(columns[1]) else { continue }
      states[String(columns[2])] = LaunchState(processID: Int32(columns[0]), status: status)
    }
    return states
  }

  struct DiskWrite: Equatable, Sendable {
    let command: String
    let path: String
    let bytes: UInt64
    let seconds: TimeInterval

    /// The app a helper ships in, so Chrome and its helpers count once.
    var owner: String { ResourceOwnership.appName(path) ?? command }
    var isSystem: Bool { ["/System/", "/usr/", "/Library/Apple/"].contains { path.hasPrefix($0) } }
  }

  /// A macOS resource report for dirtied file-backed memory, as written to DiagnosticReports.
  static func diskWrite(_ text: String) -> DiskWrite? {
    guard text.contains("Event:            disk writes") || text.contains("Event: disk writes"),
      let command = value(.init(text: text, key: "Command:")),
      let writes = value(.init(text: text, key: "Writes:"))
    else { return nil }
    let parts = writes.split(separator: " ")
    guard parts.count >= 7, let amount = Double(parts[0]),
      let seconds = Double(parts[parts.firstIndex(of: "over").map { $0 + 1 } ?? 0])
    else { return nil }
    let unit: Double =
      switch parts[1] {
      case "KB": 1_000
      case "MB": 1_000_000
      case "GB": 1_000_000_000
      default: 1
      }
    return DiskWrite(
      command: command, path: value(.init(text: text, key: "Path:")) ?? "",
      bytes: UInt64(amount * unit), seconds: seconds)
  }

  struct ValueInput {
    let text: String
    let key: String
  }

  private static func value(_ input: ValueInput) -> String? {
    for line in input.text.split(separator: "\n", maxSplits: 80) where line.hasPrefix(input.key) {
      return line.dropFirst(input.key.count).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }

  /// Names a tool server by what it runs, so copies started by different sessions group together:
  /// launchers and runtimes drop, paths become their last component, URLs their host, versions go.
  static func toolKey(_ command: String) -> String? {
    let launchers = Set([
      "npm", "npx", "exec", "node", "uv", "uvx", "tool", "run", "bun", "bunx", "java",
    ])
    let valued = Set(["-classpath", "-cp", "--header", "-H", "--require", "-r", "--with", "--from"])
    var tokens: [String] = []
    var skipNext = false
    for argument in command.split(separator: " ").map(String.init) {
      if skipNext {
        skipNext = false
        continue
      }
      if argument.hasPrefix("-") {
        if !tokens.isEmpty { break }
        skipNext = valued.contains(argument)
        continue
      }
      let name: String
      if let url = URL(string: argument), url.scheme?.hasPrefix("http") == true, let host = url.host
      {
        name = host
      } else {
        let last = PathName.last(argument)
        let unversioned = last.split(separator: "@").first ?? Substring(last)
        name = String(unversioned.split(separator: ".").first ?? unversioned)
      }
      guard !name.isEmpty, !launchers.contains(name), !name.lowercased().hasPrefix("python")
      else { continue }
      tokens.append(name)
      if tokens.count == 2 { break }
    }
    return tokens.isEmpty ? nil : tokens.joined(separator: " ")
  }
}

enum BackgroundLoadRules {
  static let memoryCleaners = ["Memory Clean", "Memory Cleaner", "iBoostUp", "Memory Diag"]
  static let serviceFloor: UInt64 = 200 * 1_024 * 1_024
  static let toolFloor: UInt64 = 300 * 1_024 * 1_024
  static let diskFloor: UInt64 = 30_000_000_000

  struct ServiceInput {
    let service: LaunchService
    let state: LaunchState?
    let memory: UInt64
  }

  static func service(_ input: ServiceInput) -> BackgroundFinding? {
    let service = input.service
    let id = "launch:\(service.label)"
    if input.state?.processID == nil, let status = input.state?.status, status != 0,
      service.interval != nil || service.calendar || service.keepAlive
    {
      let every = service.interval.map { " every \(Self.duration($0))" } ?? ""
      return BackgroundFinding(
        id: id, kind: .failingJob, title: service.command,
        detail: "Fails\(every) · \(Self.exitReason(status)) · \(service.label)",
        value: nil, bytes: 0, action: .turnOff(service))
    }
    guard input.state?.processID != nil, service.keepAlive || service.runAtLoad,
      input.memory >= serviceFloor
    else { return nil }
    return BackgroundFinding(
      id: id, kind: .loginService, title: service.command,
      detail: service.keepAlive
        ? "Starts at login and restarts when it exits · \(service.label)"
        : "Starts at login · \(service.label)",
      value: ByteText.compact(input.memory), bytes: input.memory, action: .turnOff(service))
  }

  struct ToolCopy: Equatable, Sendable {
    let key: String
    let session: Int32
    let bytes: UInt64
  }

  /// A tool server is worth naming once three sessions each run their own copy.
  static func agentTools(_ copies: [ToolCopy]) -> [BackgroundFinding] {
    Dictionary(grouping: copies, by: \.key).compactMap { key, copies in
      let sessions = Set(copies.map(\.session)).count
      let bytes = copies.reduce(0) { $0 + $1.bytes }
      guard sessions >= 3, bytes >= toolFloor else { return nil }
      return BackgroundFinding(
        id: "tools:\(key)", kind: .agentTools, title: key,
        detail:
          "\(copies.count) copies, one per agent session · load it only in the repos that use it",
        value: ByteText.compact(bytes), bytes: bytes, action: nil)
    }
  }

  struct DiskInput {
    let reports: [(path: String, date: Date, write: BackgroundLoadParser.DiskWrite)]
  }

  static func diskWriters(_ input: DiskInput) -> [BackgroundFinding] {
    Dictionary(
      grouping: input.reports.filter { !$0.write.isSystem }, by: \.write.owner
    ).compactMap { command, reports in
      guard let worst = reports.max(by: { $0.write.bytes < $1.write.bytes }),
        worst.write.bytes >= diskFloor
      else { return nil }
      let times = reports.count == 1 ? "once" : "\(reports.count) times"
      return BackgroundFinding(
        id: "disk:\(command)", kind: .diskWriter, title: command,
        detail:
          "Wrote \(ByteText.compact(worst.write.bytes)) in \(Self.duration(worst.write.seconds)) · "
          + "macOS flagged it \(times) this week",
        value: ByteText.compact(worst.write.bytes), bytes: worst.write.bytes,
        action: .reveal(worst.path))
    }
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 1 { return "\(Int(seconds))s" }
    if minutes < 60 { return "\(minutes) min" }
    return "\(minutes / 60) h"
  }

  static func exitReason(_ status: Int32) -> String {
    switch status {
    case 127: "command not found (exit 127)"
    case 126: "not executable (exit 126)"
    case let signal where signal < 0: "killed by signal \(-signal)"
    default: "exit \(status)"
    }
  }

  static func ordered(_ findings: [BackgroundFinding]) -> [BackgroundFinding] {
    findings.sorted { left, right in
      left.kind != right.kind ? left.kind < right.kind : left.bytes > right.bytes
    }
  }
}

enum BackgroundLoadScanner {
  struct Input: Sendable {
    let resources: [ResourceProcess]
    let home: String
    let reports: String
  }

  static func scan(_ input: Input) -> [BackgroundFinding] {
    let tree = LiveProcessTree.read()
    func treeBytes(_ root: Int32) -> UInt64 {
      tree.descendants([root]).reduce(0) { $0 + (ProcessFootprint.bytes($1) ?? 0) }
    }
    var findings: [BackgroundFinding] = []

    let states = BackgroundLoadParser.launchStates(
      CommandRunner.run(
        .init(
          executable: "/bin/launchctl", arguments: ["list"], timeout: 5,
          maximumBytes: 2 * 1_024 * 1_024, input: nil, environment: .inherited)
      ).text)
    let agents = input.home + "/Library/LaunchAgents"
    let plists = (try? FileManager.default.contentsOfDirectory(atPath: agents)) ?? []
    for name in plists where name.hasSuffix(".plist") {
      guard let service = LaunchService.read(agents + "/" + name) else { continue }
      let state = states[service.label]
      if let finding = BackgroundLoadRules.service(
        .init(service: service, state: state, memory: state?.processID.map(treeBytes) ?? 0))
      {
        findings.append(finding)
      }
    }

    for resource in input.resources
    where resource.executable.contains("Virtualization.VirtualMachine")
      || resource.name.hasPrefix("qemu-system")
    {
      let bytes = resource.memoryBytes ?? 0
      findings.append(
        .init(
          id: "vm:\(resource.id)", kind: .virtualMachine, title: "Virtual machine",
          detail: "Holds its memory until stopped · \(resource.owner)",
          value: ByteText.compact(bytes), bytes: bytes, action: nil))
    }

    for app in NSWorkspace.shared.runningApplications {
      guard let name = app.localizedName,
        BackgroundLoadRules.memoryCleaners.contains(where: { name.hasPrefix($0) })
      else { continue }
      findings.append(
        .init(
          id: "cleaner:\(app.processIdentifier)", kind: .memoryCleaner, title: name,
          detail:
            "Purging caches makes macOS read files again and does not free the memory builds hold",
          value: nil, bytes: 0, action: .quit(app.processIdentifier)))
    }

    let commands = Dictionary(
      (RegrowActivity.parse(
        CommandRunner.run(
          .init(
            executable: "/bin/ps", arguments: ["-axwwo", "pid=,args="], timeout: 8,
            maximumBytes: 8 * 1_024 * 1_024, input: nil, environment: .inherited)
        ).text) ?? []).map { ($0.processID, $0.arguments) }, uniquingKeysWith: { a, _ in a })
    let children = Dictionary(grouping: input.resources, by: \.parentProcessID)
    func subtreeBytes(_ root: ResourceProcess) -> UInt64 {
      (root.memoryBytes ?? 0) + children[root.id, default: []].reduce(0) { $0 + subtreeBytes($1) }
    }
    let agentNames = Set(["claude", "codex"])
    let wrappers = Set(["zsh", "bash", "sh", "login", "caffeinate"])
    var copies: [BackgroundLoadRules.ToolCopy] = []
    for session in input.resources where agentNames.contains(session.name) {
      for tool in children[session.id, default: []]
      where !agentNames.contains(tool.name) && !wrappers.contains(tool.name) {
        guard let key = commands[tool.id].flatMap(BackgroundLoadParser.toolKey) else { continue }
        copies.append(.init(key: key, session: session.id, bytes: subtreeBytes(tool)))
      }
    }
    findings += BackgroundLoadRules.agentTools(copies)

    let weekAgo = Date.now.addingTimeInterval(-7 * 86_400)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: input.reports)) ?? []
    var reports: [(path: String, date: Date, write: BackgroundLoadParser.DiskWrite)] = []
    for name in files where name.hasSuffix(".diag") {
      let path = input.reports + "/" + name
      guard
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
          as? Date, date > weekAgo,
        let handle = FileHandle(forReadingAtPath: path)
      else { continue }
      let head = String(decoding: handle.readData(ofLength: 4_096), as: UTF8.self)
      try? handle.close()
      if let write = BackgroundLoadParser.diskWrite(head) {
        reports.append((path, date, write))
      }
    }
    findings += BackgroundLoadRules.diskWriters(.init(reports: reports))
    return BackgroundLoadRules.ordered(findings)
  }
}

enum BackgroundLoadActions {
  static let disabledFolder = "Disabled by BlitzClean"

  /// Unloads a login service and moves its plist aside, so it stays off after a restart and moving the
  /// file back turns it on again.
  static func turnOff(_ service: LaunchService) -> String {
    let domain = "gui/\(getuid())/\(service.label)"
    _ = CommandRunner.run(
      .init(
        executable: "/bin/launchctl", arguments: ["bootout", domain], timeout: 10,
        maximumBytes: 65_536, input: nil, environment: .inherited))
    let source = URL(fileURLWithPath: service.plist)
    let folder = source.deletingLastPathComponent().appendingPathComponent(disabledFolder)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let destination = folder.appendingPathComponent(source.lastPathComponent)
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: source, to: destination)
      return
        "Turned off \(service.command). To turn it on again, move it back from LaunchAgents/\(disabledFolder)."
    } catch {
      return "Stopped \(service.command), but couldn't move its file: \(error.localizedDescription)"
    }
  }
}

@MainActor
final class BackgroundLoadModel: ObservableObject {
  @Published private(set) var findings: [BackgroundFinding] = []
  @Published private(set) var scannedAt: Date?
  @Published var message: String?
  private var isScanning = false

  func scan(_ resources: [ResourceProcess]) {
    guard !isScanning else { return }
    isScanning = true
    let input = BackgroundLoadScanner.Input(
      resources: resources, home: FileManager.default.homeDirectoryForCurrentUser.path,
      reports: "/Library/Logs/DiagnosticReports")
    Task {
      let findings = await Task.detached(priority: .utility) {
        BackgroundLoadScanner.scan(input)
      }.value
      if findings != self.findings { self.findings = findings }
      scannedAt = .now
      isScanning = false
    }
  }

  func perform(_ request: PerformRequest) {
    switch request.action {
    case .turnOff(let service):
      message = BackgroundLoadActions.turnOff(service)
    case .quit(let processID):
      let quit = NSRunningApplication(processIdentifier: processID)?.terminate() == true
      message =
        quit ? "Quit \(request.title)." : "\(request.title) didn't quit. Quit it from its menu."
    case .reveal(let path):
      Finder.reveal(path)
      return
    }
    scan(request.resources)
  }

  struct PerformRequest {
    let action: BackgroundFinding.Action
    let title: String
    let resources: [ResourceProcess]
  }
}
