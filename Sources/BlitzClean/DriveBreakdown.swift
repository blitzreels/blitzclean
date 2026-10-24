import AppKit
import Darwin
import Foundation

/// One band of the main drive's breakdown, from the user's point of view rather than the folder tree.
enum DriveGroup: String, CaseIterable, Codable, Sendable {
  case personal, home, caches, simulators, ai, containers, apps, messages, appData, trash, system

  var title: String {
    switch self {
    case .personal: "Your files"
    case .home: "Projects and other folders"
    case .caches: "Caches and temporary files"
    case .simulators: "iOS simulators"
    case .ai: "AI tools"
    case .containers: "Docker and virtual machines"
    case .apps: "Apps"
    case .messages: "Messages and mail"
    case .appData: "App data"
    case .trash: "Trash"
    case .system: "macOS and system"
    }
  }

  var shortTitle: String {
    switch self {
    case .personal: "Your files"
    case .home: "Projects"
    case .caches: "Caches"
    case .simulators: "Simulators"
    case .ai: "AI tools"
    case .containers: "Docker"
    case .apps: "Apps"
    case .messages: "Messages"
    case .appData: "App data"
    case .trash: "Trash"
    case .system: "macOS"
    }
  }

  var detail: String {
    switch self {
    case .personal: "Documents, downloads, photos and media · browse to choose what goes"
    case .home: "Code and other folders in your home folder"
    case .caches: "Rebuilt automatically · safe to delete"
    case .simulators: "Simulated iPhones and iOS versions installed by Xcode"
    case .ai: "Codex and Claude chats, worktrees and temporary files"
    case .containers: "Container images, volumes and Linux VM disks"
    case .apps: "Installed applications"
    case .messages: "Attachments and mailboxes · remove them in the app"
    case .appData: "Settings, databases and downloads kept by apps"
    case .trash: "Deleted items still using space"
    case .system: "Managed by macOS"
    }
  }

  var symbol: String {
    switch self {
    case .personal: "photo.on.rectangle.angled"
    case .home: "folder.fill"
    case .caches: "sparkles"
    case .simulators: "iphone.gen3"
    case .ai: "brain.head.profile"
    case .containers: "shippingbox.fill"
    case .apps: "square.grid.2x2.fill"
    case .messages: "message.fill"
    case .appData: "tray.full.fill"
    case .trash: "trash.fill"
    case .system: "applelogo"
    }
  }
}

/// How a unit can give its space back.
enum DriveRemoval: String, Codable, Sendable {
  /// Permanently deletes the folder's contents, skipping recent and open items.
  case deleteContents
  /// Permanently deletes the folder itself.
  case deleteFolder
  case emptyTrash
  /// Shuts down and deletes every simulator device through `simctl`.
  case simulators
  /// Deletes one iOS simulator version through Xcode's simulator service.
  case simulatorRuntime
  case uninstall
  case projects
  case docker
  case browse
  case reveal
  case none

  var isDestructive: Bool {
    [.deleteContents, .deleteFolder, .emptyTrash, .simulators, .simulatorRuntime, .uninstall]
      .contains(self)
  }
}

struct DriveUnit: Identifiable, Equatable, Codable, Sendable {
  let id: String
  let title: String
  let detail: String
  let group: DriveGroup
  let paths: [String]
  let removal: DriveRemoval
  /// Children changed more recently than this are kept when deleting contents.
  let minimumAge: TimeInterval
  var bytes: UInt64
  /// Folders aggregated into this unit, such as node_modules across projects.
  var folders: Int
  /// Some folders could not be read, so the size is a minimum.
  var partial: Bool
}

struct DriveCapacity: Equatable, Codable, Sendable {
  let total: UInt64
  let available: UInt64
  let purgeable: UInt64
  let system: UInt64
  let swap: UInt64

  var used: UInt64 { total - min(total, available) }

  static func read(home: String) -> Self {
    var data = statfs()
    guard statfs("/System/Volumes/Data", &data) == 0 || statfs(home, &data) == 0 else {
      return .init(total: 0, available: 0, purgeable: 0, system: 0, swap: 0)
    }
    let size = UInt64(data.f_bsize)
    let available = data.f_bavail * size
    let important =
      (try? URL(fileURLWithPath: home).resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey
      ]))?.volumeAvailableCapacityForImportantUsage ?? 0
    let system = ["/", "/System/Volumes/Preboot", "/System/Volumes/Update"]
      .compactMap(spaceUsed).reduce(0, +)
    return .init(
      total: data.f_blocks * size, available: available,
      purgeable: important > 0 && UInt64(important) > available
        ? UInt64(important) - available : 0,
      system: system, swap: spaceUsed("/System/Volumes/VM") ?? 0)
  }

  /// One APFS volume's own usage; statfs only reports the shared container.
  private static func spaceUsed(_ path: String) -> UInt64? {
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(0x0080_0000)
    var buffer = [UInt8](repeating: 0, count: 32)
    guard getattrlist(path, &list, &buffer, buffer.count, 0) == 0 else { return nil }
    let used = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    return used > 0 ? UInt64(used) : nil
  }
}

struct DriveBreakdown: Equatable, Codable, Sendable {
  var units: [DriveUnit]
  var capacity: DriveCapacity
  var scannedAt: Date

  var measured: UInt64 {
    units.filter { $0.group != .system }.reduce(0) { $0 + $1.bytes }
  }

  /// Adds macOS, swap, and the space no readable folder accounts for, so the groups sum to used space.
  func withSystem() -> Self {
    var copy = self
    copy.units.removeAll { $0.group == .system }
    let known = measured + capacity.system + capacity.swap
    let rest = capacity.used > known ? capacity.used - known : 0
    copy.units += [
      .system(
        .init(
          id: "system.macos", title: "macOS", detail: "The system itself and its update data",
          bytes: capacity.system)),
      .system(
        .init(
          id: "system.swap", title: "Swap",
          detail: "Memory written to disk · shrinks when memory frees up or after a restart",
          bytes: capacity.swap)),
      .system(
        .init(
          id: "system.other", title: "System Data",
          detail: "Snapshots, indexes and folders macOS does not let apps read",
          bytes: rest)),
    ]
    return copy
  }

  func bytes(_ group: DriveGroup) -> UInt64 {
    units.filter { $0.group == group }.reduce(0) { $0 + $1.bytes }
  }
}

extension DriveUnit {
  struct SystemInput {
    let id: String
    let title: String
    let detail: String
    let bytes: UInt64
  }

  static func system(_ input: SystemInput) -> Self {
    .init(
      id: input.id, title: input.title, detail: input.detail, group: .system, paths: [],
      removal: .none, minimumAge: 0, bytes: input.bytes, folders: 0, partial: false)
  }
}

/// Decides which unit owns each folder on the main drive. Pure, so the rules are testable.
struct DriveCatalog: Sendable {
  struct Spec: Sendable {
    let id: String
    let title: String
    let detail: String
    let group: DriveGroup
    let paths: [String]
    let removal: DriveRemoval
    var minimumAge: TimeInterval = 0
  }

  static let dependencies = "projects.dependencies"
  static let builds = "projects.builds"
  static let homeLoose = "home:loose"
  static let libraryLoose = "lib:loose"
  static let sharedLibrary = "sys:library"
  static let runtimeRoot = "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime"

  let home: String
  let temporary: String
  let systemRoots: [String]
  let specs: [Spec]
  private let exact: [String: String]

  /// Folders outside home that hold apps, shared data, Homebrew and simulator runtimes.
  static let systemRoots = [
    "/Applications", "/Library", "/opt/homebrew", "/usr/local", "/Users/Shared",
    runtimeRoot,
  ]

  struct Input {
    let home: String
    let temporary: String
    let systemRoots: [String]
  }

  init(_ input: Input) {
    home = input.home
    temporary = input.temporary
    systemRoots = input.systemRoots
    let h = input.home
    let hour: TimeInterval = 3_600
    specs = [
      .init(
        id: "caches.xcode", title: "Xcode build data",
        detail: "DerivedData · Xcode rebuilds it on the next build", group: .caches,
        paths: [h + "/Library/Developer/Xcode/DerivedData"], removal: .deleteContents,
        minimumAge: hour),
      .init(
        id: "caches.devicesupport", title: "Device debug symbols",
        detail: "Xcode downloads them again when a device connects", group: .caches,
        paths: [
          h + "/Library/Developer/Xcode/iOS DeviceSupport",
          h + "/Library/Developer/Xcode/watchOS DeviceSupport",
        ], removal: .deleteContents, minimumAge: hour),
      .init(
        id: "caches.apps", title: "App caches",
        detail: "Apps rebuild them · files open in an app are skipped", group: .caches,
        paths: [h + "/Library/Caches"], removal: .deleteContents, minimumAge: hour),
      .init(
        id: "caches.tools", title: "Command-line tool caches",
        detail: "~/.cache · downloaded again when a tool needs it", group: .caches,
        paths: [h + "/.cache"], removal: .deleteContents, minimumAge: hour),
      .init(
        id: "caches.packages", title: "Package manager caches",
        detail: "npm, pnpm, Gradle, Bun and Cargo downloads · fetched again on install",
        group: .caches,
        paths: [
          h + "/.npm", h + "/Library/pnpm/store", h + "/.gradle/caches", h + "/.bun/install/cache",
          h + "/.cargo/registry/cache",
        ], removal: .deleteContents, minimumAge: hour),
      .init(
        id: "caches.temporary", title: "Temporary files",
        detail: "Left by apps and tools · items used in the last 6 hours stay", group: .caches,
        paths: [input.temporary], removal: .deleteContents, minimumAge: 6 * hour),
      .init(
        id: "caches.logs", title: "Logs", detail: "Diagnostic logs older than a day",
        group: .caches, paths: [h + "/Library/Logs"], removal: .deleteContents,
        minimumAge: 24 * hour),
      .init(
        id: "caches.archives", title: "Xcode archives",
        detail: "Needed to read crash reports of builds you shipped", group: .caches,
        paths: [h + "/Library/Developer/Xcode/Archives"], removal: .reveal),
      .init(
        id: "simulators.devices", title: "Simulator devices",
        detail: "Simulated iPhones with their apps and data · Xcode creates new ones when needed",
        group: .simulators, paths: [h + "/Library/Developer/CoreSimulator/Devices"],
        removal: .simulators),
      .init(
        id: "simulators.caches", title: "Simulator caches",
        detail: "Rebuilt when a simulator boots",
        group: .simulators, paths: [h + "/Library/Developer/CoreSimulator/Caches"],
        removal: .deleteContents, minimumAge: hour),
      .init(
        id: "simulators.runtimes", title: "Simulator system files",
        detail: "Shared simulator caches kept by macOS", group: .simulators,
        paths: ["/Library/Developer/CoreSimulator", Self.runtimeRoot], removal: .reveal),
      .init(
        id: "ai.codex.temporary", title: "Codex temporary files",
        detail: "Scratch files from finished Codex tasks · unused for a day", group: .ai,
        paths: [h + "/.codex/tmp", h + "/.codex/.tmp"], removal: .deleteContents,
        minimumAge: 24 * hour),
      .init(
        id: "ai.codex.worktrees", title: "Codex worktrees",
        detail: "Project copies made by Codex · check for unmerged work", group: .ai,
        paths: [h + "/.codex/worktrees"], removal: .browse),
      .init(
        id: "ai.codex.history", title: "Codex chat history",
        detail: "Past sessions · deleting removes them from Codex", group: .ai,
        paths: [h + "/.codex/sessions", h + "/.codex/archived_sessions"], removal: .browse),
      .init(
        id: "ai.codex", title: "Codex app data", detail: "Settings, databases and plugins",
        group: .ai, paths: [h + "/.codex", h + "/Library/Application Support/Codex"],
        removal: .reveal),
      .init(
        id: "ai.claude.desktop", title: "Claude desktop",
        detail: "Includes its virtual machine · manage in Claude", group: .ai,
        paths: [h + "/Library/Application Support/Claude"], removal: .reveal),
      .init(
        id: "ai.claude.code", title: "Claude Code", detail: "Chats, plugins and settings",
        group: .ai, paths: [h + "/.claude"], removal: .browse),
      .init(
        id: "containers.docker", title: "Docker Desktop",
        detail: "Images and build cache can be cleaned · volumes are kept", group: .containers,
        paths: [
          h + "/Library/Containers/com.docker.docker",
          h + "/Library/Group Containers/group.com.docker",
          h + "/.docker",
        ], removal: .docker),
      .init(
        id: "containers.colima", title: "Colima and Lima VMs",
        detail: "Linux VM disks used by Docker · clean images through Docker", group: .containers,
        paths: [h + "/.colima", h + "/.lima"], removal: .docker),
      .init(
        id: "containers.orbstack", title: "OrbStack", detail: "Manage its data in OrbStack",
        group: .containers,
        paths: [h + "/.orbstack", h + "/Library/Group Containers/HUAQ24HBR6.dev.orbstack"],
        removal: .reveal),
      .init(
        id: "personal.downloads", title: "Downloads", detail: "Installers and saved files",
        group: .personal, paths: [h + "/Downloads"], removal: .browse),
      .init(
        id: "personal.desktop", title: "Desktop", detail: "Files on your desktop",
        group: .personal, paths: [h + "/Desktop"], removal: .browse),
      .init(
        id: "personal.documents", title: "Documents", detail: "Your documents",
        group: .personal, paths: [h + "/Documents"], removal: .browse),
      .init(
        id: "personal.pictures", title: "Pictures", detail: "Includes the Photos library",
        group: .personal, paths: [h + "/Pictures"], removal: .browse),
      .init(
        id: "personal.movies", title: "Movies", detail: "Videos and project files",
        group: .personal, paths: [h + "/Movies"], removal: .browse),
      .init(
        id: "personal.music", title: "Music", detail: "Music and audio projects",
        group: .personal, paths: [h + "/Music"], removal: .browse),
      .init(
        id: "personal.shared", title: "Shared folder", detail: "/Users/Shared",
        group: .personal, paths: ["/Users/Shared"], removal: .browse),
      .init(
        id: "personal.icloud", title: "iCloud Drive", detail: "Files downloaded to this Mac",
        group: .personal, paths: [h + "/Library/Mobile Documents"], removal: .reveal),
      .init(
        id: "messages.messages", title: "Messages",
        detail: "Attachments · Messages › Settings can delete old conversations",
        group: .messages,
        paths: [h + "/Library/Messages", h + "/Library/Containers/com.apple.MobileSMS"],
        removal: .reveal),
      .init(
        id: "messages.mail", title: "Mail", detail: "Downloaded mailboxes and attachments",
        group: .messages, paths: [h + "/Library/Mail", h + "/Library/Containers/com.apple.mail"],
        removal: .reveal),
      .init(
        id: "messages.whatsapp", title: "WhatsApp",
        detail: "Media from chats · Settings › Storage in WhatsApp", group: .messages,
        paths: [
          h + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared",
          h + "/Library/Containers/net.whatsapp.WhatsApp",
        ], removal: .reveal),
      .init(
        id: "trash", title: "Trash", detail: "Already deleted · emptying frees the space",
        group: .trash, paths: [h + "/.Trash"], removal: .emptyTrash),
      .init(
        id: "apps.homebrew", title: "Homebrew packages",
        detail: "Command-line tools · brew cleanup removes old versions", group: .apps,
        paths: ["/opt/homebrew", "/usr/local"], removal: .reveal),
    ]
    var exact: [String: String] = [:]
    for spec in specs { for path in spec.paths { exact[path] = spec.id } }
    self.exact = exact
  }

  /// Top-level folders walked for the breakdown; all live on the Data volume.
  var roots: [String] { [home, temporary] + systemRoots }

  /// Directories expanded into separate work items so large trees scan in parallel.
  func expands(_ path: String) -> Bool {
    path == home || path == home + "/Library" || path == home + "/dev"
      || path == home + "/Library/Application Support" || path == home + "/Library/Containers"
      || path == home + "/Library/Group Containers" || path == home + "/Library/Developer"
      || path == "/Applications" || path == "/Library"
  }

  struct Folder {
    let path: String
    let name: String
    /// The unit that owns the parent folder, if any.
    let inherited: String?
  }

  /// The unit that owns a folder: a fixed location, a project cache, an app, or a remainder bucket.
  func unit(_ folder: Folder) -> String? {
    if let id = exact[folder.path] { return id }
    if folder.name.hasSuffix(".asset"),
      (folder.path as NSString).deletingLastPathComponent == Self.runtimeRoot
    {
      return "runtime:" + folder.path
    }
    if folder.inherited == Self.dependencies || folder.inherited == Self.builds { return nil }
    let parent = (folder.path as NSString).deletingLastPathComponent
    if parent == "/Applications" || parent == home + "/Applications" { return "app:" + folder.path }
    if isProjectArea(folder.path) {
      if folder.name == "node_modules" { return Self.dependencies }
      if Self.buildFolders.contains(folder.name) { return Self.builds }
    }
    if let inherited = folder.inherited, !inherited.hasPrefix("lib:"), !inherited.hasPrefix("home:")
    {
      return nil
    }
    let library = home + "/Library"
    if parent == library + "/Application Support" || parent == library + "/Containers"
      || parent == library + "/Group Containers"
    {
      return "lib:" + folder.path
    }
    if parent == library, !Self.libraryGroups.contains(folder.name) {
      return "lib:" + folder.path
    }
    if parent == home, folder.name != "Library" { return "home:" + folder.path }
    if parent == "/", folder.name == "Library" { return Self.sharedLibrary }
    return nil
  }

  /// The unit for a file sitting directly in a walked or expanded folder.
  func unit(file parent: String, inherited: String?) -> String? {
    if let inherited { return inherited }
    if parent == home { return Self.homeLoose }
    if parent.hasPrefix(home + "/Library") { return Self.libraryLoose }
    if parent == "/Library" { return Self.sharedLibrary }
    return nil
  }

  /// Visible folders under home outside Library, where project caches live.
  private func isProjectArea(_ path: String) -> Bool {
    guard path.hasPrefix(home + "/") else { return false }
    let first = path.dropFirst(home.count + 1).split(separator: "/").first ?? ""
    return !first.hasPrefix(".") && first != "Library" && first != "Applications"
  }

  private static let buildFolders: Set<String> = [
    ".next", ".turbo", ".build", "DerivedData", ".expo", ".parcel-cache", ".svelte-kit", ".nuxt",
    ".angular", "Pods",
  ]
  private static let libraryGroups: Set<String> = [
    "Application Support", "Containers", "Group Containers", "Developer",
  ]

  func spec(_ id: String) -> Spec? { specs.first { $0.id == id } }

  /// Names and actions for units found while scanning rather than listed in `specs`.
  func describe(_ id: String) -> Spec {
    if let spec = spec(id) { return spec }
    switch id {
    case Self.dependencies:
      return .init(
        id: id, title: "Project dependencies",
        detail: "node_modules · reinstalled by your package manager", group: .home, paths: [],
        removal: .projects)
    case Self.builds:
      return .init(
        id: id, title: "Project build output",
        detail: ".next, .build, DerivedData and Pods inside projects · rebuilt on the next build",
        group: .home, paths: [], removal: .projects)
    case Self.homeLoose:
      return .init(
        id: id, title: "Files in your home folder", detail: home, group: .home, paths: [home],
        removal: .browse)
    case Self.libraryLoose:
      return .init(
        id: id, title: "Other Library data", detail: "Smaller app folders in ~/Library",
        group: .appData, paths: [home + "/Library"], removal: .reveal)
    case Self.sharedLibrary:
      return .init(
        id: id, title: "Shared app data", detail: "/Library · installed for every user",
        group: .appData, paths: ["/Library"], removal: .reveal)
    default: break
    }
    if id.hasPrefix("runtime:") {
      let path = String(id.dropFirst(8))
      let runtime = SimulatorRuntimeAsset.read(path)
      return .init(
        id: id, title: "iOS " + (runtime?.version ?? "simulator"),
        detail: "Simulator version \(runtime?.build ?? "") · its simulated devices go with it",
        group: .simulators, paths: [path], removal: .simulatorRuntime)
    }
    if id.hasPrefix("app:") {
      let path = String(id.dropFirst(4))
      let name = (path as NSString).lastPathComponent
      let isApp = name.hasSuffix(".app")
      return .init(
        id: id, title: isApp ? String(name.dropLast(4)) : name,
        detail: isApp ? "Application" : "Folder in Applications", group: .apps, paths: [path],
        removal: isApp ? .uninstall : .reveal)
    }
    if id.hasPrefix("home:") {
      let path = String(id.dropFirst(5))
      return .init(
        id: id, title: (path as NSString).lastPathComponent, detail: "Folder in your home folder",
        group: .home, paths: [path], removal: .browse)
    }
    let path = String(id.dropFirst(4))
    let name = (path as NSString).lastPathComponent
    let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    if parent == "Containers", let leftover = Self.leftover(bundleID: name) {
      return .init(
        id: id, title: leftover, detail: "Left over from an app that is no longer installed",
        group: .appData, paths: [path], removal: .deleteFolder)
    }
    return .init(
      id: id, title: parent == "Containers" ? Self.appName(bundleID: name) ?? name : name,
      detail: parent == "Library" ? "Library" : parent, group: .appData, paths: [path],
      removal: .reveal)
  }

  static func appName(bundleID: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return nil
    }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(
      of: ".app", with: "")
  }

  /// A container whose app and parent app are both gone; Apple's own containers never qualify.
  static func leftover(bundleID: String) -> String? {
    guard !bundleID.hasPrefix("com.apple."), bundleID.split(separator: ".").count >= 3 else {
      return nil
    }
    var parts = bundleID.split(separator: ".").map(String.init)
    while parts.count >= 2 {
      if NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: "."))
        != nil
      {
        return nil
      }
      parts.removeLast()
    }
    return bundleID
  }
}

/// Measures the main drive in one pass, attributing every block to exactly one unit.
/// It stays on the Data volume, so mounted iPhones (DeviceFS), simulator runtimes and disk images never count.
struct DriveScanner: Sendable {
  let catalog: DriveCatalog

  final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [String: UInt64] = [:]
    private var folders: [String: Int] = [:]
    private var partial: Set<String> = []
    private var visited = 0
    private var cancelled = false

    struct Snapshot: Sendable {
      let bytes: [String: UInt64]
      let folders: [String: Int]
      let partial: Set<String>
      let visited: Int
    }

    var snapshot: Snapshot {
      lock.lock()
      defer { lock.unlock() }
      return .init(bytes: bytes, folders: folders, partial: partial, visited: visited)
    }

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }

    func cancel() {
      lock.lock()
      cancelled = true
      lock.unlock()
    }

    struct Batch {
      var bytes: [String: UInt64] = [:]
      var folders: [String: Int] = [:]
      var partial: Set<String> = []
      var visited = 0

      struct Entry {
        let metadata: stat?
        let key: String?
        let progress: Progress
      }

      mutating func add(_ entry: Entry) {
        guard let key = entry.key, let metadata = entry.metadata else { return }
        guard let counted = entry.progress.links.bytes(metadata) else { return }
        bytes[key, default: 0] += counted
        visited += 1
      }
    }

    func merge(_ batch: Batch) {
      lock.lock()
      defer { lock.unlock() }
      bytes.merge(batch.bytes, uniquingKeysWith: +)
      folders.merge(batch.folders, uniquingKeysWith: +)
      partial.formUnion(batch.partial)
      visited += batch.visited
    }

    /// Hard-linked files count once across every worker, so pnpm stores and link clones count once.
    let links = HardLinkLedger()
  }

  private struct Work {
    let path: String
    let inherited: String?
  }

  /// Walks every root and returns bytes per unit id.
  func scan(_ progress: Progress) -> Progress.Snapshot {
    var info = stat()
    guard stat("/System/Volumes/Data", &info) == 0 || stat(catalog.home, &info) == 0 else {
      return progress.snapshot
    }
    let device = info.st_dev
    var work: [Work] = []
    var direct = Progress.Batch()
    var queue = catalog.roots.compactMap { root -> Work? in
      var rootInfo = stat()
      guard lstat(root, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
        rootInfo.st_dev == device
      else { return nil }
      return Work(
        path: root,
        inherited: catalog.unit(
          .init(path: root, name: (root as NSString).lastPathComponent, inherited: nil)))
    }
    var seen: Set<String> = []
    while let item = queue.popLast() {
      guard seen.insert(item.path).inserted else { continue }
      guard catalog.expands(item.path) else {
        work.append(item)
        continue
      }
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: item.path) else {
        if let key = item.inherited { direct.partial.insert(key) }
        continue
      }
      for name in names {
        let path = item.path == "/" ? "/" + name : item.path + "/" + name
        var child = stat()
        guard lstat(path, &child) == 0, child.st_dev == device else { continue }
        if child.st_mode & S_IFMT == S_IFDIR {
          if catalog.roots.contains(path), path != item.path { continue }
          let key = catalog.unit(.init(path: path, name: name, inherited: item.inherited))
          queue.append(.init(path: path, inherited: key ?? item.inherited))
        } else if let key = catalog.unit(file: item.path, inherited: item.inherited) {
          direct.bytes[key, default: 0] += progress.links.bytes(child) ?? 0
          direct.visited += 1
        }
      }
    }
    progress.merge(direct)
    let next = WorkQueue(work.sorted { $0.path < $1.path })
    DispatchQueue.concurrentPerform(iterations: 6) { _ in
      while let item = next.pop(), !progress.isCancelled {
        walk(.init(work: item, device: device, progress: progress))
      }
    }
    return progress.snapshot
  }

  /// Measures one unit again after a removal.
  func measure(_ unit: DriveUnit) -> (bytes: UInt64, partial: Bool) {
    let progress = Progress()
    var info = stat()
    guard stat("/System/Volumes/Data", &info) == 0 || stat(catalog.home, &info) == 0 else {
      return (0, true)
    }
    for path in unit.paths {
      var root = stat()
      guard lstat(path, &root) == 0, root.st_dev == info.st_dev else { continue }
      walk(
        .init(work: .init(path: path, inherited: unit.id), device: info.st_dev, progress: progress))
    }
    let snapshot = progress.snapshot
    return (snapshot.bytes[unit.id] ?? 0, snapshot.partial.contains(unit.id))
  }

  private struct WalkInput {
    let work: Work
    let device: dev_t
    let progress: Progress
  }

  private func walk(_ input: WalkInput) {
    guard let tree = FileTree(.init(path: input.work.path, needsMetadata: true)) else { return }
    var stack: [(level: Int, key: String?)] = [(-1, input.work.inherited)]
    var batch = Progress.Batch()
    while let entry = tree.next() {
      let level = entry.level
      let kind = entry.kind
      switch kind {
      case .directory, .unreadableDirectory:
        if kind == .directory, entry.metadata?.st_dev != input.device {
          tree.skip(entry)
          continue
        }
        let path = entry.path
        let inherited = stack.last?.key
        let key =
          level == 0
          ? input.work.inherited
          : catalog.unit(.init(path: path, name: entry.name, inherited: inherited)) ?? inherited
        guard kind == .directory else {
          if let key { batch.partial.insert(key) }
          continue
        }
        if key != inherited, let key, key == DriveCatalog.dependencies || key == DriveCatalog.builds
        {
          batch.folders[key, default: 0] += 1
        }
        stack.append((level, key))
        batch.add(.init(metadata: entry.metadata, key: key, progress: input.progress))
      case .directoryEnd:
        if stack.count > 1, stack.last?.level == level { stack.removeLast() }
      case .unreadable:
        if let key = stack.last?.key { batch.partial.insert(key) }
      case .file, .other:
        batch.add(.init(metadata: entry.metadata, key: stack.last?.key, progress: input.progress))
      }
      if batch.visited >= 4_096 {
        input.progress.merge(batch)
        batch = .init()
        if input.progress.isCancelled { return }
      }
    }
    input.progress.merge(batch)
  }

  private final class WorkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Work]

    init(_ items: [Work]) { self.items = items }

    func pop() -> Work? {
      lock.lock()
      defer { lock.unlock() }
      return items.popLast()
    }
  }
}

/// One iOS simulator version registered with the simulator service, as `simctl runtime list -j` reports it.
struct SimulatorRuntimeCopy: Decodable, Equatable, Sendable {
  let identifier: String
  let build: String
  let path: String?
  let parentImagePath: String?

  /// Whether this registration was made from the download at `asset`, so deleting it deletes the download.
  func uses(_ asset: String) -> Bool {
    [path, parentImagePath].contains { $0?.hasPrefix(asset + "/") == true }
  }
}

enum SimulatorRuntimeCopies {
  /// Nil when the output is not the JSON object of runtimes, so a failed read never looks like "none installed".
  static func read(_ json: String) -> [SimulatorRuntimeCopy]? {
    let decoded = try? JSONDecoder().decode(
      [String: SimulatorRuntimeCopy].self, from: Data(json.utf8))
    return decoded.map { Array($0.values) }
  }

  static func list() -> Result<[SimulatorRuntimeCopy], CommandReadError> {
    DriveRemover.simctl(["runtime", "list", "-j"]).read(read)
  }
}

/// One downloaded iOS simulator version under `DriveCatalog.runtimeRoot`.
struct SimulatorRuntimeAsset: Equatable, Sendable {
  let version: String
  let build: String

  static func read(_ path: String) -> Self? {
    guard
      let data = FileManager.default.contents(atPath: path + "/Info.plist"),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let properties = plist["MobileAssetProperties"] as? [String: Any],
      let version = properties["SimulatorVersion"] as? String,
      let build = properties["Build"] as? String
    else { return nil }
    return .init(version: version, build: build)
  }
}
