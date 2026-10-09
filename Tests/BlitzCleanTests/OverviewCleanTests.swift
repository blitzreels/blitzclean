import AppKit
import SwiftUI
import Testing

@testable import BlitzClean

@MainActor
struct OverviewCleanTests {
  @Test func readyCachesCanRunWhileProjectCheckIsPending() async throws {
    let fixture = fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let driver = OverviewCleanFixtureDriver(
      .init(candidates: candidates, failures: Set(candidates.map(\.path)), delay: .milliseconds(10))
    )
    let caches = QuickCleanModel(driver: driver)
    caches.scan()
    try await wait(caches)
    let storage = StorageBreakdownModel(
      overviewConfiguration: .init(
        store: .init(url: fixture.root.appendingPathComponent("audit-history.json")),
        scanRequest: .init(roots: [], minimumBytes: 0, maxEntries: 1),
        synchronizesInBackground: false))
    let audit = DashboardAuditModel()
    audit.start(
      .init(checks: [
        .caches: { [] },
        .projects: {
          try? await Task.sleep(for: .milliseconds(500))
          return []
        },
      ]))
    for _ in 0..<100 where audit.progress.results[.caches] == nil {
      try await Task.sleep(for: .milliseconds(5))
    }
    audit.cleanCaches(
      .init(
        monitor: SystemMonitor(), memory: MemoryRescueModel(), processes: DevProcessModel(),
        recovery: AppRecoveryModel(), caches: caches, storage: storage, docker: DockerStorageModel()
      ))
    #expect(caches.isCleaning)
    #expect(audit.progress.results[.projects] == nil)
    try await wait(caches)
    #expect(await driver.deleted == candidates.map(\.path))
    for _ in 0..<100 where audit.progress.isRunning {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(audit.cleanupResult?.outcome.skippedCount == candidates.count)
  }

  @Test func quickCleanLeavesDiagnosticReportsForExplicitReview() async throws {
    let fixture = fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let report = CacheCandidate(
      path: "/fixture/report.ips",
      rule: .init(
        title: "Reports", path: "/fixture", recipe: "Test report", owners: [],
        kind: .diagnosticReport),
      tree: .init(fingerprint: "report", bytes: 4096, newest: .distantPast))
    let driver = OverviewCleanFixtureDriver(
      .init(candidates: candidates + [report], failures: [], delay: .zero))
    let model = QuickCleanModel(driver: driver)
    model.scan()
    try await wait(model)
    #expect(model.totalBytes == model.quickBytes + report.tree.bytes)
    model.cleanAll(history: fixture.history)
    try await wait(model)
    #expect(await driver.deleted == candidates.map(\.path))
    #expect(model.candidates.map(\.path) == [report.path])
    #expect(!model.canClean)
    model.selected = [report.path]
    model.clean(history: fixture.history)
    try await wait(model)
    #expect(await driver.deleted.last == report.path)
    #expect(fixture.history.ledger.wins.flatMap(\.paths).contains(report.path))
  }

  @Test func oneClickCleansAllEligibleCachesAndRecordsOnlySuccessfulRemovals() async throws {
    let fixture = fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let driver = OverviewCleanFixtureDriver(
      .init(candidates: candidates, failures: ["/fixture/second"], delay: .milliseconds(25)))
    let model = QuickCleanModel(driver: driver)
    model.scan()
    model.cleanAll(history: fixture.history)
    #expect(!model.isCleaning)
    try await wait(model)
    model.selected = ["/fixture/second"]
    model.cleanAll(history: fixture.history)
    model.cleanAll(history: fixture.history)
    model.scan()
    #expect(model.isCleaning)
    #expect(!model.isScanning)
    #expect(!model.canClean)
    try await wait(model)
    #expect(await driver.deleted == candidates.map(\.path))
    #expect(model.completed == 2)
    #expect(model.result?.removedCount == 1)
    #expect(model.result?.skippedCount == 1)
    #expect(model.result?.removedBytes == candidates[0].tree.bytes)
    #expect(!model.canClean)
    #expect(model.candidates.map(\.path) == ["/fixture/second"])
    #expect(fixture.history.ledger.wins.flatMap(\.paths) == ["/fixture/first"])
    #expect(model.notes.contains { $0.contains("Fixture cache") })
    #expect(model.notes.contains("One location could not be read."))
    model.scan()
    #expect(model.result == nil)
    #expect(model.status == nil)
    try await wait(model)
  }

  @Test func emptyScanCannotDeleteAnything() async throws {
    let fixture = fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let driver = OverviewCleanFixtureDriver(
      .init(candidates: [], failures: [], delay: .zero))
    let model = QuickCleanModel(driver: driver)
    model.cleanAll(history: fixture.history)
    model.scan()
    try await wait(model)
    model.cleanAll(history: fixture.history)
    #expect(!model.canClean)
    #expect(model.result == nil)
    #expect(await driver.deleted.isEmpty)
  }

  @Test func allFailuresNeverReportSuccessfulCleanup() async throws {
    let fixture = fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = QuickCleanModel(
      driver: OverviewCleanFixtureDriver(
        .init(candidates: candidates, failures: Set(candidates.map(\.path)), delay: .zero)))
    model.scan()
    try await wait(model)
    model.cleanAll(history: fixture.history)
    try await wait(model)
    #expect(model.result?.removedCount == 0)
    #expect(model.result?.removedBytes == 0)
    #expect(model.result?.skippedCount == 2)
    #expect(model.candidates.count == 2)
    #expect(fixture.history.ledger.wins.isEmpty)
  }

  @Test func rendersCleanupStatesWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["BLITZCLEAN_CLEAN_RENDER_DIR"] else {
      return
    }
    let directory = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = QuickCleanModel(
      driver: OverviewCleanFixtureDriver(
        .init(candidates: candidates, failures: [], delay: .seconds(1))))
    model.scan()
    try render(
      .init(model: model, history: fixture.history, directory: directory, name: "scanning"))
    try await wait(model)
    try render(.init(model: model, history: fixture.history, directory: directory, name: "ready"))
    model.cleanAll(history: fixture.history)
    try render(
      .init(model: model, history: fixture.history, directory: directory, name: "cleaning"))
    try await wait(model)
    try render(.init(model: model, history: fixture.history, directory: directory, name: "done"))
    let blocked = QuickCleanModel(
      driver: OverviewCleanFixtureDriver(
        .init(candidates: candidates, failures: Set(candidates.map(\.path)), delay: .zero)))
    blocked.scan()
    try await wait(blocked)
    blocked.cleanAll(history: fixture.history)
    try await wait(blocked)
    try render(.init(model: blocked, history: fixture.history, directory: directory, name: "kept"))
    let empty = QuickCleanModel(
      driver: OverviewCleanFixtureDriver(.init(candidates: [], failures: [], delay: .zero)))
    empty.scan()
    try await wait(empty)
    try render(.init(model: empty, history: fixture.history, directory: directory, name: "empty"))
  }

  private struct RenderRequest {
    let model: QuickCleanModel
    let history: CleanupOverviewModel
    let directory: URL
    let name: String
  }

  private func render(_ request: RenderRequest) throws {
    for width in [648.0, 812.0] {
      let renderer = ImageRenderer(
        content: AuditRenderFixture.card(
          .init(
            model: request.model,
            summary: .init(
              .init(
                items: request.model.candidates.map {
                  .init(path: $0.path, bytes: $0.tree.bytes, source: .caches)
                }, dockerBytes: 0, hasSkippedLocations: !request.model.notes.isEmpty,
                dockerUnavailable: false)),
            isScanning: request.model.isScanning)
        )
        .padding(28).frame(width: width)
        .background(BlitzUI.canvasBackground).blitzTheme())
      renderer.scale = 2
      let image = try #require(renderer.cgImage)
      let data = try #require(
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
      try data.write(
        to: request.directory.appendingPathComponent("cache-\(request.name)-\(Int(width)).png"))
    }
  }

  private var candidates: [CacheCandidate] {
    ["first", "second"].map { name in
      .init(
        path: "/fixture/\(name)",
        rule: .init(
          title: "Fixture cache", path: "/fixture", recipe: "Test data", owners: [], kind: .cache),
        tree: .init(fingerprint: name, bytes: 1_500_000_000, newest: .distantPast))
    }
  }

  private func fixture() -> (history: CleanupOverviewModel, root: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("overview-clean-test-\(UUID())")
    return (
      CleanupOverviewModel(
        .init(
          store: .init(url: root.appendingPathComponent("history.json")),
          scanRequest: .init(roots: [], minimumBytes: 0, maxEntries: 1),
          synchronizesInBackground: false)), root
    )
  }

  private func wait(_ model: QuickCleanModel) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while model.isBusy {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private actor OverviewCleanFixtureDriver: QuickCleanDriver {
  struct Configuration: Sendable {
    let candidates: [CacheCandidate]
    let failures: Set<String>
    let delay: Duration
  }

  let configuration: Configuration
  private(set) var deleted: [String] = []

  init(_ configuration: Configuration) { self.configuration = configuration }

  func scan() async -> CacheScanResult {
    try? await Task.sleep(for: configuration.delay)
    return .init(candidates: configuration.candidates, notes: ["One location could not be read."])
  }

  func delete(_ candidate: CacheCandidate) async throws -> CleanupWin {
    deleted.append(candidate.path)
    try await Task.sleep(for: configuration.delay)
    if configuration.failures.contains(candidate.path) { throw CacheCleanError.changed }
    return .init(
      id: UUID().uuidString, date: .now, title: "Fixture cache", paths: [candidate.path],
      before: nil, after: nil, bytes: candidate.tree.bytes)
  }
}
