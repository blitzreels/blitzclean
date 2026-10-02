import Darwin
import Foundation

struct StorageDrive: Identifiable, Sendable {
  let path: String
  let name: String
  let internalDisk: Bool
  let available: UInt64
  let total: UInt64
  var id: String { path }
  var scanRoots: [String] {
    path == "/" ? ["/", "/System/Volumes/Data"] : [path]
  }
}

enum StorageDrives {
  static func mounted() -> [StorageDrive] {
    let keys: Set<URLResourceKey> = [
      .volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
      .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
    ]
    return
      (FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [])
      .compactMap { url in
        guard let values = try? url.resourceValues(forKeys: keys),
          values.volumeIsLocal == true, values.volumeIsBrowsable != false
        else { return nil }
        return StorageDrive(
          path: url.path, name: values.volumeName ?? url.lastPathComponent,
          internalDisk: values.volumeIsInternal == true,
          available: UInt64(max(0, values.volumeAvailableCapacity ?? 0)),
          total: UInt64(max(0, values.volumeTotalCapacity ?? 0)))
      }.sorted { $0.path < $1.path }
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
  let elapsed: TimeInterval
}

struct LargestFileHeap {
  let capacity: Int
  private(set) var files: [ReviewFile] = []
  private var identities: Set<String> = []

  init(capacity: Int) { self.capacity = capacity }

  private func identity(_ file: ReviewFile) -> String { "\(file.device):\(file.inode)" }

  mutating func insert(_ file: ReviewFile) {
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
    let progress: @Sendable (DriveScanProgress) -> Void
  }

  static func scan(_ request: Request) -> DriveScanProgress {
    let start = Date.now
    var lastPublish = Date.distantPast
    var heap = LargestFileHeap(capacity: request.resultLimit)
    var folderBytes: [String: UInt64] = [:]
    var visited = 0
    var unreadable = 0
    var errors: [String] = []
    var currentPath = ""
    var walkers: [DriveWalker] = []
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
        if errors.count < 20 { errors.append(root) }
        continue
      }
      guard roots.insert(path).inserted else { continue }
      if let walker = DriveWalker(path) {
        walkers.append(walker)
      } else {
        unreadable += 1
        if errors.count < 20 { errors.append(path) }
      }
    }
    func snapshot(_ complete: Bool) -> DriveScanProgress {
      DriveScanProgress(
        files: heap.sorted, folderBytes: folderBytes, visited: visited, unreadable: unreadable,
        unreadablePaths: errors, currentPath: currentPath, complete: complete,
        elapsed: Date.now.timeIntervalSince(start))
    }
    while !walkers.isEmpty && !Task.isCancelled {
      for walker in walkers {
        for _ in 0..<2_048 {
          guard !Task.isCancelled, let entry = walker.next() else { break }
          let info = entry.pointee
          currentPath = String(cString: info.fts_path)
          if info.fts_info == FTS_D,
            (walker.root == "/"
              && (firmlinks.contains(currentPath) || currentPath == "/System/Volumes"))
              || (walker.root == "/System/Volumes/Data"
                && currentPath == "/System/Volumes/Data/Volumes")
          {
            walker.skip(entry)
            continue
          }
          if [FTS_DNR, FTS_ERR, FTS_NS].contains(Int32(info.fts_info)) {
            unreadable += 1
            if errors.count < 20 { errors.append(currentPath) }
          }
          guard info.fts_info == FTS_F, let metadata = info.fts_statp?.pointee else { continue }
          visited += 1
          let bytes = UInt64(max(0, metadata.st_blocks)) * 512
          let relative = currentPath.dropFirst(walker.root == "/" ? 1 : walker.root.count + 1)
          if let separator = relative.firstIndex(of: "/") {
            var child = (walker.root == "/" ? "" : walker.root) + "/" + relative[..<separator]
            if request.roots == ["/"], child.hasPrefix("/System/Volumes/Data/") {
              child = String(child.dropFirst("/System/Volumes/Data".count))
            }
            folderBytes[child, default: 0] += bytes
          }
          guard bytes >= request.minimumBytes else { continue }
          let file = ReviewFile(
            path: currentPath, bytes: bytes,
            modifiedAt: Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec)),
            device: metadata.st_dev, inode: metadata.st_ino, logicalBytes: metadata.st_size,
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec))
          heap.insert(file)
        }
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

private final class DriveWalker {
  let root: String
  private let paths: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
  private let tree: UnsafeMutablePointer<FTS>
  private(set) var finished = false

  init?(_ path: String) {
    root = path
    paths = .allocate(capacity: 2)
    paths.initialize(to: strdup(path))
    paths.advanced(by: 1).initialize(to: nil)
    guard let tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
      free(paths.pointee)
      paths.deinitialize(count: 2)
      paths.deallocate()
      return nil
    }
    self.tree = tree
  }

  func next() -> UnsafeMutablePointer<FTSENT>? {
    guard !finished else { return nil }
    let entry = fts_read(tree)
    if entry == nil { finished = true }
    return entry
  }

  func skip(_ entry: UnsafeMutablePointer<FTSENT>) {
    fts_set(tree, entry, FTS_SKIP)
  }

  deinit {
    fts_close(tree)
    free(paths.pointee)
    paths.deinitialize(count: 2)
    paths.deallocate()
  }
}
