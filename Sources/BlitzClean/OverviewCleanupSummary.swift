import Foundation

struct OverviewCleanupSummary: Equatable {
  enum Source: String, CaseIterable {
    case caches = "Caches"
    case reports = "Diagnostic reports"
    case projects = "Project data"
    case regrown = "Regrown folders"
    case simulators = "Simulated devices"
    case docker = "Docker"
  }

  struct Item {
    let path: String
    let bytes: UInt64
    let source: Source
  }

  struct Input {
    let items: [Item]
    let dockerBytes: UInt64
    let hasSkippedLocations: Bool
    let dockerUnavailable: Bool
  }

  let bytesBySource: [Source: UInt64]
  let hasSkippedLocations: Bool
  let dockerUnavailable: Bool

  init(_ input: Input) {
    var unique: [String: Item] = [:]
    for item in input.items where item.bytes > 0 {
      let path = URL(fileURLWithPath: item.path).standardizedFileURL.path
      if item.bytes > (unique[path]?.bytes ?? 0) {
        unique[path] = Item(path: path, bytes: item.bytes, source: item.source)
      }
    }
    var roots: [String] = []
    var totals: [Source: UInt64] = [:]
    for item in unique.values.sorted(by: { $0.path < $1.path }) {
      guard !roots.contains(where: { item.path.hasPrefix($0 + "/") }) else { continue }
      roots.append(item.path)
      totals[item.source, default: 0] += item.bytes
    }
    if input.dockerBytes > 0, !input.dockerUnavailable { totals[.docker] = input.dockerBytes }
    bytesBySource = totals
    hasSkippedLocations = input.hasSkippedLocations
    dockerUnavailable = input.dockerUnavailable
  }

  var totalBytes: UInt64 { bytesBySource.values.reduce(0, +) }
  var isPartial: Bool { hasSkippedLocations || dockerUnavailable }
  var breakdown: String {
    Source.allCases.compactMap { source in
      bytesBySource[source].map { "\(source.rawValue) \(ByteText.full($0))" }
    }.joined(separator: " · ")
  }

  var emptyMessage: String {
    isPartial
      ? "No cleanup available in checked locations; some locations could not be checked."
      : "No cleanup available in the checked locations."
  }
}

@MainActor
extension OverviewCleanupSummary {
  struct Models {
    let caches: QuickCleanModel
    let storage: StorageBreakdownModel
    let repeats: RepeatCleanupModel
    let docker: DockerStorageModel
  }

  init(models: Models) {
    var items = models.caches.candidates.map {
      Item(
        path: $0.path, bytes: $0.tree.bytes,
        source: $0.rule.kind == .cache ? .caches : .reports)
    }
    items += models.storage.readyItems.map {
      Item(path: $0.path, bytes: $0.bytes, source: .projects)
    }
    items += models.repeats.ready.filter { $0.target.recipe != .pnpmPrune }.map {
      Item(
        path: $0.target.path, bytes: models.repeats.statuses[$0.id]?.bytes ?? 0, source: .regrown)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    items += models.storage.simulatorDevices.filter { $0.state == "Shutdown" }.map {
      Item(
        path: home + "/Library/Developer/CoreSimulator/Devices/" + $0.id,
        bytes: $0.bytes, source: .simulators)
    }
    self.init(
      .init(
        items: items,
        dockerBytes: models.docker.errorMessage == nil
          ? models.docker.snapshot?.rebuildableBytes ?? 0 : 0,
        hasSkippedLocations: !models.caches.notes.isEmpty,
        dockerUnavailable: models.docker.isInstalled && models.docker.errorMessage != nil))
  }
}
