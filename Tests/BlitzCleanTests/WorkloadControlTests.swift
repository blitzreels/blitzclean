import Darwin
import Foundation
import Testing

@testable import BlitzClean

struct WorkloadControlTests {
  @Test func terminationFailureIsReportedWithoutAutomaticForceKill() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "trap '' TERM; sleep 30 & wait"]
    try process.run()
    defer {
      for pid in LiveProcessTree.read().descendants([process.processIdentifier]) {
        _ = kill(pid, SIGKILL)
      }
    }
    try await Task.sleep(for: .milliseconds(100))
    let identity = try #require(DevProcessIdentity.read(process.processIdentifier))
    let result = await WorkloadControl.execute(.init(identities: [identity], signal: .quit))
    #expect(!result.completed)
    #expect(result.remaining >= 1)
    #expect(process.isRunning)
    let forced = await WorkloadControl.execute(
      .init(identities: result.identities, signal: .forceQuit))
    #expect(forced.completed)
  }

  @Test func nativeInventoryDoesNotNeedTheDashboardOrExternalCommands() {
    let started = Date.now
    let inventory = EmergencyInventory.read()
    #expect(Date.now.timeIntervalSince(started) < 3)
    #expect(inventory.allSatisfy { !$0.identities.isEmpty })
    #expect(!inventory.flatMap(\.identities).contains { $0.process.processID == getpid() })
  }

  @Test func pauseIncludesChildrenCreatedAfterTheOriginalSnapshot() async throws {
    let parent = Process()
    parent.executableURL = URL(fileURLWithPath: "/bin/sh")
    parent.arguments = ["-c", "sleep 30 & wait"]
    try parent.run()
    defer {
      for pid in LiveProcessTree.read().descendants([parent.processIdentifier]) {
        _ = kill(pid, SIGCONT)
        _ = kill(pid, SIGTERM)
      }
    }
    try await Task.sleep(for: .milliseconds(100))
    let identity = try #require(DevProcessIdentity.read(parent.processIdentifier))
    let paused = await WorkloadControl.execute(.init(identities: [identity], signal: .pause))
    #expect(paused.completed)
    #expect(paused.affected >= 2)
    #expect(
      paused.identities.allSatisfy {
        DevProcessIdentity.read($0.process.processID)?.process.stopped == true
      })
    let stopped = await WorkloadControl.execute(.init(identities: paused.identities, signal: .quit))
    #expect(stopped.completed)
    #expect(stopped.retainedBytes == 0)
  }

  @Test func changedIdentityDoesNotClaimItsChildren() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer { if child.isRunning { child.terminate() } }
    let identity = try #require(DevProcessIdentity.read(child.processIdentifier))
    let changed = DevProcessIdentity(process: identity.process, executable: "/changed")
    let result = await WorkloadControl.execute(.init(identities: [changed], signal: .pause))
    #expect(result.affected == 0)
    #expect(DevProcessIdentity.read(child.processIdentifier)?.process.stopped == false)
  }
}
