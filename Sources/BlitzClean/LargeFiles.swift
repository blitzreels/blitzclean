import Foundation

enum LargeFileKind: String, CaseIterable, Codable, Sendable {
  case all = "All"
  case videos = "Videos"
  case images = "Images"
  case archives = "Archives"
  case folders = "Folders"
  case other = "Other"

  static func of(_ file: ReviewFile) -> Self {
    switch file.kind {
    case "Video": .videos
    case "Image": .images
    case "Archive / installer": .archives
    default: .other
    }
  }
}

/// A large file or top-level folder in the user's own folders.
struct LargeFileItem: Equatable, Identifiable, Sendable {
  let path: String
  let bytes: UInt64
  let modifiedAt: Date
  let kind: LargeFileKind
  let identity: TrashIdentity

  var id: String { path }
  var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct LargeFileScanRequest: Sendable {
  /// Searched recursively for single large files.
  let fileRoots: [String]
  /// Their direct child folders are measured as a whole.
  let folderRoots: [String]
  let minimumFileBytes: UInt64
  let minimumFolderBytes: UInt64
  let folderEntryLimit: Int
  let eligible: @Sendable (String) -> Bool

  static var standard: Self {
    let home = FileManager.default.homeDirectoryForCurrentUser
    func folder(_ name: String) -> String { home.appendingPathComponent(name).path }
    return Self(
      fileRoots: ["Downloads", "Desktop", "Documents", "Movies", "Pictures", "Music"].map(folder),
      folderRoots: ["Downloads", "Desktop", "Movies"].map(folder),
      minimumFileBytes: 50 * 1_024 * 1_024, minimumFolderBytes: 300 * 1_024 * 1_024,
      folderEntryLimit: 100_000, eligible: ReviewFileDeletion.canTrashPath)
  }
}

struct LargeFileScanResult: Sendable {
  let items: [LargeFileItem]
  let limited: Bool
}

enum LargeFileScanner {
  static func scan(_ request: LargeFileScanRequest) -> LargeFileScanResult {
    var limited = false
    var folders: [LargeFileItem] = []
    for root in request.folderRoots {
      let children =
        (try? FileManager.default.contentsOfDirectory(
          at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles])) ?? []
      for url in children where !Task.isCancelled {
        guard let item = folder(.init(url: url, request: request)) else { continue }
        if item.bytes == 0 {
          limited = true
        } else if item.bytes >= request.minimumFolderBytes {
          folders.append(item)
        }
      }
    }
    let files = CleanupReviewScanner.scan(
      .init(roots: request.fileRoots, minimumBytes: request.minimumFileBytes, maxEntries: 400_000))
    let folderPrefixes = folders.map { $0.path + "/" }
    let fileItems = files.files.compactMap { file -> LargeFileItem? in
      guard request.eligible(file.path),
        !folderPrefixes.contains(where: { file.path.hasPrefix($0) }),
        ProjectNameCache.shared.name(
          URL(fileURLWithPath: file.path).deletingLastPathComponent().path)
          == nil
      else { return nil }
      return LargeFileItem(
        path: file.path, bytes: file.bytes, modifiedAt: file.modifiedAt, kind: .of(file),
        identity: .init(path: file.path, device: file.device, inode: file.inode, isFolder: false))
    }
    return LargeFileScanResult(
      items: (folders + fileItems).sorted {
        $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes
      },
      limited: limited || files.limited)
  }

  struct FolderRequest {
    let url: URL
    let request: LargeFileScanRequest
  }

  /// A measured folder, or a zero-byte item when it was too large to read completely.
  static func folder(_ input: FolderRequest) -> LargeFileItem? {
    var info = stat()
    guard lstat(input.url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      let path = ReviewFile.canonicalPath(input.url.path), input.request.eligible(path),
      !FileManager.default.fileExists(atPath: input.url.appendingPathComponent(".git").path)
    else { return nil }
    let identity = TrashIdentity(
      path: path, device: info.st_dev, inode: info.st_ino, isFolder: true)
    guard
      let contents = OldFileScanner.folder(
        .init(path: path, limit: input.request.folderEntryLimit, cutoff: .distantFuture))
    else {
      return LargeFileItem(
        path: path, bytes: 0, modifiedAt: .distantPast, kind: .folders, identity: identity)
    }
    return LargeFileItem(
      path: path, bytes: contents.bytes, modifiedAt: contents.newest, kind: .folders,
      identity: identity)
  }
}
