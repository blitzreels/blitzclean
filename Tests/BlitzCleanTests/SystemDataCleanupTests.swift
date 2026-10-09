import Foundation
import Testing

@testable import BlitzClean

struct SystemDataCleanupTests {
  @Test func onlyOldRegularDiagnosticReportsAreEligibleAndRemovable() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try file(.init(root: root, name: "old.ips", days: 40))
    let recent = try file(.init(root: root, name: "recent.crash", days: 10))
    let personal = try file(.init(root: root, name: "notes.txt", days: 40))
    let linked = root.appendingPathComponent("linked.ips")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: old)
    let folder = root.appendingPathComponent("folder.ips")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let rule = diagnosticRule(root)
    let scan = CacheCleaner.scan(.init(rules: [rule], date: .now))
    #expect(scan.candidates.map(\.path) == [old.path])
    let win = try CacheCleaner.delete(try #require(scan.candidates.first))
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(win.bytes != nil)
    #expect(FileManager.default.fileExists(atPath: recent.path))
    #expect(FileManager.default.fileExists(atPath: personal.path))
    #expect(FileManager.default.fileExists(atPath: folder.path))
    #expect(!rule.accepts(folder.path))
    #expect(!rule.accepts(linked.path))
  }

  @Test func deletionRechecksReportTypeAgeAndActivity() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let rule = diagnosticRule(root)
    for name in ["personal.txt", "too-recent.ips"] {
      let url = try file(.init(root: root, name: name, days: 10))
      let tree = try CacheCleaner.tree(.init(path: url.path, deadline: .now.addingTimeInterval(5)))
      let candidate = CacheCandidate(path: url.path, rule: rule, tree: tree)
      #expect(throws: CacheCleanError.self) { try CacheCleaner.delete(candidate) }
      #expect(FileManager.default.fileExists(atPath: url.path))
    }
    let old = try file(.init(root: root, name: "open.ips", days: 40))
    let tree = try CacheCleaner.tree(.init(path: old.path, deadline: .now.addingTimeInterval(5)))
    let handle = try FileHandle(forReadingFrom: old)
    defer { try? handle.close() }
    #expect(throws: CacheCleanError.self) {
      try CacheCleaner.delete(.init(path: old.path, rule: rule, tree: tree))
    }
    #expect(FileManager.default.fileExists(atPath: old.path))
  }

  @Test func linkedBrowserCacheCannotEscapeIntoAppData() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Application Support")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let personal = try file(.init(root: support, name: "profile.db", days: 40))
    let catalog = SystemDataCatalog.rules(home: root.path)
    let browser = try #require(catalog.first { $0.title == "Safari cache" })
    let cache = URL(fileURLWithPath: browser.path)
    try FileManager.default.createDirectory(
      at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: support)
    let tree = try CacheCleaner.tree(
      .init(path: personal.path, deadline: .now.addingTimeInterval(5)))
    #expect(throws: CacheCleanError.self) {
      try CacheCleaner.delete(
        .init(path: browser.path + "/profile.db", rule: browser, tree: tree))
    }
    #expect(FileManager.default.fileExists(atPath: personal.path))
  }

  private struct FileInput {
    let root: URL
    let name: String
    let days: Double
  }

  private func file(_ input: FileInput) throws -> URL {
    let url = input.root.appendingPathComponent(input.name)
    try Data(repeating: 42, count: 4096).write(to: url)
    try FileManager.default.setAttributes(
      [.modificationDate: Date.now.addingTimeInterval(-input.days * 86_400)], ofItemAtPath: url.path
    )
    return url
  }

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("system-data-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return URL(fileURLWithPath: try #require(ReviewFile.canonicalPath(root.path)))
  }

  private func diagnosticRule(_ root: URL) -> CacheRule {
    .init(
      title: "Reports", path: root.path, recipe: "Test reports", owners: [], kind: .diagnosticReport
    )
  }
}
