import Foundation

enum ReviewMediaKind: String, Codable, CaseIterable {
  case all = "All files"
  case video = "Videos"
  case image = "Images"
}

enum ReviewMediaAge: Int, Codable, CaseIterable {
  case any = 0
  case month = 30
  case quarter = 90
  case year = 365

  var title: String { self == .any ? "Any age" : "Older than \(rawValue) days" }
}

enum ReviewMediaSort: String, Codable, CaseIterable {
  case largest = "Largest first"
  case oldest = "Oldest first"
  case newest = "Newest first"
  case name = "Name"
}

struct MediaReviewFilter: Codable, Equatable, Sendable {
  var kind = ReviewMediaKind.all
  var format = "all"
  var age = ReviewMediaAge.any
  var sort = ReviewMediaSort.largest
  var query = ""

  func apply(_ input: FilterInput) -> [ReviewFile] {
    let cutoff = input.date.addingTimeInterval(-Double(age.rawValue) * 86_400)
    return input.files.filter { file in
      (kind == .all || (kind == .video ? file.kind == "Video" : file.kind == "Image"))
        && (format == "all" || URL(fileURLWithPath: file.path).pathExtension.lowercased() == format)
        && (age == .any || file.modifiedAt < cutoff)
        && (query.isEmpty || file.path.localizedCaseInsensitiveContains(query))
    }.sorted { left, right in
      switch sort {
      case .largest: left.bytes == right.bytes ? left.path < right.path : left.bytes > right.bytes
      case .oldest:
        left.modifiedAt == right.modifiedAt
          ? left.path < right.path : left.modifiedAt < right.modifiedAt
      case .newest:
        left.modifiedAt == right.modifiedAt
          ? left.path < right.path : left.modifiedAt > right.modifiedAt
      case .name: left.path.localizedStandardCompare(right.path) == .orderedAscending
      }
    }
  }

  struct FilterInput {
    let files: [ReviewFile]
    let date: Date
  }
}

struct MediaReviewSession: Codable, Sendable {
  let version: Int
  let request: ReviewScanRequest
  let filter: MediaReviewFilter
  let files: [ReviewFile]
  let scannedAt: Date?
  let limited: Bool
}

struct MediaReviewStore: Sendable {
  let url: URL
  static let maximumBytes = 8 * 1_024 * 1_024

  private var filterURL: URL { url.appendingPathExtension("filters.json") }

  func loadFilter() throws -> MediaReviewFilter? {
    guard FileManager.default.fileExists(atPath: filterURL.path) else { return nil }
    let data = try Data(contentsOf: filterURL)
    guard data.count < 32_768 else { throw CocoaError(.fileReadTooLarge) }
    return try JSONDecoder().decode(MediaReviewFilter.self, from: data)
  }

  func saveFilter(_ filter: MediaReviewFilter) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(filter).write(to: filterURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filterURL.path)
  }

  func load() throws -> MediaReviewSession? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maximumBytes else {
      throw CocoaError(.fileReadTooLarge)
    }
    let session = try JSONDecoder().decode(MediaReviewSession.self, from: Data(contentsOf: url))
    guard session.version == 1, session.files.count <= 5_000 else { return nil }
    return session
  }

  func save(_ session: MediaReviewSession) throws {
    let data = try JSONEncoder().encode(session)
    guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
