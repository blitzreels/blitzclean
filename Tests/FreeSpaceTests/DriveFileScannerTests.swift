import Foundation
import Testing

@testable import FreeSpace

struct DriveFileScannerTests {
  @Test @MainActor func homeFilesCanBeSelectedWithoutAllowingHomeRootsToBeTrashed() {
    let model = FolderExplorerModel()
    func entry(_ input: (name: String, directory: Bool)) -> FolderEntry {
      FolderEntry(
        path: model.homePath + "/" + input.name, name: input.name, isDirectory: input.directory,
        isHidden: input.name.hasPrefix("."), bytes: 4_096, device: 1, inode: 1)
    }
    #expect(model.canTrash(entry((name: "recording.mov", directory: false))))
    #expect(model.canTrash(entry((name: "Old exports", directory: true))))
    #expect(!model.canTrash(entry((name: "Downloads", directory: true))))
    #expect(!model.canTrash(entry((name: "Library", directory: true))))
    #expect(!model.canTrash(entry((name: ".ssh", directory: true))))
  }

  @Test func systemFilesStayViewOnlyAcrossDataAliases() {
    for path in [
      "/System/kernel", "/Library/cache", "/System/Volumes/Data/Library/cache",
      "/Users/me/Applications/Test.app/Contents/data", "/Volumes/Backup/Test.app/data",
    ] {
      #expect(!ReviewFileDeletion.canTrashPath(path))
    }
    #expect(ReviewFileDeletion.canTrashPath("/System/Volumes/Data/Users/me/Movies/video.mov"))
    #expect(ReviewFileDeletion.canTrashPath("/Volumes/External/Movies/video.mov"))
  }

  private func fixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("BlitzClean-drive-test-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func recursiveScanIncludesHiddenPackagesDependenciesAndMultipleRoots() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let names = [
      "first/.cache/video.mov", "first/node_modules/asset.mp4",
      "second/Editor.app/Contents/data.bin", "second/a/b/c/d/e/photo.png",
    ]
    for name in names {
      let url = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 1, count: 4_096).write(to: url)
    }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("first/loop"), withDestinationURL: root)
    let result = DriveFileScanner.scan(
      .init(
        roots: [
          root.appendingPathComponent("first").path, root.appendingPathComponent("second").path,
        ],
        minimumBytes: 1, resultLimit: 5_000, progress: { _ in }))
    #expect(result.files.count == 4)
    #expect(result.visited == 4)
    #expect(result.unreadable == 0)
    #expect(result.complete)
    let hidden = try #require(
      ReviewFile.canonicalPath(root.appendingPathComponent("first/.cache").path))
    let package = try #require(
      ReviewFile.canonicalPath(root.appendingPathComponent("second/Editor.app").path))
    #expect(result.folderBytes[hidden] == 4_096)
    #expect(result.folderBytes[package] == 4_096)
    for file in result.files { #expect(file.currentVersion?.matchesIdentity(file) == true) }
  }

  @Test func boundedHeapKeepsLargestFilesInsteadOfFirstFiles() {
    var heap = LargestFileHeap(capacity: 5)
    for index in 0..<10_000 {
      heap.insert(
        .init(
          path: "/fixture/\(index)", bytes: UInt64(index), modifiedAt: .distantPast,
          device: 1, inode: UInt64(index), logicalBytes: Int64(index), modifiedNanoseconds: 0))
    }
    #expect(heap.files.count == 5)
    #expect(heap.sorted.map(\.bytes) == [9_999, 9_998, 9_997, 9_996, 9_995])
  }

  @Test func missingDriveReportsFailureAlongsideAccessibleResults() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 1, count: 4_096).write(to: root.appendingPathComponent("file.mov"))
    let missing = root.appendingPathComponent("disconnected").path
    let result = DriveFileScanner.scan(
      .init(roots: [missing, root.path], minimumBytes: 0, resultLimit: 100, progress: { _ in }))
    #expect(result.files.count == 1)
    #expect(result.unreadable == 1)
    #expect(result.unreadablePaths == [missing])
  }

  @Test func cancellationReturnsAlreadyFoundFiles() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<3_000 {
      try Data([1]).write(to: root.appendingPathComponent("\(index).bin"))
    }
    let worker = Task.detached {
      DriveFileScanner.scan(
        .init(
          roots: [root.path], minimumBytes: 0, resultLimit: 5_000,
          progress: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
          }))
    }
    let result = await worker.value
    let complete = result.complete
    let count = result.files.count
    #expect(!complete)
    #expect(count > 0)
    #expect(count < 3_000)
  }

  @Test func legacyRequestsDecodeWithoutLosingFilters() throws {
    let data = Data(#"{"roots":["/tmp"],"minimumBytes":10,"maxEntries":100}"#.utf8)
    let request = try JSONDecoder().decode(ReviewScanRequest.self, from: data)
    #expect(!request.entireHierarchy)
    #expect(request.roots == ["/tmp"])
  }

  @Test @MainActor func directoryBrowserListsFilesAndMeasuresChildFolders() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let child = root.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 8_192).write(to: child.appendingPathComponent("video.mov"))
    let model = FolderExplorerModel(path: root.path)
    model.open(root.path)
    for _ in 0..<250 where model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
    #expect(model.entries.first?.isDirectory == true)
    #expect(model.entries.first?.bytes == 8_192)
    model.open(child.path)
    for _ in 0..<250 where model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
    #expect(model.entries.map(\.name) == ["video.mov"])
    #expect(model.entries.first?.bytes == 8_192)
    #expect(model.entries.first?.inode != nil)
    model.goUp()
    #expect(model.path == ReviewFile.canonicalPath(root.path))
    #expect(model.entries.first?.name == "child")
    model.goBack()
    #expect(model.path == ReviewFile.canonicalPath(child.path))
    model.goForward()
    #expect(model.path == ReviewFile.canonicalPath(root.path))
    #expect(model.forwardPaths.isEmpty)
    model.goBack()
    model.open(root.path)
    #expect(model.forwardPaths.isEmpty)
    model.cancelScan()
  }

  @Test @MainActor func emptySavedScanDoesNotPreventRefresh() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 1, count: 4_096).write(to: root.appendingPathComponent("file.mov"))
    let model = CleanupOverviewModel(
      .init(
        store: .init(url: root.appendingPathComponent("history.json")),
        scanRequest: .init(
          roots: [root.path], minimumBytes: 1, maxEntries: 10, entireHierarchy: true),
        synchronizesInBackground: false))
    model.applyScan(.init(files: [], limited: true))
    model.refreshIfNeeded()
    #expect(model.isScanning)
    for _ in 0..<100 where model.isScanning { try await Task.sleep(for: .milliseconds(50)) }
    #expect(model.files.contains { $0.name == "file.mov" })
    #expect(model.driveProgress?.complete == true)
  }
}
