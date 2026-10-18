import Darwin
import Foundation

enum PersonalTrashError: LocalizedError {
  case changed, used, open, unverified

  var errorDescription: String? {
    switch self {
    case .changed: "It changed since the scan."
    case .used: "It was opened or changed since the scan."
    case .open: "It is open in another app."
    case .unverified: "The open-file check could not finish."
    }
  }
}

/// The file or folder a scan saw, so a replaced item at the same path is never moved.
struct TrashIdentity: Equatable, Sendable {
  let path: String
  let device: Int32
  let inode: UInt64
  let isFolder: Bool
}

struct TrashedItem: Sendable {
  let original: String
  let trashed: URL?
}

struct TrashMove {
  let identity: TrashIdentity
  /// Feature rule checked last, such as the item still being unused.
  let recheck: () throws -> Void
}

enum PersonalTrash {
  /// Rechecks identity, location rules and open files immediately before moving one item.
  static func move(_ move: TrashMove) throws -> TrashedItem {
    let identity = move.identity
    var info = stat()
    guard lstat(identity.path, &info) == 0, info.st_dev == identity.device,
      info.st_ino == identity.inode, ReviewFile.canonicalPath(identity.path) == identity.path,
      ReviewFileDeletion.canTrashPath(identity.path)
    else { throw PersonalTrashError.changed }
    try move.recheck()
    let check = CleanupActivity.command(
      identity.isFolder
        ? ["-nP", "-Fp", "+D", identity.path] : ["-nP", "-Fp", "--", identity.path])
    if check.status == 0 { throw PersonalTrashError.open }
    guard check.status == 1, check.output.isEmpty else { throw PersonalTrashError.unverified }
    try RemovalGate.check(
      .init(
        path: identity.path, expected: .init(device: identity.device, inode: identity.inode),
        method: .trash))
    var resulting: NSURL?
    try FileManager.default.trashItem(
      at: URL(fileURLWithPath: identity.path), resultingItemURL: &resulting)
    return TrashedItem(original: identity.path, trashed: resulting as URL?)
  }

  /// Puts items back where they were, unless something new now occupies that path.
  static func restore(_ items: [TrashedItem]) -> Int {
    var restored = 0
    for item in items {
      guard let trashed = item.trashed,
        FileManager.default.fileExists(atPath: trashed.path),
        !FileManager.default.fileExists(atPath: item.original)
      else { continue }
      do {
        try FileManager.default.moveItem(at: trashed, to: URL(fileURLWithPath: item.original))
        restored += 1
      } catch { continue }
    }
    return restored
  }
}
