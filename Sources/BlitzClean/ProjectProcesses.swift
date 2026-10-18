import Darwin
import Foundation

struct ProjectProcessInfo: Identifiable, Codable, Equatable, Sendable {
  let processID: Int32
  let parentProcessID: Int32
  let name: String
  let workingDirectory: String
  let listeningPorts: [Int]
  /// The exact instance seen by the scan. Nil when macOS would not describe it, or when the row
  /// came from a saved scan of an earlier launch; such rows can only be stopped after a rescan.
  let identity: DevProcessIdentity?

  var id: Int32 {
    processID
  }
}

struct ProcessInspectionOutput: Sendable {
  let workingDirectories: String
  let listeningPorts: String
  let processParents: String
  let identify: @Sendable (Int32) -> DevProcessIdentity?
}

struct ProjectProcessScanner: Sendable {
  /// Nil when a command failed or was cut short: a partial list would make busy projects look idle.
  func processes() -> [ProjectProcessInfo]? {
    guard
      let workingDirectories = commandOutput(
        .init(
          executable: "/usr/sbin/lsof", arguments: ["-d", "cwd", "-Fpcn"], allowsNoMatch: false)),
      let listeningPorts = commandOutput(
        .init(
          executable: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"],
          allowsNoMatch: true)),
      let processParents = commandOutput(
        .init(executable: "/bin/ps", arguments: ["-axo", "pid=,ppid="], allowsNoMatch: false))
    else { return nil }
    return ProjectProcessParser.processes(
      .init(
        workingDirectories: workingDirectories, listeningPorts: listeningPorts,
        processParents: processParents, identify: DevProcessIdentity.read))
  }

  private func commandOutput(_ request: ProcessCommandRequest) -> String? {
    let result = DeveloperCommand.run(
      .init(
        executable: request.executable, arguments: request.arguments,
        timeout: 3, maximumBytes: 4 * 1_024 * 1_024))
    if result.status == 0 { return result.output }
    if request.allowsNoMatch, result.status == 1, result.output.isEmpty { return "" }
    return nil
  }
}

struct ProcessCommandRequest: Sendable {
  let executable: String
  let arguments: [String]
  /// lsof exits 1 when nothing matches, such as no listening ports.
  let allowsNoMatch: Bool
}

enum ProjectProcessParser {
  static func processes(_ output: ProcessInspectionOutput) -> [ProjectProcessInfo] {
    let portsByProcess = listeningPorts(output.listeningPorts)
    let parentsByProcess = processParents(output.processParents)
    var processID: Int32?
    var processName = "Process"
    var expectsWorkingDirectory = false
    var processes: [ProjectProcessInfo] = []

    for line in output.workingDirectories.split(separator: "\n").map(String.init) {
      switch line.first {
      case "p":
        processID = Int32(line.dropFirst())
      case "c":
        processName = String(line.dropFirst())
      case "f":
        expectsWorkingDirectory = line == "fcwd"
      case "n":
        guard expectsWorkingDirectory, let processID else {
          continue
        }

        processes.append(
          ProjectProcessInfo(
            processID: processID,
            parentProcessID: parentsByProcess[processID] ?? 0,
            name: processName,
            workingDirectory: String(line.dropFirst()),
            listeningPorts: portsByProcess[processID, default: []],
            identity: output.identify(processID)
          )
        )
        expectsWorkingDirectory = false
      default:
        continue
      }
    }

    let currentProcessID = ProcessInfo.processInfo.processIdentifier
    let candidates = processes.filter { process in
      process.processID != ProcessInfo.processInfo.processIdentifier
    }
    let candidateByID = Dictionary(
      candidates.map { process in
        (process.processID, process)
      }, uniquingKeysWith: { first, _ in first })
    var actionableIDs = Set(
      candidates.filter { process in
        !process.listeningPorts.isEmpty || process.parentProcessID == 1
      }.map(\.processID))

    for candidate in candidates where actionableIDs.contains(candidate.processID) {
      var parentProcessID = candidate.parentProcessID
      var visited: Set<Int32> = []
      while visited.insert(parentProcessID).inserted, let parent = candidateByID[parentProcessID],
        parent.processID != currentProcessID
      {
        actionableIDs.insert(parent.processID)
        parentProcessID = parent.parentProcessID
      }
    }

    return candidates.filter { process in
      actionableIDs.contains(process.processID)
    }
  }

  static func workingDirectories(_ output: String) -> [Int32: String] {
    var processID: Int32?
    var result: [Int32: String] = [:]

    for line in output.split(separator: "\n").map(String.init) {
      switch line.first {
      case "p":
        processID = Int32(line.dropFirst())
      case "n":
        guard let processID, result[processID] == nil else {
          continue
        }

        result[processID] = String(line.dropFirst())
      default:
        continue
      }
    }

    return result
  }

  static func listeningPorts(_ output: String) -> [Int32: [Int]] {
    var processID: Int32?
    var result: [Int32: Set<Int>] = [:]

    for line in output.split(separator: "\n").map(String.init) {
      switch line.first {
      case "p":
        processID = Int32(line.dropFirst())
      case "n":
        guard let processID, let port = port(String(line.dropFirst())) else {
          continue
        }

        result[processID, default: []].insert(port)
      default:
        continue
      }
    }

    return result.mapValues { ports in
      ports.sorted()
    }
  }

  private static func processParents(_ output: String) -> [Int32: Int32] {
    Dictionary(
      output.split(separator: "\n").compactMap { line in
        let values = line.split(whereSeparator: \Character.isWhitespace)
        guard values.count == 2,
          let processID = Int32(values[0]),
          let parentProcessID = Int32(values[1])
        else {
          return nil
        }

        return (processID, parentProcessID)
      }, uniquingKeysWith: { first, _ in first })
  }

  private static func port(_ endpoint: String) -> Int? {
    guard let separator = endpoint.lastIndex(of: ":") else {
      return nil
    }

    let suffix = endpoint[endpoint.index(after: separator)...]
    let digits = suffix.prefix { character in
      character.isNumber
    }
    return Int(digits)
  }
}

struct StopProjectProcessesRequest: Sendable {
  let processes: [ProjectProcessInfo]
}

struct StopProjectProcessesResult: Sendable {
  let signaledCount: Int
  let failureCount: Int
  let changedCount: Int
}

struct ProjectProcessController: Sendable {
  func stop(_ request: StopProjectProcessesRequest) -> StopProjectProcessesResult {
    var signaledCount = 0
    var failureCount = 0
    var changedCount = 0

    for process in request.processes {
      guard !WorkspacePreferences.isKeptRunning(process.workingDirectory) else {
        failureCount += 1
        continue
      }
      guard let identity = process.identity, identity.process.processID == process.processID else {
        changedCount += 1
        continue
      }
      switch ProcessSignal.send(.init(expected: identity, signal: SIGTERM)) {
      case .sent: signaledCount += 1
      case .changed: changedCount += 1
      case .refused, .failed: failureCount += 1
      }
    }

    return StopProjectProcessesResult(
      signaledCount: signaledCount, failureCount: failureCount, changedCount: changedCount)
  }
}
