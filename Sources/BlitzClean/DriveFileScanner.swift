import Darwin
import Foundation

struct StorageDrive: Identifiable, Equatable, Sendable {
  let path: String
  let name: String
  let internalDisk: Bool
  let browsable: Bool
  let available: UInt64
  let total: UInt64
  var volumeID: String? = nil
  var id: String { path }
  var usedBytes: UInt64? {
    guard total > 0, available <= total else { return nil }
    return total - available
  }

  var scanRoots: [String] {
    path == "/" ? ["/", "/System/Volumes/Data"] : [path]
  }
}

enum StorageDrives {
  static func mounted(includeAdditional: Bool = false) -> [StorageDrive] {
    let keys: Set<URLResourceKey> = [
      .volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
      .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeUUIDStringKey,
    ]
    return
      (FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: Array(keys),
        options: includeAdditional ? [] : [.skipHiddenVolumes]) ?? [])
      .compactMap { url in
        guard let values = try? url.resourceValues(forKeys: keys),
          (values.volumeIsBrowsable != false && (includeAdditional || values.volumeIsLocal == true))
            || (includeAdditional && url.path.hasPrefix("/Volumes/")
              && values.volumeIsInternal != true && values.volumeIsLocal == true)
        else { return nil }
        return StorageDrive(
          path: url.path, name: values.volumeName ?? url.lastPathComponent,
          internalDisk: values.volumeIsInternal == true,
          browsable: values.volumeIsBrowsable != false,
          available: UInt64(max(0, values.volumeAvailableCapacity ?? 0)),
          total: values.volumeAvailableCapacity == nil
            ? 0 : UInt64(max(0, values.volumeTotalCapacity ?? 0)), volumeID: values.volumeUUIDString
        )
      }.sorted {
        if ($0.path == "/") != ($1.path == "/") { return $0.path == "/" }
        if $0.browsable != $1.browsable { return $0.browsable }
        return $0.path.localizedStandardCompare($1.path) == .orderedAscending
      }
  }

  static func containing(_ input: (path: String, drives: [StorageDrive])) -> StorageDrive? {
    input.drives.filter {
      if $0.path == "/" { return input.path.hasPrefix("/") && !input.path.hasPrefix("/Volumes/") }
      return input.path == $0.path || input.path.hasPrefix($0.path + "/")
    }.max { $0.path.count < $1.path.count }
  }

  static var roots: [String] { mounted().flatMap(\.scanRoots) }
}

struct DriveScanProgress: Sendable {
  let files: [ReviewFile]
  let folderBytes: [String: UInt64]
  let visited: Int
  let unreadable: Int
  let unreadablePaths: [String]
  let currentPath: String
  let complete: Bool
  var contents: DriveContents? = nil
  let elapsed: TimeInterval
}

struct LargestFileHeap {
  let capacity: Int
  private(set) var files: [ReviewFile] = []
  private var identities: Set<String> = []

  init(capacity: Int) { self.capacity = capacity }

  private func identity(_ file: ReviewFile) -> String { "\(file.device):\(file.inode)" }

  mutating func insert(_ file: ReviewFile) {
    guard capacity > 0, files.count < capacity || file.bytes > files[0].bytes else { return }
    let key = identity(file)
    guard capacity > 0, !identities.contains(key) else { return }
    if files.count < capacity {
      identities.insert(key)
      files.append(file)
      var index = files.count - 1
      while index > 0 {
        let parent = (index - 1) / 2
        guard files[index].bytes < files[parent].bytes else { break }
        files.swapAt(index, parent)
        index = parent
      }
    } else if file.bytes > files[0].bytes {
      identities.remove(identity(files[0]))
      identities.insert(key)
      files[0] = file
      var index = 0
      while index * 2 + 1 < files.count {
        var child = index * 2 + 1
        if child + 1 < files.count, files[child + 1].bytes < files[child].bytes { child += 1 }
        guard files[child].bytes < files[index].bytes else { break }
        files.swapAt(index, child)
        index = child
      }
    }
  }

  var sorted: [ReviewFile] {
    files.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
  }
}

enum DriveFileScanner {
  struct Request: Sendable {
    let roots: [String]
    let minimumBytes: UInt64
    let resultLimit: Int
    var categorize = false
    let progress: @Sendable (DriveScanProgress) -> Void
  }

  static func scan(_ request: Request) -> DriveScanProgress {
    let start = Date.now
    var lastPublish = Date.distantPast
    var heap = LargestFileHeap(capacity: request.resultLimit)
    var composition = DriveContents()
    var largest: [DriveFileCategory: LargestFileHeap] = [:]
    var folderBytes: [String: UInt64] = [:]
    var visited = 0
    var unreadable = 0
    var errors: [String] = []
    var currentPath = ""
    var walkers: [FileTree] = []
    let ledger = HardLinkLedger()
    var roots = Set<String>()
    let firmlinks = Set(
      (try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8))?
        .split(separator: "\n").compactMap { $0.split(separator: "\t").first.map(String.init) }
        ?? [])
    let requestedRoots = request.roots.flatMap {
      $0 == "/" ? ["/", "/System/Volumes/Data"] : [$0]
    }
    for root in requestedRoots {
      guard let path = ReviewFile.canonicalPath(root) else {
        unreadable += 1
        composition.incompleteFolders.insert("/")
        if errors.count < 20 { errors.append(root) }
        continue
      }
      guard roots.insert(path).inserted else { continue }
      if let walker = FileTree(.init(path: path, needsMetadata: true)) {
        walkers.append(walker)
      } else {
        unreadable += 1
        composition.incompleteFolders.insert("/")
        if errors.count < 20 { errors.append(path) }
      }
    }
    func snapshot(_ complete: Bool) -> DriveScanProgress {
      if request.categorize { composition.largest = largest.mapValues(\.sorted) }
      return DriveScanProgress(
        files: heap.sorted, folderBytes: folderBytes, visited: visited, unreadable: unreadable,
        unreadablePaths: errors, currentPath: currentPath, complete: complete,
        contents: request.categorize ? composition : nil,
        elapsed: Date.now.timeIntervalSince(start))
    }
    while !walkers.isEmpty && !Task.isCancelled {
      for walker in walkers {
        for _ in 0..<2_048 {
          guard !Task.isCancelled, let entry = walker.next() else { break }
          currentPath = entry.path
          if entry.kind == .directory,
            (walker.root == "/"
              && (firmlinks.contains(currentPath) || currentPath == "/System/Volumes"))
              || (walker.root == "/System/Volumes/Data"
                && currentPath == "/System/Volumes/Data/Volumes")
          {
            walker.skip(entry)
            continue
          }
          if entry.kind == .unreadable || entry.kind == .unreadableDirectory {
            unreadable += 1
            if request.categorize {
              composition.markUnreadable((path: currentPath, root: walker.root))
            }
            if errors.count < 20 { errors.append(currentPath) }
          }
          guard entry.kind == .file, let metadata = entry.metadata else { continue }
          visited += 1
          let bytes = AllocatedSize.of(metadata)
          let counted = ledger.bytes(metadata) ?? 0
          let relative = currentPath.dropFirst(walker.root == "/" ? 1 : walker.root.count + 1)
          if let separator = relative.firstIndex(of: "/") {
            var child = (walker.root == "/" ? "" : walker.root) + "/" + relative[..<separator]
            if request.roots == ["/"], child.hasPrefix("/System/Volumes/Data/") {
              child = String(child.dropFirst("/System/Volumes/Data".count))
            }
            folderBytes[child, default: 0] += counted
          }
          guard bytes >= request.minimumBytes else { continue }
          let file = ReviewFile(
            path: currentPath, bytes: bytes,
            modifiedAt: Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec)),
            device: metadata.st_dev, inode: metadata.st_ino, logicalBytes: metadata.st_size,
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec))
          if request.categorize, counted > 0 {
            let category = DriveFileCategory.classify(relative)
            composition.bytes[category, default: 0] += counted
            if category == .builds, let folder = DriveFileCategory.buildFolder(file.path) {
              composition.buildFolders[folder, default: 0] += counted
            }
            largest[category, default: LargestFileHeap(capacity: DriveContents.fileLimit)].insert(
              file)
          }
          heap.insert(file)
        }
      }
      for walker in walkers where walker.finished && !walker.completed {
        unreadable += 1
        composition.incompleteFolders.insert("/")
      }
      walkers.removeAll(where: \.finished)
      if Date.now.timeIntervalSince(lastPublish) >= 0.75 {
        request.progress(snapshot(false))
        lastPublish = .now
      }
    }
    let result = snapshot(!Task.isCancelled)
    request.progress(result)
    return result
  }
}
