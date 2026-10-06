import Foundation

/// Where BlitzClean keeps its local files: `~/Library/Application Support/BlitzClean`.
enum AppData {
  static var directory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/BlitzClean", isDirectory: true)
  }

  /// Folder used by builds released before 1.2.0.
  static var legacyDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/FreeSpace", isDirectory: true)
  }

  static func file(_ name: String) -> URL {
    directory.appendingPathComponent(name)
  }

  struct MigrationInput {
    let legacy: URL
    let current: URL
  }

  /// Moves files from the legacy folder without replacing anything already in the current one.
  static func migrateLegacyFiles(_ input: MigrationInput) {
    let manager = FileManager.default
    guard
      let items = try? manager.contentsOfDirectory(
        at: input.legacy, includingPropertiesForKeys: [.isDirectoryKey])
    else { return }
    try? manager.createDirectory(at: input.current, withIntermediateDirectories: true)
    for item in items {
      let destination = input.current.appendingPathComponent(item.lastPathComponent)
      let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      if !manager.fileExists(atPath: destination.path) {
        try? manager.moveItem(at: item, to: destination)
      } else if isDirectory {
        migrateLegacyFiles(.init(legacy: item, current: destination))
      }
    }
    if (try? manager.contentsOfDirectory(atPath: input.legacy.path))?.isEmpty == true {
      try? manager.removeItem(at: input.legacy)
    }
  }
}
