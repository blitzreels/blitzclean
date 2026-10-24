import Darwin
import Foundation
import Testing

@testable import BlitzClean

struct WorkloadControlTests {
  @Test func terminationFailureIsReportedWithoutAutomaticForceKill() async throws {
    let shell = try TestProcesses.start(
      .init(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 30 & wait"]))
    defer { shell.stop() }
    #expect(await eventually { LiveProcessTree.read().descendants([shell.processID]).count > 1 })
    let identity = try #require(DevProcessIdentity.read(shell.processID))
    let result = await WorkloadControl.execute(.init(identities: [identity], signal: .quit))
    #expect(!result.completed)
    #expect(result.remaining >= 1)
    #expect(shell.isRunning)
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
    let parent = try TestProcesses.start(
      .init(executable: "/bin/sh", arguments: ["-c", "sleep 30 & wait"]))
    defer { parent.stop() }
    #expect(await eventually { LiveProcessTree.read().descendants([parent.processID]).count > 1 })
    let identity = try #require(DevProcessIdentity.read(parent.processID))
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
    let child = try TestProcesses.start(.init(executable: "/bin/sleep", arguments: ["30"]))
    defer { child.stop() }
    let identity = try #require(DevProcessIdentity.read(child.processID))
    let changed = DevProcessIdentity(process: identity.process, executable: "/changed")
    let result = await WorkloadControl.execute(.init(identities: [changed], signal: .pause))
    #expect(result.affected == 0)
    #expect(DevProcessIdentity.read(child.processID)?.process.stopped == false)
  }
}
