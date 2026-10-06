import Foundation
import Testing

@testable import BlitzClean

struct AppDataMigrationTests {
  private let manager = FileManager.default

  private func temporaryRoot() throws -> URL {
    let root = manager.temporaryDirectory.appendingPathComponent(
      "blitzclean-appdata-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test func movesLegacyFilesWithoutReplacingCurrentOnes() throws {
    let root = try temporaryRoot()
    defer { try? manager.removeItem(at: root) }
    let legacy = root.appendingPathComponent("FreeSpace")
    let current = root.appendingPathComponent("BlitzClean")
    try manager.createDirectory(
      at: legacy.appendingPathComponent("reports"), withIntermediateDirectories: true)
    try manager.createDirectory(
      at: current.appendingPathComponent("reports"), withIntermediateDirectories: true)
    try Data("old history".utf8).write(to: legacy.appendingPathComponent("cleanup-history.json"))
    try Data("old chart".utf8).write(to: legacy.appendingPathComponent("resource-history.json"))
    try Data("new chart".utf8).write(to: current.appendingPathComponent("resource-history.json"))
    try Data("{}".utf8).write(to: legacy.appendingPathComponent("reports/agent.json"))

    AppData.migrateLegacyFiles(.init(legacy: legacy, current: current))

    #expect(
      try String(
        contentsOf: current.appendingPathComponent("cleanup-history.json"), encoding: .utf8)
        == "old history")
    #expect(
      try String(
        contentsOf: current.appendingPathComponent("resource-history.json"), encoding: .utf8)
        == "new chart")
    #expect(manager.fileExists(atPath: current.appendingPathComponent("reports/agent.json").path))
    #expect(manager.fileExists(atPath: legacy.appendingPathComponent("resource-history.json").path))
    #expect(!manager.fileExists(atPath: legacy.appendingPathComponent("reports").path))
  }

  @Test func removesTheLegacyFolderOnceEmpty() throws {
    let root = try temporaryRoot()
    defer { try? manager.removeItem(at: root) }
    let legacy = root.appendingPathComponent("FreeSpace")
    let current = root.appendingPathComponent("BlitzClean")
    try manager.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data("log".utf8).write(to: legacy.appendingPathComponent("memory-history.json"))

    AppData.migrateLegacyFiles(.init(legacy: legacy, current: current))

    #expect(!manager.fileExists(atPath: legacy.path))
    #expect(manager.fileExists(atPath: current.appendingPathComponent("memory-history.json").path))
  }

  @Test func doesNothingWithoutALegacyFolder() throws {
    let root = try temporaryRoot()
    defer { try? manager.removeItem(at: root) }
    let current = root.appendingPathComponent("BlitzClean")
    AppData.migrateLegacyFiles(
      .init(legacy: root.appendingPathComponent("FreeSpace"), current: current))
    #expect(!manager.fileExists(atPath: current.path))
  }
}
