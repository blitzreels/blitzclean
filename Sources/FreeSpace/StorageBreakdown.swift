import Foundation

struct StorageItem: Identifiable, Equatable, Codable, Sendable {
  let name: String
  let path: String
  let bytes: UInt64
  let cleanupKind: StorageCleanupKind?
  let cleanupAvailability: StorageCleanupAvailability?
  let lastActivityAt: Date?
  let contentBytes: UInt64?
  let nodeOrigin: NodeStorageOrigin?
  let projectRootPath: String?
  let dependencyInstalledAt: Date?
  let activeProcesses: [ProjectProcessInfo]?

  var id: String {
    path
  }
}

enum StorageCleanupKind: String, Equatable, Codable, Sendable {
  case nodeModules
  case generatedBuildCache
  case simulatorCache
}

enum StorageCleanupAvailability: Equatable, Codable, Sendable {
  case ready
  case blocked(String)

  var isReady: Bool {
    self == .ready
  }
}

enum StorageSafety: String, Equatable, Codable, Sendable {
  case safe = "Safe to Rebuild"
  case caution = "Check First"
  case review = "Personal Data"
}

struct StorageCategory: Identifiable, Equatable, Codable, Sendable {
  let id: String
  let name: String
  let detail: String
  let systemImage: String
  let safety: StorageSafety
  let bytes: UInt64
  let items: [StorageItem]
}

struct StorageScanResult: Equatable, Codable, Sendable {
  let categories: [StorageCategory]
  let scannedAt: Date
  let simulatorDeviceCount: Int
  let bootedSimulatorCount: Int
  let simulatorDevices: [SimulatorDeviceInfo]
}

struct SimulatorDeviceInfo: Identifiable, Equatable, Codable, Sendable {
  let id: String
  let name: String
  let runtime: String
  let state: String
  let lastBootedAt: Date?
  let bytes: UInt64
}

@MainActor
final class StorageBreakdownModel: ObservableObject {
  private static let automaticScanInterval: TimeInterval = 60 * 60
  let overview = CleanupOverviewModel(.application)

  @Published private(set) var categories: [StorageCategory] = []
  @Published private(set) var scannedAt: Date?
  @Published private(set) var isScanning = false
  @Published private(set) var isCleaning = false
  @Published private(set) var simulatorDeviceCount = 0
  @Published private(set) var bootedSimulatorCount = 0
  @Published private(set) var simulatorDevices: [SimulatorDeviceInfo] = []
  @Published private(set) var cleanupMessage: String?
  @Published private(set) var cleanupCompletedCount = 0
  @Published private(set) var cleanupTotalCount = 0
  @Published private(set) var stoppingProcessPath: String?
  @Published var selectedPaths: Set<String> = []

  private let scanner = StorageBreakdownScanner()
  private let cleanupService = DeveloperCleanupService()
  private let processController = ProjectProcessController()
  private var scanTask: Task<Void, Never>?

  init() {
    guard let cachedResult = StorageScanCache.load() else {
      return
    }

    categories = cachedResult.categories
    scannedAt = cachedResult.scannedAt
    simulatorDeviceCount = cachedResult.simulatorDeviceCount
    bootedSimulatorCount = cachedResult.bootedSimulatorCount
    simulatorDevices = cachedResult.simulatorDevices
  }

  func scanIfNeeded() {
    overview.refreshIfNeeded()
    if let scannedAt,
      Date().timeIntervalSince(scannedAt) < Self.automaticScanInterval
    {
      return
    }

    scan()
  }

  func scan() {
    overview.refreshIfNeeded()
    guard !isScanning else {
      return
    }

    isScanning = true
    let scanner = scanner

    scanTask = Task.detached(priority: .utility) { [weak self] in
      guard let self else {
        return
      }

      let result = scanner.scan { update in
        Task { @MainActor in
          self.applyScanUpdate(update)
        }
      }
      await self.applyScan(result)
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

  private func applyScan(_ result: StorageScanResult) {
    categories = result.categories
    scannedAt = result.scannedAt
    simulatorDeviceCount = result.simulatorDeviceCount
    bootedSimulatorCount = result.bootedSimulatorCount
    simulatorDevices = result.simulatorDevices
    selectedPaths.formIntersection(readyItems.map(\.path))
    isScanning = false
    StorageScanCache.save(result)
  }

  var readyItems: [StorageItem] {
    categories.flatMap(\.items).filter { item in
      item.cleanupAvailability?.isReady == true && FileManager.default.fileExists(atPath: item.path)
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
      if result.failureCount == 0 {
        cleanupMessage = "Stopped \(result.signaledCount) process(es). Rescanning before selection."
      } else {
        cleanupMessage =
          "Stopped \(result.signaledCount); \(result.failureCount) could not be stopped."
      }
      scan()
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
      scan()
    }
  }
}

struct StorageSelection {
  let path: String
  let isSelected: Bool
}

struct OldDependencySelection {
  let days: Int
  let isSelected: Bool
}

enum StorageScanUpdate: Sendable {
  case category(StorageCategory)
  case simulators([SimulatorDeviceInfo])
}

enum StorageScanCache {
  private static let key = "storage-scan-result-v4"

  static func load() -> StorageScanResult? {
    guard let data = UserDefaults.standard.data(forKey: key) else {
      return nil
    }

    return try? JSONDecoder().decode(StorageScanResult.self, from: data)
  }

  static func save(_ result: StorageScanResult) {
    guard let data = try? JSONEncoder().encode(result) else {
      return
    }

    UserDefaults.standard.set(data, forKey: key)
  }
}

struct StorageBreakdownScanner: Sendable {
  private var fileManager: FileManager {
    FileManager.default
  }

  func scan(_ onUpdate: @escaping @Sendable (StorageScanUpdate) -> Void) -> StorageScanResult {
    let home = fileManager.homeDirectoryForCurrentUser.path
    let simulatorState = simulatorState()
    onUpdate(.simulators(simulatorState.devices))
    var categories: [StorageCategory] = []

    for definition in fixedCategories(home) {
      let scannedCategory = category(
        CategoryRequest(definition: definition, simulatorState: simulatorState)
      )
      categories.append(scannedCategory)
      onUpdate(.category(scannedCategory))
    }
    let activeProcesses = ProjectProcessScanner().processes()
    let activeWorkingDirectories = Set(activeProcesses.map(\.workingDirectory))

    let projectRoots = existingPaths(
      [
        "\(home)/dev",
        "\(home)/Developer",
        "\(home)/Projects",
        "\(home)/Documents",
      ] + DeveloperLocations.additionalProjectRoots)
    let nodeModules = nodeModulesCategory(
      NodeModulesScanRequest(
        roots: projectRoots,
        activeWorkingDirectories: activeWorkingDirectories,
        activeProcesses: activeProcesses
      )
    )
    categories.append(nodeModules)
    onUpdate(.category(nodeModules))

    let largeFileRoots = existingPaths(
      [
        "\(home)/Desktop",
        "\(home)/Documents",
        "\(home)/Downloads",
        "\(home)/Movies",
        "\(home)/dev",
      ] + DeveloperLocations.additionalProjectRoots)
    let largeFiles = largeFilesCategory(largeFileRoots)
    categories.append(largeFiles)
    onUpdate(.category(largeFiles))

    return StorageScanResult(
      categories: categories.sorted { left, right in
        left.bytes > right.bytes
      },
      scannedAt: .now,
      simulatorDeviceCount: simulatorState.deviceCount,
      bootedSimulatorCount: simulatorState.bootedCount,
      simulatorDevices: simulatorState.devices
    )
  }

  private func fixedCategories(_ home: String) -> [CategoryDefinition] {
    [
      CategoryDefinition(
        id: "computer-applications",
        name: "Applications",
        detail: "Installed apps",
        systemImage: "app.dashed",
        safety: .review,
        paths: [
          "/Applications",
          "\(home)/Applications",
        ]
      ),
      CategoryDefinition(
        id: "computer-personal-files",
        name: "Personal Files",
        detail: "Documents, downloads, media, and desktop files",
        systemImage: "folder.fill",
        safety: .review,
        paths: [
          "\(home)/Desktop",
          "\(home)/Downloads",
          "\(home)/Movies",
          "\(home)/Music",
          "\(home)/Pictures",
        ]
      ),
      CategoryDefinition(
        id: "computer-library-data",
        name: "Library & App Data",
        detail: "App support, developer data, caches, and containers",
        systemImage: "books.vertical.fill",
        safety: .review,
        paths: [
          "\(home)/Library/Application Support",
          "\(home)/Library/Developer",
          "\(home)/Library/Caches",
          "\(home)/Library/Containers",
          "\(home)/Library/Group Containers",
          "\(home)/Library/Mobile Documents",
        ]
      ),
      CategoryDefinition(
        id: "computer-system-data",
        name: "System Data",
        detail: "Shared libraries, package managers, and temporary data",
        systemImage: "apple.logo",
        safety: .review,
        paths: [
          "/Library",
          "/private/var",
          "/opt",
          "/usr/local",
        ]
      ),
      CategoryDefinition(
        id: "xcode",
        name: "Xcode",
        detail: "DerivedData, archives, and device support",
        systemImage: "hammer",
        safety: .caution,
        paths: [
          "\(home)/Library/Developer/Xcode/DerivedData",
          "\(home)/Library/Developer/Xcode/Archives",
          "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
        ]
      ),
      CategoryDefinition(
        id: "simulators",
        name: "Apple Simulators",
        detail: "Simulator devices and caches",
        systemImage: "iphone.gen3",
        safety: .caution,
        paths: [
          "\(home)/Library/Developer/CoreSimulator/Devices",
          "\(home)/Library/Developer/CoreSimulator/Caches",
        ]
      ),
      CategoryDefinition(
        id: "android",
        name: "Android",
        detail: "SDK and emulators",
        systemImage: "shippingbox",
        safety: .caution,
        paths: [
          "\(home)/Library/Android/sdk",
          "\(home)/.android/avd",
        ]
      ),
      CategoryDefinition(
        id: "package-caches",
        name: "Package Caches",
        detail: "Homebrew, npm, pnpm, Bun, pip, SwiftPM, and CocoaPods",
        systemImage: "shippingbox.fill",
        safety: .safe,
        paths: [
          "\(home)/Library/Caches/Homebrew",
          "\(home)/.npm/_cacache",
          "\(home)/Library/pnpm/store",
          "\(home)/.bun/install/cache",
          "\(home)/Library/Caches/pip",
          "\(home)/.cache/uv",
          "\(home)/Library/Caches/org.swift.swiftpm",
          "\(home)/Library/Caches/CocoaPods",
        ]
      ),
      CategoryDefinition(
        id: "build-caches",
        name: "Build Caches",
        detail: "Gradle, Maven, Bazel, and wrapper distributions",
        systemImage: "wrench.and.screwdriver.fill",
        safety: .safe,
        paths: [
          "\(home)/.gradle/caches",
          "\(home)/.gradle/wrapper/dists",
          "\(home)/.m2/repository",
          "\(home)/.cache/bazel",
        ]
      ),
      CategoryDefinition(
        id: "claude",
        name: "Claude",
        detail: "CLI and desktop app data",
        systemImage: "brain",
        safety: .review,
        paths: [
          "\(home)/.claude",
          "\(home)/Library/Application Support/Claude",
          "\(home)/Library/Caches/Claude",
        ]
      ),
      CategoryDefinition(
        id: "cursor",
        name: "Cursor",
        detail: "Editor data and caches",
        systemImage: "cursorarrow.rays",
        safety: .caution,
        paths: [
          "\(home)/.cursor",
          "\(home)/Library/Application Support/Cursor",
          "\(home)/Library/Caches/Cursor",
          "\(home)/Library/Caches/com.todesktop.230313mzl4w4u92",
        ]
      ),
      CategoryDefinition(
        id: "ai-models",
        name: "AI Models",
        detail: "Ollama, Hugging Face, and LM Studio",
        systemImage: "cpu",
        safety: .caution,
        paths: [
          "\(home)/.ollama",
          "\(home)/.cache/huggingface",
          "\(home)/.lmstudio",
          "\(home)/.cache/lm-studio",
        ]
      ),
    ]
  }

  private func category(_ request: CategoryRequest) -> StorageCategory {
    let definition = request.definition
    let sizes = directorySizes(existingPaths(definition.paths))
    let items = sizes.map { pathSize in
      let isSimulatorCache =
        definition.id == "simulators"
        && URL(fileURLWithPath: pathSize.path).lastPathComponent == "Caches"
      return StorageItem(
        name: abbreviatedPath(pathSize.path),
        path: pathSize.path,
        bytes: pathSize.bytes,
        cleanupKind: isSimulatorCache ? .simulatorCache : nil,
        cleanupAvailability: isSimulatorCache
          ? simulatorCacheAvailability(request.simulatorState)
          : nil,
        lastActivityAt: nil,
        contentBytes: nil,
        nodeOrigin: nil,
        projectRootPath: nil,
        dependencyInstalledAt: nil,
        activeProcesses: nil
      )
    }.sorted { left, right in
      left.bytes > right.bytes
    }

    return StorageCategory(
      id: definition.id,
      name: definition.name,
      detail: definition.detail,
      systemImage: definition.systemImage,
      safety: definition.safety,
      bytes: items.reduce(0) { result, item in
        result + item.bytes
      },
      items: items
    )
  }

  private func nodeModulesCategory(_ request: NodeModulesScanRequest) -> StorageCategory {
    let paths = Set(
      request.roots.flatMap { root in
        findPaths(
          FindRequest(
            root: root,
            arguments: ["-type", "d", "-name", "node_modules", "-prune", "-print0"]
          )
        )
      })
    let contexts = paths.map { path in
      NodeModulesResolver.resolve(
        NodeModulesResolutionRequest(
          nodeModulesPath: path,
          fileManager: fileManager
        )
      )
    }
    let contextsByTarget = Dictionary(grouping: contexts, by: \.cleanupTargetPath)
      .compactMapValues(\.first)
    let targets = Array(contextsByTarget.keys)
    let sizes = directorySizes(targets)
    let contentSizes = Dictionary(
      uniqueKeysWithValues: directoryContentSizes(targets).map { size in
        (size.path, size.bytes)
      }
    )
    var activityByProject: [String: Date?] = [:]
    let sortedItems = sizes.map { pathSize in
      guard let context = contextsByTarget[pathSize.path] else {
        return StorageItem(
          name: abbreviatedPath(pathSize.path),
          path: pathSize.path,
          bytes: pathSize.bytes,
          cleanupKind: .nodeModules,
          cleanupAvailability: .blocked("Project could not be resolved"),
          lastActivityAt: nil,
          contentBytes: contentSizes[pathSize.path],
          nodeOrigin: .project,
          projectRootPath: nil,
          dependencyInstalledAt: modificationDate(pathSize.path),
          activeProcesses: nil
        )
      }
      let availability = NodeModulesSafety.evaluate(
        NodeModulesSafetyRequest(
          context: context,
          activeWorkingDirectories: request.activeWorkingDirectories,
          fileManager: fileManager
        )
      )
      let activityRoot = context.projectRootPath ?? context.cleanupTargetPath
      let activityPrefix = activityRoot.hasSuffix("/") ? activityRoot : activityRoot + "/"
      let matchingProcesses = request.activeProcesses.filter { process in
        process.workingDirectory == activityRoot
          || process.workingDirectory.hasPrefix(activityPrefix)
      }
      let activity: Date?

      if let projectRootPath = context.projectRootPath, context.origin != .npmCache {
        if let cached = activityByProject[projectRootPath] {
          activity = cached
        } else {
          let resolved = ProjectActivityResolver.latestChange(
            ProjectActivityRequest(
              rootPath: projectRootPath,
              fileManager: fileManager
            )
          )
          activityByProject[projectRootPath] = resolved
          activity = resolved
        }
      } else {
        activity = nil
      }

      return StorageItem(
        name: context.displayName,
        path: pathSize.path,
        bytes: pathSize.bytes,
        cleanupKind: context.origin.isGenerated ? .generatedBuildCache : .nodeModules,
        cleanupAvailability: availability,
        lastActivityAt: activity,
        contentBytes: contentSizes[pathSize.path],
        nodeOrigin: context.origin,
        projectRootPath: context.projectRootPath,
        dependencyInstalledAt: modificationDate(pathSize.path),
        activeProcesses: matchingProcesses.isEmpty ? nil : matchingProcesses
      )
    }.sorted { left, right in
      left.bytes > right.bytes
    }

    return StorageCategory(
      id: "node-modules",
      name: "node_modules",
      detail: "Project dependency folders",
      systemImage: "shippingbox.fill",
      safety: .caution,
      bytes: sortedItems.reduce(0) { result, item in
        result + item.bytes
      },
      items: sortedItems
    )
  }

  private func largeFilesCategory(_ roots: [String]) -> StorageCategory {
    let paths = Set(
      roots.flatMap { root in
        spotlightPaths(
          SpotlightRequest(
            root: root,
            query: "kMDItemFSSize >= 1073741824"
          )
        )
      })
    let sortedItems = paths.compactMap { path -> StorageItem? in
      guard
        let attributes = try? fileManager.attributesOfItem(atPath: path),
        let size = (attributes[.size] as? NSNumber)?.uint64Value
      else {
        return nil
      }

      return StorageItem(
        name: URL(fileURLWithPath: path).lastPathComponent,
        path: path,
        bytes: size,
        cleanupKind: nil,
        cleanupAvailability: nil,
        lastActivityAt: nil,
        contentBytes: nil,
        nodeOrigin: nil,
        projectRootPath: nil,
        dependencyInstalledAt: nil,
        activeProcesses: nil
      )
    }.sorted { left, right in
      left.bytes > right.bytes
    }

    return StorageCategory(
      id: "large-files",
      name: "Large Files",
      detail: "Individual files over 1 GB",
      systemImage: "doc.fill",
      safety: .review,
      bytes: sortedItems.reduce(0) { result, item in
        result + item.bytes
      },
      items: Array(sortedItems.prefix(12))
    )
  }

  private func directorySizes(_ paths: [String]) -> [PathSize] {
    directorySizes(
      DirectorySizeRequest(
        paths: paths,
        duArguments: ["-sk"]
      )
    )
  }

  private func directoryContentSizes(_ paths: [String]) -> [PathSize] {
    directorySizes(
      DirectorySizeRequest(
        paths: paths,
        duArguments: ["-sk", "-A"]
      )
    )
  }

  private func directorySizes(_ request: DirectorySizeRequest) -> [PathSize] {
    let paths = request.paths
    guard !paths.isEmpty else {
      return []
    }

    let output: Data

    if paths.count > 1 {
      let input = paths.joined(separator: "\0") + "\0"
      output = commandOutput(
        CommandRequest(
          (
            executable: "/usr/bin/xargs",
            arguments: [
              "-0", "-P", "4", "-n", "1", "/usr/bin/du",
            ] + request.duArguments,
            standardInput: Data(input.utf8)
          ))
      )
    } else {
      output = commandOutput(
        CommandRequest(
          (
            executable: "/usr/bin/du",
            arguments: request.duArguments + paths,
            standardInput: nil
          ))
      )
    }

    let text = String(decoding: output, as: UTF8.self)
    var sizes: [PathSize] = []

    for line in text.split(separator: "\n") {
      guard
        let separatorIndex = line.firstIndex(of: "\t"),
        let kibibytes = UInt64(line[..<separatorIndex])
      else {
        continue
      }

      let pathStart = line.index(after: separatorIndex)
      sizes.append(
        PathSize(
          path: String(line[pathStart...]),
          bytes: kibibytes * 1_024
        )
      )
    }

    return sizes
  }

  private func findPaths(_ request: FindRequest) -> [String] {
    let output = commandOutput(
      CommandRequest(
        (
          executable: "/usr/bin/find",
          arguments: [request.root] + request.arguments,
          standardInput: nil
        ))
    )

    return output.split(separator: 0).map { data in
      String(decoding: data, as: UTF8.self)
    }
  }

  private func spotlightPaths(_ request: SpotlightRequest) -> [String] {
    let output = commandOutput(
      CommandRequest(
        (
          executable: "/usr/bin/mdfind",
          arguments: ["-0", "-onlyin", request.root, request.query],
          standardInput: nil
        ))
    )

    return output.split(separator: 0).map { data in
      String(decoding: data, as: UTF8.self)
    }
  }

  private func commandOutput(_ request: CommandRequest) -> Data {
    let outputPipe = Pipe()
    let inputPipe = request.standardInput == nil ? nil : Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: request.executable)
    process.arguments = request.arguments
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = inputPipe

    do {
      try process.run()

      if let standardInput = request.standardInput, let inputPipe {
        try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
        try inputPipe.fileHandleForWriting.close()
      }

      let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return output
    } catch {
      return Data()
    }
  }

  private func existingPaths(_ paths: [String]) -> [String] {
    paths.filter { path in
      fileManager.fileExists(atPath: path)
    }
  }

  private func abbreviatedPath(_ path: String) -> String {
    let home = fileManager.homeDirectoryForCurrentUser.path

    if path.hasPrefix(home) {
      return "~" + path.dropFirst(home.count)
    }

    return path
  }

  private func simulatorState() -> SimulatorState {
    let output = commandOutput(
      CommandRequest(
        (
          executable: "/usr/bin/xcrun",
          arguments: ["simctl", "list", "devices", "--json"],
          standardInput: nil
        ))
    )

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    guard let decoded = try? decoder.decode(SimulatorDeviceList.self, from: output) else {
      return SimulatorState(deviceCount: 0, bootedCount: 0, isKnown: false, devices: [])
    }

    let devices = decoded.devices.flatMap { runtime, devices in
      devices.map { device in
        SimulatorDeviceInfo(
          id: device.udid,
          name: device.name,
          runtime: simulatorRuntimeName(runtime),
          state: device.state,
          lastBootedAt: device.lastBootedAt,
          bytes: device.dataPathSize ?? 0
        )
      }
    }.sorted { left, right in
      if left.state == "Booted" && right.state != "Booted" {
        return true
      }

      return (left.lastBootedAt ?? .distantPast) > (right.lastBootedAt ?? .distantPast)
    }
    return SimulatorState(
      deviceCount: devices.count,
      bootedCount: devices.filter { $0.state == "Booted" }.count,
      isKnown: true,
      devices: devices
    )
  }

  private func simulatorRuntimeName(_ identifier: String) -> String {
    identifier
      .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
      .replacingOccurrences(of: "-", with: " ")
  }

  private func modificationDate(_ path: String) -> Date? {
    try? URL(fileURLWithPath: path)
      .resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
  }

  private func simulatorCacheAvailability(_ state: SimulatorState) -> StorageCleanupAvailability {
    guard state.isKnown else {
      return .blocked("Simulator state unavailable")
    }

    guard state.bootedCount == 0 else {
      return .blocked("Simulator is running")
    }

    return .ready
  }
}

enum NodeModulesSafety {
  static func evaluate(_ request: NodeModulesSafetyRequest) -> StorageCleanupAvailability {
    let context = request.context
    let root = context.projectRootPath ?? context.cleanupTargetPath
    let activityRoot = ReviewFile.canonicalPath(root) ?? root
    let projectPrefix = activityRoot.hasSuffix("/") ? activityRoot : activityRoot + "/"
    let isActive = request.activeWorkingDirectories.contains { path in
      if path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
        return true
      }
      let physicalPath = ReviewFile.canonicalPath(path) ?? path
      return physicalPath == activityRoot || physicalPath.hasPrefix(projectPrefix)
    }
    guard !isActive else {
      return .blocked("Project is in use")
    }

    if context.origin.isGenerated {
      return .ready
    }

    guard context.manifestPath != nil else {
      return .blocked("Missing package.json")
    }

    guard context.lockfilePath != nil else {
      return .blocked("No exact reinstall lock")
    }

    return .ready
  }
}

private struct CategoryDefinition: Sendable {
  let id: String
  let name: String
  let detail: String
  let systemImage: String
  let safety: StorageSafety
  let paths: [String]
}

private struct CategoryRequest {
  let definition: CategoryDefinition
  let simulatorState: SimulatorState
}

private struct NodeModulesScanRequest {
  let roots: [String]
  let activeWorkingDirectories: Set<String>
  let activeProcesses: [ProjectProcessInfo]
}

struct NodeModulesSafetyRequest {
  let context: NodeModulesContext
  let activeWorkingDirectories: Set<String>
  let fileManager: FileManager
}

private struct SimulatorState {
  let deviceCount: Int
  let bootedCount: Int
  let isKnown: Bool
  let devices: [SimulatorDeviceInfo]
}

private struct SimulatorDeviceList: Decodable {
  let devices: [String: [SimulatorDevice]]
}

private struct SimulatorDevice: Decodable {
  let udid: String
  let name: String
  let state: String
  let lastBootedAt: Date?
  let dataPathSize: UInt64?
}

private struct PathSize: Sendable {
  let path: String
  let bytes: UInt64
}

private struct DirectorySizeRequest {
  let paths: [String]
  let duArguments: [String]
}

private struct FindRequest: Sendable {
  let root: String
  let arguments: [String]
}

private struct SpotlightRequest: Sendable {
  let root: String
  let query: String
}

private struct CommandRequest: Sendable {
  let executable: String
  let arguments: [String]
  let standardInput: Data?

  init(_ input: (executable: String, arguments: [String], standardInput: Data?)) {
    executable = input.executable
    arguments = input.arguments
    standardInput = input.standardInput
  }
}
