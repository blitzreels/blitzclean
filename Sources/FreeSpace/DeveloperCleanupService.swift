import Foundation

struct CleanupRequest: Sendable {
  let items: [StorageItem]
}

struct CleanupResult: Equatable, Sendable {
  let cleanedPaths: Set<String>
  let recoveredBytes: UInt64
  let failureCount: Int

  var message: String {
    if failureCount == 0 {
      return
        "Deleted \(cleanedPaths.count) item(s) · \(ByteText.full(recoveredBytes)) estimated size; check disk free for actual gain"
    }

    return "Deleted \(cleanedPaths.count) item(s) · \(failureCount) failed"
  }
}

struct DeveloperCleanupService: Sendable {
  private let deleteItem: @Sendable (URL) throws -> Void

  init(
    deleteItem: @escaping @Sendable (URL) throws -> Void = { url in
      try FileManager.default.removeItem(at: url)
    }
  ) {
    self.deleteItem = deleteItem
  }

  func clean(_ request: CleanupRequest) -> CleanupResult {
    var cleanedPaths: Set<String> = []
    var recoveredBytes: UInt64 = 0
    var failureCount = 0

    for item in request.items where item.cleanupAvailability?.isReady == true {
      do {
        try deleteItem(URL(fileURLWithPath: item.path))
        cleanedPaths.insert(item.path)
        recoveredBytes += item.bytes
      } catch {
        failureCount += 1
      }
    }

    return CleanupResult(
      cleanedPaths: cleanedPaths,
      recoveredBytes: recoveredBytes,
      failureCount: failureCount
    )
  }
}
