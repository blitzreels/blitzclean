import Darwin
import Foundation
import Testing

@testable import BlitzClean

struct BuildBrakeTests {
  private let gib: UInt64 = 1_024 * 1_024 * 1_024
  private let mib: Double = 1_024 * 1_024
  private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

  private struct Fixture {
    let pid: Int32
    let name: String
    let gib: UInt64
    let stopped: Bool
    var growthMiB: Double = 0
  }

  private func candidate(_ fixture: Fixture) -> BuildBrakeCandidate {
    .init(
      process: .init(
        identity: .init(
          process: .init(
            processID: fixture.pid, owner: getuid(), startSeconds: 1, startMicroseconds: 0,
            state: UInt32(fixture.stopped ? SSTOP : SRUN)),
          executable: "/repo/node_modules/.bin/\(fixture.name)"),
        name: fixture.name, project: "blitzreels", footprint: fixture.gib * gib,
        agent: "Claude Code"),
      growth: fixture.growthMiB * mib)
  }

  private struct Situation {
    let risk: MemoryRisk
    var availableGiB: UInt64 = 20
    var candidates: [BuildBrakeCandidate] = []
    var paused: [BuildBrakeEntry] = []
    var lastAction = Date.distantPast
  }

  private func decide(_ situation: Situation) -> BuildBrakeDecision {
    BuildBrakePolicy.decide(
      .init(
        risk: situation.risk, total: 36 * gib, available: situation.availableGiB * gib, date: now,
        candidates: situation.candidates, paused: situation.paused,
        lastAction: situation.lastAction))
  }

  private func entry(_ fixture: Fixture, pausedSecondsAgo: TimeInterval) -> BuildBrakeEntry {
    .init(process: candidate(fixture).process, pausedAt: now.addingTimeInterval(-pausedSecondsAgo))
  }

  @Test func warningPausesTheLargestRunningBuild() {
    let tsc = candidate(.init(pid: 10, name: "tsc", gib: 14, stopped: false))
    let candidates = [
      candidate(.init(pid: 11, name: "esbuild", gib: 4, stopped: false)), tsc,
      candidate(.init(pid: 12, name: "tsc", gib: 20, stopped: true)),
    ]
    #expect(decide(.init(risk: .warning, candidates: candidates)) == .pause(tsc.process))
  }

  @Test func risingSwapPausesOnlyABuildHoldingAQuarterOfMemory() {
    let small = [candidate(.init(pid: 10, name: "tsc", gib: 8, stopped: false))]
    #expect(decide(.init(risk: .growing, candidates: small)) == .none)
    let large = candidate(.init(pid: 11, name: "node", gib: 16, stopped: false))
    #expect(decide(.init(risk: .growing, candidates: small + [large])) == .pause(large.process))
  }

  /// On October 25 a typecheck grew about 170 MB a second; at 8 GB free that leaves under a minute.
  @Test func fastGrowthPausesBeforeMacOSWarns() {
    let tsc = candidate(.init(pid: 10, name: "tsc", gib: 3, stopped: false, growthMiB: 170))
    let slow = candidate(.init(pid: 11, name: "esbuild", gib: 2, stopped: false, growthMiB: 5))
    #expect(
      decide(.init(risk: .normal, availableGiB: 8, candidates: [slow, tsc])) == .pause(tsc.process))
    #expect(decide(.init(risk: .normal, availableGiB: 20, candidates: [slow, tsc])) == .none)
  }

  @Test func pausesAreSpacedSoMemoryCanSettle() {
    let candidates = [candidate(.init(pid: 10, name: "tsc", gib: 14, stopped: false))]
    #expect(
      decide(.init(risk: .critical, candidates: candidates, lastAction: now.addingTimeInterval(-2)))
        == .none)
  }

  @Test func resumesSmallestFirstOnlyWithRoomToSpare() {
    let large = entry(.init(pid: 10, name: "tsc", gib: 14, stopped: true), pausedSecondsAgo: 60)
    let small = entry(.init(pid: 11, name: "esbuild", gib: 4, stopped: true), pausedSecondsAgo: 60)
    #expect(decide(.init(risk: .normal, paused: [large, small])) == .resume(small))
    #expect(decide(.init(risk: .normal, availableGiB: 8, paused: [large, small])) == .none)
    #expect(decide(.init(risk: .growing, paused: [large, small])) == .none)
    let fresh = entry(.init(pid: 12, name: "tsc", gib: 2, stopped: true), pausedSecondsAgo: 5)
    #expect(decide(.init(risk: .normal, paused: [fresh])) == .none)
  }

  @Test func aLongPauseWhileMemoryStaysShortIsStuck() {
    let paused = entry(.init(pid: 10, name: "tsc", gib: 14, stopped: true), pausedSecondsAgo: 180)
    func stuck(_ input: (risk: MemoryRisk, available: UInt64)) -> Bool {
      BuildBrakePolicy.isStuck(
        .init(
          entry: paused, risk: input.risk, total: 36 * gib, available: input.available * gib,
          date: now))
    }
    #expect(stuck((.warning, 6)))
    #expect(stuck((.normal, 5)))
    #expect(!stuck((.normal, 20)))
  }

  @Test func runtimesCountOnlyWhenAnAgentStartedThem() {
    #expect(BuildBrakePolicy.qualifies(.init(name: "tsc", startedByAgent: false)))
    #expect(BuildBrakePolicy.qualifies(.init(name: "node", startedByAgent: true)))
    #expect(!BuildBrakePolicy.qualifies(.init(name: "node", startedByAgent: false)))
    #expect(!BuildBrakePolicy.qualifies(.init(name: "claude", startedByAgent: true)))
  }

  @Test func watchLowersACompilersPriorityAndRestoresIt() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("brake-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let tsc = folder.appendingPathComponent("tsc")
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: tsc.path)
    _ = CommandRunner.run(
      .init(
        executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", tsc.path],
        timeout: 20, maximumBytes: 65_536, input: nil, environment: .inherited))
    let child = try TestProcesses.start(.init(executable: tsc.path, arguments: ["30"]))
    defer { child.stop() }
    func priority() -> String {
      CommandRunner.run(
        .init(
          executable: "/bin/ps", arguments: ["-o", "pri=", "-p", "\(child.processID)"], timeout: 5,
          maximumBytes: 1_024, input: nil, environment: .inherited)
      ).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    usleep(3_000_000)
    var watch = BuildWatch()
    defer { watch.restorePriority() }
    let sample = watch.sample(.now)
    #expect(sample.candidates.contains { $0.process.identity.process.processID == child.processID })
    #expect(priority() == "4")
    watch.restorePriority()
    #expect(priority() != "4")
  }

  @Test func savedPausesResumeAfterARelaunch() throws {
    let child = try TestProcesses.start(.init(executable: "/bin/sleep", arguments: ["30"]))
    defer { child.stop() }
    #expect(kill(child.processID, SIGSTOP) == 0)
    let deadline = Date.now.addingTimeInterval(2)
    var identity = try #require(DevProcessIdentity.read(child.processID))
    while !identity.process.stopped && Date.now < deadline {
      usleep(10_000)
      identity = try #require(DevProcessIdentity.read(child.processID))
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("build-brake-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let saved = BuildBrakeEntry(
      process: .init(identity: identity, name: "sleep", project: nil, footprint: gib, agent: nil),
      pausedAt: .now.addingTimeInterval(-60))
    try JSONEncoder().encode([saved]).write(to: url)

    var brake = BuildBrake(url: url)
    #expect(brake.paused.count == 1)
    let outcome = brake.step(.init(risk: .normal, total: 36 * gib, available: 30 * gib, date: .now))
    #expect(outcome?.message == "Resumed sleep.")
    #expect(brake.paused.isEmpty)
    #expect(DevProcessIdentity.read(child.processID)?.process.stopped == false)
  }

  @Test func thresholdsScaleWithMemory() {
    #expect(BuildBrakePolicy.minimumBytes(8 * gib) == 512 * 1_024 * 1_024)
    #expect(BuildBrakePolicy.minimumBytes(36 * gib) == 36 * gib / 32)
    #expect(BuildBrakePolicy.minimumBytes(128 * gib) == 4 * gib)
    let growing = candidate(.init(pid: 10, name: "tsc", gib: 1, stopped: false, growthMiB: 100))
    let left = BuildBrakePolicy.secondsLeft(
      .init(available: 8 * gib, total: 16 * gib, candidates: [growing]))
    #expect(Int(left) == Int(Double(8 * gib - 16 * gib / 10) / (100 * mib)))
  }

  @Test func anAgentRestartingAPausedBuildIsNamedOnTheSecondRetry() {
    var tracker = BuildRetryTracker()
    let tsc = candidate(.init(pid: 10, name: "tsc", gib: 15, stopped: false)).process
    #expect(tracker.paused(.init(process: tsc, date: now)) == nil)
    tracker.ended(.init(label: tsc.label, date: now.addingTimeInterval(60)))
    #expect(tracker.paused(.init(process: tsc, date: now.addingTimeInterval(120))) == nil)
    #expect(tracker.paused(.init(process: tsc, date: now.addingTimeInterval(150))) == nil)
    tracker.ended(.init(label: tsc.label, date: now.addingTimeInterval(200)))
    let warning = tracker.paused(.init(process: tsc, date: now.addingTimeInterval(260)))
    #expect(warning?.hasPrefix("Claude Code restarted tsc · blitzreels 2 times") == true)
    tracker.ended(.init(label: tsc.label, date: now.addingTimeInterval(300)))
    #expect(tracker.paused(.init(process: tsc, date: now.addingTimeInterval(360))) == nil)
    tracker.ended(.init(label: tsc.label, date: now.addingTimeInterval(400)))
    #expect(tracker.paused(.init(process: tsc, date: now.addingTimeInterval(400 + 600))) == nil)
  }

  @Test func onlyOneCopyActs() {
    let released = ActingCopy.Copy(level: 1, isDevelopment: false)
    let dev = ActingCopy.Copy(level: 1, isDevelopment: true)
    let old = ActingCopy.Copy(level: 0, isDevelopment: false)
    #expect(!ActingCopy.acts(.init(own: dev, others: [released])))
    #expect(ActingCopy.acts(.init(own: released, others: [dev])))
    #expect(ActingCopy.acts(.init(own: dev, others: [old])))
    #expect(!ActingCopy.acts(.init(own: old, others: [dev])))
    #expect(ActingCopy.acts(.init(own: dev, others: [])))
  }
}

struct NativeProcessRecordsTests {
  @Test func elapsedMatchesPSFormat() {
    #expect(NativeProcessRecords.elapsed(5) == "00:05")
    #expect(NativeProcessRecords.elapsed(3_725) == "01:02:05")
    #expect(NativeProcessRecords.elapsed(2 * 86_400 + 3_725) == "2-01:02:05")
  }

  @Test func readsThisProcessWithoutStartingPS() throws {
    let child = try TestProcesses.start(.init(executable: "/bin/sleep", arguments: ["30"]))
    defer { child.stop() }
    let record = try #require(
      NativeProcessRecords.shared.read().first { $0.processID == child.processID })
    #expect(record.arguments == "/bin/sleep 30")
    #expect(record.parentProcessID == getpid())
    #expect(record.terminal == nil)
  }
}
