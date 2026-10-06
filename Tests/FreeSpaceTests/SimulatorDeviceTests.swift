import Foundation
import Testing

@testable import FreeSpace

struct SimulatorDeviceTests {
  private static let id = "12298A08-D491-458D-A97B-BBBC0B811AB2"

  private func device(_ state: String) -> SimulatorDeviceInfo {
    .init(
      id: Self.id, name: "iPhone test", runtime: "iOS 26.5", state: state, lastBootedAt: nil,
      bytes: 42)
  }

  private static func listing(_ state: String) -> String {
    """
    {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"udid":"\(id)","name":"iPhone test","state":"\(state)","dataPathSize":42}]}}
    """
  }

  @Test func deleteUsesExactDeviceIDAndVerifiesRemoval() throws {
    let runner = Runner(outputs: [Self.listing("Shutdown"), "", "{\"devices\":{}}"])
    let service = SimulatorDeviceService(run: runner.run)
    let result = try service.execute(.init(device: device("Shutdown"), action: .delete))
    #expect(
      runner.arguments == [
        ["simctl", "list", "devices", "--json"], ["simctl", "delete", Self.id],
        ["simctl", "list", "devices", "--json"],
      ])
    #expect(result.devices.isEmpty)
    #expect(result.win?.bytes == 42)
    #expect(result.message.contains("runtime stays installed"))
  }

  @Test func bootedDeviceCannotBeDeletedEvenWithStaleShutdownRow() {
    let runner = Runner(outputs: [Self.listing("Booted")])
    let service = SimulatorDeviceService(run: runner.run)
    #expect(throws: (any Error).self) {
      try service.execute(.init(device: device("Shutdown"), action: .delete))
    }
    #expect(runner.arguments.count == 1)
  }

  @Test func deleteDoesNotClaimSuccessWhileDeviceRemains() {
    let runner = Runner(outputs: [Self.listing("Shutdown"), "", Self.listing("Shutdown")])
    #expect(throws: (any Error).self) {
      try SimulatorDeviceService(run: runner.run).execute(
        .init(device: device("Shutdown"), action: .delete))
    }
  }

  @Test func malformedOrChangedIdentityCannotDeleteAnything() {
    let invalid = SimulatorDeviceInfo(
      id: "all", name: "iPhone test", runtime: "iOS 26.5", state: "Shutdown", lastBootedAt: nil,
      bytes: 1)
    let runner = Runner(outputs: [
      Self.listing("Shutdown").replacingOccurrences(of: "iPhone test", with: "Renamed device")
    ])
    let service = SimulatorDeviceService(run: runner.run)
    #expect(throws: (any Error).self) {
      try service.execute(.init(device: invalid, action: .delete))
    }
    #expect(runner.arguments.isEmpty)
    #expect(throws: (any Error).self) {
      try service.execute(.init(device: device("Shutdown"), action: .delete))
    }
    #expect(runner.arguments.count == 1)
  }

  @Test func shutdownIsSeparateFromDelete() throws {
    let runner = Runner(outputs: [Self.listing("Booted"), "", Self.listing("Shutdown")])
    let result = try SimulatorDeviceService(run: runner.run).execute(
      .init(device: device("Booted"), action: .shutdown))
    #expect(runner.arguments[1] == ["simctl", "shutdown", Self.id])
    #expect(result.devices.first?.state == "Shutdown")
    #expect(result.win == nil)
  }

  @Test func simulatorDeviceFilesCannotUseGenericTrash() {
    let root = NSHomeDirectory() + "/Library/Developer/CoreSimulator/Devices"
    #expect(!ReviewFileDeletion.canTrashPath(root))
    #expect(!ReviewFileDeletion.canTrashPath(root + "/\(Self.id)/data/recording.mp4"))
    #expect(!ReviewFileDeletion.canTrashPath("/System/Volumes/Data" + root + "/" + Self.id))
    #expect(ReviewFileDeletion.canTrashPath(NSHomeDirectory() + "/Movies/recording.mp4"))
  }

  private final class Runner: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String]
    private var calls: [[String]] = []
    init(outputs: [String]) { self.outputs = outputs }
    var arguments: [[String]] { lock.withLock { calls } }
    func run(_ request: DeveloperCommand.Request) -> CleanupCommandResult {
      lock.withLock {
        calls.append(request.arguments)
        return .init(
          status: outputs.isEmpty ? -1 : 0, output: outputs.isEmpty ? "" : outputs.removeFirst())
      }
    }
  }
}
