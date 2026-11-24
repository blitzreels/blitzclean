import Foundation
import Testing

@testable import BlitzClean

struct DriveContentsTests {
  @Test func categoriesMeasureEveryAllocatedFileAndCountHardLinksOnce() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var expected: [DriveFileCategory: UInt64] = [:]
    for (index, item) in [
      ("Recordings/clip.mov", DriveFileCategory.recordings), ("Exports/clip.mov", .exports),
      ("Photos/pic.heic", .photos), ("Tools/Studio.app/Contents/main", .applications),
      ("project/node_modules/code", .builds), ("notes.txt", .other),
    ].enumerated() {
      let url = root.appendingPathComponent(item.0)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: UInt8(index), count: 16384).write(to: url)
      expected[item.1] = try #require(ReviewFile.read(url.path)).bytes
    }
    try FileManager.default.linkItem(
      at: root.appendingPathComponent("Exports/clip.mov"),
      to: root.appendingPathComponent("Exports/copy.mov"))
    let scan = DriveFileScanner.scan(
      .init(
        roots: [root.path], minimumBytes: 0, resultLimit: 0, categorize: true, progress: { _ in }))
    let contents = try #require(scan.contents)
    let physicalRoot = try #require(ReviewFile.canonicalPath(root.path))
    #expect(scan.complete)
    #expect(contents.bytes == expected)
    #expect(contents.largest[.exports]?.count == 1)
    #expect(
      contents.buildFolders[physicalRoot + "/project/node_modules"]
        == expected[.builds])
    #expect(
      scan.folderBytes[physicalRoot + "/Recordings"] == expected[.recordings])
  }

  @Test func growthExcludesIncompleteFoldersFromEitherScan() {
    let old = DriveFolderReading(date: .now, bytes: ["A": 20, "B": 5, "C": 30], incomplete: ["B"])
    let new = DriveFolderReading(
      date: .now, bytes: ["A": 30, "B": 25, "C": 40, "D": 60], incomplete: ["C"])
    let growth = new.growth(since: old)
    #expect(growth.map(\.key) == ["D", "A"])
    #expect(growth.map(\.value) == [60, 10])
  }

  @Test func protectedFoldersCoverChildrenAndParentRemovals() {
    #expect(DriveKeptFolders.overlaps(("calls", "calls/current/clip.mov")))
    #expect(DriveKeptFolders.overlaps(("calls/current", "calls")))
    #expect(!DriveKeptFolders.overlaps(("calls", "calls-export")))
  }
}
