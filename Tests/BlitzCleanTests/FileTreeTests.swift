import Darwin
import Foundation
import Testing

@testable import BlitzClean

struct FileTreeTests {
  @Test
  func footprintKeepsReadableBytesWhenSomeFoldersAreLocked() throws {
    let root = try folder()
    let locked = root + "/locked"
    try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
      try? FileManager.default.removeItem(atPath: root)
    }
    try Data(repeating: 1, count: 64 * 1_024).write(to: URL(fileURLWithPath: root + "/data"))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
    let footprint = try #require(
      FolderFootprint.measure(.init(path: root, deadline: .distantFuture)))
    #expect(footprint.partial)
    #expect(footprint.allocated >= 64 * 1_024)
    #expect(DependencyFileScan.measure(root) == nil)
  }

  @Test
  func footprintIsNilForMissingFoldersAndPastDeadlines() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(atPath: root) }
    #expect(
      FolderFootprint.measure(.init(path: root + "/missing", deadline: .distantFuture)) == nil)
    #expect(FolderFootprint.measure(.init(path: root, deadline: .distantPast)) == nil)
  }

  @Test
  func browseCountsHardLinkedFilesOnce() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(atPath: root) }
    for name in ["store", "project"] {
      try FileManager.default.createDirectory(
        atPath: root + "/" + name, withIntermediateDirectories: true)
    }
    let original = URL(fileURLWithPath: root + "/store/package.bin")
    try Data(repeating: 7, count: 256 * 1_024).write(to: original)
    try FileManager.default.linkItem(
      at: original, to: URL(fileURLWithPath: root + "/project/package.bin"))
    let result = DriveFileScanner.scan(
      .init(roots: [root], minimumBytes: 0, resultLimit: 10, progress: { _ in }))
    var info = stat()
    try #require(lstat(original.path, &info) == 0)
    #expect(result.folderBytes.values.reduce(0, +) == AllocatedSize.of(info))
  }

  @Test
  func walkerSkipsSubtreesOnRequest() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(
      atPath: root + "/skip/inner", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      atPath: root + "/keep", withIntermediateDirectories: true)
    let tree = try #require(FileTree(.init(path: root, needsMetadata: false)))
    var seen: [String] = []
    while let entry = tree.next() {
      guard entry.kind == .directory else { continue }
      seen.append(entry.name)
      if entry.name == "skip" { tree.skip(entry) }
    }
    #expect(tree.completed)
    #expect(seen.contains("keep"))
    #expect(!seen.contains("inner"))
  }

  private func folder() throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("file-tree-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return try #require(ReviewFile.canonicalPath(url.path))
  }
}
