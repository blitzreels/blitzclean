import AppKit
import Darwin
import Testing

@testable import BlitzClean

/// Exercises the native driver against a real app when `BLITZCLEAN_LIVE_REVIVE` names its bundle ID.
/// The app must abort on SIGCONT while `/tmp/revive-probe-crash-on-resume` exists.
@MainActor
struct LiveReviveTests {
  @Test func stoppedAppIsRevivedAndACrashIsReported() async throws {
    guard let identifier = ProcessInfo.processInfo.environment["BLITZCLEAN_LIVE_REVIVE"] else {
      return
    }
    let flag = "/tmp/revive-probe-crash-on-resume"
    unlink(flag)
    let engine = AppRecoveryEngine(driver: NativeAppRecoveryDriver())

    let app = try #require(runningApp(identifier))
    #expect(kill(app.processID, SIGSTOP) == 0)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await engine.check(app) == .stopped)
    let revived = await engine.revive(app)
    #expect(revived.outcome == .revived)
    #expect(await engine.check(app) != .stopped)

    #expect(creat(flag, 0o644) >= 0)
    defer { unlink(flag) }
    #expect(kill(app.processID, SIGSTOP) == 0)
    try await Task.sleep(for: .milliseconds(200))
    let crashed = await engine.revive(app)
    #expect(crashed.outcome == .crashed)
    #expect(crashed.resumeSent)
    #expect(crashed.crashReport?.pathExtension == "ips")
  }

  private func runningApp(_ identifier: String) -> MemoryApp? {
    MemoryAppProvider().descriptors().first { $0.bundleIdentifier == identifier }.map {
      MemoryApp(
        processID: $0.processID, name: $0.name, bundleIdentifier: $0.bundleIdentifier,
        bundleURL: $0.bundleURL, memoryBytes: 0, protectionReason: $0.protectionReason,
        isActive: $0.isActive, launchDate: $0.launchDate, childProcessCount: 0)
    }
  }
}
