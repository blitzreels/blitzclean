import Foundation

struct ResourceHistoryStore {
  let url: URL
  static let maximumBytes = 512 * 1_024

  static var application: Self {
    .init(url: AppData.file("resource-history.json"))
  }

  func load() throws -> [ResourceSample] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    guard data.count <= Self.maximumBytes else {
      try preserveUnreadableFile()
      throw CocoaError(.fileReadTooLarge)
    }
    let samples: [ResourceSample]
    do {
      samples = try JSONDecoder().decode([ResourceSample].self, from: data)
    } catch {
      try preserveUnreadableFile()
      throw error
    }
    var history = ResourceHistory.persisted
    history.restore(samples)
    return history.samples
  }

  func save(_ samples: [ResourceSample]) throws {
    var history = ResourceHistory.persisted
    history.restore(samples)
    let data = try JSONEncoder().encode(history.samples)
    guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func preserveUnreadableFile() throws {
    let backup = url.deletingLastPathComponent().appendingPathComponent(
      "\(url.lastPathComponent).unreadable-\(UUID().uuidString)")
    try FileManager.default.moveItem(at: url, to: backup)
  }
}
