import Foundation
import Testing

@testable import BlitzClean

struct FolderExplorerCacheTests {
  @Test @MainActor func refreshKeepsMeasuredSizesAndSelectionVisible() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = fixture.model()
    model.open(fixture.root.path)
    try await waitFor { !model.isScanning }
    let measured = try #require(model.entries.first)
    #expect(measured.bytes == 8_192)
    model.selected = [fixture.child.path]
    model.rescan()
    #expect(model.entries.first?.bytes == measured.bytes)
    #expect(model.scannedAt != nil)
    #expect(model.selected == [fixture.child.path])
    model.cancelScan()
  }

  @Test @MainActor func expiredSizesAppearImmediatelyThenUpdateAndSurviveRelaunch() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.save((bytes: 32_768, complete: true, date: .now.addingTimeInterval(-600)))
    let model = fixture.model()
    model.open(fixture.root.path)
    #expect(model.entries.first?.bytes == 32_768)
    #expect(model.isScanning)
    try await waitFor { !model.isScanning }
    #expect(model.entries.first?.bytes == 8_192)
    let reopened = fixture.model()
    reopened.open(fixture.root.path)
    #expect(reopened.entries.first?.bytes == 8_192)
    #expect(!reopened.isScanning)
  }

  @Test @MainActor func backgroundProgressKeepsBarsStableUntilFinalSizesArrive() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.save((bytes: 32_768, complete: true, date: .now))
    let gate = ScanGate()
    defer { gate.release() }
    let childPath = fixture.child.path
    let model = fixture.model { request in
      request.progress(
        Self.progress((path: childPath, bytes: 4_096, complete: false, unreadable: 0)))
      gate.wait()
      return Self.progress((path: childPath, bytes: 16_384, complete: true, unreadable: 0))
    }
    model.open(fixture.root.path)
    model.rescan()
    try await waitFor { model.visited == 1 }
    #expect(model.entries.first?.bytes == 32_768)
    #expect(model.maxBytes == 32_768)
    #expect(model.entries.first?.sizeEstimate == .previous)
    gate.release()
    try await waitFor { !model.isScanning }
    #expect(model.entries.first?.bytes == 16_384)
    #expect(model.entries.first?.sizeEstimate == nil)
  }

  @Test @MainActor func interruptedFirstScanIsCachedAcrossNavigationAndRelaunch() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let gate = ScanGate()
    defer { gate.release() }
    let childPath = fixture.child.path
    let rootPath = fixture.root.path
    let model = fixture.model { request in
      guard request.roots == [rootPath] else { return DriveFileScanner.scan(request) }
      request.progress(
        Self.progress((path: childPath, bytes: 4_096, complete: false, unreadable: 0)))
      gate.wait()
      return Self.progress((path: childPath, bytes: 16_384, complete: true, unreadable: 0))
    }
    model.open(rootPath)
    try await waitFor { model.visited == 1 }
    #expect(model.entries.first?.bytes == 4_096)
    model.open(childPath)
    try await waitFor { !model.isScanning }
    #expect(model.entries.first?.name == "clip.mov")
    #expect(model.cachedListing(rootPath)?.entries.first?.bytes == 4_096)
    #expect(model.cachedListing(rootPath)?.complete == false)
    gate.release()
    try await Task.sleep(for: .milliseconds(40))
    #expect(model.entries.first?.name == "clip.mov")
    model.goBack()
    #expect(model.entries.first?.name == "Videos")
    #expect(model.entries.first?.bytes == 4_096)
    #expect(model.isScanning)
    model.cancelScan()
    let reopened = fixture.model()
    reopened.open(rootPath)
    #expect(reopened.entries.first?.bytes == 4_096)
    #expect(reopened.isScanning)
    reopened.cancelScan()
  }

  @Test @MainActor func unreadableResultsAreCachedAsMinimums() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let childPath = fixture.child.path
    let model = fixture.model { _ in
      Self.progress((path: childPath, bytes: 4_096, complete: true, unreadable: 1))
    }
    model.open(fixture.root.path)
    try await waitFor { !model.isScanning }
    #expect(model.entries.first?.sizeEstimate == .minimum)
    let reopened = fixture.model()
    reopened.open(fixture.root.path)
    #expect(reopened.entries.first?.bytes == 4_096)
    #expect(reopened.entries.first?.sizeEstimate == .minimum)
    #expect(!reopened.isScanning)
  }

  @Test @MainActor func changedFolderIdentityCannotInheritAnOldSize() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.save((bytes: 32_768, complete: true, date: .now.addingTimeInterval(-600)))
    try FileManager.default.moveItem(
      at: fixture.child, to: fixture.root.appendingPathComponent("Original"))
    try FileManager.default.createDirectory(at: fixture.child, withIntermediateDirectories: true)
    let gate = ScanGate()
    defer { gate.release() }
    let model = fixture.model { request in
      request.progress(Self.progress((path: "", bytes: 0, complete: false, unreadable: 0)))
      gate.wait()
      return DriveFileScanner.scan(request)
    }
    model.open(fixture.root.path)
    try await waitFor { model.visited == 1 }
    #expect(model.entries.first { $0.name == "Videos" }?.bytes == nil)
    #expect(model.entries.contains { $0.name == "Original" })
    gate.release()
    try await waitFor { !model.isScanning }
    #expect(model.entries.first { $0.name == "Videos" }?.bytes == 0)
    #expect(model.entries.first { $0.name == "Original" }?.bytes == 8_192)
  }

  @Test func legacyCacheDecodesAndRetentionIsBounded() throws {
    let data = Data(
      #"{"path":"/fixture","scannedAt":0,"entries":[{"path":"/fixture/file","name":"file","isDirectory":false,"isHidden":false,"bytes":4096,"device":1,"inode":1}]}"#
        .utf8)
    let legacy = try JSONDecoder().decode(FolderListing.self, from: data)
    #expect(legacy.complete)
    #expect(legacy.entries.first?.sizeEstimate == nil)
    var listings: [String: FolderListing] = [:]
    for index in 0..<80 {
      let path = "/fixture/\(index)"
      listings[path] = FolderListing(
        .init(
          path: path, scannedAt: Date(timeIntervalSince1970: Double(index)), entries: [],
          complete: true))
    }
    let bounded = FolderSizeCache.bounded(listings)
    #expect(bounded.count == 60)
    #expect(bounded["/fixture/0"] == nil)
    #expect(bounded["/fixture/79"] != nil)
  }

  @Test @MainActor func unavailableFolderDoesNotEraseSavedSizes() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.save((bytes: 32_768, complete: true, date: .now.addingTimeInterval(-600)))
    try FileManager.default.removeItem(at: fixture.root)
    let model = fixture.model()
    model.open(fixture.root.path)
    try await waitFor { !model.isScanning }
    #expect(model.entries.first?.bytes == 32_768)
    #expect(model.statusMessage == "Folder unavailable. Showing saved sizes.")
    #expect(model.cachedListing(fixture.root.path)?.entries.first?.bytes == 32_768)
    #expect(model.cachedListing(fixture.root.path)?.complete == false)
  }

  @MainActor private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<250 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(condition())
  }

  private static func progress(
    _ input: (path: String, bytes: UInt64, complete: Bool, unreadable: Int)
  ) -> DriveScanProgress {
    .init(
      files: [], folderBytes: [input.path: input.bytes], visited: 1, unreadable: input.unreadable,
      unreadablePaths: [], currentPath: input.path, complete: input.complete, elapsed: 1)
  }

  @MainActor private struct Fixture {
    let root: URL
    let child: URL
    let suite: String
    let store: FolderSizeCache

    init() throws {
      suite = "BlitzClean-cache-test-\(UUID())"
      store = FolderSizeCache(defaults: try #require(UserDefaults(suiteName: suite)))
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(suite)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      root = URL(fileURLWithPath: try #require(ReviewFile.canonicalPath(directory.path)))
      child = root.appendingPathComponent("Videos")
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
      try Data(repeating: 1, count: 8_192).write(to: child.appendingPathComponent("clip.mov"))
    }

    func model(
      _ scan: @escaping @Sendable (DriveFileScanner.Request) -> DriveScanProgress = DriveFileScanner
        .scan
    ) -> FolderExplorerModel {
      .init(.init(path: root.path, cacheStore: store, scan: scan))
    }

    func save(_ input: (bytes: UInt64, complete: Bool, date: Date)) throws {
      var entries = try FolderSizeScanner().listing(of: root.path)
      entries[0].bytes = input.bytes
      store.save([
        root.path: FolderListing(
          .init(path: root.path, scannedAt: input.date, entries: entries, complete: input.complete))
      ])
    }

    func remove() {
      store.defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }

  private final class ScanGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false

    func wait() {
      condition.lock()
      defer { condition.unlock() }
      let deadline = Date.now.addingTimeInterval(5)
      while !released {
        if !condition.wait(until: deadline) { return }
      }
    }

    func release() {
      condition.lock()
      released = true
      condition.broadcast()
      condition.unlock()
    }
  }
}
