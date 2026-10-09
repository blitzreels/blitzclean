import AppKit
import Darwin
import Foundation

struct LeftoverProcess: Identifiable, Equatable, Sendable {
  let identity: DevProcessIdentity
  let executableName: String
  let title: String
  let workingDirectory: String?
  let memoryBytes: UInt64?
  let cpuPercent: Double
  var processID: Int32 { identity.process.processID }
  var startedAt: Date {
    Date(
      timeIntervalSince1970: Double(identity.process.startSeconds) + Double(
        identity.process.startMicroseconds) / 1_000_000)
  }
  var id: String {
    "\(processID)-\(identity.process.startSeconds)-\(identity.process.startMicroseconds)"
  }

  func matches(_ query: String) -> Bool {
    title.localizedCaseInsensitiveContains(query)
      || executableName.localizedCaseInsensitiveContains(query)
      || (workingDirectory?.localizedCaseInsensitiveContains(query) ?? false)
      || String(processID).contains(query)
  }
}

enum LeftoverProcessFinder {
  static let hiddenKey = "projects.leftovers.hidden"
  static let builtInHidden: Set<String> = ["ssh-agent", "gpg-agent", "keyboxd", "dirmngr"]
  private static let systemPrefixes = [
    "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/",
    "/Library/Developer/PrivateFrameworks/", "/Library/Developer/CoreSimulator/",
    "/Library/Filesystems/", "/Library/PrivilegedHelperTools/",
  ]

  struct RunningApps: Sendable {
    let processIDs: Set<Int32>
    let bundlePaths: Set<String>

    static func current() -> Self {
      let apps = NSWorkspace.shared.runningApplications
      return Self(
        processIDs: Set(apps.map(\.processIdentifier)),
        bundlePaths: Set(apps.compactMap { $0.bundleURL?.standardizedFileURL.path }))
    }
  }

  struct Input {
    let records: [RawProcessRecord]
    let executables: [Int32: String]
    let directories: [Int32: String]
    let footprints: [Int32: UInt64]
    let identities: [Int32: DevProcessIdentity]
    let apps: RunningApps
    let excludedIDs: Set<Int32>
    let keptRunningRoots: [String]
  }

  static func candidates(_ input: Input) -> [LeftoverProcess] {
    input.records.compactMap { record -> LeftoverProcess? in
      guard record.parentProcessID == 1, !input.excludedIDs.contains(record.processID),
        !input.apps.processIDs.contains(record.processID),
        let identity = input.identities[record.processID], identity.process.owner == getuid(),
        let path = input.executables[record.processID], path == identity.executable,
        eligibleExecutable(.init(path: path, apps: input.apps))
      else { return nil }
      let name = URL(fileURLWithPath: path).lastPathComponent
      let directory = input.directories[record.processID].flatMap { $0 == "/" ? nil : $0 }
      if let directory,
        input.keptRunningRoots.contains(where: {
          WorkspacePreferences.contains(.init(directory: directory, root: $0))
        })
      {
        return nil
      }
      return LeftoverProcess(
        identity: identity, executableName: name,
        title: title(
          .init(name: name, arguments: DevProcessClassifier.argumentTokens(record.arguments))),
        workingDirectory: directory, memoryBytes: input.footprints[record.processID],
        cpuPercent: record.cpuPercent)
    }.sorted {
      ($0.cpuPercent, $0.memoryBytes ?? 0, $1.processID)
        > ($1.cpuPercent, $1.memoryBytes ?? 0, $0.processID)
    }
  }

  static func find(_ input: Input) -> [LeftoverProcess]? {
    let candidates = candidates(input)
    guard !candidates.isEmpty else { return [] }
    guard let jobs = managedProcessIDs() else { return nil }
    return candidates.filter { !jobs.contains($0.processID) }
  }

  static func managedProcessIDs() -> Set<Int32>? {
    let result = DeveloperCommand.run(
      .init(
        executable: "/bin/launchctl", arguments: ["list"], timeout: 3,
        maximumBytes: 1_024 * 1_024))
    guard result.status == 0 else { return nil }
    return launchdJobs(result.output)
  }

  static func launchdJobs(_ output: String) -> Set<Int32>? {
    let lines = output.split(whereSeparator: \.isNewline)
    guard
      lines.first?.split(whereSeparator: \.isWhitespace).map(String.init) == [
        "PID", "Status", "Label",
      ]
    else { return nil }
    var jobs: Set<Int32> = []
    for line in lines.dropFirst() {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count == 3, Int32(fields[1]) != nil, !fields[2].isEmpty else { return nil }
      if fields[0] == "-" { continue }
      guard let processID = Int32(fields[0]), processID > 1 else { return nil }
      jobs.insert(processID)
    }
    return jobs
  }

  struct TitleInput {
    let name: String
    let arguments: [String]
  }

  static func title(_ input: TitleInput) -> String {
    let name = input.name
    let arguments = input.arguments
    let lowered = name.lowercased()
    let interpreters = ["python", "node", "ruby", "perl", "java", "bun", "deno", "php"]
    guard let interpreter = interpreters.first(where: { lowered.hasPrefix($0) }) else {
      return name
    }
    let takesValue: Set<String> = [
      "-cp", "-classpath", "--class-path", "-r", "--require", "-X", "-W",
    ]
    var remaining = arguments.dropFirst().makeIterator()
    while let argument = remaining.next() {
      if argument == "-m", let module = remaining.next() { return "\(interpreter) \(module)" }
      if argument == "-jar", let jar = remaining.next() {
        return "\(interpreter) \(URL(fileURLWithPath: jar).lastPathComponent)"
      }
      if takesValue.contains(argument) {
        _ = remaining.next()
        continue
      }
      if argument.hasPrefix("-") { continue }
      let script = URL(fileURLWithPath: argument).lastPathComponent
      let shown =
        interpreter == "java"
        ? (script.split(separator: ".").last.map(String.init) ?? script) : script
      return "\(interpreter) \(shown)"
    }
    return name
  }

  private static func isSystemOrService(_ path: String) -> Bool {
    systemPrefixes.contains { path.hasPrefix($0) } || path.contains(".xpc/")
      || path.contains(".appex/")
  }

  struct ExecutableInput {
    let path: String
    let apps: RunningApps
  }

  static func eligibleExecutable(_ input: ExecutableInput) -> Bool {
    guard !isSystemOrService(input.path),
      !builtInHidden.contains(URL(fileURLWithPath: input.path).lastPathComponent)
    else { return false }
    guard let app = enclosingApp(input.path) else { return true }
    return !input.apps.bundlePaths.contains(app)
  }

  private static func enclosingApp(_ path: String) -> String? {
    guard let range = path.range(of: ".app/") else { return nil }
    return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app").standardizedFileURL
      .path
  }
}

struct LeftoverStopRequest: Sendable {
  let process: LeftoverProcess
  let force: Bool
}

enum LeftoverProcessStopper {
  static func signal(_ request: LeftoverStopRequest) -> Bool {
    signals([request]).count == 1
  }

  static func signals(_ requests: [LeftoverStopRequest]) -> [LeftoverStopRequest] {
    guard !requests.isEmpty, let managedIDs = LeftoverProcessFinder.managedProcessIDs() else {
      return []
    }
    let apps = LeftoverProcessFinder.RunningApps.current()
    return requests.filter {
      signalVerified(.init(request: $0, managedIDs: managedIDs, apps: apps))
    }
  }

  private struct SignalInput {
    let request: LeftoverStopRequest
    let managedIDs: Set<Int32>
    let apps: LeftoverProcessFinder.RunningApps
  }

  private static func signalVerified(_ input: SignalInput) -> Bool {
    let request = input.request
    let processID = request.process.processID
    guard processID > 1, processID != getpid(),
      !input.managedIDs.contains(processID), !input.apps.processIDs.contains(processID),
      LeftoverProcessFinder.eligibleExecutable(
        .init(path: request.process.identity.executable, apps: input.apps)),
      let directory = ProcessWorkingDirectory.read(processID),
      !WorkspacePreferences.isKeptRunning(directory), isCurrent(request),
      parentProcessID(processID) == 1,
      !WorkspacePreferences.isKeptRunning(request.process.workingDirectory)
    else { return false }
    return Darwin.kill(processID, request.force ? SIGKILL : SIGTERM) == 0
  }

  static func isCurrent(_ request: LeftoverStopRequest) -> Bool {
    guard let current = DevProcessIdentity.read(request.process.processID) else { return false }
    return request.process.identity.matches(current) && current.process.owner == getuid()
  }

  private static func parentProcessID(_ processID: Int32) -> Int32? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Int32(info.pbi_ppid)
  }
}
