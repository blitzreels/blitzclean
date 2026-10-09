import Foundation
import Testing

@testable import BlitzClean

struct BlitzCleanTests {
  @Test
  func trayUsesUnderstandableMetricNames() {
    let text = MenuBarStatusText.make(
      .init(
        snapshot: .empty, showDisk: true, showCPU: true, showMemory: true, memoryDisplay: .available
      ))
    #expect(text.contains("CPU"))
    #expect(text.contains("RAM"))
    #expect(text.contains("free"))
  }
}

struct LiveCPUTests {
  @Test
  func measuresIntervalAndRejectsReusedPIDs() {
    let previous: [CPUCounter] = [
      .init(id: 1, name: "worker", start: 10, ticks: 1_000_000_000),
      .init(id: 2, name: "old", start: 20, ticks: 1_000_000_000),
    ]
    let current: [CPUCounter] = [
      .init(id: 1, name: "worker", start: 10, ticks: 4_000_000_000),
      .init(id: 2, name: "new", start: 30, ticks: 4_000_000_000),
    ]
    let usage = CPUProcessReader.usage(
      .init(previous: previous, current: current, seconds: 2, nanosecondsPerTick: 1))
    #expect(usage.count == 1)
    #expect(usage.first?.percent == 150)
    #expect(
      CPUProcessReader.usage(
        .init(previous: previous, current: current, seconds: 0, nanosecondsPerTick: 1)
      ).isEmpty)
  }

  @Test
  func historyIsBoundedAndPreservesUnavailableCPU() {
    var history = ResourceHistory(capacity: 2)
    for _ in 0..<10 { history.append(.empty) }
    #expect(history.samples.count == 2)
    #expect(history.samples.allSatisfy { $0.cpu == nil })
  }

  @Test
  func inactiveAppPagesAreNotAllCountedAsAvailable() {
    let stats = VMMemoryStats(
      free: 10, active: 20, inactive: 50, wired: 10,
      compressed: 10, fileBacked: 15, purgeable: 5, swapOutBytes: 0, total: 100)
    #expect(stats.available == 30)
  }

  @Test
  func normalLaunchOpensDashboardAndBackgroundLaunchStaysQuiet() {
    var normal = InitialWindowRequest(["BlitzClean"])
    #expect(normal.consume() == "dashboard")
    #expect(normal.consume() == nil)
    var background = InitialWindowRequest(["BlitzClean", "--background"])
    #expect(background.consume() == nil)
  }
}

@Suite(.serialized)
struct QuickCleanTests {
  private func fixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("blitzclean-cache-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(fileURLWithPath: ReviewFile.canonicalPath(url.path)!)
  }

  private func rule(_ root: URL) -> CacheRule {
    .init(
      title: "Fixture cache", path: root.path, recipe: "A disposable test download.", owners: [],
      kind: .cache)
  }

  private func age(_ url: URL) throws {
    try FileManager.default.setAttributes(
      [.modificationDate: Date.now.addingTimeInterval(-10 * 86_400)], ofItemAtPath: url.path)
  }

  @Test
  func scanKeepsRecentFilesAndSkipsSymlinks() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("old.cache")
    let recent = root.appendingPathComponent("recent.cache")
    try Data(repeating: 42, count: 4096).write(to: old)
    try Data(repeating: 42, count: 4096).write(to: recent)
    try age(old)
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("linked.cache").path, withDestinationPath: old.path)
    let scan = CacheCleaner.scan(.init(rules: [rule(root)], date: .now))
    #expect(scan.candidates.map(\.path) == [old.path])
    #expect(!scan.notes.isEmpty)
    #expect(FileManager.default.fileExists(atPath: recent.path))
  }

  @Test
  func nestedChangesAndActiveFilesBlockCleanup() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("download")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("payload.cache")
    try Data(repeating: 42, count: 4096).write(to: file)
    try age(file)
    try age(directory)
    let tree = try CacheCleaner.tree(
      .init(path: directory.path, deadline: .now.addingTimeInterval(5)))
    let candidate = CacheCandidate(path: directory.path, rule: rule(root), tree: tree)
    let handle = try FileHandle(forReadingFrom: file)
    #expect(throws: CacheCleanError.self) { try CacheCleaner.delete(candidate) }
    try handle.close()
    try Data(repeating: 43, count: 8192).write(to: file)
    #expect(throws: CacheCleanError.self) { try CacheCleaner.delete(candidate) }
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test
  func deletesOnlyReviewedInactiveFixtureAndMeasuresDisk() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("old.cache")
    let keep = root.appendingPathComponent("keep.cache")
    try Data(repeating: 42, count: 4096).write(to: file)
    try Data(repeating: 42, count: 4096).write(to: keep)
    try age(file)
    let tree = try CacheCleaner.tree(.init(path: file.path, deadline: .now.addingTimeInterval(5)))
    let win = try CacheCleaner.delete(.init(path: file.path, rule: rule(root), tree: tree))
    #expect(win.paths == [file.path])
    #expect(win.before?.isInternal == true)
    #expect(win.after != nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(FileManager.default.fileExists(atPath: keep.path))
  }

  @Test
  func refusesRootItselfAndLinkedAncestors() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let tree = CacheTree(fingerprint: "unused", bytes: 1, newest: .distantPast)
    #expect(throws: CacheCleanError.self) {
      try CacheCleaner.validateLocation(.init(path: root.path, rule: rule(root), tree: tree))
    }
    let folder = root.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: folder.path)
    #expect(throws: CacheCleanError.self) {
      try CacheCleaner.validateLocation(.init(path: link.path, rule: rule(root), tree: tree))
    }
  }
}

@MainActor
struct MenuBarSizeTests {
  @Test
  func allMetricsFitACrowdedMenuBar() throws {
    let image = MenuBarLabelRenderer.image(
      content: MenuBarHealthLabel(snapshot: .empty, risk: .critical).metrics, colored: true)
    #expect(image.size.width > 20)
    #expect(image.size.width <= 180)
    #expect(image.size.height <= 24)
  }
}

struct NativeCPUIntegrationTests {
  @Test
  func accountsForAppleSiliconClockUnits() {
    let usage = CPUProcessReader.usage(
      .init(
        previous: [.init(id: 1, name: "test", start: 1, ticks: 0)],
        current: [.init(id: 1, name: "test", start: 1, ticks: 24_000_000)],
        seconds: 1, nanosecondsPerTick: 125.0 / 3.0))
    #expect(abs((usage.first?.percent ?? 0) - 100) < 0.01)
  }

  @Test
  func realBusyProcessReportsCoreUsage() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      process.terminate()
      process.waitUntilExit()
    }
    let before = CPUProcessReader.counters()
    let start = ProcessInfo.processInfo.systemUptime
    try await Task.sleep(for: .seconds(1))
    let after = CPUProcessReader.counters()
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    let scale = try #require(CPUProcessReader.nanosecondsPerTick)
    let usage = CPUProcessReader.usage(
      .init(
        previous: before, current: after,
        seconds: elapsed, nanosecondsPerTick: scale))
    let percent = try #require(usage.first { $0.id == process.processIdentifier }?.percent)
    #expect(percent > 10)
    #expect(percent <= 120)
  }
}
