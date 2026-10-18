import Foundation

/// Finds rebuildable project dependencies and the simulator cache, the items Storage › Cleanup can
/// delete with one recipe. Drive, Browse and Largest files measure the disk with `FileTree` instead.
struct StorageBreakdownScanner: Sendable {
  struct Timing: Sendable {
    let stage: String
    let seconds: TimeInterval
  }

  var timing: @Sendable (Timing) -> Void = { _ in }
  var measure: @Sendable (String) -> DependencyFootprint? = DependencyFileScan.measure

  struct Request {
    /// Limits the scan to one folder the user chose; nil checks every project location.
    let projectRoot: String?
    let onUpdate: @Sendable (StorageScanUpdate) -> Void
  }
  private var fileManager: FileManager {
    FileManager.default
  }

  func scan(_ request: Request) -> StorageScanResult {
    if let root = request.projectRoot { return scanLocation(.init(root: root, request: request)) }
    let onUpdate = request.onUpdate
    let home = fileManager.homeDirectoryForCurrentUser.path
    let simulatorState = simulatorState()
    onUpdate(.simulators(simulatorState.devices))
    var categories: [StorageCategory] = []
    if let simulators = simulatorCacheCategory(.init(home: home, state: simulatorState)) {
      categories.append(simulators)
      onUpdate(.category(simulators))
    }
    let activeProcesses = ProjectProcessScanner().processes()
    let activeWorkingDirectories = Set((activeProcesses ?? []).map(\.workingDirectory))

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

  private struct LocationRequest {
    let root: String
    let request: Request
  }

  private func scanLocation(_ input: LocationRequest) -> StorageScanResult {
    let root = input.root
    let discovery = DependencyFileScan.discoverWithin(
      .init(root: root, deadline: .now.addingTimeInterval(15), maximumEntries: 150_000))
    let processes = ProjectProcessScanner().processes()
    let category = nodeModulesCategory(
      .init(
        roots: discovery.paths,
        activeWorkingDirectories: Set((processes ?? []).map(\.workingDirectory)),
        activeProcesses: processes, containingRoot: root))
    let checked = StorageCategory(
      id: category.id, name: "Project caches",
      detail: discovery.complete
        ? "Rebuild and activity checks for this location"
        : "Partial scan · choose a project folder to check the rest",
      systemImage: category.systemImage, safety: category.safety, bytes: category.bytes,
      items: category.items)
    input.request.onUpdate(.category(checked))
    return .init(
      categories: [checked], scannedAt: .now, simulatorDeviceCount: 0,
      bootedSimulatorCount: 0, simulatorDevices: [])
  }

  private struct SimulatorCacheRequest {
    let home: String
    let state: SimulatorState
  }

  private func simulatorCacheCategory(_ request: SimulatorCacheRequest) -> StorageCategory? {
    let path = request.home + "/Library/Developer/CoreSimulator/Caches"
    guard
      let footprint = FolderFootprint.measure(
        .init(path: path, deadline: .now.addingTimeInterval(60)))
    else { return nil }
    let item = StorageItem(
      name: abbreviatedPath(path), path: path, bytes: footprint.allocated,
      cleanupKind: .simulatorCache, cleanupAvailability: simulatorCacheAvailability(request.state),
      lastActivityAt: nil, contentBytes: footprint.content, nodeOrigin: nil, projectRootPath: nil,
      dependencyInstalledAt: nil, activeProcesses: nil)
    return StorageCategory(
      id: "simulators", name: "Apple Simulators", detail: "Simulator caches",
      systemImage: "iphone.gen3", safety: .caution, bytes: item.bytes, items: [item])
  }

  private func nodeModulesCategory(_ request: NodeModulesScanRequest) -> StorageCategory {
    var phase = Date.now
    let paths = DependencyFileScan.discover(request.roots)
    timing(.init(stage: "dependencies.discover", seconds: Date.now.timeIntervalSince(phase)))
    phase = .now
    let contexts = paths.map { path in
      NodeModulesResolver.resolve(
        NodeModulesResolutionRequest(
          nodeModulesPath: path,
          fileManager: fileManager
        )
      )
    }
    let containedContexts = contexts.filter { context in
      guard let root = request.containingRoot else { return true }
      guard let root = ReviewFile.canonicalPath(root),
        let target = ReviewFile.canonicalPath(context.cleanupTargetPath)
      else { return false }
      return target == root || target.hasPrefix(root + "/")
    }
    let contextsByTarget = Dictionary(grouping: containedContexts, by: \.cleanupTargetPath)
      .compactMapValues(\.first)
    let targets = Array(contextsByTarget.keys)
    timing(.init(stage: "dependencies.resolve", seconds: Date.now.timeIntervalSince(phase)))
    phase = .now
    let footprints = DependencyFileScan.measureAll(.init(paths: targets, measure: measure))
    let sizes = footprints.map { PathSize(path: $0.key, bytes: $0.value.allocated) }
    let contentSizes = footprints.mapValues(\.content)
    timing(.init(stage: "dependencies.sizes", seconds: Date.now.timeIntervalSince(phase)))
    phase = .now
    var activityByProject: [String: Date?] = [:]
    let activityDeadline = Date.now.addingTimeInterval(5)
    let sortedItems = sizes.sorted { $0.bytes > $1.bytes }.map { pathSize in
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
      let availability =
        request.activeProcesses == nil
        ? .blocked("Running processes could not be checked")
        : NodeModulesSafety.evaluate(
          NodeModulesSafetyRequest(
            context: context,
            activeWorkingDirectories: request.activeWorkingDirectories,
            fileManager: fileManager
          )
        )
      let activityRoot = context.projectRootPath ?? context.cleanupTargetPath
      let activityPrefix = activityRoot.hasSuffix("/") ? activityRoot : activityRoot + "/"
      let matchingProcesses = (request.activeProcesses ?? []).filter { process in
        process.workingDirectory == activityRoot
          || process.workingDirectory.hasPrefix(activityPrefix)
      }
      let activity: Date?

      if let projectRootPath = context.projectRootPath, context.origin != .npmCache {
        if let cached = activityByProject[projectRootPath] {
          activity = cached
        } else {
          let resolved = ProjectActivityResolver.scan(
            .init(
              rootPath: projectRootPath, maximumEntries: 20_000,
              deadline: min(activityDeadline, .now.addingTimeInterval(0.15))))
          activityByProject[projectRootPath] = .some(resolved)
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

    timing(
      .init(stage: "dependencies.activity-and-safety", seconds: Date.now.timeIntervalSince(phase)))
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
    let output = CommandRunner.run(
      .init(
        executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "--json"],
        timeout: 60, maximumBytes: 16 * 1_024 * 1_024, input: nil, environment: .inherited)
    ).data

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

private struct NodeModulesScanRequest {
  let roots: [String]
  let activeWorkingDirectories: Set<String>
  /// Nil when running processes could not be read; every dependency is then kept.
  let activeProcesses: [ProjectProcessInfo]?
  var containingRoot: String? = nil
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
