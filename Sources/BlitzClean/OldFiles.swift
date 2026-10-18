import CoreServices
import Darwin
import Foundation

enum OldFileSource: String, Codable, Sendable {
  case downloads = "Downloads"
  case screenshots = "Screenshot"
}

enum OldFileAge: Int, CaseIterable, Identifiable, Sendable {
  case threeMonths = 3
  case sixMonths = 6
  case oneYear = 12

  var id: Int { rawValue }
  var title: String {
    switch self {
    case .threeMonths: "3 months"
    case .sixMonths: "6 months"
    case .oneYear: "1 year"
    }
  }

  func cutoff(from date: Date) -> Date {
    Calendar.current.date(byAdding: .month, value: -rawValue, to: date)
      ?? date.addingTimeInterval(-Double(rawValue) * 30 * 86_400)
  }
}

/// A top-level item in Downloads, or a screenshot, that has not been used since the cutoff.
struct OldFileItem: Codable, Equatable, Identifiable, Sendable {
  let path: String
  let bytes: UInt64
  /// Newest of the date added, last change (anywhere inside a folder) and last open.
  let lastUsedAt: Date
  let isFolder: Bool
  let source: OldFileSource
  let device: Int32
  let inode: UInt64

  var id: String { path }
  var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct OldFileScanRequest: Sendable {
  let downloads: String
  let screenshotFolders: [String]
  let cutoff: Date
  /// Folder contents read per item before it counts as unmeasured and is left out.
  let folderEntryLimit: Int
  let eligible: @Sendable (String) -> Bool
  /// Dates that count as use: added, modified and last opened.
  let usageDates: @Sendable (URL) -> [Date]

  static func standard(cutoff: Date) -> Self {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var screenshots = [home.appendingPathComponent("Desktop").path]
    if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
      let path = (custom as NSString).expandingTildeInPath
      if !screenshots.contains(path) { screenshots.append(path) }
    }
    return Self(
      downloads: home.appendingPathComponent("Downloads").path, screenshotFolders: screenshots,
      cutoff: cutoff, folderEntryLimit: 20_000, eligible: ReviewFileDeletion.canTrashPath,
      usageDates: OldFileScanner.usageDates)
  }
}

struct OldFileScanResult: Sendable {
  let items: [OldFileItem]
  /// Items left out because their contents could not be fully read.
  let unmeasured: Int
}

enum OldFileScanner {
  static let screenshotPrefixes = [
    "Screenshot ", "Screen Shot ", "Screen Recording ", "CleanShot ",
  ]
  private static let partialDownloads: Set<String> = ["download", "crdownload", "part", "partial"]

  static func scan(_ request: OldFileScanRequest) -> OldFileScanResult {
    var items: [OldFileItem] = []
    var unmeasured = 0
    for url in children(request.downloads) {
      guard !Task.isCancelled else { break }
      switch read(.init(url: url, source: .downloads, request: request)) {
      case .old(let item): items.append(item)
      case .unmeasured: unmeasured += 1
      case .recent, .ineligible: break
      }
    }
    var seen = Set(items.map(\.path))
    for folder in request.screenshotFolders {
      for url in children(folder) where isScreenshot(url.lastPathComponent) {
        guard !Task.isCancelled else { break }
        if case .old(let item) = read(.init(url: url, source: .screenshots, request: request)),
          seen.insert(item.path).inserted
        {
          items.append(item)
        }
      }
    }
    return OldFileScanResult(
      items: items.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes },
      unmeasured: unmeasured)
  }

  static func isScreenshot(_ name: String) -> Bool {
    let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
    return screenshotPrefixes.contains { name.hasPrefix($0) }
      && ["png", "jpg", "jpeg", "heic", "tiff", "gif", "mov", "mp4"].contains(ext)
  }

  private static func children(_ folder: String) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles])) ?? []
  }

  enum Reading: Equatable {
    case old(OldFileItem)
    case recent, unmeasured, ineligible
  }

  struct ReadRequest {
    let url: URL
    let source: OldFileSource
    let request: OldFileScanRequest
  }

  static func read(_ input: ReadRequest) -> Reading {
    let path = input.url.path
    var info = stat()
    guard lstat(path, &info) == 0, let physical = ReviewFile.canonicalPath(path) else {
      return .ineligible
    }
    let type = info.st_mode & S_IFMT
    guard type == S_IFREG || type == S_IFDIR,
      !partialDownloads.contains(input.url.pathExtension.lowercased()),
      input.request.eligible(physical)
    else { return .ineligible }
    var newest = input.request.usageDates(URL(fileURLWithPath: physical)).max() ?? .distantFuture
    guard newest < input.request.cutoff else { return .recent }
    var bytes = UInt64(max(0, info.st_blocks)) * 512
    if type == S_IFDIR {
      guard
        let contents = folder(
          .init(path: physical, limit: input.request.folderEntryLimit, cutoff: input.request.cutoff)
        )
      else { return .unmeasured }
      guard contents.newest < input.request.cutoff else { return .recent }
      bytes += contents.bytes
      newest = max(newest, contents.newest)
    }
    return .old(
      OldFileItem(
        path: physical, bytes: bytes, lastUsedAt: newest, isFolder: type == S_IFDIR,
        source: input.source, device: info.st_dev, inode: info.st_ino))
  }

  struct FolderRequest {
    let path: String
    let limit: Int
    let cutoff: Date
  }

  struct FolderContents {
    let bytes: UInt64
    let newest: Date
  }

  /// Nil when the folder could not be read completely; a partial read is never called old.
  static func folder(_ request: FolderRequest) -> FolderContents? {
    let keys: [URLResourceKey] = [
      .isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey,
      .totalFileAllocatedSizeKey,
    ]
    var failed = false
    guard
      let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: request.path), includingPropertiesForKeys: keys,
        options: [],
        errorHandler: { _, _ in
          failed = true
          return false
        })
    else { return nil }
    var bytes: UInt64 = 0
    var newest = Date.distantPast
    var count = 0
    for case let url as URL in enumerator {
      count += 1
      guard count <= request.limit, !Task.isCancelled,
        let values = try? url.resourceValues(forKeys: Set(keys))
      else { return nil }
      if let modified = values.contentModificationDate {
        newest = max(newest, modified)
        if newest >= request.cutoff { return FolderContents(bytes: bytes, newest: newest) }
      }
      if values.isRegularFile == true, values.isSymbolicLink != true {
        bytes += UInt64(max(0, values.totalFileAllocatedSize ?? 0))
      }
    }
    return failed ? nil : FolderContents(bytes: bytes, newest: newest)
  }

  static func usageDates(_ url: URL) -> [Date] {
    let values = try? url.resourceValues(forKeys: [
      .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey,
    ])
    return [
      values?.addedToDirectoryDate ?? values?.creationDate, values?.contentModificationDate,
      lastOpened(url.path),
    ].compactMap { $0 }
  }

  static func lastOpened(_ path: String) -> Date? {
    guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
    return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
  }
}

struct OldFileTrashRequest: Sendable {
  let item: OldFileItem
  /// The same age and eligibility rules the scan used.
  let rules: OldFileScanRequest
}

enum OldFileTrash {
  /// Also rechecks that the item is still unused before moving it.
  static func trash(_ request: OldFileTrashRequest) throws -> TrashedItem {
    let item = request.item
    return try PersonalTrash.move(
      .init(
        identity: .init(
          path: item.path, device: item.device, inode: item.inode, isFolder: item.isFolder),
        recheck: {
          let reading = OldFileScanner.read(
            .init(url: URL(fileURLWithPath: item.path), source: item.source, request: request.rules)
          )
          guard case .old = reading else { throw PersonalTrashError.used }
        }))
  }
}
