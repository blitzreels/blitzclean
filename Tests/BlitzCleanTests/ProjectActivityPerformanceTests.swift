import Foundation
import Testing

@testable import BlitzClean

struct ProjectActivityPerformanceTests {
  @Test func ignoresGeneratedTreesButKeepsSourceAssets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDate = Date(timeIntervalSince1970: 1_800_000_000)
    for name in [
      "src/file.swift", "public/assets/image.png", ".build/output", ".venv/library", "Pods/library",
    ] {
      let url = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: url)
      let date =
        name.hasPrefix("src/") || name.hasPrefix("public/")
        ? sourceDate : Date(timeIntervalSince1970: 2_000_000_000)
      try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
    #expect(
      ProjectActivityResolver.latestChange(.init(rootPath: root.path, fileManager: .default))
        == sourceDate)
    #expect(
      ProjectActivityResolver.scan(
        .init(rootPath: root.path, maximumEntries: 1, deadline: .now.addingTimeInterval(10))) == nil
    )
    #expect(
      ProjectActivityResolver.scan(
        .init(rootPath: root.path, maximumEntries: 1000, deadline: .distantPast)) == nil)
  }

  @Test func doesNotFollowLinksOutsideTheProject() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("outside").path, withDestinationPath: NSHomeDirectory())
    #expect(
      ProjectActivityResolver.latestChange(.init(rootPath: root.path, fileManager: .default)) == nil
    )
  }
}
