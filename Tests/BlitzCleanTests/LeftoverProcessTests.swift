import Darwin
import Foundation
import Testing

@testable import BlitzClean

struct LeftoverProcessTests {
  private struct Fixture {
    let processID: Int32
    var parentProcessID: Int32 = 1
    let executable: String
    var arguments: String? = nil
    var directory: String? = "/Users/me/dev/site"
    var hasIdentity = true
  }

  private func candidates(
    _ fixtures: [Fixture],
    apps: LeftoverProcessFinder.RunningApps = .init(
      processIDs: [], bundlePaths: []),
    excluded: Set<Int32> = [], keptRunning: [String] = []
  ) -> [LeftoverProcess] {
    LeftoverProcessFinder.candidates(
      .init(
        records: fixtures.map {
          RawProcessRecord(
            processID: $0.processID, parentProcessID: $0.parentProcessID, userID: 501,
            cpuPercent: Double($0.processID), residentKilobytes: 0, elapsed: "01:00",
            terminal: nil, arguments: $0.arguments ?? $0.executable)
        },
        executables: Dictionary(
          uniqueKeysWithValues: fixtures.map { ($0.processID, $0.executable) }),
        directories: Dictionary(
          uniqueKeysWithValues: fixtures.compactMap { f in f.directory.map { (f.processID, $0) } }),
        footprints: Dictionary(uniqueKeysWithValues: fixtures.map { ($0.processID, 1_024) }),
        startTimes: Dictionary(
          uniqueKeysWithValues: fixtures.filter(\.hasIdentity).map { ($0.processID, 1_000) }),
        apps: apps, excludedIDs: excluded, keptRunningRoots: keptRunning))
  }

  @Test
  func listsProcessesWhoseParentExited() {
    let found = candidates([
      .init(
        processID: 10, executable: "/opt/homebrew/bin/python3",
        arguments: "/opt/homebrew/bin/python3 -m http.server 8000"),
      .init(processID: 11, parentProcessID: 500, executable: "/opt/homebrew/bin/node"),
    ])

    #expect(found.map(\.processID) == [10])
    #expect(found.first?.title == "python http.server")
    #expect(found.first?.executableName == "python3")
    #expect(found.first?.workingDirectory == "/Users/me/dev/site")
  }

  @Test
  func skipsSystemServicesAndRunningApps() {
    let apps = LeftoverProcessFinder.RunningApps(
      processIDs: [30], bundlePaths: ["/Applications/Brave Browser.app"])
    let found = candidates(
      [
        .init(processID: 20, executable: "/usr/libexec/trustd"),
        .init(
          processID: 21, executable: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
        ),
        .init(
          processID: 22,
          executable:
            "/Applications/Brave Browser.app/Contents/Frameworks/Brave.framework/Helpers/Brave Helper"
        ),
        .init(
          processID: 23,
          executable: "/Applications/Tool.app/Contents/XPCServices/Sync.xpc/Contents/MacOS/Sync"),
        .init(processID: 24, executable: "/Applications/Gone.app/Contents/MacOS/gone-helper"),
        .init(processID: 30, executable: "/Applications/Notes Plus.app/Contents/MacOS/Notes Plus"),
      ], apps: apps)

    #expect(found.map(\.processID) == [24])
  }

  @Test
  func protectsAISessionsAgentsKeepRunningAndUnverifiedProcesses() {
    let found = candidates(
      [
        .init(processID: 40, executable: "/Users/me/.local/bin/claude"),
        .init(processID: 41, executable: "/usr/bin/ssh-agent"),
        .init(processID: 42, executable: "/opt/homebrew/bin/node", hasIdentity: false),
        .init(
          processID: 43, executable: "/opt/homebrew/bin/node",
          directory: "/Users/me/dev/kept/packages/api"),
        .init(processID: 44, executable: "/opt/homebrew/bin/node", directory: "/"),
      ], excluded: [40], keptRunning: ["/Users/me/dev/kept"])

    #expect(found.map(\.processID) == [44])
    #expect(found.first?.workingDirectory == nil)
  }

  @Test
  func ranksByCPU() {
    let found = candidates([
      .init(processID: 50, executable: "/opt/homebrew/bin/ruby"),
      .init(processID: 52, executable: "/opt/homebrew/bin/ruby"),
      .init(processID: 51, executable: "/opt/homebrew/bin/ruby"),
    ])

    #expect(found.map(\.processID) == [52, 51, 50])
  }

  @Test
  func readsLaunchdJobPIDs() {
    let jobs = LeftoverProcessFinder.launchdJobs(
      "PID\tStatus\tLabel\n412\t0\tcom.apple.Finder\n-\t0\tcom.example.idle\n918\t-9\thomebrew.mxcl.postgresql\n"
    )

    #expect(jobs == [412, 918])
  }

  @Test
  func namesWhatAnInterpreterRuns() {
    let title = LeftoverProcessFinder.title
    #expect(title("python3.12", ["python3", "-u", "-m", "http.server"]) == "python http.server")
    #expect(
      title("node", ["node", "--require", "ts-node/register", "/srv/daemon.js"]) == "node daemon.js"
    )
    #expect(
      title("java", ["java", "-cp", "lib/*", "org.gradle.launcher.daemon.GradleDaemon"])
        == "java GradleDaemon")
    #expect(title("java", ["java", "-jar", "/opt/tools/server.jar"]) == "java server.jar")
    #expect(title("node", ["node"]) == "node")
    #expect(title("esbuild", ["esbuild", "--service=0.19.2"]) == "esbuild")
  }

  @Test
  func describesOutcomes() {
    let process = LeftoverProcess(
      processID: 60, executableName: "node", title: "node daemon.js", workingDirectory: nil,
      memoryBytes: 2_048, cpuPercent: 0, startedAt: .now)
    let identity = DevProcessIdentity(
      process: .init(processID: 60, owner: 501, startSeconds: 1, startMicroseconds: 0, state: 0),
      executable: "/opt/homebrew/bin/node")
    let request = LeftoverStopRequest(process: process, expected: identity, force: false)
    let message = DevProcessModel.leftoverMessage

    #expect(
      message(.init(requested: [request], signaled: [request], running: 1))
        == "node daemon.js is still running. Use Force Quit to end it now.")
    #expect(
      message(.init(requested: [request], signaled: [], running: 0))
        == "node daemon.js already exited or changed. The list is refreshed.")
    #expect(
      message(
        .init(requested: [request, request, request], signaled: [request, request], running: 1))
        == "Quit 1 of 3 leftover processes · 1 still running · 1 exited or changed")
  }

  // MARK: Signals, against disposable processes

  /// Starts `sleep` from a shell that exits at once, so launchd becomes its parent.
  private func startLeftover() throws -> Int32 {
    let shell = Process()
    let pipe = Pipe()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "/bin/sleep 30 >/dev/null 2>&1 & echo $!"]
    shell.standardOutput = pipe
    try shell.run()
    shell.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return try #require(Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  private func request(_ processID: Int32, identity: DevProcessIdentity, force: Bool = false)
    -> LeftoverStopRequest
  {
    LeftoverStopRequest(
      process: .init(
        processID: processID, executableName: "sleep", title: "sleep", workingDirectory: nil,
        memoryBytes: nil, cpuPercent: 0, startedAt: .now),
      expected: identity, force: force)
  }

  private func waitForExit(_ processID: Int32) async -> Bool {
    for _ in 0..<40 {
      if DevProcessIdentity.read(processID) == nil { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  @Test
  func quitsAVerifiedLeftover() async throws {
    let processID = try startLeftover()
    defer { kill(processID, SIGKILL) }
    let identity = try #require(DevProcessIdentity.read(processID))

    #expect(LeftoverProcessStopper.signal(request(processID, identity: identity)))
    #expect(await waitForExit(processID))
  }

  @Test
  func refusesAReusedProcessID() async throws {
    let processID = try startLeftover()
    defer { kill(processID, SIGKILL) }
    let identity = try #require(DevProcessIdentity.read(processID))
    let earlier = DevProcessIdentity(
      process: .init(
        processID: processID, owner: identity.process.owner,
        startSeconds: identity.process.startSeconds - 60,
        startMicroseconds: identity.process.startMicroseconds, state: identity.process.state),
      executable: identity.executable)

    #expect(!LeftoverProcessStopper.signal(request(processID, identity: earlier, force: true)))
    #expect(LeftoverProcessStopper.isCurrent(request(processID, identity: identity)))
  }

  @Test
  func refusesAProcessWhoseParentIsRunning() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer { child.terminate() }
    let identity = try #require(DevProcessIdentity.read(child.processIdentifier))

    #expect(!LeftoverProcessStopper.signal(request(child.processIdentifier, identity: identity)))
    #expect(child.isRunning)
  }
}
