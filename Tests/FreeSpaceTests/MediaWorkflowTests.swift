import Foundation
import Testing

@testable import FreeSpace

struct MediaWorkflowTests {
  struct Fixture {
    let root: URL
    let files: [ReviewFile]
  }

  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("media-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["original.mp4", "copy.mov", "different.mp4", "image.png"] {
      try Data(repeating: name == "different.mp4" ? 2 : 1, count: 4096)
        .write(to: root.appendingPathComponent(name))
    }
    return .init(
      root: root,
      files: ["original.mp4", "copy.mov", "different.mp4", "image.png"].compactMap {
        ReviewFile.read(root.appendingPathComponent($0).path)
      })
  }

  @Test func comparesContentsRatherThanNamesOrSizes() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let result = MediaDuplicateScanner.scan(fixture.files)
    #expect(result.groups.count == 1)
    #expect(
      Set(result.groups.first?.files.map(\.name) ?? []) == [
        "original.mp4", "copy.mov", "image.png",
      ])
    #expect(result.skipped == 0)
    #expect(!result.limited)
  }

  @Test func excludesHardLinksAndChangedSnapshots() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let original = try #require(fixture.files.first)
    let link = fixture.root.appendingPathComponent("hardlink.mp4")
    try FileManager.default.linkItem(atPath: original.path, toPath: link.path)
    let linked = try #require(ReviewFile.read(link.path))
    #expect(MediaDuplicateScanner.scan([original, linked]).groups.isEmpty)
    try Data(repeating: 8, count: 8192).write(to: URL(fileURLWithPath: original.path))
    #expect(throws: ReviewDeleteError.self) {
      try MediaDuplicateScanner.digest(.init(file: original, deadline: .now.addingTimeInterval(5)))
    }
  }

  @Test func filtersTypeExtensionAgeAndPathThenSorts() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let old = fixture.root.appendingPathComponent("original.mp4")
    try FileManager.default.setAttributes(
      [.modificationDate: Date.now.addingTimeInterval(-100 * 86_400)],
      ofItemAtPath: old.path)
    let files = fixture.files.compactMap(\.currentVersion)
    var filter = MediaReviewFilter()
    filter.kind = .video
    filter.format = "mp4"
    filter.age = .quarter
    filter.query = "ORIGINAL"
    filter.sort = .oldest
    #expect(filter.apply(.init(files: files, date: .now)).map(\.name) == ["original.mp4"])
    filter.kind = .image
    #expect(filter.apply(.init(files: files, date: .now)).isEmpty)
  }

  @Test @MainActor func scanAndLatestFiltersSurviveRelaunchAndMissingFilesArePruned() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let configuration = CleanupOverviewConfiguration(
      store: CleanupHistoryStore(url: fixture.root.appendingPathComponent("history.json")),
      scanRequest: .init(roots: [fixture.root.path], minimumBytes: 0, maxEntries: 100),
      synchronizesInBackground: false)
    let first = CleanupOverviewModel(configuration)
    first.applyScan(.init(files: fixture.files, limited: true))
    first.mediaFilter.kind = .video
    first.mediaFilter.age = .month
    first.mediaFilter.query = "recording"
    let next = CleanupOverviewModel(configuration)
    #expect(next.files == fixture.files)
    #expect(next.reviewMinimumBytes == 0)
    #expect(next.reviewRoots == [fixture.root.path])
    #expect(next.scannedAt == first.scannedAt)
    #expect(next.scanLimited)
    #expect(next.mediaFilter == first.mediaFilter)
    try FileManager.default.removeItem(atPath: fixture.files[0].path)
    next.synchronize()
    #expect(next.files.count == fixture.files.count - 1)
    #expect(CleanupOverviewModel(configuration).files == next.files)
  }

  @Test func resourceHistorySurvivesRelaunchAndDropsWeekOldSamples() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = ResourceHistoryStore(url: fixture.root.appendingPathComponent("resources.json"))
    let now = Date.now
    let samples = (0..<500).map { index in
      ResourceSample(date: now.addingTimeInterval(Double(index - 500)), cpu: 0.5, memory: 0.7)
    }
    try store.save(samples)
    #expect(try store.load().count == 451)
    #expect(try Data(contentsOf: store.url).count < ResourceHistoryStore.maximumBytes)
    try store.save([
      .init(date: now.addingTimeInterval(-8 * 86_400), cpu: 0.1, memory: 0.2),
      .init(date: now.addingTimeInterval(-2 * 86_400), cpu: nil, memory: 0.4),
      .init(date: now.addingTimeInterval(60), cpu: 0.3, memory: 0.6), samples.last!,
    ])
    #expect(try store.load().count == 2)
    #expect(try store.load().first?.date == now.addingTimeInterval(-2 * 86_400))
  }

  @Test func weekOfMetricsStaysWithinLocalHistoryBudget() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date.now
    let older = (0..<3_000).map { index in
      ResourceSample(
        date: now.addingTimeInterval(-7 * 86_400 + 3_600 + Double(index * 198)),
        cpu: 0.3, memory: 0.6)
    }
    let recent = (0..<450).map { index in
      ResourceSample(date: now.addingTimeInterval(Double(index * 2 - 900)), cpu: nil, memory: 0.7)
    }
    var history = ResourceHistory.persisted
    history.restore(older + recent)
    #expect(history.samples.count < 2_500)
    #expect(history.samples.first!.date < now.addingTimeInterval(-6 * 86_400))
    #expect(history.samples.last == recent.last)
    let store = ResourceHistoryStore(url: fixture.root.appendingPathComponent("resources.json"))
    try store.save(history.samples)
    #expect(try store.load() == history.samples)
    #expect(try Data(contentsOf: store.url).count < ResourceHistoryStore.maximumBytes)
  }

  @Test func damagedResourceHistoryDoesNotLookLikeAnEmptySuccessfulLoad() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = ResourceHistoryStore(url: fixture.root.appendingPathComponent("resources.json"))
    try Data("broken".utf8).write(to: store.url)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(!FileManager.default.fileExists(atPath: store.url.path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains {
        $0.hasPrefix("resources.json.unreadable-")
      })
  }

  @Test func corruptReviewDoesNotBecomeAnEmptySuccessfulScan() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = MediaReviewStore(url: fixture.root.appendingPathComponent("broken.json"))
    try Data("incomplete".utf8).write(to: store.url)
    #expect(throws: (any Error).self) { try store.load() }
  }
}

@Suite(.serialized)
struct MediaExportTests {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("BlitzClean media ' \(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  struct Generate {
    let root: URL
    let name: String
    let size: String
  }

  private func generate(_ input: Generate) throws -> ReviewFile {
    let ffmpeg = try #require(MediaExportEngine.executable("ffmpeg"))
    let url = input.root.appendingPathComponent(input.name)
    _ = try MediaProcess.run(
      .init(
        executable: ffmpeg,
        arguments: [
          "-v", "error", "-nostdin", "-f", "lavfi", "-i", "testsrc2=size=\(input.size):rate=24",
          "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1", "-c:v", "mjpeg",
          "-q:v", "2", "-threads", "2", "-c:a", "pcm_s16le", url.path,
        ],
        directory: input.root, timeout: 20, diskGuard: nil))
    return try #require(ReviewFile.read(url.path))
  }

  @Test func optimizesAndJoinsRealVideosWithoutChangingOriginals() throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try generate(.init(root: root, name: "first ' clip.mov", size: "160x96"))
    let second = try generate(.init(root: root, name: "second.mov", size: "160x96"))
    let originals = try [first, second].map { try Data(contentsOf: URL(fileURLWithPath: $0.path)) }
    let compact = try MediaExportEngine.run(
      .init(files: [first], roots: [root.path], destination: root, kind: .video))
    let compactProbe = try MediaExportEngine.probe(URL(fileURLWithPath: compact.output))
    #expect(compact.outputBytes < compact.inputBytes)
    #expect(compactProbe.video?.width == 160)
    #expect(compactProbe.video?.height == 96)
    #expect(compactProbe.audioCount == 1)
    #expect(abs((compactProbe.duration ?? 0) - 1) < 0.1)
    let joined = try MediaExportEngine.run(
      .init(files: [second, first], roots: [root.path], destination: root, kind: .join))
    let joinedProbe = try MediaExportEngine.probe(URL(fileURLWithPath: joined.output))
    #expect(abs((joinedProbe.duration ?? 0) - 2) < 0.1)
    #expect(joinedProbe.video?.codecName == "mjpeg")
    #expect(joinedProbe.audioCount == 1)
    #expect(
      try [first, second].map { try Data(contentsOf: URL(fileURLWithPath: $0.path)) } == originals)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(!remaining.contains { $0.hasPrefix(".blitzclean-export-") })
  }

  @Test func rejectsIncompatibleJoiningAndOpenInputs() throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try generate(.init(root: root, name: "first.mov", size: "160x96"))
    let second = try generate(.init(root: root, name: "second.mov", size: "192x108"))
    #expect(throws: MediaOperationError.self) {
      try MediaExportEngine.run(
        .init(files: [first, second], roots: [root.path], destination: root, kind: .join))
    }
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: first.path))
    defer { try? handle.close() }
    #expect(throws: MediaOperationError.self) {
      try MediaExportEngine.run(
        .init(files: [first], roots: [root.path], destination: root, kind: .video))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
  }

  @Test func preservesTransparencyAndRejectsLossyFlattening() throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let ffmpeg = try #require(MediaExportEngine.executable("ffmpeg"))
    let url = root.appendingPathComponent("alpha.png")
    _ = try MediaProcess.run(
      .init(
        executable: ffmpeg,
        arguments: [
          "-v", "error", "-f", "lavfi", "-i", "color=red@0.4:size=64x64,format=rgba",
          "-frames:v", "1", "-threads", "2", "-update", "1", url.path,
        ],
        directory: root, timeout: 20, diskGuard: nil))
    let file = try #require(ReviewFile.read(url.path))
    let original = try Data(contentsOf: url)
    #expect(throws: MediaOperationError.self) {
      try MediaExportEngine.run(
        .init(files: [file], roots: [root.path], destination: root, kind: .image))
    }
    let result = try MediaExportEngine.run(
      .init(files: [file], roots: [root.path], destination: root, kind: .losslessImage))
    let probe = try MediaExportEngine.probe(URL(fileURLWithPath: result.output))
    #expect(probe.video?.pixFmt == "rgba")
    #expect(probe.video?.width == 64)
    #expect(try Data(contentsOf: url) == original)
  }

  @Test func terminatesTimedOutAndCancelledProcesses() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: MediaOperationError.self) {
      try MediaProcess.run(
        .init(
          executable: "/bin/sleep", arguments: ["5"], directory: root, timeout: 0.1, diskGuard: nil)
      )
    }
    let worker = Task.detached {
      try MediaProcess.run(
        .init(
          executable: "/bin/sleep", arguments: ["30"], directory: root, timeout: 40, diskGuard: nil)
      )
    }
    try await Task.sleep(for: .milliseconds(100))
    worker.cancel()
    do {
      _ = try await worker.value
      Issue.record("Cancelled process returned success")
    } catch { #expect(error is MediaOperationError || error is CancellationError) }
  }
}
