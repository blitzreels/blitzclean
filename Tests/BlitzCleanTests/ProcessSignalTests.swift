import Darwin
import Foundation
import Testing

@testable import BlitzClean

struct ProcessSignalTests {
  @Test
  func refusesLaunchdAndItself() throws {
    let own = try #require(DevProcessIdentity.read(getpid()))
    #expect(ProcessSignal.send(.init(expected: own, signal: SIGCONT)) == .refused)
    let launchd = DevProcessIdentity(
      process: .init(processID: 1, owner: 0, startSeconds: 0, startMicroseconds: 0, state: 0),
      executable: "/sbin/launchd")
    #expect(ProcessSignal.send(.init(expected: launchd, signal: SIGTERM)) == .refused)
  }

  @Test
  func resumesStoppedProcessesSoTheyCanQuit() throws {
    let sleep = try TestProcesses.start(.init(executable: "/bin/sleep", arguments: ["30"]))
    defer { sleep.stop() }
    let child = try #require(sleep.process)
    let identity = try #require(DevProcessIdentity.read(child.processIdentifier))
    #expect(ProcessSignal.send(.init(expected: identity, signal: SIGSTOP)).wasSent)
    try #require(
      eventuallyBlocking {
        DevProcessIdentity.read(child.processIdentifier)?.process.stopped == true
      })
    #expect(ProcessSignal.send(.init(expected: identity, signal: SIGTERM)).wasSent)
    child.waitUntilExit()
    #expect(child.terminationStatus == SIGTERM)
  }

  @Test
  func reportsExitedProcessesAsChanged() throws {
    let finished = try TestProcesses.start(.init(executable: "/usr/bin/true", arguments: []))
    defer { finished.stop() }
    let child = try #require(finished.process)
    let identity = DevProcessIdentity(
      process: .init(
        processID: child.processIdentifier, owner: getuid(), startSeconds: 1,
        startMicroseconds: 0, state: 0),
      executable: "/usr/bin/true")
    child.waitUntilExit()
    #expect(ProcessSignal.send(.init(expected: identity, signal: SIGTERM)) == .changed)
  }
}
