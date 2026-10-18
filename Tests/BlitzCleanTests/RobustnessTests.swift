import Foundation
import Testing

@testable import BlitzClean

struct RobustnessTests {
  @Test
  func unreadableSettingEntriesKeepTheRestAndAreBackedUp() throws {
    let temporary = TestDefaults("saved-settings")
    let key = "workspace.preferences.v1"
    let stored = Data(
      """
      [{"directory":"/a","name":"A","keepRunning":true},{"directory":"/b"}]
      """.utf8)
    temporary.defaults.set(stored, forKey: key)
    let read: [WorkspacePreference]? = SavedSettings.list(
      .init(key: key, defaults: temporary.defaults))
    #expect(read?.map(\.directory) == ["/a"])
    #expect(temporary.defaults.data(forKey: key + ".unreadable") == stored)
  }

  @Test
  func settingsThatAreNotAListReadAsUnknown() {
    let temporary = TestDefaults("saved-settings")
    temporary.defaults.set(Data("{}".utf8), forKey: "list")
    let read: [WorkspacePreference]? = SavedSettings.list(
      .init(key: "list", defaults: temporary.defaults))
    #expect(read == nil)
    let empty: [WorkspacePreference]? = SavedSettings.list(
      .init(key: "missing", defaults: temporary.defaults))
    #expect(empty == [])
  }

  @Test
  func unreadableHistoryIsMovedAsideAndSavingContinues() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = CleanupHistoryStore(url: folder.appendingPathComponent("cleanup-history.json"))
    try Data(#"{"wins":[{"broken":true}]}"#.utf8).write(to: store.url)
    let win = CleanupWin(
      id: "new", date: .now, title: "Deleted cache", paths: ["/tmp/cache"], before: nil,
      after: nil)
    let merged = try store.merge(CleanupLedger(wins: [win]))
    #expect(merged.wins.map(\.id) == ["new"])
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(names.contains { $0.hasPrefix("cleanup-history.json.unreadable-") })
    #expect(try store.load().wins.map(\.id) == ["new"])
  }

  @Test
  func agentReportsAcceptLooseNumbersAndSkipOnlyBadEntries() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("report-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(
      """
      {"started":{"at":"1792350000"},"removed":[
        {"path":"/tmp/a","allocatedBytes":1.5e9,"freeBefore":"100","freeAfter":200.0,"time":1792350001.5},
        {"allocatedBytes":12},
        {"path":"/tmp/b","allocatedBytes":"nope"}
      ]}
      """.utf8
    ).write(to: url)
    let wins = CleanupReportImporter.wins(url)
    #expect(wins.count == 2)
    #expect(wins.first?.bytes == 1_500_000_000)
  }

  @Test
  func claudeProjectFoldersReplaceEveryNonASCIICharacter() {
    #expect(
      AIThreadNames.claudeProjectFolder("/Users/me/Développement/app")
        == "-Users-me-D-veloppement-app")
    #expect(AIThreadNames.claudeProjectFolder("/a b/c.d") == "-a-b-c-d")
  }

  @Test
  func claudeInstalledUnderApplicationSupportIsRecognised() throws {
    let record = RawProcessRecord(
      processID: 4_242, parentProcessID: 1, userID: 501, cpuPercent: 1, residentKilobytes: 1_024,
      elapsed: "01:00", terminal: "ttys001",
      arguments:
        "/Users/me/Library/Application Support/Claude/claude-code/2.1.295/claude --session-id abc")
    let process = try #require(
      DevProcessClassifier.classify(
        .init(
          record: record, listeningPorts: [], workingDirectory: "/Users/me/dev", memoryBytes: nil)
      ))
    #expect(process.kind == .claudeCode)
  }
}
