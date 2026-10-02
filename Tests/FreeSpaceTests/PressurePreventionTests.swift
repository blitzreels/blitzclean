import Darwin
import Foundation
import Testing

@testable import FreeSpace

struct PressurePreventionTests {
  @Test func stopHandlesPausedWorkersAndRejectsStaleOrChangedIdentities() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    defer {
      if process.isRunning {
        kill(process.processIdentifier, SIGCONT)
        process.terminate()
      }
      process.waitUntilExit()
    }
    let identity = try #require(DevProcessIdentity.read(process.processIdentifier))
    let root = "/tmp/stop-fixture-\(UUID())"
    let target = ProjectPauseTarget(
      directory: root, name: "Fixture", cpuPercent: 0, memoryBytes: 0,
      identities: [identity], capturedAt: .now)
    var kept = target
    kept.keepRunning = true
    #expect(ProjectPausePolicy.stop(kept) == 0)
    let stale = ProjectPauseTarget(
      directory: root, name: "Fixture", cpuPercent: 0, memoryBytes: 0,
      identities: [identity], capturedAt: .now.addingTimeInterval(-60))
    #expect(ProjectPausePolicy.stop(stale) == 0)
    let replaced = ProjectPauseTarget(
      directory: root, name: "Fixture", cpuPercent: 0, memoryBytes: 0,
      identities: [.init(process: identity.process, executable: "/different")], capturedAt: .now)
    #expect(ProjectPausePolicy.stop(replaced) == 0)
    #expect(ProjectPausePolicy.signal(.init(target: target, resume: false)) == 1)
    try await Task.sleep(for: .milliseconds(50))
    #expect(ProjectPausePolicy.stop(target) == 1)
    for _ in 0..<30 where ProjectPausePolicy.remaining(target) > 0 {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(ProjectPausePolicy.remaining(target) == 0)
  }

  @Test func backgroundWorkersAreRunningProjectsWithoutPorts() {
    let resource = ResourceProcess(
      processID: 100, parentProcessID: 1, name: "node", owner: "Background service",
      directory: "/tmp/openseo", memoryBytes: 500_000_000, cpuPercent: 50, isTool: false)
    let project = WorkspaceProject(
      directory: "/tmp/openseo",
      preference: .init(
        directory: "/tmp/openseo", name: "OpenSEO", keepRunning: false, startCommand: nil),
      resources: [resource], servers: [])
    #expect(project.isRunning)
  }

  @Test func childWorkersInTemporaryDirectoriesStayWithTheirProject() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))
    let resources = [
      ResourceProcess(
        processID: 1_001, parentProcessID: 1, name: "node", owner: "Background service",
        directory: root.path, memoryBytes: 10, cpuPercent: 0, isTool: false),
      ResourceProcess(
        processID: 1_002, parentProcessID: 1_001, name: "node", owner: "Background service",
        directory: "/tmp", memoryBytes: 20, cpuPercent: 0, isTool: false),
      ResourceProcess(
        processID: 1_003, parentProcessID: 1_002, name: "ffmpeg", owner: "Background service",
        directory: "/", memoryBytes: 30, cpuPercent: 0, isTool: false),
    ]
    let projects = WorkspaceCatalog.projects(
      .init(resources: resources, processes: [], preferences: []))
    #expect(projects.count == 1)
    #expect(projects.first?.memoryBytes == 60)
    #expect(projects.first?.resources.count == 3)
  }

  @Test func projectPauseExcludesAISessionsToolsAndAppExecutables() throws {
    let identity = try #require(DevProcessIdentity.read(getpid()))
    let resources = [
      ResourceProcess(
        processID: getpid(), parentProcessID: 1, name: "node", owner: "Codex",
        directory: "/tmp/project", memoryBytes: 1, cpuPercent: 0, isTool: true)
    ]
    let project = WorkspaceProject(
      directory: "/tmp/project",
      preference: .init(
        directory: "/tmp/project", name: "Project", keepRunning: false, startCommand: nil),
      resources: resources, servers: [])
    #expect(
      ProjectPausePolicy.target(
        .init(
          project: project, identities: [getpid(): identity], excludedIDs: [getpid()], date: .now))
        == nil)
  }

  @Test func workersInsideDependenciesResolveToTheOwningProject() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let child = root.appendingPathComponent("node_modules/some-worker/dist")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))
    #expect(WorkspaceCatalog.root(child.path) == WorkspacePreferences.canonical(root.path))
  }

  @Test func warnsBeforeDiskReserveIsExhausted() {
    var evaluator = DiskRiskEvaluator()
    let date = Date(timeIntervalSince1970: 1_000)
    _ = evaluator.evaluate(.init(date: date, available: 50_000_000_000, swapUsed: 15_000_000_000))
    let result = evaluator.evaluate(
      .init(date: date.addingTimeInterval(60), available: 40_000_000_000, swapUsed: 20_000_000_000))
    #expect(result.risk >= .warning)
  }

  @Test func constrainedSwapWarnsEvenBeforeNativeMemoryWarning() {
    var evaluator = PressureEvaluator()
    let date = Date(timeIntervalSince1970: 1_000)
    let memory = MemoryGuardSample(
      date: date, pressure: .normal, available: 3_000_000_000, total: 36_000_000_000,
      compressed: 9_000_000_000, swapUsed: 29_000_000_000, swapOutBytes: 0)
    let result = evaluator.evaluate(
      .init(
        memory: memory,
        disk: .init(date: date, available: 9_000_000_000, swapUsed: memory.swapUsed), cpu: 0.4))
    #expect(result.risk == .critical)
    #expect(result.title.contains("Memory and disk"))
    #expect(result.action.contains("Avoid starting"))
  }

  @Test func oldSwapWithHealthyHeadroomDoesNotWarn() {
    var evaluator = PressureEvaluator()
    let memory = MemoryGuardSample(
      date: .now, pressure: .normal, available: 20_000_000_000, total: 36_000_000_000,
      compressed: 1_000_000_000, swapUsed: 29_000_000_000, swapOutBytes: 0)
    let result = evaluator.evaluate(
      .init(
        memory: memory,
        disk: .init(date: memory.date, available: 60_000_000_000, swapUsed: memory.swapUsed),
        cpu: 0.4))
    #expect(result.risk == .normal)
  }

  @Test func briefCPUSpikeDoesNotWarnButSustainedCPUDoes() {
    var evaluator = PressureEvaluator()
    let start = Date(timeIntervalSince1970: 1_000)
    for second in [0.0, 5.0, 15.0] {
      let date = start.addingTimeInterval(second)
      let memory = MemoryGuardSample(
        date: date, pressure: .normal, available: 20_000_000_000, total: 36_000_000_000,
        compressed: 1_000_000_000, swapUsed: 0, swapOutBytes: 0)
      let result = evaluator.evaluate(
        .init(
          memory: memory, disk: .init(date: date, available: 60_000_000_000, swapUsed: 0), cpu: 0.98
        ))
      #expect(result.risk == (second == 15 ? .warning : .normal))
    }
  }

  @Test func hungInspectionCommandHasADeadline() {
    let start = Date.now
    let result = DeveloperCommand.run(
      .init(
        executable: "/bin/sleep", arguments: ["20"], timeout: 0.2, maximumBytes: 1_024))
    #expect(result.status == -1)
    #expect(Date.now.timeIntervalSince(start) < 3)
  }

  @Test func nativeDirectoryReadFindsCurrentProcess() {
    let directory = ProcessWorkingDirectory.read(getpid())
    #expect(directory != nil)
    #expect(
      directory.map(WorkspacePreferences.canonical)
        == WorkspacePreferences.canonical(FileManager.default.currentDirectoryPath))
  }

  @Test func pauseResumeRevalidatesIdentityAndDoesNotResumeChangedPID() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    defer {
      kill(process.processIdentifier, SIGCONT)
      process.terminate()
      process.waitUntilExit()
    }
    let identity = try #require(DevProcessIdentity.read(process.processIdentifier))
    let target = ProjectPauseTarget(
      directory: "/tmp/pressure-fixture-\(UUID())", name: "Fixture", cpuPercent: 0,
      memoryBytes: 0, identities: [identity], capturedAt: .now)
    #expect(ProjectPausePolicy.signal(.init(target: target, resume: false)) == 1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(DevProcessIdentity.read(process.processIdentifier)?.process.stopped == true)
    #expect(ProjectPausePolicy.signal(.init(target: target, resume: true)) == 1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(DevProcessIdentity.read(process.processIdentifier)?.process.stopped == false)
    let wrong = DevProcessIdentity(process: identity.process, executable: "/wrong/process")
    let changed = ProjectPauseTarget(
      directory: target.directory, name: target.name, cpuPercent: 0, memoryBytes: 0,
      identities: [wrong], capturedAt: .now)
    #expect(ProjectPausePolicy.signal(.init(target: changed, resume: false)) == 0)
    var protected = target
    protected.keepRunning = true
    #expect(ProjectPausePolicy.signal(.init(target: protected, resume: false)) == 0)
    let stale = ProjectPauseTarget(
      directory: target.directory, name: target.name, cpuPercent: 0, memoryBytes: 0,
      identities: [identity], capturedAt: .now.addingTimeInterval(-60))
    #expect(ProjectPausePolicy.signal(.init(target: stale, resume: false)) == 0)

  }

  @Test func scanIncludesNestedBackgroundWorkersWithoutPorts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OpenSEO-fixture-\(UUID())")
    let child = root.appendingPathComponent("node_modules/worker")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    process.currentDirectoryURL = child
    try process.run()
    defer {
      process.terminate()
      process.waitUntilExit()
      try? FileManager.default.removeItem(at: root)
    }
    let start = Date.now
    let snapshot = DevProcessScanner().snapshot()
    let elapsed = Date.now.timeIntervalSince(start)
    let worker = try #require(snapshot.resources.first { $0.id == process.processIdentifier })
    #expect(worker.directory != nil)
    #expect(
      snapshot.workspaceRoots[worker.id]
        == WorkspacePreferences.canonical(root.path))
    #expect(elapsed < 8)
    print("Project scan: \(snapshot.resources.count) processes in \(Int(elapsed * 1_000)) ms")
  }
}
