import Darwin
import Foundation
import Testing

@testable import BlitzClean

struct AppForceQuitTests {
  @Test func builtInAppsRemainProtectedWhenTheyBecomeVisibleInRecovery() async {
    let mail = MemoryApp(
      processID: 42, name: "Mail", bundleIdentifier: "com.apple.mail",
      bundleURL: URL(fileURLWithPath: "/System/Applications/Mail.app"), memoryBytes: 100,
      protectionReason: "macOS system app", isActive: false,
      launchDate: Date(timeIntervalSince1970: 100), childProcessCount: 0)
    let driver = ForceQuitTestDriver(.init(exitsAfter: 0, forceError: false, resolveError: false))
    let report = await ForceQuitEngine(driver: driver).run(mail)
    #expect(report.outcome == .failed)
    #expect(!report.requestSent)
    #expect(await driver.forceCalls == 0)
  }

  private let app = MemoryApp(
    processID: 42, name: "Fixture", bundleIdentifier: "com.example.fixture",
    bundleURL: URL(fileURLWithPath: "/Applications/Fixture.app"), memoryBytes: 100,
    protectionReason: nil, isActive: false,
    launchDate: Date(timeIntervalSince1970: 100), childProcessCount: 0)

  @Test func confirmsExitAfterForceQuit() async {
    let driver = ForceQuitTestDriver(.init(exitsAfter: 2, forceError: false, resolveError: false))
    let report = await ForceQuitEngine(driver: driver).run(app)
    #expect(report.outcome == .terminated)
    #expect(report.requestSent)
    #expect(await driver.forceCalls == 1)
  }

  @Test func doesNotClaimExitWhenTargetKeepsRunning() async {
    let driver = ForceQuitTestDriver(.init(exitsAfter: nil, forceError: false, resolveError: false))
    let report = await ForceQuitEngine(driver: driver).run(app)
    #expect(report.outcome == .stillRunning)
    #expect(report.requestSent)
    #expect(await driver.forceCalls == 1)
  }

  @Test func refusedOrChangedTargetIsNeverReportedAsForceQuit() async {
    for configuration in [
      ForceQuitTestDriver.Configuration(exitsAfter: nil, forceError: true, resolveError: false),
      .init(exitsAfter: nil, forceError: false, resolveError: true),
    ] {
      let driver = ForceQuitTestDriver(configuration)
      let report = await ForceQuitEngine(driver: driver).run(app)
      #expect(report.outcome == .failed)
      #expect(!report.requestSent)
    }
  }
}

private actor ForceQuitTestDriver: ForceQuitDriver {
  struct Configuration: Sendable {
    let exitsAfter: Int?
    let forceError: Bool
    let resolveError: Bool
  }

  let configuration: Configuration
  private var polls = 0
  private(set) var forceCalls = 0

  init(_ configuration: Configuration) { self.configuration = configuration }

  func resolve(_ app: MemoryApp) throws -> RecoveryTarget {
    if configuration.resolveError { throw RecoveryFailure(message: "Target changed") }
    return RecoveryTarget(
      app: app,
      process: RecoveryProcess(
        processID: app.processID, owner: 501, startSeconds: 100,
        startMicroseconds: 0, state: UInt32(SSLEEP)))
  }

  func forceQuit(_ target: RecoveryTarget) throws {
    if configuration.forceError { throw RecoveryFailure(message: "Request refused") }
    forceCalls += 1
  }

  func isTerminated(_ target: RecoveryTarget) -> Bool {
    polls += 1
    return configuration.exitsAfter.map { polls >= $0 } ?? false
  }

  func pause() {}
}
