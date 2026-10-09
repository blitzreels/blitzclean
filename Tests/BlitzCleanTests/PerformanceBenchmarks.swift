import Foundation
import Testing

@testable import BlitzClean

struct PerformanceBenchmarks {
  @MainActor @Test func liveDashboardAudit() async throws {
    guard ProcessInfo.processInfo.environment["BLITZCLEAN_BENCHMARK"] == "audit" else { return }
    UserDefaults.standard.addSuite(named: AppBrand.bundleIdentifier)
    defer { UserDefaults.standard.removeSuite(named: AppBrand.bundleIdentifier) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "audit-benchmark-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CleanupHistoryStore(url: root.appendingPathComponent("history.json"))
    try store.save(CleanupHistoryStore.application.load())
    let storage = StorageBreakdownModel(
      overviewConfiguration: .init(
        store: store, scanRequest: .init(roots: [], minimumBytes: 0, maxEntries: 1),
        synchronizesInBackground: false))
    let models = DashboardAuditModel.Models(
      monitor: SystemMonitor(), memory: MemoryRescueModel(), processes: DevProcessModel(),
      recovery: AppRecoveryModel(), caches: QuickCleanModel(), storage: storage,
      docker: DockerStorageModel())
    let audit = DashboardAuditModel()
    let start = Date.now
    audit.check(models)
    var recorded: Set<AuditCheck> = []
    var firstResult: TimeInterval?
    while audit.progress.isRunning {
      for check in AuditCheck.allCases
      where audit.progress.results[check] != nil && !recorded.contains(check) {
        let elapsed = Date.now.timeIntervalSince(start)
        if firstResult == nil { firstResult = elapsed }
        print("BENCH audit \(check.rawValue): \(elapsed)s")
        fflush(stdout)
        recorded.insert(check)
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    let elapsed = Date.now.timeIntervalSince(start)
    for check in AuditCheck.allCases where !recorded.contains(check) {
      print("BENCH audit \(check.rawValue): \(elapsed)s")
    }
    let unmeasured = storage.repeats.statuses.values.filter { $0.bytes == nil && $0.blocker != nil }
      .count
    print(
      "BENCH audit unmeasured: \(unmeasured) historical folders; \(storage.incompleteMeasurements) shared measurements"
    )
    print(
      "BENCH audit total: \(elapsed)s; \(storage.repeats.entries.count) historical folders; \(DeveloperLocations.additionalProjectRoots.count) extra roots"
    )
    fflush(stdout)
    #expect((firstResult ?? elapsed) < 3, "The first completed check took more than 3 seconds")
    #expect(elapsed < 30, "The full local audit took more than 30 seconds")
  }

  @Test func liveReadOnlyScans() throws {
    guard let mode = ProcessInfo.processInfo.environment["BLITZCLEAN_BENCHMARK"] else { return }
    guard mode != "audit" else { return }
    if mode == "storage" || mode == "inventory" {
      let start = Date.now
      let result = StorageBreakdownScanner(timing: { timing in
        print("BENCH \(timing.stage): \(timing.seconds)s")
        fflush(stdout)
      }).scan(
        .init(
          scope: mode == "inventory" ? .inventory : .cleanup,
          onUpdate: { update in
            let label: String
            switch update {
            case .category(let category): label = category.id
            case .simulators: label = "simulators"
            }
            print("BENCH storage progress \(label): \(Date.now.timeIntervalSince(start))s")
            fflush(stdout)
          }))
      let elapsed = Date.now.timeIntervalSince(start)
      print("BENCH storage total: \(elapsed)s; \(result.categories.count) categories")
      if mode == "storage" {
        #expect(elapsed < 25, "Cleanup scan exceeds the 25-second local scan budget")
        #expect(
          !result.categories.contains { $0.id.hasPrefix("computer-") || $0.id == "large-files" })
      }
    } else {
      for iteration in 1...3 {
        var start = Date.now
        let processes = DevProcessScanner().snapshot()
        print(
          "BENCH processes \(iteration): \(Date.now.timeIntervalSince(start))s; \(processes.resources.count) processes"
        )
        start = .now
        _ = SystemMetricsProvider().snapshot()
        print("BENCH system metrics \(iteration): \(Date.now.timeIntervalSince(start))s")
        start = .now
        let caches = CacheCleaner.scan(.init(rules: CacheRule.standard, date: .now))
        print(
          "BENCH quick caches \(iteration): \(Date.now.timeIntervalSince(start))s; \(caches.candidates.count) candidates"
        )
        start = .now
        _ = try? DockerStorageService().load()
        print("BENCH docker \(iteration): \(Date.now.timeIntervalSince(start))s")
        fflush(stdout)
      }
    }
  }
}
