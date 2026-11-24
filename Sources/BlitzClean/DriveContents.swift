import Foundation

enum DriveFileCategory: String, Codable, CaseIterable, Sendable {
  case recordings = "Recordings"
  case exports = "Exports"
  case videos = "Other videos"
  case photos = "Images"
  case audio = "Audio"
  case applications = "Applications"
  case builds = "Build data"
  case archives = "Archives and installers"
  case other = "Other files"

  static func classify(_ relative: Substring) -> Self {
    let path = "/" + relative.lowercased()
    if path.contains(".app/") { return .applications }
    if buildComponents.contains(where: { path.contains("/" + $0 + "/") }) { return .builds }
    if ["/exports/", "/export/", "/renders/"].contains(where: path.contains) { return .exports }
    let ext = relative.split(separator: "/").last?.split(separator: ".").last?.lowercased() ?? ""
    switch ext {
    case "mp4", "mov", "m4v", "mkv", "avi", "mts", "mxf", "webm":
      return ["/recordings/", "/captures/", "/dcim/", " source takes/", "/screen recordings/"]
        .contains(where: path.contains) ? .recordings : .videos
    case "jpg", "jpeg", "heif", "heic", "png", "gif", "webp", "tiff", "dng", "cr3", "arw":
      return .photos
    case "wav", "aiff", "mp3", "m4a", "flac", "aac": return .audio
    case "zip", "dmg", "tar", "gz", "pkg", "7z", "iso", "rar", "xip": return .archives
    default: return .other
    }
  }

  static let buildComponents = ["node_modules", ".next", ".build", "deriveddata", "_cacache"]

  static func buildFolder(_ path: String) -> String? {
    let parts = path.split(separator: "/")
    guard let end = parts.firstIndex(where: { buildComponents.contains($0.lowercased()) }) else {
      return nil
    }
    return "/" + parts[...end].joined(separator: "/")
  }
}

struct DriveContents: Codable, Sendable {
  static let fileLimit = 100
  var buildFolders: [String: UInt64] = [:]
  var bytes: [DriveFileCategory: UInt64] = [:]
  var largest: [DriveFileCategory: [ReviewFile]] = [:]
  var incompleteFolders: Set<String> = []

  mutating func markUnreadable(_ input: (path: String, root: String)) {
    let visible = StorageGuidance.visiblePath(input.path)
    let root = input.root == "/System/Volumes/Data" ? "/" : input.root
    if let child = visible.dropFirst(root == "/" ? 1 : root.count + 1).split(separator: "/").first {
      incompleteFolders.insert(String(child))
    } else {
      incompleteFolders.insert("/")
    }
  }
}

struct DriveFolderReading: Codable, Sendable {
  let date: Date
  let bytes: [String: UInt64]
  let incomplete: Set<String>

  func growth(since previous: Self) -> [(key: String, value: UInt64)] {
    let excluded = incomplete.union(previous.incomplete)
    guard !excluded.contains("/") else { return [] }
    return bytes.compactMap { name, current -> (key: String, value: UInt64)? in
      let old = previous.bytes[name] ?? 0
      guard !excluded.contains(name), current > old else { return nil }
      return (name, current - old)
    }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
  }
}

struct DriveContentsReport: Codable, Sendable {
  let mount: String
  let contents: DriveContents
  let reading: DriveFolderReading
  let previous: DriveFolderReading?
  let visited: Int
  let unreadable: Int
}

struct DriveKeptFolders {
  let drive: StorageDrive
  private static let defaultsKey = "driveAnalysis.keptFolders"
  private var key: String { drive.volumeID ?? drive.path }
  private static var saved: [String: [String]] {
    UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
  }
  var folders: [String] { Self.saved[key] ?? [] }

  static func blocksRemoval(_ path: String) -> Bool {
    let rules = saved
    guard !rules.isEmpty else { return false }
    let url = URL(fileURLWithPath: path)
    guard let mount = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume else {
      return true
    }
    let root = mount.path == "/System/Volumes/Data" ? URL(fileURLWithPath: "/") : mount
    let uuid = (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    guard let names = rules[uuid ?? root.path] else { return false }
    let visible = StorageGuidance.visiblePath(path)
    let prefix = root.path == "/" ? "/" : root.path + "/"
    guard visible == root.path || visible.hasPrefix(prefix) else { return true }
    let relative = String(visible.dropFirst(prefix.count))
    return names.contains { overlaps((relative, $0)) }
  }

  func relative(_ path: String) -> String? {
    let visible = StorageGuidance.visiblePath(path)
    if visible == drive.path { return "" }
    let prefix = drive.path == "/" ? "/" : drive.path + "/"
    guard visible.hasPrefix(prefix) else { return nil }
    return String(visible.dropFirst(prefix.count))
  }

  func protects(_ path: String) -> Bool {
    guard let relative = relative(path) else { return false }
    return folders.contains { Self.overlaps((relative, $0)) }
  }

  static func overlaps(_ paths: (String, String)) -> Bool {
    paths.0 == paths.1 || paths.0.isEmpty || paths.1.isEmpty || paths.0.hasPrefix(paths.1 + "/")
      || paths.1.hasPrefix(paths.0 + "/")
  }

  func set(_ names: [String]) {
    var saved = Self.saved
    saved[key] = names.isEmpty ? nil : names.sorted()
    UserDefaults.standard.set(saved, forKey: Self.defaultsKey)
  }
}

@MainActor
final class DriveContentsModel: ObservableObject {
  @Published private(set) var report: DriveContentsReport?
  @Published private(set) var progress: DriveScanProgress?
  @Published private(set) var scanning = false
  @Published var message: String?
  private var earlierMount: DriveFolderReading?
  private var generation = UUID()
  private var worker: Task<DriveScanProgress, Never>?

  private func store(_ drive: StorageDrive) -> URL? {
    guard let id = drive.volumeID.flatMap(UUID.init(uuidString:)) else { return nil }
    return AppData.file("drive-contents").appendingPathComponent(id.uuidString + ".json")
  }

  func load(_ drive: StorageDrive) {
    if let url = store(drive), let data = try? Data(contentsOf: url),
      let saved = try? JSONDecoder().decode(DriveContentsReport.self, from: data)
    {
      if saved.mount == drive.path {
        report = saved
        return
      }
      earlierMount = saved.reading
    }
    scan(drive)
  }

  func stop() {
    generation = UUID()
    worker?.cancel()
    worker = nil
    scanning = false
    progress = nil
  }

  func scan(_ drive: StorageDrive) {
    stop()
    let token = generation
    let prior = report?.reading ?? earlierMount
    scanning = true
    message = nil
    let task = Task.detached(priority: .utility) { [weak self] in
      DriveFileScanner.scan(
        .init(
          roots: [drive.path], minimumBytes: 0, resultLimit: 0, categorize: true,
          progress: { [weak self] snapshot in
            Task { @MainActor in
              guard let self, self.generation == token, self.scanning else { return }
              self.progress = snapshot
            }
          }))
    }
    worker = task
    Task {
      let result = await task.value
      guard token == generation else { return }
      scanning = false
      progress = nil
      worker = nil
      guard result.complete, let contents = result.contents,
        !contents.incompleteFolders.contains("/"),
        Self.stillMounted(drive)
      else {
        message = "The scan could not finish. Reconnect the drive or check folder access."
        return
      }
      let folders = Dictionary(
        uniqueKeysWithValues: result.folderBytes.map { (PathName.last($0.key), $0.value) })
      let reading = DriveFolderReading(
        date: .now, bytes: folders, incomplete: contents.incompleteFolders)
      let next = DriveContentsReport(
        mount: drive.path, contents: contents, reading: reading,
        previous: prior, visited: result.visited, unreadable: result.unreadable)
      report = next
      if let url = store(drive) {
        do {
          try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
          try JSONEncoder().encode(next).write(to: url, options: .atomic)
        } catch { message = "Scan finished. Its comparison could not be saved." }
      }
    }
  }

  nonisolated static func stillMounted(_ drive: StorageDrive) -> Bool {
    let values = try? URL(fileURLWithPath: drive.path).resourceValues(forKeys: [
      .volumeURLKey, .volumeUUIDStringKey,
    ])
    return values?.volume?.path == drive.path && values?.volumeUUIDString == drive.volumeID
  }
}

struct DriveDuplicateReview {
  let file: ReviewFile
  let keeper: ReviewFile
  let digest: String
  let drive: StorageDrive

  func trash() throws {
    guard DriveContentsModel.stillMounted(drive),
      !DriveKeptFolders(drive: drive).protects(file.path),
      file.fileIdentity != keeper.fileIdentity
    else { throw ReviewDeleteError.protected }
    let deadline = Date.now.addingTimeInterval(120)
    guard try MediaDuplicateScanner.digest(.init(file: file, deadline: deadline)) == digest,
      try MediaDuplicateScanner.digest(.init(file: keeper, deadline: deadline)) == digest
    else { throw ReviewDeleteError.changed }
    try ReviewFileDeletion.validateIdentity(.init(file: keeper, roots: drive.scanRoots))
    try ReviewFileDeletion.trash(.init(file: file, roots: drive.scanRoots))
  }
}
