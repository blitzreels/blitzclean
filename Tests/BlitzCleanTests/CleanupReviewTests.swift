import Foundation
import Testing

@testable import BlitzClean

struct CleanupReviewTests {
  @Test func temporaryDirectoryAliasesAllowDeletingScannedFiles() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(root.path.hasPrefix("/private/var/"))
    let alias = String(root.path.dropFirst("/private".count))
    let video = root.appendingPathComponent("alias-video.mov")
    try Data(repeating: 1, count: 16_384).write(to: video)
    let result = CleanupReviewScanner.scan(
      ReviewScanRequest(roots: [alias], minimumBytes: 1, maxEntries: 100))
    let file = try #require(result.files.first)
    #expect(file.path == video.path)
    let deleted = try ReviewFileDeletion.delete(ReviewDeleteRequest(file: file, roots: [alias]))
    #expect(deleted.paths == [video.path])
    #expect(!FileManager.default.fileExists(atPath: video.path))
  }

  @Test func redirectedParentCannotDeleteTheMovedOriginal() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("reviewed")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let video = directory.appendingPathComponent("original.mov")
    try Data(repeating: 1, count: 16_384).write(to: video)
    let file = try #require(ReviewFile.read(video.path))
    let moved = root.appendingPathComponent("moved")
    try FileManager.default.moveItem(at: directory, to: moved)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
    #expect(file.currentVersion == nil)
    #expect(throws: ReviewDeleteError.self) {
      try ReviewFileDeletion.delete(ReviewDeleteRequest(file: file, roots: [root.path]))
    }
    #expect(
      FileManager.default.fileExists(atPath: moved.appendingPathComponent("original.mov").path))
  }

  @Test func hungActivityCheckHasABoundedDeadline() {
    let start = ContinuousClock.now
    let result = CleanupActivity.runCommand(
      CleanupCommandRequest(executable: "/bin/sleep", arguments: ["10"], timeout: 0.05))
    #expect(result.status == -1)
    #expect(ContinuousClock.now - start < .seconds(2))
  }

  @Test func allocationChangesAloneDoNotBlockDeletion() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("test.mov")
    try Data(repeating: 1, count: 16_384).write(to: url)
    let current = try #require(ReviewFile.read(url.path))
    let earlierAllocation = ReviewFile(
      path: current.path, bytes: current.bytes + 4096, modifiedAt: current.modifiedAt,
      device: current.device, inode: current.inode, logicalBytes: current.logicalBytes,
      modifiedNanoseconds: current.modifiedNanoseconds)
    try ReviewFileDeletion.validateIdentity(
      ReviewDeleteRequest(file: earlierAllocation, roots: [root.path]))
  }

  @Test
  func historyPersistsMeasurementsWithoutCountingExternalSpaceOrDuplicates() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CleanupHistoryStore(url: root.appendingPathComponent("history.json"))
    var ledger = CleanupLedger()
    let internalWin = win(WinFixture(id: "internal", before: 100, after: 140, internalDisk: true))
    ledger.record(internalWin)
    ledger.record(internalWin)
    ledger.record(win(WinFixture(id: "external", before: 10, after: 900, internalDisk: false)))
    ledger.record(win(WinFixture(id: "busy-disk", before: 100, after: 90, internalDisk: true)))
    try store.save(ledger)
    let loaded = try store.load()
    #expect(loaded == ledger)
    #expect(loaded.wins.count == 3)
    #expect(loaded.internalGains == 40)
    #expect(loaded.wins.first { $0.id == "busy-disk" }?.measuredGain == 0)
    let mode =
      try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions]
      as? NSNumber
    #expect(mode?.intValue == 0o600)
  }

  @Test
  func historyIsBoundedAndKeepsNewestWins() {
    var ledger = CleanupLedger()
    for index in 0..<1_020 {
      ledger.record(
        CleanupWin(
          id: String(index), date: Date(timeIntervalSince1970: Double(index)), title: "Fixture",
          paths: ["/fixture"], before: nil, after: nil))
    }
    #expect(ledger.wins.count == 1_000)
    #expect(ledger.wins.first?.id == "1019")
    #expect(ledger.wins.last?.id == "20")
    #expect(ledger.internalGains == 0)
  }

  @Test
  func reviewScanFindsFilesAndPrunesDependenciesAndSymlinks() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let video = root.appendingPathComponent("recording.mov")
    try Data(repeating: 7, count: 16_384).write(to: video)
    let dependencies = root.appendingPathComponent("node_modules")
    try FileManager.default.createDirectory(at: dependencies, withIntermediateDirectories: true)
    try Data(repeating: 8, count: 32_768).write(
      to: dependencies.appendingPathComponent("asset.mp4"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("linked.mov"), withDestinationURL: video)
    let result = CleanupReviewScanner.scan(
      ReviewScanRequest(roots: [root.path], minimumBytes: 1, maxEntries: 100))
    #expect(result.files.map(\.name) == ["recording.mov"])
    #expect(result.files.first?.kind == "Video")
  }

  @Test
  func changedOrReplacedFilesCannotBeDeletedFromAnOldScan() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("test.mov")
    try Data("first".utf8).write(to: url)
    let file = try #require(ReviewFile.read(url.path))
    try Data("changed bytes".utf8).write(to: url)
    #expect(throws: ReviewDeleteError.self) {
      try ReviewFileDeletion.validateIdentity(ReviewDeleteRequest(file: file, roots: [root.path]))
    }
    try FileManager.default.removeItem(at: url)
    let target = root.appendingPathComponent("original.mov")
    try Data("first".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    #expect(throws: ReviewDeleteError.self) {
      try ReviewFileDeletion.validateIdentity(ReviewDeleteRequest(file: file, roots: [root.path]))
    }
    #expect(FileManager.default.fileExists(atPath: target.path))
  }

  @Test
  func deepFolderCannotHideTopLevelFilesWhenScanBudgetIsReached() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let deep = root.appendingPathComponent("many-files")
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    for index in 0..<30 {
      try Data([1]).write(to: deep.appendingPathComponent("\(index).txt"))
    }
    try Data(repeating: 2, count: 32_768).write(to: root.appendingPathComponent("large.mov"))
    let result = CleanupReviewScanner.scan(
      ReviewScanRequest(roots: [root.path], minimumBytes: 16_384, maxEntries: 8))
    #expect(result.files.map(\.name) == ["large.mov"])
    #expect(result.limited)
  }

  @Test
  func openFileIsProtectedAndClosedFixtureDeletionCreatesMeasurement() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("disposable-test-file.mov")
    try Data(repeating: 1, count: 65_536).write(to: url)
    let file = try #require(ReviewFile.read(url.path))
    let handle = try FileHandle(forReadingFrom: url)
    #expect(throws: ReviewDeleteError.self) {
      try ReviewFileDeletion.delete(ReviewDeleteRequest(file: file, roots: [root.path]))
    }
    #expect(FileManager.default.fileExists(atPath: url.path))
    try handle.close()
    let result = try ReviewFileDeletion.delete(ReviewDeleteRequest(file: file, roots: [root.path]))
    #expect(result.paths == [url.path])
    #expect(result.before != nil)
    #expect(result.after != nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  private func fixture() throws -> URL {
    let temporary = try #require(
      ReviewFile.canonicalPath(FileManager.default.temporaryDirectory.path))
    let root = URL(fileURLWithPath: temporary)
      .appendingPathComponent("blitzclean-review-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test
  func dependencyDeletionRechecksCurrentProjectActivityAndLockfile() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let node = root.appendingPathComponent("node_modules")
    try FileManager.default.createDirectory(at: node, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))
    let lock = root.appendingPathComponent("pnpm-lock.yaml")
    try Data().write(to: lock)
    let item = StorageItem(
      name: "Fixture", path: node.path, bytes: 1, cleanupKind: .nodeModules,
      cleanupAvailability: .ready, lastActivityAt: nil, contentBytes: nil, nodeOrigin: .project,
      projectRootPath: root.path, dependencyInstalledAt: nil, activeProcesses: [])
    #expect(CleanupActivity.revalidate(item) == .ready)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    process.currentDirectoryURL = root
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }
    #expect(CleanupActivity.revalidate(item) == .blocked("Project is in use"))
    process.terminate()
    process.waitUntilExit()
    try FileManager.default.removeItem(at: lock)
    #expect(CleanupActivity.revalidate(item) == .blocked("No exact reinstall lock"))
    #expect(FileManager.default.fileExists(atPath: node.path))
  }

  private func win(_ input: WinFixture) -> CleanupWin {
    let path = input.internalDisk ? "/System/Volumes/Data" : "/Volumes/External"
    return CleanupWin(
      id: input.id, date: Date(timeIntervalSince1970: 1_700_000_000), title: "Fixture",
      paths: ["/fixture"],
      before: CleanupVolume(path: path, available: input.before, isInternal: input.internalDisk),
      after: CleanupVolume(path: path, available: input.after, isInternal: input.internalDisk))
  }
}

private struct WinFixture {
  let id: String
  let before: UInt64
  let after: UInt64
  let internalDisk: Bool
}
