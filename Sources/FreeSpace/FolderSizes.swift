import AppKit
import Foundation

struct FolderEntry: Identifiable, Equatable, Codable, Sendable {
  let path: String
  let name: String
  let isDirectory: Bool
  let isHidden: Bool
  var bytes: UInt64?

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
      return FolderEntry(
        path: child.path,
        name: child.lastPathComponent,
        isDirectory: isDirectory,
        isHidden: values.isHidden ?? child.lastPathComponent.hasPrefix("."),
        bytes: isDirectory ? nil : UInt64(max(0, fileBytes ?? 0))
      )
    }
  }

  func directoryBytes(_ path: String) -> UInt64 {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    process.arguments = ["-xsk", path]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    guard (try? process.run()) != nil else {
      return 0
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    let kilobytes =
      text.split(whereSeparator: \Character.isWhitespace).first.flatMap { value in
        UInt64(value)
      } ?? 0
    return kilobytes * 1_024
  }
}

@MainActor
final class FolderExplorerModel: ObservableObject {
  static let freshInterval: TimeInterval = 6 * 60 * 60

  @Published private(set) var path: String
  @Published private(set) var entries: [FolderEntry] = []
  @Published private(set) var isScanning = false
  @Published private(set) var pendingCount = 0
  @Published private(set) var scannedAt: Date?
  @Published private(set) var statusMessage: String?
  @Published var showsHidden = true

  private let scanner = FolderSizeScanner()
  private var cache: [String: FolderListing]
  private var scanTask: Task<Void, Never>?
  private var generation = 0

  init(path: String = FileManager.default.homeDirectoryForCurrentUser.path) {
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
    showsHidden ? entries : entries.filter { entry in !entry.isHidden }
  }

  var maxBytes: UInt64 {
    entries.compactMap(\.bytes).max() ?? 0
  }

  func cachedListing(_ path: String) -> FolderListing? {
    cache[path]
  }

  func loadIfNeeded() {
    guard entries.isEmpty, !isScanning else {
      return
    }

    open(path)
  }

  func open(_ newPath: String) {
    path = newPath
    statusMessage = nil

    if let listing = cache[newPath],
      Date().timeIntervalSince(listing.scannedAt) < Self.freshInterval
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
    generation += 1
    let currentGeneration = generation
    let scanner = scanner
    let scanPath = path

    isScanning = true
    scannedAt = nil
    let initial = FolderListingSorter.sorted(scanner.listing(of: scanPath))
    entries = initial
    pendingCount = initial.filter(\.isDirectory).count

    scanTask = Task { [weak self] in
      let directories = initial.filter(\.isDirectory)
      await withTaskGroup(of: (String, UInt64).self) { group in
        var nextIndex = 0
        while nextIndex < min(4, directories.count) {
          let entry = directories[nextIndex]
          nextIndex += 1
          group.addTask(priority: .utility) {
            (entry.path, scanner.directoryBytes(entry.path))
          }
        }

        for await (entryPath, bytes) in group {
          guard !Task.isCancelled else {
            return
          }

          self?.apply(bytes: bytes, to: entryPath, generation: currentGeneration)
          if nextIndex < directories.count {
            let entry = directories[nextIndex]
            nextIndex += 1
            group.addTask(priority: .utility) {
              (entry.path, scanner.directoryBytes(entry.path))
            }
          }
        }
      }

      guard let self, !Task.isCancelled, self.generation == currentGeneration else {
        return
      }

      self.finishScan(path: scanPath)
    }
  }

  func reveal(_ entry: FolderEntry) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
  }

  func canTrash(_ entry: FolderEntry) -> Bool {
    let protectedPrefixes = [
      "/System", "/usr", "/bin", "/sbin", "/private", "/Library", "/Applications",
    ]
    if protectedPrefixes.contains(where: { prefix in
      entry.path == prefix || entry.path.hasPrefix(prefix + "/")
    }) {
      return false
    }

    if entry.path == homePath
      || URL(fileURLWithPath: entry.path).deletingLastPathComponent().path == homePath
    {
      return false
    }

    return entry.path.hasPrefix(homePath + "/") || entry.path.hasPrefix("/Volumes/")
  }

  func trash(_ entry: FolderEntry) {
    guard canTrash(entry) else {
      statusMessage = "\(entry.name) is protected"
      return
    }

    do {
      try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
      statusMessage = "Moved \(entry.name) to Trash"
      entries.removeAll { candidate in
        candidate.path == entry.path
      }
      invalidateAncestors(of: entry.path)
    } catch {
      statusMessage = "Could not trash \(entry.name): \(error.localizedDescription)"
    }
  }

  private func apply(bytes: UInt64, to entryPath: String, generation: Int) {
    guard generation == self.generation,
      let index = entries.firstIndex(where: { entry in entry.path == entryPath })
    else {
      return
    }

    entries[index].bytes = bytes
    entries = FolderListingSorter.sorted(entries)
    pendingCount = max(0, pendingCount - 1)
  }

  private func finishScan(path scannedPath: String) {
    isScanning = false
    pendingCount = 0
    let listing = FolderListing(path: scannedPath, scannedAt: .now, entries: entries)
    scannedAt = listing.scannedAt
    cache[scannedPath] = listing
    FolderSizeCache.save(cache)
  }

  private func cancelScan() {
    scanTask?.cancel()
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
