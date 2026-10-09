import Foundation
import Testing

@testable import BlitzClean

struct DependencyFileScanTests {
  @Test func expiredAuditBudgetNeverPublishesPartialFolderBytes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("file"))
    let audit = FolderMeasurementSession(deadline: .distantPast)
    #expect(audit.directoryBytes(root.path) == nil)
    #expect(audit.incompleteCount == 1)
    #expect(FolderMeasurementSession().directoryBytes(root.path) != nil)
  }

  @Test func auditSharesConcurrentMeasurementsIncludingUnavailablePaths() {
    let probe = MeasurementProbe()
    let session = FolderMeasurementSession(measure: probe.measure)
    DispatchQueue.concurrentPerform(iterations: 64) { index in
      let path = "folder\(index % 8)"
      let value = session.footprint(path)
      #expect(value == (path == "folder0" ? nil : .init(allocated: 42, content: 42)))
    }
    #expect(probe.calls.count == 8)
    #expect(probe.calls.values.allSatisfy { $0 == 1 })
    #expect(probe.peak <= 4)
    #expect(probe.peak > 1)
  }

  @Test func newAuditRemeasuresChangedFoldersAndRejectsFileOrSymlinkRoots() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let session = FolderMeasurementSession()
    let before = try #require(session.directoryBytes(root.path))
    let file = root.appendingPathComponent("file")
    try Data(repeating: 42, count: 65_536).write(to: file)
    #expect(session.directoryBytes(root.path) == before)
    let fresh = FolderMeasurementSession()
    #expect(try #require(fresh.directoryBytes(root.path)) > before)
    #expect(fresh.directoryBytes(file.path) == nil)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.path)
    #expect(fresh.directoryBytes(link.path) == nil)
  }

  @Test func discoveryDeduplicatesRootsAndPrunesNestedDependencies() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for path in [
      "app/node_modules/pkg/node_modules", ".worktrees/app/node_modules", "app-other/node_modules",
      ".build/tool/node_modules", ".venv/package/node_modules",
    ] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("alias").path,
      withDestinationPath: root.appendingPathComponent("app").path)
    let paths = DependencyFileScan.discover([
      root.path, root.appendingPathComponent("app").path, root.path,
    ])
    #expect(
      Set(paths)
        == Set(
          ["app/node_modules", ".worktrees/app/node_modules", "app-other/node_modules"].map {
            root.appendingPathComponent($0).path
          }))
  }

  @Test func onePassMatchesDuForHardLinksSparseFilesAndSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("file")
    try Data(repeating: 42, count: 32768).write(to: file)
    try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("hardlink"))
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("link").path, withDestinationPath: NSHomeDirectory())
    let sparse = root.appendingPathComponent("sparse")
    FileManager.default.createFile(atPath: sparse.path, contents: nil)
    let handle = try FileHandle(forWritingTo: sparse)
    try handle.truncate(atOffset: 16 * 1024 * 1024)
    try handle.close()
    let measured = try #require(DependencyFileScan.measure(root.path))
    for apparent in [false, true] {
      let result = DeveloperCommand.run(
        .init(
          executable: "/usr/bin/du", arguments: (apparent ? ["-skA"] : ["-sk"]) + [root.path],
          timeout: 5, maximumBytes: 4096))
      #expect(result.status == 0)
      let kilobytes = try #require(
        result.output.split(whereSeparator: \.isWhitespace).first.flatMap { UInt64($0) })
      let actual = apparent ? measured.content : measured.allocated
      #expect((actual + 1023) / 1024 == kilobytes)
    }
    #expect(DependencyFileScan.measureAll([root.path, root.path]) == [root.path: measured])
    #expect(DependencyFileScan.measure(root.appendingPathComponent("missing").path) == nil)
  }
}

private final class MeasurementProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var active = 0
  private(set) var calls: [String: Int] = [:]
  private(set) var peak = 0

  func measure(_ path: String) -> DependencyFootprint? {
    lock.lock()
    calls[path, default: 0] += 1
    active += 1
    peak = max(peak, active)
    lock.unlock()
    Thread.sleep(forTimeInterval: 0.01)
    lock.lock()
    active -= 1
    lock.unlock()
    return path == "folder0" ? nil : .init(allocated: 42, content: 42)
  }
}
