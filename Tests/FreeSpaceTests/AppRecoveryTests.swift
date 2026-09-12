import Darwin
import Foundation
import Testing

@testable import FreeSpace

struct AppRecoveryTests {
  private let app = MemoryApp(
    processID: 42, name: "ChatGPT", bundleIdentifier: "com.openai.chat",
    bundleURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"), memoryBytes: 100,
    protectionReason: "AI app and its workers stay running", isActive: true,
    launchDate: Date(timeIntervalSince1970: 100), childProcessCount: 3)

  private func process(_ state: Int32 = SSLEEP) -> RecoveryProcess {
    RecoveryProcess(
      processID: 42, owner: 501, startSeconds: 100, startMicroseconds: 20,
      state: UInt32(state))
  }

  private func observation(_ response: RecoveryResponse) -> RecoveryObservation {
    RecoveryObservation(process: process(), response: response)
  }

  private func descriptor(_ expected: MemoryApp) -> MemoryAppDescriptor {
    MemoryAppDescriptor(
      processID: expected.processID, name: expected.name,
      bundleIdentifier: expected.bundleIdentifier, bundleURL: expected.bundleURL,
      protectionReason: expected.protectionReason, isActive: expected.isActive,
      launchDate: expected.launchDate)
  }

  @Test func responsiveAppReceivesNoSignal() async {
    let driver = RecoveryTestDriver(
      .init(
        observations: [observation(.responding), observation(.noReply)], resumeError: false,
        failObservation: nil))
    let report = await AppRecoveryEngine(driver: driver).run(.init(app: app, attemptResume: true))
    #expect(report.outcome == .alreadyResponding)
    #expect(!report.resumeSent)
    #expect(await driver.resumes == 0)
  }

  @Test func recoveryRequiresTwoSuccessfulChecks() async {
    let driver = RecoveryTestDriver(
      .init(
        observations: [.noReply, .noReply, .responding, .responding].map(observation),
        resumeError: false, failObservation: nil))
    let report = await AppRecoveryEngine(driver: driver).run(.init(app: app, attemptResume: true))
    #expect(report.outcome == .respondingNow)
    #expect(report.before.count == 2)
    #expect(report.after.count == 2)
    #expect(await driver.resumes == 1)
  }

  @Test func oneReplyDoesNotClaimRecovery() async {
    let driver = RecoveryTestDriver(
      .init(
        observations: [.noReply, .noReply, .responding, .noReply].map(observation),
        resumeError: false, failObservation: nil))
    let report = await AppRecoveryEngine(driver: driver).run(.init(app: app, attemptResume: true))
    #expect(report.outcome == .unverified)
    #expect(await driver.resumes == 1)
  }

  @Test func permissionAndUnsupportedChecksNeverClaimRecovery() async {
    for response in [RecoveryResponse.permissionNeeded, .unsupported] {
      let driver = RecoveryTestDriver(
        .init(
          observations: Array(repeating: observation(response), count: 4),
          resumeError: false, failObservation: nil))
      let report = await AppRecoveryEngine(driver: driver).run(.init(app: app, attemptResume: true))
      #expect(report.outcome == .unverified)
      #expect(report.resumeSent)
      #expect(await driver.resumes == 1)
    }
  }

  @Test func checkOnlyNeverSignalsAnUnresponsiveApp() async {
    let driver = RecoveryTestDriver(
      .init(
        observations: [observation(.noReply), observation(.noReply)],
        resumeError: false, failObservation: nil))
    let report = await AppRecoveryEngine(driver: driver).run(.init(app: app, attemptResume: false))
    #expect(report.outcome == .checked)
    #expect(await driver.resumes == 0)
  }

  @Test func persistentHangDoesNotTriggerMoreSignals() async {
    let driver = RecoveryTestDriver(
      .init(
        observations: Array(repeating: observation(.noReply), count: 4),
        resumeError: false, failObservation: nil))
    let report = await AppRecoveryEngine(driver: driver).run(.init(app: app, attemptResume: true))
    #expect(report.outcome == .noReply)
    #expect(await driver.resumes == 1)
  }

  @Test func stoppedProcessResumingDoesNotClaimWindowRecovery() async {
    let stopped = RecoveryObservation(process: process(SSTOP), response: .noReply)
    let driver = RecoveryTestDriver(
      .init(
        observations: [
          stopped, stopped, observation(.permissionNeeded), observation(.permissionNeeded),
        ],
        resumeError: false, failObservation: nil))
    let report = await AppRecoveryEngine(driver: driver).run(.init(app: app, attemptResume: true))
    #expect(report.outcome == .resumed)
    #expect(await driver.resumes == 1)
  }

  @Test func refusedSignalDoesNotClaimItWasSent() async {
    let driver = RecoveryTestDriver(
      .init(
        observations: [observation(.noReply), observation(.noReply)],
        resumeError: true, failObservation: nil))
    let report = await AppRecoveryEngine(driver: driver).run(.init(app: app, attemptResume: true))
    #expect(report.outcome == .failed)
    #expect(!report.resumeSent)
    #expect(report.after.isEmpty)
  }

  @Test func disappearingOrChangedTargetStopsTheAttempt() async {
    for failingCheck in [0, 1, 2, 3] {
      let driver = RecoveryTestDriver(
        .init(
          observations: Array(repeating: observation(.noReply), count: 4),
          resumeError: false, failObservation: failingCheck))
      let report = await AppRecoveryEngine(driver: driver).run(.init(app: app, attemptResume: true))
      #expect(report.outcome == .failed)
      #expect(report.resumeSent == (failingCheck >= 2))
      #expect(await driver.resumes == (failingCheck >= 2 ? 1 : 0))
    }
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

  @Test func safetyRejectsSystemAppsAndSelf() {
    #expect(
      RecoverySafety.refusal(
        .init(
          expected: app, current: descriptor(app), process: process(), ownProcessID: 42,
          ownUserID: 501)) != nil)
    let system = MemoryApp(
      processID: 42, name: "System", bundleIdentifier: "com.apple.system",
      bundleURL: URL(fileURLWithPath: "/System/Applications/System.app"), memoryBytes: 100,
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

private actor RecoveryTestDriver: AppRecoveryDriver {
  struct Configuration: Sendable {
    let observations: [RecoveryObservation]
    let resumeError: Bool
    let failObservation: Int?
  }
  let configuration: Configuration
  private var index = 0
  private(set) var resumes = 0

  init(_ configuration: Configuration) { self.configuration = configuration }

  func resolve(_ app: MemoryApp) throws -> RecoveryTarget {
    RecoveryTarget(app: app, process: configuration.observations[0].process)
  }

  func observe(_ target: RecoveryTarget) throws -> RecoveryObservation {
    if index == configuration.failObservation {
      throw RecoveryFailure(message: "App exited or changed")
    }
    guard index < configuration.observations.count else {
      throw RecoveryFailure(message: "Unexpected extra check")
    }
    defer { index += 1 }
    return configuration.observations[index]
  }

  func resume(_ target: RecoveryTarget) throws {
    if configuration.resumeError { throw RecoveryFailure(message: "Permission denied") }
    resumes += 1
  }

  func pause() {}
}
