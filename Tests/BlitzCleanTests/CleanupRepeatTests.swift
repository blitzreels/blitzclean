import Foundation
import Testing

@testable import BlitzClean

struct CleanupRepeatTests {
  @Test func repeatReviewPreservesRecentFilesAndSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "repeat-safety-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent(".next")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("data")
    try Data("keep".utf8).write(to: file)
    let target = RegrowTarget(path: folder.path, title: "Build", recipe: .folder, owners: [])
    #expect(throws: CacheCleanError.self) { try RegrowCleaner.reviewedTree(target) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
    try FileManager.default.createSymbolicLink(
      at: folder.appendingPathComponent("link"), withDestinationURL: file)
    #expect(throws: CacheCleanError.self) { try RegrowCleaner.reviewedTree(target) }
  }

  @Test func repeatReviewPreservesTrackedFilesEvenWhenOld() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "repeat-git-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(DeveloperCommand.git(.init(directory: root.path, arguments: ["init"])).status == 0)
    let folder = root.appendingPathComponent(".next")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("source")
    try Data("keep".utf8).write(to: file)
    #expect(
      DeveloperCommand.git(.init(directory: root.path, arguments: ["add", ".next/source"])).status
        == 0)
    for url in [file, folder] {
      try FileManager.default.setAttributes(
        [.modificationDate: Date.now.addingTimeInterval(-10 * 86_400)], ofItemAtPath: url.path)
    }
    let target = RegrowTarget(path: folder.path, title: "Build", recipe: .folder, owners: [])
    #expect(throws: RegrowCleanError.self) { try RegrowCleaner.reviewedTree(target) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
  }

  @Test func repeatReviewAcceptsOldUnusedCacheButRejectsOpenFiles() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("repeat-open-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("cache")
    try Data("keep".utf8).write(to: file)
    for url in [file, root] {
      try FileManager.default.setAttributes(
        [.modificationDate: Date.now.addingTimeInterval(-10 * 86_400)], ofItemAtPath: url.path)
    }
    let target = RegrowTarget(path: root.path, title: "Cache", recipe: .folder, owners: [])
    #expect(try RegrowCleaner.reviewedTree(target).bytes > 0)
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    #expect(throws: RegrowCleanError.self) { try RegrowCleaner.reviewedTree(target) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
  }

  private let home = "/Users/me"

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
