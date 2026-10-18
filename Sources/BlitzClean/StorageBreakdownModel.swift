import Foundation

@MainActor
final class StorageBreakdownModel: ObservableObject {
  /// The folder the user chose to check for project caches; nil checks every project location.
  @Published private(set) var projectRoot: String?
  @Published var cleanupFocus: StorageCleanupFocus?
  private static let automaticScanInterval: TimeInterval = 5 * 60
  let overview: CleanupOverviewModel
  lazy var repeats = RepeatCleanupModel(history: overview)
  lazy var oldFiles = OldFilesModel()
  lazy var largeFiles = LargeFilesModel()
  lazy var drive = DriveBreakdownModel(history: overview)

  @Published private(set) var categories: [StorageCategory] = []
  @Published private(set) var scannedAt: Date?
  @Published private(set) var isScanning = false
  @Published private(set) var incompleteMeasurements = 0
  @Published private(set) var isCleaning = false
  @Published private(set) var simulatorDeviceCount = 0
  @Published private(set) var bootedSimulatorCount = 0
  @Published private(set) var simulatorDevices: [SimulatorDeviceInfo] = []
  @Published private(set) var cleanupMessage: String?
  @Published private(set) var cleanupCompletedCount = 0
  @Published private(set) var cleanupTotalCount = 0
  @Published private(set) var stoppingProcessPath: String?
  @Published var selectedPaths: Set<String> = []

  private let cleanupService = DeveloperCleanupService()
  private let processController = ProjectProcessController()
  private var scanTask: Task<Void, Never>?
  private var rescanRequested = false
  private struct ProjectLocation {
    let path: String?
  }
  private var pendingProjectRoot: ProjectLocation?

  init(overviewConfiguration: CleanupOverviewConfiguration = .application) {
    overview = CleanupOverviewModel(overviewConfiguration)
    guard let cachedResult = StorageScanCache.load() else {
      return
    }

    categories = cachedResult.categories
    scannedAt = cachedResult.scannedAt
    simulatorDeviceCount = cachedResult.simulatorDeviceCount
    bootedSimulatorCount = cachedResult.bootedSimulatorCount
    simulatorDevices = cachedResult.simulatorDevices
  }

  func scanCleanupIfNeeded() {
    if incompleteMeasurements == 0, let scannedAt,
      Date.now.timeIntervalSince(scannedAt) < Self.automaticScanInterval
    {
      return
    }
    scanCleanup()
  }

  func selectProjectRoot(_ path: String?) {
    guard !isScanning, !isCleaning else {
      pendingProjectRoot = .init(path: path)
      cleanupMessage = "The selected folder will be checked when the current task finishes."
      return
    }
    projectRoot = path
    cleanupMessage = nil
    categories = []
    selectedPaths = []
    scanCleanup(.init(deadline: .now.addingTimeInterval(45)))
  }

  func scanCleanup(_ measurements: FolderMeasurementSession = .init()) {
    guard !isScanning else {
      rescanRequested = true
      return
    }
    isScanning = true
    let measurements =
      projectRoot == nil ? measurements : .init(deadline: .now.addingTimeInterval(45))
    let scanner = StorageBreakdownScanner(measure: measurements.footprint)
    let projectRoot = projectRoot
    scanTask = Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      let result = scanner.scan(
        .init(
          projectRoot: projectRoot,
          onUpdate: { update in
            Task { @MainActor in self.applyScanUpdate(update) }
          }))
      await self.applyScan(
        .init(result: result, incompleteMeasurements: measurements.incompleteCount))
    }
  }

  private func applyScanUpdate(_ update: StorageScanUpdate) {
    switch update {
    case .category(let category):
      categories.removeAll { existing in
        existing.id == category.id
      }
      categories.append(category)
      categories.sort { left, right in
        left.bytes > right.bytes
      }
    case .simulators(let devices):
      simulatorDevices = devices
      simulatorDeviceCount = devices.count
      bootedSimulatorCount = devices.filter { $0.state == "Booted" }.count
    }
  }

  private struct CompletedScan {
    let result: StorageScanResult
    let incompleteMeasurements: Int
  }

  private func applyScan(_ scan: CompletedScan) {
    let result = scan.result
    incompleteMeasurements = scan.incompleteMeasurements
    categories = result.categories
    scannedAt = result.scannedAt
    if projectRoot == nil {
      simulatorDeviceCount = result.simulatorDeviceCount
      bootedSimulatorCount = result.bootedSimulatorCount
      simulatorDevices = result.simulatorDevices
      StorageScanCache.save(
        .init(
          categories: categories, scannedAt: result.scannedAt,
          simulatorDeviceCount: result.simulatorDeviceCount,
          bootedSimulatorCount: result.bootedSimulatorCount,
          simulatorDevices: result.simulatorDevices))
    }
    selectedPaths.formIntersection(readyItems.map(\.path))
    isScanning = false
    if let pending = pendingProjectRoot {
      pendingProjectRoot = nil
      rescanRequested = false
      selectProjectRoot(pending.path)
    } else if rescanRequested {
      rescanRequested = false
      scanCleanup()
    }
  }

  var readyItems: [StorageItem] {
    categories.flatMap(\.items).filter { item in
      item.cleanupAvailability?.isReady == true
    }
  }

  var blockedItems: [StorageItem] {
    categories.flatMap(\.items).filter { item in
      guard let availability = item.cleanupAvailability else {
        return false
      }

      return !availability.isReady
    }
  }

  var selectedItems: [StorageItem] {
    readyItems.filter { item in
      selectedPaths.contains(item.path)
    }
  }

  var selectedBytes: UInt64 {
    selectedItems.reduce(0) { result, item in
      result + item.bytes
    }
  }

  var recommendedItems: [StorageItem] {
    let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
    return readyItems.filter { item in
      switch item.cleanupKind {
      case .generatedBuildCache, .simulatorCache:
        return true
      case .nodeModules:
        return (item.lastActivityAt ?? .distantFuture) < cutoff
      case nil:
        return false
      }
    }
  }

  var recommendedBytes: UInt64 {
    recommendedItems.reduce(0) { result, item in
      result + item.bytes
    }
  }

  var cleanupProgress: Double {
    guard cleanupTotalCount > 0 else {
      return 0
    }

    return Double(cleanupCompletedCount) / Double(cleanupTotalCount)
  }

  func setSelected(_ selection: StorageSelection) {
    if selection.isSelected {
      selectedPaths.insert(selection.path)
    } else {
      selectedPaths.remove(selection.path)
    }
  }

  func selectOldNodeModules(_ request: OldDependencySelection) {
    let cutoff = Calendar.current.date(byAdding: .day, value: -request.days, to: .now) ?? .now
    let paths = readyItems.filter { item in
      guard item.cleanupKind == .nodeModules else {
        return false
      }

      if request.days == 0 {
        return true
      }

      return (item.lastActivityAt ?? .distantFuture) < cutoff
    }.map(\.path)

    if request.isSelected {
      selectedPaths.formUnion(paths)
    } else {
      selectedPaths.subtract(paths)
    }
  }

  func clearSelection() {
    selectedPaths.removeAll()
  }

  func selectRecommended() {
    selectedPaths.formUnion(recommendedItems.map(\.path))
  }

  func stopProcessesAndSelect(_ item: StorageItem) {
    guard let processes = item.activeProcesses, !processes.isEmpty,
      stoppingProcessPath == nil, !isScanning, !isCleaning
    else {
      return
    }

    stoppingProcessPath = item.path
    cleanupMessage = nil
    selectedPaths.insert(item.path)
    let processController = processController

    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        processController.stop(
          StopProjectProcessesRequest(processes: processes)
        )
      }.value
      try? await Task.sleep(nanoseconds: 1_000_000_000)

      guard let self else {
        return
      }

      stoppingProcessPath = nil
      cleanupMessage = ProjectProcessStopMessage.text(result)
      scanCleanup()
    }
  }

  func cleanSelected() {
    let items = selectedItems
    guard !items.isEmpty, !isCleaning else {
      return
    }

    isCleaning = true
    cleanupMessage = nil
    cleanupCompletedCount = 0
    cleanupTotalCount = items.count
    let cleanupService = cleanupService

    Task { [weak self] in
      var cleanedPaths: Set<String> = []
      var recoveredBytes: UInt64 = 0
      var failureCount = 0

      for item in items {
        let outcome = await Task.detached(priority: .utility) {
          guard CleanupActivity.revalidate(item).isReady else {
            return (
              CleanupResult(cleanedPaths: [], recoveredBytes: 0, failureCount: 1),
              Optional<CleanupWin>.none
            )
          }
          let before = CleanupVolume.read(item.path)
          let result = cleanupService.clean(CleanupRequest(items: [item]))
          let win = CleanupWin(
            id: UUID().uuidString, date: .now, title: "Deleted \(item.name)",
            paths: Array(result.cleanedPaths), before: before,
            after: before.flatMap { CleanupVolume.read($0.path) }
          )
          return (result, Optional(win))
        }.value
        let result = outcome.0
        if let win = outcome.1 { self?.overview.record(win) }
        cleanedPaths.formUnion(result.cleanedPaths)
        recoveredBytes += result.recoveredBytes
        failureCount += result.failureCount
        self?.cleanupCompletedCount += 1
      }

      guard let self else {
        return
      }

      let result = CleanupResult(
        cleanedPaths: cleanedPaths,
        recoveredBytes: recoveredBytes,
        failureCount: failureCount
      )
      selectedPaths.subtract(cleanedPaths)
      isCleaning = false
      cleanupMessage = result.message
      if let pending = pendingProjectRoot {
        pendingProjectRoot = nil
        selectProjectRoot(pending.path)
      } else {
        scanCleanup()
      }
    }
  }
}
