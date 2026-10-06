import Foundation
import Testing

@testable import BlitzClean

@MainActor
struct PersistenceRegressionTests {
  @Test func storageDefaultsToBrowseWithoutASeparateFilesTab() throws {
    #expect(CleanStoragePage.restored(nil) == .browse)
    #expect(CleanStoragePage.allCases.first == .browse)
    #expect(!CleanStoragePage.allCases.contains { $0.rawValue == "Files" })
  }

  @Test func relaunchRestoresNavigation() throws {
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = CleanNavigation(defaults)
    first.page = .storage
    first.storagePage = .browse
    let reopened = CleanNavigation(defaults)
    #expect(reopened.page == .storage)
    #expect(reopened.storagePage == .browse)
  }

  @Test func removedDeveloperDestinationMigratesOnlyOnce() throws {
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("Developer storage", forKey: "navigation.page")
    defaults.set("Dependencies", forKey: "navigation.storagePage")
    let migrated = CleanNavigation(defaults)
    #expect(migrated.page == .storage)
    #expect(migrated.storagePage == .cleanup)
    migrated.storagePage = .browse
    let reopened = CleanNavigation(defaults)
    #expect(reopened.page == .storage)
    #expect(reopened.storagePage == .browse)
    #expect(CleanPage.destination(for: "storage-breakdown") == .storage)
  }

  @Test func legacyStorageChoicesKeepTheirTask() throws {
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let choices: [String: CleanStoragePage] = [
      "Mac": .mac, "Caches": .cleanup, "Dependencies": .cleanup,
      "Files & media": .browse, "Files": .browse,
    ]
    for (saved, expected) in choices {
      defaults.set("Storage", forKey: "navigation.page")
      defaults.set(saved, forKey: "navigation.storagePage")
      let navigation = CleanNavigation(defaults)
      #expect(navigation.storagePage == expected)
      #expect(CleanNavigation(defaults).storagePage == expected)
    }
  }

}

struct ScannerRegressionTests {
  @Test func discoversNestedRecordingsBeyondThreeLevels() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appendingPathComponent("recordings/2026/september/client/session")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: nested.appendingPathComponent("recording.mov"))
    let result = CleanupReviewScanner.scan(
      .init(roots: [root.path], minimumBytes: 0, maxEntries: 100))
    #expect(result.files.map(\.name) == ["recording.mov"])
  }

  @Test func doesNotSilentlyDiscardFilesAfterSixtyResults() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0..<75 {
      try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("\(index).mp4"))
    }
    let result = CleanupReviewScanner.scan(
      .init(roots: [root.path], minimumBytes: 0, maxEntries: 100))
    #expect(result.files.count == 75)
    #expect(!result.limited)
  }
}
