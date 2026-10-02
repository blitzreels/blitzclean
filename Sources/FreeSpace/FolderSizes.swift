import AppKit
import Darwin
import Foundation

struct FolderEntry: Identifiable, Equatable, Codable, Sendable {
  let path: String
  let name: String
  let isDirectory: Bool
  let isHidden: Bool
  var bytes: UInt64?
  var device: Int32?
  var inode: UInt64?

  var id: String {
    path
  }
}

struct FolderListing: Codable, Equatable, Sendable {
  let path: String
  let scannedAt: Date
  let entries: [FolderEntry]

  var totalBytes: UInt64 {
    entries.reduce(0) { result, entry in
      result + (entry.bytes ?? 0)
    }
  }
}

enum FolderListingSorter {
  static func sorted(_ entries: [FolderEntry]) -> [FolderEntry] {
    entries.sorted { left, right in
      switch (left.bytes, right.bytes) {
      case (let leftBytes?, let rightBytes?):
        if leftBytes != rightBytes {
          return leftBytes > rightBytes
        }

        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      case (.none, .none):
        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
      }
    }
  }
}

enum FolderSizeCache {
  private static let key = "folder-size-listings-v1"
  private static let maxEntries = 60

  static func load() -> [String: FolderListing] {
    guard let data = UserDefaults.standard.data(forKey: key),
      let listings = try? JSONDecoder().decode([String: FolderListing].self, from: data)
    else {
      return [:]
    }

    return listings
  }

  static func save(_ listings: [String: FolderListing]) {
    var trimmed = listings
    if trimmed.count > maxEntries {
      let oldest = trimmed.values.sorted { left, right in
        left.scannedAt < right.scannedAt
      }.prefix(trimmed.count - maxEntries)
      for listing in oldest {
        trimmed.removeValue(forKey: listing.path)
      }
    }

    guard let data = try? JSONEncoder().encode(trimmed) else {
      return
    }

    UserDefaults.standard.set(data, forKey: key)
  }
}

struct FolderSizeScanner: Sendable {
  func listing(of path: String) -> [FolderEntry] {
    let url = URL(fileURLWithPath: path)
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .totalFileAllocatedSizeKey, .fileSizeKey,
    ]
    guard
      let children = try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: Array(keys),
        options: []
      )
    else {
      return []
    }

    return children.compactMap { child in
      guard let values = try? child.resourceValues(forKeys: keys) else {
        return nil
      }

      let isSymbolicLink = values.isSymbolicLink ?? false
      let isDirectory = (values.isDirectory ?? false) && !isSymbolicLink
      let fileBytes = values.totalFileAllocatedSize ?? values.fileSize
      var identity = stat()
      guard lstat(child.path, &identity) == 0 else { return nil }
      return FolderEntry(
        path: child.path,
        name: child.lastPathComponent,
        isDirectory: isDirectory,
        isHidden: values.isHidden ?? child.lastPathComponent.hasPrefix("."),
        bytes: isDirectory ? nil : UInt64(max(0, fileBytes ?? 0)),
        device: identity.st_dev, inode: identity.st_ino
      )
    }
  }

}

@MainActor
final class FolderExplorerModel: ObservableObject {
  static let freshInterval: TimeInterval = 5 * 60

  @Published private(set) var path: String
  @Published private(set) var entries: [FolderEntry] = []
  @Published private(set) var isScanning = false
  @Published private(set) var pendingCount = 0
  @Published private(set) var scannedAt: Date?
  @Published private(set) var statusMessage: String?
  @Published var showsHidden = true
  @Published var query = ""
  @Published var selected: Set<String> = []
  @Published private(set) var isTrashing = false
  @Published private(set) var visited = 0
  @Published private(set) var sizesPartial = false
  @Published private(set) var backPaths: [String] = []
  @Published private(set) var forwardPaths: [String] = []

  private let scanner = FolderSizeScanner()
  private var cache: [String: FolderListing]
  private var scanTask: Task<Void, Never>?
  private var sizeTask: Task<DriveScanProgress, Never>?
  private var generation = 0

  init(path: String = "/") {
    self.path = path
    cache = FolderSizeCache.load()
  }

  var homePath: String {
    FileManager.default.homeDirectoryForCurrentUser.path
  }

  var breadcrumbs: [(title: String, path: String)] {
    let components = path.split(separator: "/").map(String.init)
    var crumbs: [(title: String, path: String)] = [("Mac", "/")]
    var current = ""
    for component in components {
      current += "/" + component
      crumbs.append((component, current))
    }

    return crumbs
  }

  var largestEntries: [FolderEntry] {
    Array(entries.filter { entry in entry.bytes != nil }.prefix(3))
  }

  var visibleEntries: [FolderEntry] {
    entries.filter {
      (showsHidden || !$0.isHidden)
        && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
    }
  }

  var maxBytes: UInt64 {
    entries.compactMap(\.bytes).max() ?? 0
  }

  func cachedListing(_ path: String) -> FolderListing? {
    cache[path]
  }

  func loadIfNeeded() {
    guard !isScanning else { return }
    guard
      entries.isEmpty || scannedAt == nil
        || Date.now.timeIntervalSince(scannedAt ?? .distantPast) >= Self.freshInterval
    else { return }
    open(path)
  }

  func open(_ newPath: String) {
    let resolved = ReviewFile.canonicalPath(newPath) ?? newPath
    if resolved != path {
      backPaths = Array((backPaths + [path]).suffix(100))
      forwardPaths = []
    }
    load(resolved)
  }

  func goBack() {
    guard let previous = backPaths.popLast() else { return }
    forwardPaths.append(path)
    load(previous)
  }

  func goForward() {
    guard let next = forwardPaths.popLast() else { return }
    backPaths.append(path)
    load(next)
  }

  private func load(_ newPath: String) {
    cancelScan()
    path = newPath
    query = ""
    selected = []
    statusMessage = nil
    sizesPartial = false

    if let listing = cache[path],
      Date().timeIntervalSince(listing.scannedAt) < Self.freshInterval,
      listing.entries.allSatisfy({ $0.inode != nil })
    {
      entries = FolderListingSorter.sorted(listing.entries)
      scannedAt = listing.scannedAt
      cancelScan()
      return
    }

    rescan()
  }

  func goUp() {
    guard path != "/" else {
      return
    }

    open(URL(fileURLWithPath: path).deletingLastPathComponent().path)
  }

  func rescan() {
    cancelScan()
    let currentGeneration = generation
    let scanner = scanner
    let scanPath = path
    isScanning = true
    statusMessage = nil
    scannedAt = nil
    visited = 0
    sizesPartial = false
    entries = []
    scanTask = Task { [weak self] in
      let initial = await Task.detached(priority: .utility) {
        scanner.listing(of: scanPath)
      }.value
      guard let self, !Task.isCancelled, self.generation == currentGeneration else { return }
      entries = initial.sorted {
        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      selected.formIntersection(Set(entries.map(\.path)))
      pendingCount = initial.filter(\.isDirectory).count
      let worker = Task.detached(priority: .utility) { [weak self] in
        DriveFileScanner.scan(
          .init(
            roots: [scanPath], minimumBytes: 0, resultLimit: 0,
            progress: { [weak self] progress in
              Task { @MainActor [weak self] in
                self?.applyProgress(.init(progress: progress, generation: currentGeneration))
              }
            }))
      }
      sizeTask = worker
      let result = await worker.value
      guard !Task.isCancelled, self.generation == currentGeneration else { return }
      applyProgress(.init(progress: result, generation: currentGeneration))
      sizeTask = nil
      finishScan(path: scanPath)
    }
  }

  struct ProgressInput {
    let progress: DriveScanProgress
    let generation: Int
  }

  private func applyProgress(_ input: ProgressInput) {
    guard generation == input.generation else { return }
    visited = input.progress.visited
    sizesPartial = input.progress.unreadable > 0 || !input.progress.complete
    for index in entries.indices where entries[index].isDirectory {
      if let bytes = input.progress.folderBytes[entries[index].path] {
        entries[index].bytes = bytes
      } else if input.progress.complete && input.progress.unreadable == 0 {
        entries[index].bytes = 0
      }
    }
    if input.progress.unreadable > 0 {
      statusMessage =
        "\(input.progress.unreadable) locations unreadable. Folder sizes are measured minimums."
    }
    pendingCount = entries.filter { $0.isDirectory && $0.bytes == nil }.count
  }

  func reveal(_ entry: FolderEntry) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
  }

  func canTrash(_ entry: FolderEntry) -> Bool {
    let protectedHomeFolders = [
      "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
      "Applications", ".ssh", ".gnupg",
    ]
    let protectedHomeRoot =
      entry.isDirectory
      && protectedHomeFolders.contains(entry.name)
      && URL(fileURLWithPath: entry.path).deletingLastPathComponent().path == homePath
    guard entry.path != homePath, !protectedHomeRoot,
      URL(fileURLWithPath: entry.path).deletingLastPathComponent().path != "/Volumes",
      entry.inode != nil, entry.device != nil
    else { return false }
    return ReviewFileDeletion.canTrashPath(entry.path)
  }

  func trash(_ items: [FolderEntry]) {
    guard !isTrashing else { return }
    let allowed = items.filter(canTrash)
    guard !allowed.isEmpty else { return }
    isTrashing = true
    Task {
      let results = await Task.detached(priority: .userInitiated) {
        allowed.map { entry -> (String, String?) in
          do {
            var identity = stat()
            guard lstat(entry.path, &identity) == 0,
              identity.st_ino == entry.inode, identity.st_dev == entry.device,
              ReviewFile.canonicalPath(
                URL(fileURLWithPath: entry.path).deletingLastPathComponent().path)
                == URL(fileURLWithPath: entry.path).deletingLastPathComponent().path
            else { return (entry.path, "\(entry.name) changed. Scan again before removing it.") }
            try FileManager.default.trashItem(
              at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
            return (entry.path, nil)
          } catch { return (entry.path, "\(entry.name): \(error.localizedDescription)") }
        }
      }.value
      let removed = Set(results.filter { $0.1 == nil }.map(\.0))
      entries.removeAll { removed.contains($0.path) }
      selected.subtract(removed)
      for path in removed { invalidateAncestors(of: path) }
      let errors = results.compactMap(\.1)
      statusMessage =
        "Moved \(removed.count) \(removed.count == 1 ? "item" : "items") to Trash."
        + (errors.isEmpty ? "" : " " + errors.prefix(3).joined(separator: " "))
      isTrashing = false
    }
  }

  private func finishScan(path scannedPath: String) {
    isScanning = false
    pendingCount = 0
    let listing = FolderListing(path: scannedPath, scannedAt: .now, entries: entries)
    scannedAt = listing.scannedAt
    if !sizesPartial {
      cache[scannedPath] = listing
      FolderSizeCache.save(cache)
    }
  }

  func cancelScan() {
    generation += 1
    scanTask?.cancel()
    sizeTask?.cancel()
    sizeTask = nil
    scanTask = nil
    isScanning = false
    pendingCount = 0
  }

  private func invalidateAncestors(of entryPath: String) {
    var current = URL(fileURLWithPath: entryPath).deletingLastPathComponent().path
    while true {
      cache.removeValue(forKey: current)
      if current == "/" {
        break
      }

      current = URL(fileURLWithPath: current).deletingLastPathComponent().path
    }

    FolderSizeCache.save(cache)
  }
}
