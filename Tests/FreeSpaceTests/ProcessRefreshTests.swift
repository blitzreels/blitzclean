import Foundation
import Testing

@testable import FreeSpace

struct ProcessRefreshTests {
  @Test @MainActor
  func backgroundRefreshRemovesAStoppedListenerWithoutAnyWindow() async throws {
    let listener = Process()
    listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    listener.arguments = ["-l", "127.0.0.1", String(Int.random(in: 49_152...60_000))]
    listener.standardOutput = FileHandle.nullDevice
    listener.standardError = FileHandle.nullDevice
    try listener.run()
    defer {
      if listener.isRunning { listener.terminate() }
    }
    let model = DevProcessModel()
    let firstDeadline = Date.now.addingTimeInterval(20)
    while !model.processes.contains(where: { $0.processID == listener.processIdentifier }),
      Date.now < firstDeadline
    {
      try await Task.sleep(for: .milliseconds(250))
    }
    try #require(model.processes.contains(where: { $0.processID == listener.processIdentifier }))
    let before = model.scannedAt
    listener.terminate()
    listener.waitUntilExit()
    let secondDeadline = Date.now.addingTimeInterval(20)
    while model.processes.contains(where: { $0.processID == listener.processIdentifier }),
      Date.now < secondDeadline
    {
      try await Task.sleep(for: .milliseconds(250))
    }
    #expect(!model.processes.contains(where: { $0.processID == listener.processIdentifier }))
    #expect(model.scannedAt != before)
  }
}
