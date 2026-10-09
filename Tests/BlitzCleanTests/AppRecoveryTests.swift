import Darwin
import Foundation
import Testing

@testable import BlitzClean

struct AppRecoveryTests {
  private let app = MemoryApp(
    processID: 42, name: "ChatGPT", bundleIdentifier: "com.openai.chat",
    bundleURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"), memoryBytes: 100,
    protectionReason: "AI app and its workers stay running", isActive: true,
    launchDate: Date(timeIntervalSince1970: 100), childProcessCount: 3)

  private func process(_ state: Int32 = SSLEEP, id: Int32 = 42) -> RecoveryProcess {
    RecoveryProcess(
      processID: id, owner: 501, startSeconds: 100, startMicroseconds: 20,
      state: UInt32(state))
  }

  private func running(_ response: RecoveryResponse) -> RecoveryStep {
    .observe(RecoveryObservation(process: process(), response: response))
  }

  private var stopped: RecoveryStep {
    .observe(RecoveryObservation(process: process(SSTOP), response: .noReply))
  }

  private func descriptor(_ expected: MemoryApp) -> MemoryAppDescriptor {
    MemoryAppDescriptor(
      processID: expected.processID, name: expected.name,
      bundleIdentifier: expected.bundleIdentifier, bundleURL: expected.bundleURL,
      protectionReason: expected.protectionReason, isActive: expected.isActive,
      launchDate: expected.launchDate)
  }

  private func engine(_ driver: any AppRecoveryDriver) -> AppRecoveryEngine {
    AppRecoveryEngine(driver: driver, crashReportWaits: 1)
  }

  @Test func respondingAppReceivesNoSignal() async {
    let driver = ScriptedRecoveryDriver([42: [running(.responding)]])
    let report = await engine(driver).revive(app)
    #expect(report.outcome == .alreadyRunning)
    #expect(!report.resumeSent)
    #expect(await driver.resumedIDs.isEmpty)
  }

  @Test func healthDistinguishesStoppedFrozenAndRunning() {
    let observe = { (state: Int32, response: RecoveryResponse) in
      RecoveryObservation(process: process(state), response: response)
    }
    #expect(RecoveryHealth.assess([observe(SSTOP, .permissionNeeded)]) == .stopped)
    #expect(RecoveryHealth.assess([observe(SSLEEP, .noReply)]) == .unknown)
    #expect(
      RecoveryHealth.assess([observe(SSLEEP, .noReply), observe(SSLEEP, .noReply)])
        == .unresponsive)
    #expect(RecoveryHealth.assess([observe(SSLEEP, .responding)]) == .responsive)
    #expect(RecoveryHealth.assess([observe(SSLEEP, .permissionNeeded)]) == .running)
    #expect(RecoveryHealth.assess([observe(SZOMB, .noReply)]) == .exited)
  }

  @Test func stoppedAppIsRevivedWhenItsWindowResponds() async {
    let driver = ScriptedRecoveryDriver([42: [stopped, running(.responding)]])
    let report = await engine(driver).revive(app)
    #expect(report.outcome == .revived)
    #expect(report.resumeSent)
    #expect(report.after.count == 1)
    #expect(await driver.resumedIDs == [42])
  }

  @Test func revivedWithoutAccessibilityOnceTheProcessKeepsRunning() async {
    for response in [RecoveryResponse.permissionNeeded, .unsupported] {
      let driver = ScriptedRecoveryDriver([42: [stopped, running(response)]])
      let report = await engine(driver).revive(app)
      #expect(report.outcome == .revived)
      #expect(report.after.count == 1)
      #expect(await driver.resumedIDs == [42])
    }
  }

  @Test func frozenWindowIsReportedAfterOneSignal() async {
    let driver = ScriptedRecoveryDriver([42: [running(.noReply)]])
    let report = await engine(driver).revive(app)
    #expect(report.outcome == .notResponding)
    #expect(report.resumeSent)
    #expect(await driver.resumedIDs == [42])
  }

  @Test func runningWithoutWindowPermissionIsNotCalledRevived() async {
    let driver = ScriptedRecoveryDriver([42: [running(.permissionNeeded)]])
    let report = await engine(driver).revive(app)
    #expect(report.outcome == .alreadyRunning)
    #expect(report.after.count == 1)
  }

  @Test func processStoppedAgainIsReported() async {
    let driver = ScriptedRecoveryDriver([42: [stopped]])
    let report = await engine(driver).revive(app)
    #expect(report.outcome == .stillStopped)
    #expect(await driver.resumedIDs == [42])
  }

  @Test func crashAfterResumeLinksTheCrashReport() async {
    let crash = URL(fileURLWithPath: "/tmp/ChatGPT-2026.ips")
    let driver = ScriptedRecoveryDriver([42: [stopped, .exit]], crash: crash)
    let report = await engine(driver).revive(app)
    #expect(report.outcome == .crashed)
    #expect(report.crashReport == crash)
    #expect(report.resumeSent)
  }

  @Test func exitWithoutCrashReportIsAQuit() async {
    let driver = ScriptedRecoveryDriver([42: [stopped, .exit]])
    let report = await engine(driver).revive(app)
    #expect(report.outcome == .quit)
    #expect(report.crashReport == nil)
  }

  @Test func appThatAlreadyExitedGetsNoSignal() async {
    let driver = ScriptedRecoveryDriver([42: [.exit]])
    let report = await engine(driver).revive(app)
    #expect(report.outcome == .quit)
    #expect(!report.resumeSent)
    #expect(await driver.resumedIDs.isEmpty)
  }

  @Test func refusedSignalDoesNotClaimItWasSent() async {
    let driver = ScriptedRecoveryDriver([42: [stopped]], refusesResume: true)
    let report = await engine(driver).revive(app)
    #expect(report.outcome == .failed)
    #expect(!report.resumeSent)
    #expect(report.after.isEmpty)
  }

  @Test func checkReadsStoppedStateWithoutWindowChecks() async {
    let driver = ScriptedRecoveryDriver([42: [stopped]])
    #expect(await engine(driver).check(app) == .stopped)
    #expect(await driver.observations == 0)
  }

  @Test func checkConfirmsAFrozenWindowTwice() async {
    let frozen = ScriptedRecoveryDriver([42: [running(.noReply)]])
    #expect(await engine(frozen).check(app) == .unresponsive)
    #expect(await frozen.observations == 2)
    let healthy = ScriptedRecoveryDriver([42: [running(.responding)]])
    #expect(await engine(healthy).check(app) == .responsive)
    #expect(await healthy.observations == 1)
  }

  @MainActor
  @Test func scanAndBulkReviveOnlyTargetStoppedApps() async throws {
    let hung = MemoryApp(
      processID: 43, name: "Hung", bundleIdentifier: "com.example.hung",
      bundleURL: URL(fileURLWithPath: "/Applications/Hung.app"), memoryBytes: 50,
      protectionReason: nil, isActive: false,
      launchDate: Date(timeIntervalSince1970: 200), childProcessCount: 0)
    let driver = ScriptedRecoveryDriver([
      42: [stopped, stopped, running(.responding)],
      43: [.observe(RecoveryObservation(process: process(id: 43), response: .noReply))],
    ])
    let defaults = try #require(UserDefaults(suiteName: "recovery-tests-\(UUID())"))
    let model = AppRecoveryModel(driver: driver, defaults: defaults)
    await model.scan([app, hung])
    #expect(model.check(for: app)?.health == .stopped)
    #expect(model.check(for: hung)?.health == .unresponsive)
    #expect(model.attentionCount == 2)
    #expect(!model.isScanning)
    #expect(model.scannedCount == 2)
    let restarted = MemoryApp(
      processID: app.processID, name: app.name, bundleIdentifier: app.bundleIdentifier,
      bundleURL: app.bundleURL, memoryBytes: app.memoryBytes,
      protectionReason: app.protectionReason, isActive: app.isActive,
      launchDate: Date(timeIntervalSince1970: 101), childProcessCount: app.childProcessCount)
    #expect(model.check(for: restarted) == nil)
    let reports = await model.reviveAll([app])
    #expect(reports.map(\.outcome) == [.revived])
    #expect(model.result(for: app)?.outcome == .revived)
    #expect(model.check(for: app)?.health == .responsive)
    #expect(model.check(for: hung)?.health == .unresponsive)
    #expect(await driver.resumedIDs == [42])
  }

  @MainActor
  @Test func stoppedAppRevivesWhileOtherAppsAreStillBeingChecked() async throws {
    let slow = MemoryApp(
      processID: 43, name: "Slow", bundleIdentifier: "com.example.slow",
      bundleURL: URL(fileURLWithPath: "/Applications/Slow.app"), memoryBytes: 50,
      protectionReason: nil, isActive: false,
      launchDate: Date(timeIntervalSince1970: 200), childProcessCount: 0)
    let driver = ScriptedRecoveryDriver(
      [
        42: [stopped, running(.responding)],
        43: [.observe(RecoveryObservation(process: process(id: 43), response: .noReply))],
      ], slowIDs: [43])
    let defaults = try #require(UserDefaults(suiteName: "recovery-tests-\(UUID())"))
    let model = AppRecoveryModel(driver: driver, defaults: defaults)
    let scan = Task { await model.scan([app, slow]) }
    for _ in 0..<100 where model.check(for: app)?.health != .stopped {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.check(for: app)?.health == .stopped)
    #expect(model.isScanning)
    #expect(model.activity(for: slow) == .checking)
    let report = try #require(await model.revive(app))
    #expect(report.outcome == .revived)
    #expect(model.isScanning)
    await scan.value
    #expect(model.check(for: slow)?.health == .unresponsive)
  }

  @Test func historyShowsRecoveryResultsWithoutSignalWording() {
    let legacy = MemoryIncident(
      id: UUID(), date: .now, kind: "app-recovery",
      detail:
        "ChatGPT: Resume sent · check the app. One resume request sent. One resume request was sent.",
      sample: nil, apps: [], resources: nil)
    #expect(legacy.displayTitle == "ChatGPT · Revived")
    let current = MemoryIncident(
      id: UUID(), date: .now, kind: "app-recovery",
      detail: "Discord: Not responding. It's running, but its window hasn't responded.",
      sample: nil, apps: [], resources: nil)
    #expect(current.displayTitle == "Discord · Not responding")
  }

  @MainActor
  @Test func crashedAppMovesToTheCrashList() async throws {
    let crash = URL(fileURLWithPath: "/tmp/ChatGPT-2026.ips")
    let driver = ScriptedRecoveryDriver([42: [stopped, .exit]], crash: crash)
    let defaults = try #require(UserDefaults(suiteName: "recovery-tests-\(UUID())"))
    let model = AppRecoveryModel(driver: driver, defaults: defaults)
    let report = try #require(await model.revive(app))
    #expect(report.outcome == .crashed)
    #expect(model.crashes.map(\.report) == [crash])
    #expect(model.check(for: app) == nil)
    #expect(model.activity(for: app) == nil)
    model.dismiss(try #require(model.crashes.first))
    #expect(model.crashes.isEmpty)
  }

  @Test func crashReportHeaderIsParsed() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("crash-tests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let crash = directory.appendingPathComponent("ChatGPT-2026-09-29-120000.ips")
    try Data(
      #"{"app_name":"ChatGPT","bundleID":"com.openai.chat","bug_type":"309","name":"ChatGPT"}"#
        .utf8 + Data("\n{\"body\":1}".utf8)
    ).write(to: crash)
    let fault = directory.appendingPathComponent("ExcUserFault_agent.ips")
    try Data(#"{"app_name":"agent","bug_type":"385"}"#.utf8).write(to: fault)
    let reports = CrashReports.recent(since: .distantPast, in: directory)
    #expect(reports.map(\.url.lastPathComponent) == [crash.lastPathComponent])
    let report = try #require(reports.first)
    #expect(report.matches(bundleIdentifier: "com.openai.chat", names: []))
    #expect(!report.matches(bundleIdentifier: "com.example.other", names: ["ChatGPT"]))
    #expect(CrashReports.recent(since: .now.addingTimeInterval(60), in: directory).isEmpty)
  }

  @Test func safetyAllowsProtectedForegroundAIApps() {
    #expect(
      RecoverySafety.refusal(
        .init(
          expected: app, current: descriptor(app), process: process(), ownProcessID: 100,
          ownUserID: 501)) == nil)
  }

  @Test func safetyRejectsExitedForeignAndReusedProcesses() {
    #expect(
      RecoverySafety.refusal(
        .init(
          expected: app, current: nil, process: nil, ownProcessID: 100, ownUserID: 501)) != nil)
    #expect(
      RecoverySafety.refusal(
        .init(
          expected: app, current: descriptor(app), process: process(SZOMB), ownProcessID: 100,
          ownUserID: 501)) != nil)
    #expect(
      RecoverySafety.refusal(
        .init(
          expected: app, current: descriptor(app), process: process(), ownProcessID: 100,
          ownUserID: 502)) != nil)
    let restarted = MemoryAppDescriptor(
      processID: app.processID, name: app.name, bundleIdentifier: app.bundleIdentifier,
      bundleURL: app.bundleURL, protectionReason: app.protectionReason, isActive: true,
      launchDate: Date(timeIntervalSince1970: 101))
    #expect(
      RecoverySafety.refusal(
        .init(
          expected: app, current: restarted, process: process(), ownProcessID: 100,
          ownUserID: 501)) != nil)
    #expect(
      !process().isSameInstance(
        RecoveryProcess(
          processID: 42, owner: 501, startSeconds: 100, startMicroseconds: 21, state: UInt32(SSLEEP)
        )))
  }

  @Test func safetyRejectsCoreServicesAndSelf() {
    #expect(
      RecoverySafety.refusal(
        .init(
          expected: app, current: descriptor(app), process: process(), ownProcessID: 42,
          ownUserID: 501)) != nil)
    let system = MemoryApp(
      processID: 42, name: "System", bundleIdentifier: "com.apple.system",
      bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/System.app"), memoryBytes: 100,
      protectionReason: nil, isActive: false, launchDate: app.launchDate, childProcessCount: 0)
    #expect(
      RecoverySafety.refusal(
        .init(
          expected: system, current: descriptor(system), process: process(), ownProcessID: 100,
          ownUserID: 501)) != nil)
  }

  @Test func nativeIdentityMatchesTheCurrentProcess() throws {
    let native = try #require(NativeAppRecoveryDriver.readProcess(getpid()))
    #expect(native.processID == getpid())
    #expect(native.owner == geteuid())
    #expect(native.startSeconds > 0)
    #expect(!native.exited)
    #expect(NativeAppRecoveryDriver.readProcess(0) == nil)
    #expect(NativeAppRecoveryDriver.readProcess(-1) == nil)
  }
}

enum RecoveryStep: Sendable {
  case observe(RecoveryObservation)
  case exit
}

/// The first step is the app's state until it is resumed. After a resume, observations
/// walk the remaining steps and repeat the last one.
private actor ScriptedRecoveryDriver: AppRecoveryDriver {
  private let steps: [Int32: [RecoveryStep]]
  private let crash: URL?
  private let refusesResume: Bool
  private let slowIDs: Set<Int32>
  private var afterResume: [Int32: Int] = [:]
  private(set) var resumedIDs: [Int32] = []
  private(set) var observations = 0

  init(
    _ steps: [Int32: [RecoveryStep]], crash: URL? = nil, refusesResume: Bool = false,
    slowIDs: Set<Int32> = []
  ) {
    self.steps = steps
    self.crash = crash
    self.refusesResume = refusesResume
    self.slowIDs = slowIDs
  }

  private func current(_ id: Int32) throws -> RecoveryObservation {
    guard let script = steps[id], !script.isEmpty else {
      throw RecoveryFailure(message: "Missing fixture")
    }
    var index = 0
    if let next = afterResume[id] {
      index = min(next, script.count - 1)
      afterResume[id] = next + 1
    }
    switch script[index] {
    case .observe(let observation): return observation
    case .exit: throw RecoveryExit()
    }
  }

  func resolve(_ app: MemoryApp) throws -> RecoveryTarget {
    guard case .observe(let observation)? = steps[app.processID]?.first else {
      throw steps[app.processID] == nil
        ? RecoveryFailure(message: "Missing fixture") : RecoveryExit()
    }
    return RecoveryTarget(app: app, process: observation.process)
  }

  func observe(_ target: RecoveryTarget) async throws -> RecoveryObservation {
    observations += 1
    if slowIDs.contains(target.app.processID) { try await Task.sleep(for: .milliseconds(400)) }
    return try current(target.app.processID)
  }

  func resume(_ target: RecoveryTarget) throws {
    if refusesResume { throw RecoveryFailure(message: "Permission denied") }
    resumedIDs.append(target.app.processID)
    afterResume[target.app.processID] = 1
  }

  func pause(_ duration: Duration) {}

  func crashReport(for app: MemoryApp, since: Date) -> URL? { crash }
}
