import AppKit
import Darwin
import Foundation

/// A process that kept running after the app or terminal that started it closed.
struct LeftoverProcess: Identifiable, Equatable, Sendable {
  let processID: Int32
  /// The executable's file name, such as `Python`. Hiding a leftover hides this name.
  let executableName: String
  /// What it runs: `python http.server`, `node daemon`, or `java GradleDaemon`.
  let title: String
  let workingDirectory: String?
  let memoryBytes: UInt64?
  let cpuPercent: Double
  let startedAt: Date
  var id: Int32 { processID }

  func matches(_ query: String) -> Bool {
    title.localizedCaseInsensitiveContains(query)
      || executableName.localizedCaseInsensitiveContains(query)
      || (workingDirectory?.localizedCaseInsensitiveContains(query) ?? false)
      || String(processID).contains(query)
  }
}

/// Finds leftovers among the current user's processes.
///
/// macOS gives every process whose parent exited to launchd, but launchd also starts apps,
/// agents, and XPC services on purpose. A leftover has launchd as its parent and is none of
/// these: not a launchd job, not an app, app extension, or XPC service, not part of macOS, and
/// not a helper of an app that is still running. A helper whose app quit is a leftover.
/// AI sessions stay in Memory, and Keep running projects are never listed.
enum LeftoverProcessFinder {
  static let hiddenKey = "projects.leftovers.hidden"
  /// Agents that are meant to outlive the shell that started them.
  static let builtInHidden: Set<String> = ["ssh-agent", "gpg-agent", "keyboxd", "dirmngr"]
  private static let systemPrefixes = [
    "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/",
    "/Library/Developer/PrivateFrameworks/", "/Library/Developer/CoreSimulator/",
    "/Library/Filesystems/", "/Library/PrivilegedHelperTools/",
  ]

  struct RunningApps: Sendable {
    let processIDs: Set<Int32>
    let bundlePaths: Set<String>

    /// `runningApplications` is safe to read from a background thread.
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
    /// Start times of processes with a verified identity; others cannot be signaled safely.
    let startTimes: [Int32: Double]
    let apps: RunningApps
    /// AI session processes, which Memory owns.
    let excludedIDs: Set<Int32>
    let keptRunningRoots: [String]
  }

  /// Candidates before the launchd job check, largest CPU then memory first.
  static func candidates(_ input: Input) -> [LeftoverProcess] {
    input.records.compactMap { record -> LeftoverProcess? in
      guard record.parentProcessID == 1, !input.excludedIDs.contains(record.processID),
        !input.apps.processIDs.contains(record.processID),
        let startTime = input.startTimes[record.processID],
        let path = input.executables[record.processID], !isSystemOrService(path)
      else { return nil }
      if let app = enclosingApp(path), input.apps.bundlePaths.contains(app) { return nil }
      let name = URL(fileURLWithPath: path).lastPathComponent
      guard !builtInHidden.contains(name) else { return nil }
      let directory = input.directories[record.processID].flatMap { $0 == "/" ? nil : $0 }
      if let directory,
        input.keptRunningRoots.contains(where: {
          WorkspacePreferences.contains(.init(directory: directory, root: $0))
        })
      {
        return nil
      }
      return LeftoverProcess(
        processID: record.processID, executableName: name,
        title: title(name: name, arguments: DevProcessClassifier.argumentTokens(record.arguments)),
        workingDirectory: directory, memoryBytes: input.footprints[record.processID],
        cpuPercent: record.cpuPercent, startedAt: Date(timeIntervalSince1970: startTime))
    }.sorted {
      ($0.cpuPercent, $0.memoryBytes ?? 0, $1.processID)
        > ($1.cpuPercent, $1.memoryBytes ?? 0, $0.processID)
    }
  }

  /// Leftovers, or nil when the launchd job list could not be read. Without it, agents and
  /// Homebrew services would look like leftovers, so none are shown.
  static func find(_ input: Input) -> [LeftoverProcess]? {
    let candidates = candidates(input)
    guard !candidates.isEmpty else { return [] }
    let result = DeveloperCommand.run(
      .init(
        executable: "/bin/launchctl", arguments: ["list"], timeout: 3,
        maximumBytes: 1_024 * 1_024))
    guard result.status == 0 else { return nil }
    let jobs = launchdJobs(result.output)
    return candidates.filter { !jobs.contains($0.processID) }
  }

  /// The PIDs in `launchctl list` output: jobs launchd runs on purpose in this user's domain.
  static func launchdJobs(_ output: String) -> Set<Int32> {
    Set(
      output.split(separator: "\n").dropFirst().compactMap { line in
        line.split(separator: "\t", maxSplits: 1).first.flatMap { Int32($0) }
      })
  }

  /// What an interpreter runs reads better than the interpreter itself.
  static func title(name: String, arguments: [String]) -> String {
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

  /// The outermost app bundle: `/Applications/Brave Browser.app` for each of its helpers.
  private static func enclosingApp(_ path: String) -> String? {
    guard let range = path.range(of: ".app/") else { return nil }
    return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app").standardizedFileURL
      .path
  }
}

struct LeftoverStopRequest: Sendable {
  let process: LeftoverProcess
  let expected: DevProcessIdentity
  let force: Bool
}

enum LeftoverProcessStopper {
  /// Sends SIGTERM, or SIGKILL when forced, only while the PID is still the same leftover:
  /// same start time and executable, owned by this user, parented to launchd, and outside
  /// Keep running projects. Never escalates on its own.
  static func signal(_ request: LeftoverStopRequest) -> Bool {
    let processID = request.process.processID
    guard processID > 1, processID != getpid(), isCurrent(request),
      parentProcessID(processID) == 1,
      !WorkspacePreferences.isKeptRunning(request.process.workingDirectory)
    else { return false }
    return Darwin.kill(processID, request.force ? SIGKILL : SIGTERM) == 0
  }

  /// The same process instance is still alive.
  static func isCurrent(_ request: LeftoverStopRequest) -> Bool {
    guard let current = DevProcessIdentity.read(request.process.processID) else { return false }
    return request.expected.matches(current) && current.process.owner == getuid()
  }

  private static func parentProcessID(_ processID: Int32) -> Int32? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Int32(info.pbi_ppid)
  }
}
