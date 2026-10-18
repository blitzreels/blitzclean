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

enum StorageCleanupFocus: Hashable {
  case oldFiles, largeFiles, caches, simulators, regrown, projects, docker
}

enum ProjectProcessStopMessage {
  static func text(_ result: StopProjectProcessesResult) -> String {
    var parts = ["Stopped \(result.signaledCount) process(es)"]
    if result.changedCount > 0 {
      parts.append(
        "\(result.changedCount) already exited or changed since the scan and were left alone")
    }
    if result.failureCount > 0 { parts.append("\(result.failureCount) could not be stopped") }
    return parts.joined(separator: "; ") + ". Rescanning before selection."
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
  private static let key = "storage-scan-result-v6"

  static func load() -> StorageScanResult? {
    UserDefaults.standard.removeObject(forKey: "storage-scan-result-v5")
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
