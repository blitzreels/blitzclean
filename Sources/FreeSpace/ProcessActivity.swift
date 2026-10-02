import Darwin
import Foundation

struct CPUProcess: Identifiable, Equatable, Sendable {
  let processID: Int32
  let name: String
  let workingDirectory: String?
  let cpuPercent: Double
  var id: Int32 { processID }
}

struct CPUProcessInput {
  let records: [RawProcessRecord]
  let workingDirectories: [Int32: String]
}

enum CPUProcessRanking {
  static func ranked(_ input: CPUProcessInput) -> [CPUProcess] {
    let records = Dictionary(uniqueKeysWithValues: input.records.map { ($0.processID, $0) })
    return input.records.filter { $0.cpuPercent > 0 }.map { record in
      var current = record
      var visited: Set<Int32> = []
      var directory: String?
      while visited.insert(current.processID).inserted {
        if let path = input.workingDirectories[current.processID], path != "/" {
          directory = path
          break
        }
        guard let parent = records[current.parentProcessID], parent.userID == record.userID else {
          break
        }
        current = parent
      }
      let executable = record.arguments
      let name: String
      if let appRange = executable.range(of: ".app/") {
        let appPath = String(executable[..<appRange.lowerBound])
        let appName = URL(fileURLWithPath: appPath).lastPathComponent
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        name = executableName == appName ? appName : "\(appName) · \(executableName)"
      } else {
        name = URL(fileURLWithPath: executable).lastPathComponent
      }
      return CPUProcess(
        processID: record.processID, name: name, workingDirectory: directory,
        cpuPercent: record.cpuPercent)
    }.sorted {
      $0.cpuPercent == $1.cpuPercent ? $0.processID < $1.processID : $0.cpuPercent > $1.cpuPercent
    }
  }
}

struct DevProject: Identifiable, Sendable {
  let directory: String
  let processes: [DevProcess]
  var id: String { directory }
  var name: String { URL(fileURLWithPath: directory).lastPathComponent }
  var servers: [DevProcess] { processes.filter(\.canStopWithProject) }

  static func grouped(_ processes: [DevProcess]) -> [Self] {
    let candidates = processes.filter { $0.kind.group == .servers && $0.workingDirectory != nil }
    return Dictionary(grouping: candidates) { $0.workingDirectory! }.map {
      DevProject(directory: $0.key, processes: $0.value.sorted { $0.cpuPercent > $1.cpuPercent })
    }.sorted {
      if $0.servers.isEmpty != $1.servers.isEmpty { return !$0.servers.isEmpty }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }
}

extension DevProcess {
  var canStopWithProject: Bool {
    let serverNames: Set<String> = [
      "vite", "next", "next-server", "expo", "astro", "nuxt", "remix", "webpack",
      "wrangler", "http-server", "live-server", "serve",
    ]
    return kind == .devServer && !listeningPorts.isEmpty && serverNames.contains(name)
  }
}

struct DevProcessIdentity: Equatable, Sendable {
  let process: RecoveryProcess
  let executable: String

  static func read(_ processID: Int32) -> Self? {
    guard let process = NativeAppRecoveryDriver.readProcess(processID), !process.exited else {
      return nil
    }
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return Self(
      process: process,
      executable: String(
        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
  }

  func matches(_ other: Self) -> Bool {
    process.isSameInstance(other.process) && executable == other.executable
  }
}

struct DevStopRequest: Sendable {
  let process: DevProcess
  let expected: DevProcessIdentity?
  let force: Bool
}

enum DevProcessStopper {
  static func stop(_ request: DevStopRequest) -> String {
    let target = request.process
    guard !WorkspacePreferences.isKeptRunning(target.workingDirectory) else {
      return "This project is set to Keep running. Unpin it in Projects before stopping a process."
    }
    guard let expected = request.expected, let current = DevProcessIdentity.read(target.processID),
      expected.matches(current), current.process.owner == getuid(), target.processID != getpid(),
      target.processID > 1
    else { return "\(target.name) exited or changed. Refresh before stopping it." }
    guard Darwin.kill(target.processID, request.force ? SIGKILL : SIGTERM) == 0 else {
      return "Could not stop \(target.name): \(String(cString: strerror(errno)))"
    }
    return request.force
      ? "Force quit requested for \(target.name)" : "Asked \(target.name) to stop"
  }
}

struct DevProcessSnapshot: Sendable {
  let processes: [DevProcess]
  let cpuProcesses: [CPUProcess]
  let identities: [Int32: DevProcessIdentity]
  let threads: [AIThread]
  let resources: [ResourceProcess]
  var workspaceRoots: [Int32: String] = [:]
  var incomplete = false
}

enum ProcessWorkingDirectory {
  static func read(_ processID: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = MemoryLayout<proc_vnodepathinfo>.size
    guard proc_pidinfo(processID, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else {
      return nil
    }
    return withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
      let path = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
      return path.isEmpty ? nil : path
    }
  }
}
