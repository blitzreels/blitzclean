import Darwin
import Foundation
import Testing

@testable import BlitzClean

@MainActor
struct AppRecoveryRefreshTests {
  private var app: MemoryApp {
    MemoryApp(
      processID: 42, name: "Recovery fixture", bundleIdentifier: "test.recovery",
      bundleURL: URL(fileURLWithPath: "/Applications/Recovery fixture.app"), memoryBytes: 100,
      protectionReason: nil, isActive: false, launchDate: Date(timeIntervalSince1970: 100),
      childProcessCount: 0)
  }

  @Test func cachedHealthyAppIsCheckedAgain() async throws {
    let driver = RefreshRecoveryDriver()
    let model = AppRecoveryModel(
      driver: driver, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    await model.scan([app])
    #expect(model.check(for: app)?.health == .responsive)
    await driver.set(.unresponsive)
    try await Task.sleep(for: .milliseconds(2_100))
    await model.scan([app])
    #expect(model.check(for: app)?.health == .unresponsive)
  }

  @Test func aFreshStoppedStateOverridesAnEarlierRevive() async throws {
    let driver = RefreshRecoveryDriver()
    await driver.set(.stopped)
    let model = AppRecoveryModel(
      driver: driver, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let report = try #require(await model.revive(app))
    #expect(report.outcome == .revived)
    await driver.set(.stopped)
    await model.noteProcessStates([app])
    #expect(model.check(for: app)?.health == .stopped)
    #expect(model.attentionCount == 1)
    #expect(model.result(for: app)?.outcome != .revived)
  }

  @Test func resumedElsewhereStopsShowingStopped() async {
    let driver = RefreshRecoveryDriver()
    await driver.set(.stopped)
    let model = AppRecoveryModel(
      driver: driver, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    await model.noteProcessStates([app])
    #expect(model.attentionCount == 1)
    await driver.set(.responsive)
    await model.noteProcessStates([app])
    #expect(model.check(for: app)?.health != .stopped)
    #expect(model.attentionCount == 0)
  }
  @Test func aNewStopCanBeRevivedImmediately() async throws {
    let driver = RefreshRecoveryDriver()
    let model = AppRecoveryModel(
      driver: driver, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    await driver.set(.stopped)
    _ = await model.revive(app)
    await driver.set(.stopped)
    await model.noteProcessStates([app])
    let retry = try #require(await model.revive(app))
    #expect(retry.outcome == .revived)
  }

  @Test func appRosterDoesNotWaitForMemoryMeasurements() {
    let fresh = MemoryAppDescriptor(
      processID: 43, name: "New app", bundleIdentifier: "test.new",
      bundleURL: URL(fileURLWithPath: "/Applications/New.app"), protectionReason: nil,
      isActive: true, launchDate: .now)
    let roster = RecoveryAppRoster.merge(.init(descriptors: [fresh], measured: [app]))
    #expect(roster.map(\.processID) == [43])
    #expect(roster.first?.memoryBytes == 0)
  }

  @Test func restartedAppDoesNotInheritOldMemoryMeasurements() {
    let restarted = MemoryAppDescriptor(
      processID: app.processID, name: app.name, bundleIdentifier: app.bundleIdentifier,
      bundleURL: app.bundleURL, protectionReason: nil, isActive: true, launchDate: .now)
    let roster = RecoveryAppRoster.merge(.init(descriptors: [restarted], measured: [app]))
    #expect(roster.first?.memoryBytes == 0)
    #expect(roster.first?.launchDate == restarted.launchDate)
  }

  @Test func forcedRefreshQueuedDuringACheckIsNotLost() async throws {
    let driver = RefreshRecoveryDriver()
    await driver.delayChecks()
    let model = AppRecoveryModel(
      driver: driver, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let first = Task { await model.scan([app]) }
    for _ in 0..<100 {
      if await driver.observations > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    await driver.set(.unresponsive)
    await model.scan([app], force: true)
    await first.value
    for _ in 0..<100 where model.check(for: app)?.health != .unresponsive {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.check(for: app)?.health == .unresponsive)
  }

}

private actor RefreshRecoveryDriver: AppRecoveryDriver {
  var health = RecoveryHealth.responsive
  var observations = 0
  private var delays = false
  func delayChecks() { delays = true }
  func set(_ health: RecoveryHealth) { self.health = health }
  func resolve(_ app: MemoryApp) -> RecoveryTarget {
    RecoveryTarget(app: app, process: process())
  }
  func observe(_ target: RecoveryTarget) async throws -> RecoveryObservation {
    let observation = RecoveryObservation(
      process: process(), response: health == .responsive ? .responding : .noReply)
    observations += 1
    if delays { try await Task.sleep(for: .milliseconds(100)) }
    return observation
  }
  func resume(_ target: RecoveryTarget) { health = .responsive }
  func pause(_ duration: Duration) {}
  func crashReport(for app: MemoryApp, since: Date) -> URL? { nil }
  private func process() -> RecoveryProcess {
    RecoveryProcess(
      processID: 42, owner: 501, startSeconds: 100, startMicroseconds: 0,
      state: UInt32(health == .stopped ? SSTOP : SSLEEP))
  }
}
