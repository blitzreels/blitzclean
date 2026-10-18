import AppKit
import Darwin
import Foundation

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
      records.compactMap { record in
        ProcessWorkingDirectory.read(record.processID).map { (record.processID, $0) }
      }, uniquingKeysWith: { first, _ in first })

    let footprints = Dictionary(
      records.compactMap { record in
        ProcessFootprint.bytes(record.processID).map { (record.processID, $0) }
      }, uniquingKeysWith: { first, _ in first })
    let executables = Dictionary(
      records.compactMap { record in
        ProcessExecutable.path(record.processID).map { (record.processID, $0) }
      }, uniquingKeysWith: { first, _ in first })
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
      records.compactMap { process -> (Int32, DevProcessIdentity)? in
        guard let identity = DevProcessIdentity.read(process.processID),
          Double(identity.process.startSeconds) + Double(identity.process.startMicroseconds)
            / 1_000_000 < startedAt
        else { return nil }
        return (process.processID, identity)
      }, uniquingKeysWith: { first, _ in first })
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
