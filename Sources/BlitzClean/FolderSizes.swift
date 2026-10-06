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
  var sizeEstimate: FolderSizeEstimate?

  var id: String {
    path
  }
}

enum FolderSizeEstimate: String, Codable, Sendable {
  case minimum, previous
}

struct FolderListing: Codable, Equatable, Sendable {
  let path: String
  let scannedAt: Date
  let entries: [FolderEntry]
  var complete = true

  enum CodingKeys: String, CodingKey {
    case path, scannedAt, entries, complete
  }

  init(_ input: Snapshot) {
    path = input.path
    scannedAt = input.scannedAt
    entries = input.entries
    complete = input.complete
  }

  struct Snapshot {
    let path: String
    let scannedAt: Date
    let entries: [FolderEntry]
    let complete: Bool
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    path = try values.decode(String.self, forKey: .path)
    scannedAt = try values.decode(Date.self, forKey: .scannedAt)
    entries = try values.decode([FolderEntry].self, forKey: .entries)
    complete = try values.decodeIfPresent(Bool.self, forKey: .complete) ?? true
  }

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

struct FolderSizeCache {
  private static let key = "folder-size-listings-v1"
  private static let maxEntries = 60
  let defaults: UserDefaults

  func load() -> [String: FolderListing] {
    guard let data = defaults.data(forKey: Self.key),
      let listings = try? JSONDecoder().decode([String: FolderListing].self, from: data)
    else {
      return [:]
    }

    return Self.bounded(listings)
  }

  static func bounded(_ listings: [String: FolderListing]) -> [String: FolderListing] {
    var trimmed = listings
    if trimmed.count > maxEntries {
      let oldest = trimmed.values.sorted { left, right in
        left.scannedAt < right.scannedAt
      }.prefix(trimmed.count - maxEntries)
      for listing in oldest {
        trimmed.removeValue(forKey: listing.path)
      }
    }

    return trimmed
  }

  func save(_ listings: [String: FolderListing]) {
    guard let data = try? JSONEncoder().encode(Self.bounded(listings)) else {
      return
    }

    defaults.set(data, forKey: Self.key)
  }
}

struct FolderSizeScanner: Sendable {
  func listing(of path: String) throws -> [FolderEntry] {
    let url = URL(fileURLWithPath: path)
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .totalFileAllocatedSizeKey, .fileSizeKey,
    ]
    let children = try FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: Array(keys), options: [])

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
  @Published private(set) var backPaths: [String] = []
  @Published private(set) var forwardPaths: [String] = []

  private let scanner = FolderSizeScanner()
  private let scan: @Sendable (DriveFileScanner.Request) -> DriveScanProgress
  private let cacheStore: FolderSizeCache
  private var cache: [String: FolderListing]
  private var scanTask: Task<Void, Never>?
  private var sizeTask: Task<DriveScanProgress, Never>?
  private var generation = 0
  private var hasListing = false
  private var preservedSizePaths: Set<String> = []

  struct Configuration {
    let path: String
    let cacheStore: FolderSizeCache
    let scan: @Sendable (DriveFileScanner.Request) -> DriveScanProgress
  }

  convenience init(path: String = "/") {
    self.init(
      .init(path: path, cacheStore: .init(defaults: .standard), scan: DriveFileScanner.scan))
  }

  init(_ configuration: Configuration) {
    path = configuration.path
    cacheStore = configuration.cacheStore
    cache = cacheStore.load()
    scan = configuration.scan
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
      !hasListing || cache[path]?.complete != true
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
    hasListing = false
    entries = []
    scannedAt = nil

    if let listing = cache[path],
      listing.entries.allSatisfy({ $0.inode != nil && $0.device != nil })
    {
      entries = FolderListingSorter.sorted(listing.entries)
      scannedAt = listing.scannedAt
      hasListing = true
      if listing.complete, Date.now.timeIntervalSince(listing.scannedAt) < Self.freshInterval {
        return
      }
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
    let scan = scan
    let scanPath = path
    let previous = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
    isScanning = true
    statusMessage = nil
    visited = 0
    preservedSizePaths = []
    scanTask = Task { [weak self] in
      let initial = await Task.detached(priority: .utility) {
        Result { try scanner.listing(of: scanPath) }
      }.value
      guard let self, !Task.isCancelled, self.generation == currentGeneration else { return }
      guard case .success(let children) = initial else {
        statusMessage =
          hasListing
          ? "Folder unavailable. Showing saved sizes." : "This folder could not be read."
        saveListing(complete: false)
        isScanning = false
        scanTask = nil
        return
      }
      entries = children.map { entry in
        guard entry.isDirectory, let saved = previous[entry.path], saved.isDirectory,
          let bytes = saved.bytes, saved.inode == entry.inode, saved.device == entry.device
        else { return entry }
        var restored = entry
        restored.bytes = bytes
        restored.sizeEstimate = .previous
        preservedSizePaths.insert(entry.path)
        return restored
      }
      hasListing = true
      if scannedAt == nil { scannedAt = .now }
      selected.formIntersection(Set(entries.map(\.path)))
      pendingCount = entries.filter { $0.isDirectory && $0.bytes == nil }.count
      let worker = Task.detached(priority: .utility) { [weak self] in
        scan(
          .init(
            roots: [scanPath], minimumBytes: 0, resultLimit: 0,
            progress: { [weak self] progress in
              guard !progress.complete else { return }
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
      finishScan()
    }
  }

  struct ProgressInput {
    let progress: DriveScanProgress
    let generation: Int
  }

  private func applyProgress(_ input: ProgressInput) {
    guard isScanning, generation == input.generation else { return }
    visited = input.progress.visited
    let partial = input.progress.unreadable > 0 || !input.progress.complete
    var updated = entries
    for index in updated.indices where updated[index].isDirectory {
      if !input.progress.complete && preservedSizePaths.contains(updated[index].path) { continue }
      if let bytes = input.progress.folderBytes[updated[index].path] {
        updated[index].bytes = bytes
        updated[index].sizeEstimate = partial ? .minimum : nil
      } else if input.progress.complete && input.progress.unreadable == 0 {
        updated[index].bytes = 0
        updated[index].sizeEstimate = nil
      }
    }
    if updated != entries { entries = updated }
    if input.progress.unreadable > 0 {
      statusMessage =
        "\(input.progress.unreadable) locations unreadable. ≥ is a measured minimum; ~ is a saved size."
    }
    pendingCount = entries.filter { $0.isDirectory && $0.bytes == nil }.count
  }

  func reveal(_ entry: FolderEntry) {
    Finder.reveal(entry.path)
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
    cancelScan()
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
      if !removed.isEmpty { scannedAt = .distantPast }
      let errors = results.compactMap(\.1)
      statusMessage =
        "Moved \(removed.count) \(removed.count == 1 ? "item" : "items") to Trash."
        + (errors.isEmpty ? "" : " " + errors.prefix(3).joined(separator: " "))
      isTrashing = false
    }
  }

  private func finishScan() {
    isScanning = false
    pendingCount = 0
    scanTask = nil
    scannedAt = .now
    saveListing(complete: true)
  }

  private func saveListing(complete: Bool) {
    guard hasListing, let scannedAt else { return }
    cache[path] = FolderListing(
      .init(path: path, scannedAt: scannedAt, entries: entries, complete: complete))
    cache = FolderSizeCache.bounded(cache)
    cacheStore.save(cache)
  }

  func cancelScan() {
    if isScanning { saveListing(complete: false) }
    generation += 1
    scanTask?.cancel()
    sizeTask?.cancel()
    sizeTask = nil
    scanTask = nil
    isScanning = false
    pendingCount = 0
  }

  private func invalidateAncestors(of entryPath: String) {
    cache = cache.filter { $0.key != entryPath && !$0.key.hasPrefix(entryPath + "/") }
    var current = URL(fileURLWithPath: entryPath).deletingLastPathComponent().path
    while true {
      cache.removeValue(forKey: current)
      if current == "/" {
        break
      }

      current = URL(fileURLWithPath: current).deletingLastPathComponent().path
    }

    cacheStore.save(cache)
  }
}
