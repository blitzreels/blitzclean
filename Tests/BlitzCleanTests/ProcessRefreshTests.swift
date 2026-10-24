import Foundation
import Testing

@testable import BlitzClean

struct ProcessRefreshTests {
  @Test @MainActor
  func backgroundRefreshRemovesAStoppedListenerWithoutAnyWindow() async throws {
    let listener = try TestProcesses.start(
      .init(
        executable: "/usr/bin/nc",
        arguments: ["-l", "127.0.0.1", String(Int.random(in: 49_152...60_000))]))
    defer { listener.stop() }
    let model = DevProcessModel()
    try #require(
      await eventually { model.processes.contains { $0.processID == listener.processID } })
    let before = model.scannedAt
    listener.stop()
    #expect(await eventually { !model.processes.contains { $0.processID == listener.processID } })
    #expect(model.scannedAt != before)
  }
}
