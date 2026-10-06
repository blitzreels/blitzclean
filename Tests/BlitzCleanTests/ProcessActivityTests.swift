import AppKit
import Darwin
import SwiftUI
import Testing

@testable import BlitzClean

struct ProcessActivityTests {
  @Test
  func ranksBuildWorkersAndSystemProcessesAndKeepsAppNames() {
    let records = RawProcessParser.records(
      "10 1 501 0 100 01:00 ?? node\n"
        + "11 10 501 240 100 00:10 ?? next-build (v16.3.3)\n"
        + "12 1 88 140 100 01:00 ?? /System/Library/WindowServer\n"
        + "13 1 501 10 100 01:00 ?? /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n")
    let ranked = CPUProcessRanking.ranked(
      .init(records: records, workingDirectories: [10: "/Users/me/dev/blitzreels"]))
    #expect(ranked.map(\.processID) == [11, 12, 13])
    #expect(ranked[0].workingDirectory == "/Users/me/dev/blitzreels")
    #expect(ranked[1].workingDirectory == nil)
    #expect(ranked[2].name == "Google Chrome")
  }

  @Test
  func projectStopExcludesAgentsToolsAndOtherProjects() throws {
    let records = RawProcessParser.records(
      "10 1 501 0 100 01:00 ?? node /app/node_modules/vite/bin/vite.js\n"
        + "11 1 501 0 100 01:00 ?? claude\n"
        + "12 1 501 0 100 01:00 ?? java -classpath /maestro/lib/* maestro.cli.AppKt mcp\n"
        + "13 1 501 0 100 01:00 ?? next-server (v16.3.3)\n")
    let processes = records.compactMap { record in
      DevProcessClassifier.classify(
        .init(
          record: record, listeningPorts: [record.processID == 13 ? 3000 : 5173],
          workingDirectory: record.processID == 13 ? "/dev/blitzreels" : "/dev/studios",
          memoryBytes: nil))
    }
    let studios = try #require(DevProject.grouped(processes).first { $0.name == "studios" })
    #expect(studios.servers.map(\.processID) == [10])
    #expect(!studios.processes.contains { $0.kind == .claudeCode })
  }

  @Test
  func rejectsStaleIdentityThenStopsOnlyItsOwnFixture() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer { if child.isRunning { child.terminate() } }
    let identity = try #require(DevProcessIdentity.read(child.processIdentifier))
    let process = DevProcess(
      processID: child.processIdentifier, parentProcessID: getpid(), kind: .devServer,
      name: "test fixture", detail: "", workingDirectory: nil, listeningPorts: [],
      cpuPercent: 0, memoryBytes: 0, elapsed: "00:00", terminal: nil)
    let stale = DevProcessIdentity(
      process: RecoveryProcess(
        processID: identity.process.processID, owner: identity.process.owner,
        startSeconds: identity.process.startSeconds + 1,
        startMicroseconds: identity.process.startMicroseconds, state: identity.process.state),
      executable: identity.executable)
    let refused = DevProcessStopper.stop(.init(process: process, expected: stale, force: false))
    #expect(refused.contains("exited or changed"))
    #expect(child.isRunning)
    let sent = DevProcessStopper.stop(.init(process: process, expected: identity, force: false))
    #expect(sent == "Asked test fixture to stop")
    child.waitUntilExit()
    #expect(child.terminationReason == .uncaughtSignal)
    #expect(child.terminationStatus == SIGTERM)
  }
}
