import Foundation

struct StorageVolumeContext: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let rootPath: String
  let availableBytes: UInt64
  let totalBytes: UInt64

  var usedBytes: UInt64 {
    totalBytes > availableBytes ? totalBytes - availableBytes : 0
  }

  func contains(_ path: String) -> Bool {
    if rootPath == "/" {
      return !path.hasPrefix("/Volumes/")
    }

    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    return path == rootPath || path.hasPrefix(prefix)
  }
}

struct StorageVolumeCoverage: Equatable, Sendable {
  let identifiedBytes: UInt64
  let otherBytes: UInt64
}

struct StorageVolumeBreakdownRequest: Sendable {
  let categories: [StorageCategory]
  let volume: StorageVolumeContext
}

struct StorageVolumeBreakdownResult: Sendable {
  let categories: [StorageCategory]
  let coverage: StorageVolumeCoverage
}

enum StorageVolumeBreakdown {
  static func result(_ request: StorageVolumeBreakdownRequest) -> StorageVolumeBreakdownResult {
    let categories: [StorageCategory] = request.categories.compactMap {
      category -> StorageCategory? in
      let items = category.items.filter { item in
        request.volume.contains(item.path)
      }
      guard !items.isEmpty else {
        return nil
      }

      return StorageCategory(
        id: category.id,
        name: category.name,
        detail: category.detail,
        systemImage: category.systemImage,
        safety: category.safety,
        bytes: identifiedBytes(items),
        items: items
      )
    }

    let identifiedTotal = identifiedBytes(categories.flatMap(\.items))
    let boundedIdentifiedBytes = min(request.volume.usedBytes, identifiedTotal)
    let otherBytes = request.volume.usedBytes - boundedIdentifiedBytes
    var completeCategories = categories

    if otherBytes > 0 {
      completeCategories.append(
        StorageCategory(
          id: "other-storage",
          name: "Other files & macOS",
          detail: "Apps, documents, media, and system data",
          systemImage: "internaldrive.fill",
          safety: .review,
          bytes: otherBytes,
          items: []
        )
      )
    }

    completeCategories.sort { left, right in
      left.bytes > right.bytes
    }

    return StorageVolumeBreakdownResult(
      categories: completeCategories,
      coverage: StorageVolumeCoverage(
        identifiedBytes: boundedIdentifiedBytes,
        otherBytes: otherBytes
      )
    )
  }

  private static func identifiedBytes(_ items: [StorageItem]) -> UInt64 {
    let sortedItems = items.sorted { left, right in
      pathDepth(left.path) < pathDepth(right.path)
    }
    var accountedPaths: [String] = []
    var total: UInt64 = 0

    for item in sortedItems {
      let isAlreadyAccountedFor = accountedPaths.contains { path in
        item.path == path || item.path.hasPrefix(path + "/")
      }
      guard !isAlreadyAccountedFor else {
        continue
      }

      accountedPaths.append(item.path)
      total += item.bytes
    }

    return total
  }

  private static func pathDepth(_ path: String) -> Int {
    path.split(separator: "/").count
  }
}
