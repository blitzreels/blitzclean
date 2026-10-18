import Darwin
import Foundation

struct FileIdentity: Codable, Equatable, Hashable, Sendable {
  let device: Int32
  let inode: UInt64

  static func read(_ path: String) -> Self? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return Self(device: info.st_dev, inode: info.st_ino)
  }
}

/// The last check before a user-visible file or folder leaves the disk. Every cleanup goes through
/// it, so the floor below holds even when a feature forgets one of its own checks:
/// the path is absolute and normalized, no ancestor is a link, the item is not a home, system,
/// volume, or Git root, its volume is writable, and it is still the item that was reviewed.
enum RemovalGate {
  enum Method: Sendable {
    case permanent
    case trash
  }

  struct Request: Sendable {
    let path: String
    /// Identity captured when the item was reviewed. Nil only when the caller found the item in
    /// the same pass that removes it.
    let expected: FileIdentity?
    let method: Method
  }

  enum Refusal: LocalizedError, Equatable {
    case notNormalized
    case linkedParent
    case protectedLocation(String)
    case missing
    case changed
    case readOnlyVolume

    var errorDescription: String? {
      switch self {
      case .notNormalized: "This path is not a plain location on disk, so it was kept."
      case .linkedParent: "A folder above this item is a link, so it was kept."
      case .protectedLocation(let reason): reason
      case .missing: "This item is already gone."
      case .changed: "This item changed since it was checked. Scan again before removing it."
      case .readOnlyVolume: "This volume is read-only."
      }
    }
  }

  static func remove(_ request: Request) throws {
    try check(request)
    switch request.method {
    case .permanent:
      try FileManager.default.removeItem(atPath: request.path)
    case .trash:
      try FileManager.default.trashItem(
        at: URL(fileURLWithPath: request.path), resultingItemURL: nil)
    }
  }

  static func check(_ request: Request) throws {
    let path = request.path
    let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
    guard path.hasPrefix("/"), !components.isEmpty,
      !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    else { throw Refusal.notNormalized }
    if let reason = protection(path) { throw Refusal.protectedLocation(reason) }
    let parent = (path as NSString).deletingLastPathComponent
    guard ReviewFile.canonicalPath(parent) == parent else { throw Refusal.linkedParent }
    guard let current = FileIdentity.read(path) else { throw Refusal.missing }
    if let expected = request.expected, expected != current { throw Refusal.changed }
    guard FileIdentity.read(parent)?.device == current.device else {
      throw Refusal.protectedLocation(
        "Mounted volume · eject it in Finder")
    }
    var volume = statfs()
    guard statfs(parent, &volume) == 0 else { throw Refusal.missing }
    guard volume.f_flags & UInt32(MNT_RDONLY) == 0 else { throw Refusal.readOnlyVolume }
  }

  /// Why a location can never be removed here, or nil when only the item checks apply.
  static func protection(_ path: String) -> String? {
    let visible = StorageGuidance.visiblePath(path)
    if visible.split(separator: "/").contains(".git") {
      return "Git history · kept; remove the whole project or run git gc"
    }
    if fixedRoots.contains(visible) {
      return "Top-level drive folder · open it to remove what is inside"
    }
    let home = NSHomeDirectory()
    if visible == home || (visible as NSString).deletingLastPathComponent == "/Users" {
      return "Home folder · kept"
    }
    let parent = (visible as NSString).deletingLastPathComponent
    let name = (visible as NSString).lastPathComponent
    if parent == home, homeFolders.contains(name) {
      return "Standard folder · open it to remove what is inside"
    }
    if parent == home + "/Library", libraryFolders.contains(name) {
      return "Standard folder · open it to remove what is inside"
    }
    return nil
  }

  private static let fixedRoots: Set<String> = [
    "/", "/System", "/System/Volumes", "/System/Volumes/Data", "/Library", "/Applications",
    "/Users", "/Volumes", "/private", "/private/var", "/private/tmp", "/private/etc", "/tmp",
    "/var", "/etc", "/usr", "/usr/local", "/bin", "/sbin", "/opt", "/opt/homebrew", "/cores",
  ]

  private static let homeFolders: Set<String> = [
    "Applications", "Desktop", "Developer", "Documents", "Downloads", "Library", "Movies", "Music",
    "Pictures", "Projects", "Public", "dev", ".ssh", ".gnupg", ".config", ".Trash",
  ]

  private static let libraryFolders: Set<String> = [
    "Application Support", "Caches", "Containers", "Developer", "Group Containers", "Keychains",
    "Mobile Documents", "Preferences", "Mail", "Messages", "Photos",
  ]
}
