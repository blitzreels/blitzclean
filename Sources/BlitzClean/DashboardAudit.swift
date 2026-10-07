import Foundation

enum AuditCheck: String, CaseIterable, Sendable {
  case resources = "Memory & CPU"
  case caches = "Caches"
  case projects = "Project data"
  case docker = "Docker"
  case apps = "App responsiveness"
}

struct AuditProgress: Equatable {
  private(set) var startedAt: Date?
  private(set) var completedAt: Date?
  private(set) var results: [AuditCheck: [String]] = [:]

  var isRunning: Bool { startedAt != nil && completedAt == nil }
  var pending: [AuditCheck] { AuditCheck.allCases.filter { results[$0] == nil } }
  var warnings: [String] {
    AuditCheck.allCases.flatMap { check in
      (results[check] ?? []).map { "\(check.rawValue): \($0)" }
    }
  }

  func status(for check: AuditCheck) -> String {
    guard startedAt != nil else { return "Not checked" }
    guard let warnings = results[check] else { return "Checking…" }
    if warnings.isEmpty { return "Checked" }
    return check == .docker ? "Unavailable" : "Partly checked"
  }

  mutating func begin(at date: Date) {
    startedAt = date
    completedAt = nil
    results = [:]
  }

  struct Completion {
    let check: AuditCheck
    let warnings: [String]
    let date: Date
  }

  mutating func finish(_ completion: Completion) {
    guard isRunning, results[completion.check] == nil else { return }
    results[completion.check] = completion.warnings
    if pending.isEmpty { completedAt = completion.date }
  }
}

enum AuditAction: Equatable {
  case cleanCaches, memory, cpu, recovery
  case cleanup(StorageCleanupFocus)
}

struct AuditRecommendation: Identifiable, Equatable {
  let id: String
  let title: String
  let detail: String
  let symbol: String
  let actionTitle: String
  let action: AuditAction
  let priority: Int
  /// Estimated disk space the action can recover; absent for actions that free none.
  let reward: UInt64?
}

struct AuditFindings {
  let progress: AuditProgress
  let cleanup: OverviewCleanupSummary
  let quickBytes: UInt64
  let canClean: Bool
  let pressure: PressureAssessment
  let detachedCount: Int
  let detachedBytes: UInt64
  let recoveryCount: Int

  var recommendations: [AuditRecommendation] {
    guard progress.startedAt != nil else { return [] }
    var result: [AuditRecommendation] = []
    if progress.results[.resources] != nil {
      if pressure.risk > .normal, pressure.limit != .none {
        let action: AuditAction =
          switch pressure.limit {
          case .disk: .cleanup(.caches)
          case .cpu: .cpu
          default: .memory
          }
        result.append(
          .init(
            id: "pressure", title: pressure.title, detail: pressure.action,
            symbol: "exclamationmark.circle",
            actionTitle: pressure.limit == .disk
              ? "Review storage" : pressure.limit == .cpu ? "Review CPU" : "Review memory",
            action: action, priority: pressure.risk >= .critical ? 0 : 10, reward: nil))
      }
      if detachedCount > 0 {
        result.append(
          .init(
            id: "sessions",
            title: "\(detachedCount) detached AI \(detachedCount == 1 ? "session" : "sessions")",
            detail:
              "Using \(ByteText.full(detachedBytes)) RAM. Review before quitting; work may still be running.",
            symbol: "terminal", actionTitle: "Review sessions", action: .memory, priority: 30,
            reward: nil))
      }
    }
    if progress.results[.apps] != nil, recoveryCount > 0 {
      result.append(
        .init(
          id: "recovery",
          title: "\(recoveryCount) \(recoveryCount == 1 ? "app is" : "apps are") stopped or frozen",
          detail: "Review each app to resume it or check its response.",
          symbol: "waveform.path.ecg", actionTitle: "Review apps", action: .recovery, priority: 5,
          reward: nil))
    }
    if progress.results[.caches] != nil {
      if quickBytes > 0, canClean {
        result.append(
          .init(
            id: "caches", title: "\(ByteText.full(quickBytes)) of old caches",
            detail: "Permanently removes eligible caches. Apps rebuild them when needed.",
            symbol: "archivebox", actionTitle: "Clean \(ByteText.full(quickBytes))",
            action: .cleanCaches, priority: 20, reward: quickBytes))
      }
      if let bytes = cleanup.bytesBySource[.reports], bytes > 0 {
        result.append(
          .init(
            id: "reports", title: "\(ByteText.full(bytes)) of old diagnostic reports",
            detail: "Review reports older than 30 days before removing them.",
            symbol: "doc.text", actionTitle: "Review reports", action: .cleanup(.caches),
            priority: 70, reward: bytes))
      }
    }
    if progress.results[.docker] != nil, !cleanup.dockerUnavailable,
      let bytes = cleanup.bytesBySource[.docker], bytes > 0
    {
      result.append(
        .init(
          id: "docker", title: "\(ByteText.full(bytes)) reclaimable in Docker",
          detail: "Unused images and build cache. Containers and volumes stay protected.",
          symbol: "shippingbox", actionTitle: "Review Docker", action: .cleanup(.docker),
          priority: 40, reward: bytes))
    }
    if progress.results[.projects] != nil {
      let bytes = (cleanup.bytesBySource[.projects] ?? 0) + (cleanup.bytesBySource[.regrown] ?? 0)
      if bytes > 0 {
        result.append(
          .init(
            id: "projects", title: "\(ByteText.full(bytes)) of rebuildable project data",
            detail: "Dependencies and folders that grew back. Choose what to remove.",
            symbol: "folder", actionTitle: "Review projects",
            action: .cleanup((cleanup.bytesBySource[.regrown] ?? 0) > 0 ? .regrown : .projects),
            priority: 50, reward: bytes))
      } else if progress.results[.projects]?.isEmpty == false {
        result.append(
          .init(
            id: "projects-unchecked", title: "Finish checking project data",
            detail: "Some folders could not be fully checked. Open Storage for a deeper scan.",
            symbol: "folder", actionTitle: "Review projects", action: .cleanup(.projects),
            priority: 50, reward: nil))
      }
      if let bytes = cleanup.bytesBySource[.simulators], bytes > 0 {
        result.append(
          .init(
            id: "simulators", title: "\(ByteText.full(bytes)) in shutdown simulators",
            detail: "Deleting a simulated device also removes its apps and data.",
            symbol: "iphone", actionTitle: "Review devices", action: .cleanup(.simulators),
            priority: 60, reward: bytes))
      }
    }
    return result.sorted { $0.priority == $1.priority ? $0.id < $1.id : $0.priority < $1.priority }
  }
}

struct AuditCleanupResult: Equatable {
  let outcome: QuickCleanResult
  let notes: [String]
  let date: Date
}

@MainActor
final class DashboardAuditModel: ObservableObject {
  typealias Check = @MainActor @Sendable () async -> [String]

  struct Request {
    let checks: [AuditCheck: Check]
  }

  @Published private(set) var progress = AuditProgress()
  @Published private(set) var cleanupResult: AuditCleanupResult?
  private var pendingRecheck: Request?

  func recheck(_ request: Request) {
    if progress.isRunning {
      pendingRecheck = request
    } else {
      start(request)
    }
  }

  func start(_ request: Request) {
    guard !progress.isRunning else { return }
    progress.begin(at: .now)
    Task {
      await withTaskGroup(of: AuditProgress.Completion.self) { group in
        for check in AuditCheck.allCases {
          let run = request.checks[check]
          group.addTask {
            let warnings = await run?() ?? ["This check is unavailable."]
            return .init(check: check, warnings: warnings, date: .now)
          }
        }
        for await completion in group { progress.finish(completion) }
      }
      if let pendingRecheck {
        self.pendingRecheck = nil
        start(pendingRecheck)
      }
    }
  }

  @MainActor struct Models {
    let monitor: SystemMonitor
    let memory: MemoryRescueModel
    let processes: DevProcessModel
    let recovery: AppRecoveryModel
    let caches: QuickCleanModel
    let storage: StorageBreakdownModel
    let docker: DockerStorageModel

    var isMutating: Bool {
      caches.isCleaning || storage.isCleaning || docker.isCleaning
        || !storage.repeats.removing.isEmpty || recovery.isReviving
    }
  }

  func check(_ models: Models) {
    guard !models.isMutating else { return }
    start(request(models))
  }

  private func request(_ models: Models) -> Request {
    return
      .init(checks: [
        .resources: {
          models.monitor.refresh()
          models.memory.refresh()
          models.processes.refresh()
          await Self.wait { models.processes.isRefreshing || models.memory.isRefreshing }
          var warnings = models.processes.statusMessage.map { [$0] } ?? []
          let snapshot = models.monitor.snapshot
          if snapshot.ramTotal == 0 || snapshot.diskTotal == 0 || snapshot.cpuUsage == nil {
            warnings.append("Some resource readings are unavailable.")
          }
          return warnings
        },
        .caches: {
          models.caches.scan()
          await Self.wait { models.caches.isScanning }
          return models.caches.notes
        },
        .projects: {
          let measurements = FolderMeasurementSession(deadline: .now.addingTimeInterval(20))
          models.storage.scanCleanup(measurements)
          models.storage.repeats.check(
            .init(force: true, scope: .overview, measure: measurements.directoryBytes))
          await Self.wait { models.storage.isScanning || models.storage.repeats.isChecking }
          let unknown = models.storage.categories.filter { $0.id == "node-modules" }
            .flatMap(\.items).filter { $0.lastActivityAt == nil }.count
          var warnings: [String] = []
          if unknown > 0 {
            warnings.append(
              "Activity could not be fully checked for \(unknown) project folders; review them individually."
            )
          }
          if measurements.incompleteCount > 0 {
            warnings.append(
              "\(measurements.incompleteCount) folders need a deeper scan in Storage → Cleanup. Their sizes are not included."
            )
          }
          return warnings
        },
        .docker: {
          guard models.docker.isInstalled else { return [] }
          models.docker.refresh()
          await Self.wait { models.docker.isRefreshing }
          return models.docker.errorMessage == nil
            ? [] : ["Docker could not be reached. Open Docker, then check again."]
        },
        .apps: {
          await Self.wait { models.recovery.isScanning }
          let apps = RecoveryAppRoster.merge(
            .init(descriptors: MemoryAppProvider().descriptors(), measured: models.memory.apps))
          await models.recovery.scan(apps, force: true)
          let incomplete = apps.filter {
            let health = models.recovery.check(for: $0)?.health
            return health == nil || health == .unknown || health == .running
          }
          return incomplete.isEmpty
            ? []
            : ["Responsiveness could not be verified for \(incomplete.count) apps."]
        },
      ])
  }

  func cleanCaches(_ models: Models) {
    guard progress.results[.caches] != nil, !models.isMutating, models.caches.canClean else {
      return
    }
    cleanupResult = nil
    models.caches.cleanAll(history: models.storage.overview)
    Task {
      await Self.wait { models.caches.isCleaning }
      if let result = models.caches.result {
        cleanupResult = .init(outcome: result, notes: models.caches.notes, date: .now)
      }
      models.monitor.refresh()
      if (models.caches.result?.removedCount ?? 0) > 0 { recheck(request(models)) }
    }
  }

  private static func wait(_ isBusy: @MainActor () -> Bool) async {
    while isBusy() { try? await Task.sleep(for: .milliseconds(100)) }
  }
}
