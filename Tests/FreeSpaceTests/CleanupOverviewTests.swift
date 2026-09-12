import AppKit
import Foundation
import Testing

@testable import FreeSpace

@MainActor
struct CleanupOverviewTests {
  @Test func explicitReopenRequestsTheWorkspaceWindow() {
    let delegate = AppDelegate()
    #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
  }

  @Test func explicitWindowRequestIsConsumedOnlyOnce() {
    var background = InitialWindowRequest(["FreeSpace", "--background"])
    #expect(background.consume() == nil)
    var storage = InitialWindowRequest(["FreeSpace", "--storage"])
    #expect(storage.consume() == "storage-breakdown")
    #expect(storage.consume() == nil)
    var memory = InitialWindowRequest(["FreeSpace", "--memory-rescue"])
    #expect(memory.consume() == "memory-rescue")
    #expect(memory.consume() == nil)
    var workspace = InitialWindowRequest(["Buildkeep", "--workspace"])
    #expect(workspace.consume() == "workspace")
    #expect(workspace.consume() == nil)
  }

  @Test func cancelledScanCannotReplaceANewFolderSelection() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let other = fixture.root.appendingPathComponent("chosen-folder")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let selected = other.appendingPathComponent("chosen.bin")
    try Data(repeating: 1, count: 16_384).write(to: selected)
    let model = CleanupOverviewModel(fixture.configuration)
    model.refresh()
    model.cancelScan()
    #expect(!model.isScanning)
    #expect(model.scanStatus != nil)
    model.configureReview(.init(roots: [other.path], minimumBytes: 1, maxEntries: 100))
    try await waitForCompletion(model)
    #expect(model.files.map(\.path) == [selected.path])
    #expect(model.reviewRoots == [other.path])
  }

  @Test func confirmedDeletionRemovesTheRealFileAndRecordsSuccess() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = CleanupOverviewModel(fixture.configuration)
    model.applyScan(CleanupReviewScanner.scan(fixture.configuration.scanRequest))
    let file = try #require(model.files.first)
    model.delete(file)
    #expect(model.deletingPath == file.path)
    try await waitForCompletion(model)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(!model.files.contains { $0.path == file.path })
    #expect(model.deletionFailure == nil)
    #expect(model.ledger.wins.count == 1)
    #expect(model.message?.contains("Deleted") == true)
  }

  @Test func openFileStaysVisibleWithAnActionableRowError() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = CleanupOverviewModel(fixture.configuration)
    model.applyScan(CleanupReviewScanner.scan(fixture.configuration.scanRequest))
    let file = try #require(model.files.first)
    let handle = try FileHandle(forReadingFrom: fixture.file)
    defer { try? handle.close() }
    model.delete(file)
    try await waitForCompletion(model)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(model.files.contains { $0.path == file.path })
    #expect(model.deletionFailure?.path == file.path)
    #expect(model.deletionFailure?.message.contains("Close the file") == true)
    #expect(model.ledger.wins.isEmpty)
  }

  @Test func anotherConfirmedFileIsDeletedWithoutWaitingForTheFirst() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = try #require(ReviewFile.read(fixture.file.path))
    let second = try additionalFile(fixture)
    let model = CleanupOverviewModel(fixture.configuration)
    model.applyScan(CleanupReviewScanner.scan(fixture.configuration.scanRequest))
    let scannedAt = model.scannedAt
    model.delete(first)
    model.delete(second)
    #expect(model.deletingPath == first.path)
    #expect(model.queuedFiles.map(\.path) == [second.path])
    try await waitForCompletion(model)
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(!FileManager.default.fileExists(atPath: second.path))
    #expect(Set(model.ledger.wins.flatMap(\.paths)) == [first.path, second.path])
    #expect(model.scannedAt == scannedAt)
    #expect(model.queuedFiles.isEmpty)
  }

  @Test func aFailedFileDoesNotStopTheQueueOrLoseItsRowError() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = try #require(ReviewFile.read(fixture.file.path))
    let second = try additionalFile(fixture)
    let handle = try FileHandle(forReadingFrom: fixture.file)
    defer { try? handle.close() }
    let model = CleanupOverviewModel(fixture.configuration)
    model.applyScan(CleanupReviewScanner.scan(fixture.configuration.scanRequest))
    model.delete(first)
    model.delete(second)
    try await waitForCompletion(model)
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(!FileManager.default.fileExists(atPath: second.path))
    #expect(model.files.contains { $0.path == first.path })
    #expect(model.deletionFailures[first.path]?.contains("Close the file") == true)
    #expect(model.message?.contains("Deleted \(second.name)") == true)
    #expect(model.ledger.wins.flatMap(\.paths) == [second.path])
    try handle.close()
    model.delete(first)
    #expect(model.deletionFailures[first.path] == nil)
    try await waitForCompletion(model)
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(model.ledger.wins.count == 2)
  }

  @Test func changedQueuedFilesAreCheckedAgainBeforeDeletion() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = try #require(ReviewFile.read(fixture.file.path))
    let second = try additionalFile(fixture)
    let model = CleanupOverviewModel(fixture.configuration)
    model.applyScan(CleanupReviewScanner.scan(fixture.configuration.scanRequest))
    model.delete(first)
    model.delete(second)
    let changed = Data(repeating: 11, count: 32_768)
    try changed.write(to: URL(fileURLWithPath: second.path), options: .atomic)
    try await waitForCompletion(model)
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(try Data(contentsOf: URL(fileURLWithPath: second.path)) == changed)
    #expect(model.deletionFailures[second.path] != nil)
    #expect(model.ledger.wins.flatMap(\.paths) == [first.path])
  }

  @Test func duplicateRequestsDoNotRepeatADeletion() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = try #require(ReviewFile.read(fixture.file.path))
    let second = try additionalFile(fixture)
    let model = CleanupOverviewModel(fixture.configuration)
    model.delete(first)
    model.delete(first)
    model.delete(second)
    model.delete(second)
    #expect(model.queuedFiles.map(\.path) == [second.path])
    try await waitForCompletion(model)
    #expect(model.ledger.wins.count == 2)
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(!FileManager.default.fileExists(atPath: second.path))
    #expect(model.message?.contains("Deleted \(second.name)") == true)
  }

  @Test func cancelOnlyRemovesWaitingFiles() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = try #require(ReviewFile.read(fixture.file.path))
    let second = try additionalFile(fixture)
    let model = CleanupOverviewModel(fixture.configuration)
    model.delete(first)
    model.delete(second)
    model.cancelQueuedDeletion(first)
    model.cancelQueuedDeletion(second)
    #expect(model.deletingPath == first.path)
    #expect(model.queuedFiles.isEmpty)
    try await waitForCompletion(model)
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
    #expect(model.ledger.wins.flatMap(\.paths) == [first.path])
  }

  @Test func filesCanRefreshDuringDeletion() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = CleanupOverviewModel(fixture.configuration)
    let file = try #require(ReviewFile.read(fixture.file.path))
    model.delete(file)
    model.refresh()
    #expect(model.isScanning)
    try await waitForCompletion(model)
    #expect(!model.files.contains { $0.path == file.path })
  }

  @Test func alreadyRemovedFileDoesNotReportAFailedDeletion() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = CleanupOverviewModel(fixture.configuration)
    model.applyScan(CleanupReviewScanner.scan(fixture.configuration.scanRequest))
    let file = try #require(model.files.first)
    try FileManager.default.removeItem(at: fixture.file)
    model.delete(file)
    try await waitForCompletion(model)
    #expect(model.deletionFailure == nil)
    #expect(!model.files.contains { $0.path == file.path })
    #expect(model.ledger.wins.isEmpty)
    #expect(model.message?.contains("already gone") == true)
  }

  @Test func unreadableHistoryIsPreservedWhenRecordingAWin() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = CleanupOverviewModel(fixture.configuration)
    let invalid = Data("incomplete write".utf8)
    try invalid.write(to: fixture.configuration.store.url)
    model.record(win("local"))
    #expect(try Data(contentsOf: fixture.configuration.store.url) == invalid)
    #expect(model.historyError != nil)
    #expect(model.ledger.wins.map(\.id) == ["local"])
  }

  @Test func backgroundSynchronizationUpdatesHistoryAndDeletedRows() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = CleanupOverviewModel(
      CleanupOverviewConfiguration(
        store: fixture.configuration.store, scanRequest: fixture.configuration.scanRequest,
        synchronizesInBackground: true))
    model.applyScan(CleanupReviewScanner.scan(fixture.configuration.scanRequest))
    var ledger = CleanupLedger()
    ledger.record(win("background-import"))
    try fixture.configuration.store.save(ledger)
    try FileManager.default.removeItem(at: fixture.file)
    let deadline = ContinuousClock.now + .seconds(5)
    while model.ledger.wins.isEmpty || model.files.contains(where: { $0.path == fixture.file.path })
    {
      try #require(
        ContinuousClock.now < deadline, "Background refresh should not require a window or restart")
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(model.ledger.wins.map(\.id) == ["background-import"])
  }

  private func waitForCompletion(_ model: CleanupOverviewModel) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while model.deletingPath != nil || !model.queuedFiles.isEmpty || model.isScanning {
      try #require(ContinuousClock.now < deadline, "Deletion should not remain stuck")
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test func deletedFileCannotReturnFromAnOlderScan() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = CleanupOverviewModel(fixture.configuration)
    let scan = CleanupReviewScanner.scan(fixture.configuration.scanRequest)
    #expect(scan.files.count == 1)
    try FileManager.default.removeItem(at: fixture.file)
    model.applyScan(scan)
    #expect(model.files.isEmpty)
  }

  @Test func removedFileDisappearsBeforeTheNextFullScan() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = CleanupOverviewModel(fixture.configuration)
    model.applyScan(CleanupReviewScanner.scan(fixture.configuration.scanRequest))
    try FileManager.default.removeItem(at: fixture.file)
    model.refreshIfNeeded()
    #expect(model.files.isEmpty)
    #expect(!model.isScanning)
  }

  @Test func historyRefreshesWithoutRestartingTheApp() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = CleanupOverviewModel(fixture.configuration)
    model.applyScan(CleanupReviewScanner.scan(fixture.configuration.scanRequest))
    var ledger = CleanupLedger()
    ledger.record(win("external"))
    try fixture.configuration.store.save(ledger)
    model.refreshIfNeeded()
    #expect(model.ledger.wins.map(\.id) == ["external"])
  }

  @Test func recordingADeletionPreservesExternallyImportedWins() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = CleanupOverviewModel(fixture.configuration)
    var ledger = CleanupLedger()
    ledger.record(win("external"))
    try fixture.configuration.store.save(ledger)
    model.record(win("local"))
    let saved = try fixture.configuration.store.load()
    #expect(Set(saved.wins.map(\.id)) == ["external", "local"])
  }

  private func fixture() throws -> OverviewFixture {
    let temporary = try #require(
      ReviewFile.canonicalPath(FileManager.default.temporaryDirectory.path))
    let root = URL(fileURLWithPath: temporary)
      .appendingPathComponent("freespace-overview-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("disposable-video.mov")
    try Data(repeating: 7, count: 16_384).write(to: file)
    return OverviewFixture(
      root: root, file: file,
      configuration: CleanupOverviewConfiguration(
        store: CleanupHistoryStore(url: root.appendingPathComponent("history.json")),
        scanRequest: ReviewScanRequest(roots: [root.path], minimumBytes: 1, maxEntries: 100),
        synchronizesInBackground: false))
  }

  private func additionalFile(_ fixture: OverviewFixture) throws -> ReviewFile {
    let url = fixture.root.appendingPathComponent("second-video.mov")
    try Data(repeating: 9, count: 16_384).write(to: url)
    return try #require(ReviewFile.read(url.path))
  }

  private func win(_ id: String) -> CleanupWin {
    CleanupWin(id: id, date: .now, title: id, paths: ["/fixture"], before: nil, after: nil)
  }
}

private struct OverviewFixture {
  let root: URL
  let file: URL
  let configuration: CleanupOverviewConfiguration
}
