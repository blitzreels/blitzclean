import Foundation
import Testing

@testable import BlitzClean

struct CleanupRepeatTests {
  private let home = "/Users/me"

  @MainActor @Test func unavailableSizeIsDistinctFromAFolderThatDidNotGrowBack() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("app/.next")
    let missing = root.appendingPathComponent("missing/.next")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let history = CleanupOverviewModel(
      .init(
        store: .init(url: root.appendingPathComponent("history.json")),
        scanRequest: .init(roots: [], minimumBytes: 0, maxEntries: 1),
        synchronizesInBackground: false))
    history.record(win("folders", day: 1, paths: [folder.path, missing.path], bytes: 1024))
    let model = RepeatCleanupModel(history: history, home: root.path)
    model.check(.init(force: true, scope: .overview, measure: { _ in nil }))
    for _ in 0..<1000 where model.isChecking {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isChecking)
    #expect(model.statuses[folder.path]?.bytes == nil)
    #expect(model.statuses[folder.path]?.blocker != nil)
    #expect(model.statuses[missing.path] == .init(bytes: nil, blocker: nil))
  }

  @MainActor @Test func overviewSkipsPnpmSizeButDetailedCheckStillMeasuresIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = CleanupOverviewModel(
      .init(
        store: .init(url: root.appendingPathComponent("history.json")),
        scanRequest: .init(roots: [], minimumBytes: 0, maxEntries: 1),
        synchronizesInBackground: false))
    history.record(win("pnpm", day: 1, paths: [home + "/Library/pnpm/store"], bytes: 1024))
    history.record(win("project", day: 1, paths: [home + "/dev/app/.next"], bytes: 1024))
    let model = RepeatCleanupModel(history: history, home: home)
    model.check(.init(force: true, scope: .overview, measure: { _ in 2048 }))
    for _ in 0..<1000 where model.isChecking {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isChecking)
    #expect(model.statuses[home + "/dev/app/.next"]?.bytes == 2048)
    #expect(model.statuses[home + "/Library/pnpm/store"] == nil)
    model.check(.init(force: false, scope: .all, measure: { _ in 4096 }))
    for _ in 0..<1000 where model.isChecking {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isChecking)
    #expect(model.statuses[home + "/Library/pnpm/store"]?.bytes == 4096)
  }

  @MainActor @Test func openingDetailsDuringAuditQueuesTheFullHistoryCheck() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = CleanupOverviewModel(
      .init(
        store: .init(url: root.appendingPathComponent("history.json")),
        scanRequest: .init(roots: [], minimumBytes: 0, maxEntries: 1),
        synchronizesInBackground: false))
    history.record(win("pnpm", day: 1, paths: [home + "/Library/pnpm/store"], bytes: 1024))
    let model = RepeatCleanupModel(history: history, home: home)
    model.check(.init(force: true, scope: .overview, measure: { _ in 2048 }))
    model.check()
    for _ in 0..<1000 where model.isChecking {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isChecking)
    #expect(model.statuses[home + "/Library/pnpm/store"]?.bytes == 2048)
  }

  @Test
  func removedPathsMapToTheFolderThatRegrows() {
    let cases: [(String, String?, RegrowRecipe?)] = [
      ("/Users/me/dev/app/.next/cache", "/Users/me/dev/app/.next", .folder),
      ("/Users/me/dev/app/.next/standalone", "/Users/me/dev/app/.next", .folder),
      ("/Users/me/dev/mono/apps/web/.next", "/Users/me/dev/mono/apps/web/.next", .folder),
      ("/Users/me/dev/app/node_modules/pkg/.next", "/Users/me/dev/app/node_modules", .dependencies),
      ("/Users/me/dev/app/.trigger/tmp/build-1", "/Users/me/dev/app/.trigger/tmp", .folder),
      ("/Users/me/Library/pnpm/store/v10", "/Users/me/Library/pnpm/store", .pnpmPrune),
      ("/Users/me/.npm/_cacache", "/Users/me/.npm/_cacache", .folder),
      (
        "/Users/me/Library/Developer/Xcode/DerivedData/App-abc/Build",
        "/Users/me/Library/Developer/Xcode/DerivedData/App-abc", .folder
      ),
      ("/Users/me/Documents/report.pdf", nil, nil),
      ("/Users/me/.Trash/app/.next", nil, nil),
      ("/Users/other/dev/app/.next", nil, nil),
    ]
    for (path, expected, recipe) in cases {
      let target = RegrowCatalog.target(for: path, home: home)
      #expect(target?.path == expected, "\(path)")
      #expect(target?.recipe == recipe, "\(path)")
    }
  }

  @Test
  func entriesGroupRepeatRemovalsAndOnlyCreditSingleTargetWins() {
    var ledger = CleanupLedger()
    ledger.record(win("a", day: 1, paths: ["/Users/me/dev/app/.next/cache"], bytes: 100))
    ledger.record(win("b", day: 3, paths: ["/Users/me/dev/app/.next"], bytes: 250))
    ledger.record(
      win(
        "c", day: 2, paths: ["/Users/me/dev/app/.next/server", "/Users/me/.npm/_cacache"],
        bytes: 900))
    ledger.record(win("d", day: 4, paths: ["/Users/me/Movies/clip.mov"], bytes: 5))
    let entries = RegrowCatalog.entries(ledger, home: home)
    #expect(entries.map(\.target.path) == ["/Users/me/dev/app/.next", "/Users/me/.npm/_cacache"])
    #expect(entries[0].removals == 3)
    #expect(entries[0].freedBytes == 350)
    #expect(entries[0].lastRemovedAt == Date(timeIntervalSince1970: 3 * 86_400))
    #expect(entries[1].freedBytes == 0)
  }

  @Test
  func onlyBuildAndDevProcessesBlockAProjectFolder() {
    let root = "/Users/me/dev/app"
    func building(_ arguments: String) -> Bool {
      RegrowActivity.isBuilding(.init(arguments: arguments, directory: root), root: root)
    }
    #expect(building("/Users/me/dev/app/node_modules/.bin/next-server"))
    #expect(building("node /Users/me/dev/app/node_modules/next/dist/bin/next dev"))
    #expect(building("pnpm run app:dev"))
    #expect(building("/opt/homebrew/bin/turbo run build"))
    #expect(!building("node /Users/me/.npm/_npx/abc/node_modules/.bin/mcp-remote https://x.dev"))
    #expect(!building("npm exec @playwright/mcp"))
    #expect(!building("/bin/zsh -il"))
    #expect(
      !building(
        "/Users/me/.local/bin/cursor-agent --use-system-ca /x/index.js worker start --worker-dir /Users/me/dev/app"
      ))
    #expect(!building("claude --resume /Users/me/dev/app/"))

    let activity = RegrowActivity(processes: [
      .init(arguments: "pnpm dev", directory: "/Users/me/dev/other"),
      .init(arguments: "/bin/zsh", directory: root),
    ])
    let target = RegrowTarget(
      path: root + "/.next", title: "Next.js build", recipe: .folder, owners: [])
    #expect(activity.blocker(target, projectRoot: root) == nil)
    let busy = RegrowActivity(processes: [.init(arguments: "pnpm dev", directory: root + "/apps")])
    #expect(busy.blocker(target, projectRoot: root)?.contains("app") == true)

    let cache = RegrowTarget(
      path: "/Users/me/.npm/_cacache", title: "npm cache", recipe: .folder, owners: ["npm"])
    let npm = RegrowActivity(processes: [.init(arguments: "npm install", directory: nil)])
    #expect(npm.blocker(cache, projectRoot: nil) == "npm is running")
  }

  @Test
  func agentReportsImportAsRemovalsWithStableIDs() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("storage-cleanup-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let json = """
      {"started":{"at":1790622810,"free":1},
       "removed":[
        {"path":"/Users/me/dev/app/.next","allocatedBytes":2000,"freeBefore":10,"freeAfter":2010,"time":1790622900,"kind":"build"},
        {"path":"/Volumes/X/cache","allocatedBytes":null}
       ],
       "skipped":[{"path":"/Users/me/.npm/_npx/1","reason":"In use"}]}
      """
    try Data(json.utf8).write(to: url)
    let wins = CleanupReportImporter.wins(url)
    #expect(
      wins.map(\.id) == ["report:\(url.lastPathComponent):0", "report:\(url.lastPathComponent):1"])
    #expect(wins[0].bytes == 2000)
    #expect(wins[0].measuredGain == 2000)
    #expect(wins[0].after?.isInternal == true)
    #expect(wins[0].date == Date(timeIntervalSince1970: 1_790_622_900))
    #expect(wins[1].date == Date(timeIntervalSince1970: 1_790_622_810))
    #expect(wins[1].after == nil)
    #expect(CleanupReportImporter.wins(url.appendingPathExtension("missing")).isEmpty)
  }

  private func win(_ id: String, day: Double, paths: [String], bytes: UInt64) -> CleanupWin {
    CleanupWin(
      id: id, date: Date(timeIntervalSince1970: day * 86_400), title: id, paths: paths, before: nil,
      after: nil, bytes: bytes)
  }
}
