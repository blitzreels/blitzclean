import Foundation
import Testing

@testable import BlitzClean

struct ProjectProcessTests {
  @Test
  func joinsWorkingDirectoriesWithListeningPorts() throws {
    let processes = try #require(
      ProjectProcessParser.processes(
        ProcessInspectionOutput(
          workingDirectories: """
            p4776
            cnode
            fcwd
            n/Users/me/dev/project
            p9012
            cvite
            fcwd
            n/Users/me/dev/other
            """,
          listeningPorts: """
            p4776
            cnode
            f19
            n*:3333
            f20
            n127.0.0.1:61078
            p9012
            cvite
            f21
            n[::1]:5173
            """,
          processParents: """
            4776 1
            9012 400
            """,
          identify: { _ in nil }
        )
      ))

    #expect(processes.count == 2)
    #expect(processes[0].name == "node")
    #expect(processes[0].parentProcessID == 1)
    #expect(processes[0].listeningPorts == [3333, 61078])
    #expect(processes[1].listeningPorts == [5173])
  }

  @Test
  func refusesProcessesWithoutScannedIdentity() {
    let result = ProjectProcessController().stop(
      .init(processes: [process(identity: nil)]))
    #expect(result.signaledCount == 0)
    #expect(result.changedCount == 1)
  }

  @Test
  func refusesReusedProcessIDs() throws {
    let child = try TestProcesses.start(.init(executable: "/bin/sleep", arguments: ["30"]))
    defer { child.stop() }
    let live = try #require(DevProcessIdentity.read(child.processID))
    let earlier = DevProcessIdentity(
      process: .init(
        processID: live.process.processID, owner: live.process.owner,
        startSeconds: live.process.startSeconds - 60,
        startMicroseconds: live.process.startMicroseconds, state: live.process.state),
      executable: live.executable)
    let result = ProjectProcessController().stop(.init(processes: [process(identity: earlier)]))
    #expect(result.signaledCount == 0)
    #expect(result.changedCount == 1)
    #expect(child.isRunning)
  }

  @Test
  func stopsTheScannedInstance() throws {
    let sleep = try TestProcesses.start(.init(executable: "/bin/sleep", arguments: ["30"]))
    defer { sleep.stop() }
    let child = try #require(sleep.process)
    let identity = try #require(DevProcessIdentity.read(child.processIdentifier))
    let result = ProjectProcessController().stop(.init(processes: [process(identity: identity)]))
    child.waitUntilExit()
    #expect(result.signaledCount == 1)
    #expect(child.terminationReason == .uncaughtSignal)
  }

  @Test
  func explainsChangedProcesses() {
    let text = ProjectProcessStopMessage.text(
      .init(signaledCount: 1, failureCount: 0, changedCount: 2))
    #expect(text.contains("2 already exited or changed"))
  }

  private func process(identity: DevProcessIdentity?) -> ProjectProcessInfo {
    .init(
      processID: identity?.process.processID ?? 99_999, parentProcessID: 1, name: "sleep",
      workingDirectory: "/nonexistent-blitzclean-test", listeningPorts: [], identity: identity)
  }
}
