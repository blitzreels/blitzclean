import Darwin
import Foundation

/// A physical walk of one folder tree that stays on its starting volume and never follows links.
/// Every storage scanner reads the disk through it, so they agree on what a byte is.
final class FileTree {
  struct Request {
    let path: String
    let needsMetadata: Bool
  }

  enum Kind: Equatable {
    case directory
    case directoryEnd
    case unreadableDirectory
    case file
    case unreadable
    case other
  }

  struct Entry {
    fileprivate let pointer: UnsafeMutablePointer<FTSENT>

    var kind: Kind {
      switch Int32(pointer.pointee.fts_info) {
      case FTS_D: .directory
      case FTS_DP: .directoryEnd
      case FTS_DNR: .unreadableDirectory
      case FTS_F: .file
      case FTS_ERR, FTS_NS: .unreadable
      default: .other
      }
    }
    var level: Int { Int(pointer.pointee.fts_level) }
    var path: String { String(cString: pointer.pointee.fts_path) }
    var metadata: stat? { pointer.pointee.fts_statp?.pointee }
    var name: String {
      withUnsafePointer(to: &pointer.pointee.fts_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(pointer.pointee.fts_namelen) + 1) {
          String(cString: $0)
        }
      }
    }
  }

  let root: String
  private let paths: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
  private let tree: UnsafeMutablePointer<FTS>
  private(set) var finished = false
  /// False after `next()` returned nil because reading the tree failed rather than ended.
  private(set) var completed = true

  init?(_ request: Request) {
    root = request.path
    paths = .allocate(capacity: 2)
    paths.initialize(to: strdup(request.path))
    paths.advanced(by: 1).initialize(to: nil)
    let options = FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV | (request.needsMetadata ? 0 : FTS_NOSTAT)
    guard let tree = fts_open(paths, options, nil) else {
      free(paths.pointee)
      paths.deinitialize(count: 2)
      paths.deallocate()
      return nil
    }
    self.tree = tree
  }

  func next() -> Entry? {
    guard !finished else { return nil }
    errno = 0
    guard let pointer = fts_read(tree) else {
      finished = true
      completed = errno == 0
      return nil
    }
    return Entry(pointer: pointer)
  }

  func skip(_ entry: Entry) { fts_set(tree, entry.pointer, FTS_SKIP) }

  deinit {
    fts_close(tree)
    free(paths.pointee)
    paths.deinitialize(count: 2)
    paths.deallocate()
  }
}

/// Space a file occupies on disk. A hard-linked file counts once per ledger, so pnpm stores and
/// cloned links are not counted several times.
enum AllocatedSize {
  static func of(_ metadata: stat) -> UInt64 { UInt64(max(0, metadata.st_blocks)) * 512 }
}

final class HardLinkLedger: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: Set<FileIdentity> = []

  /// This entry's allocation, or nil for a later link to a file already counted.
  func bytes(_ metadata: stat) -> UInt64? {
    if metadata.st_nlink > 1, metadata.st_mode & S_IFMT != S_IFDIR {
      let identity = FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
      guard lock.withLock({ seen.insert(identity).inserted }) else { return nil }
    }
    return AllocatedSize.of(metadata)
  }
}

struct FolderFootprint: Equatable, Sendable {
  let allocated: UInt64
  let content: UInt64
  /// Some entries could not be read, so the totals are a lower bound.
  let partial: Bool

  struct Request: Sendable {
    let path: String
    let deadline: Date
  }

  /// Nil when the folder cannot be opened or the deadline passes first.
  static func measure(_ request: Request) -> Self? {
    guard Date.now < request.deadline,
      let tree = FileTree(.init(path: request.path, needsMetadata: true))
    else { return nil }
    let ledger = HardLinkLedger()
    var allocated: UInt64 = 0
    var content: UInt64 = 0
    var partial = false
    var entries = 0
    while let entry = tree.next() {
      entries += 1
      if entries % 128 == 0, Date.now >= request.deadline { return nil }
      if entry.level == 0, entry.kind == .unreadable { return nil }
      switch entry.kind {
      case .directoryEnd: continue
      case .unreadable, .unreadableDirectory:
        partial = true
        continue
      default: break
      }
      guard let metadata = entry.metadata else {
        partial = true
        continue
      }
      guard let bytes = ledger.bytes(metadata) else { continue }
      allocated += bytes
      content += UInt64(max(0, metadata.st_size))
    }
    guard entries > 0, Date.now < request.deadline else { return nil }
    return .init(allocated: allocated, content: content, partial: partial || !tree.completed)
  }
}
