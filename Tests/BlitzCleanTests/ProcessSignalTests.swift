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
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
    let identity = try #require(DevProcessIdentity.read(child.processIdentifier))
    #expect(ProcessSignal.send(.init(expected: identity, signal: SIGSTOP)).wasSent)
    var stopped = false
    for _ in 0..<50 where !stopped {
      stopped = DevProcessIdentity.read(child.processIdentifier)?.process.stopped == true
      if !stopped { usleep(20_000) }
    }
    try #require(stopped)
    #expect(ProcessSignal.send(.init(expected: identity, signal: SIGTERM)).wasSent)
    child.waitUntilExit()
    #expect(child.terminationStatus == SIGTERM)
  }

  @Test
  func reportsExitedProcessesAsChanged() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try child.run()
    let identity = DevProcessIdentity(
      process: .init(
        processID: child.processIdentifier, owner: getuid(), startSeconds: 1,
        startMicroseconds: 0, state: 0),
      executable: "/usr/bin/true")
    child.waitUntilExit()
    #expect(ProcessSignal.send(.init(expected: identity, signal: SIGTERM)) == .changed)
  }
}
