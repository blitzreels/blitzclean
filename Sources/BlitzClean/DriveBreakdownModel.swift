import AppKit
import Darwin
import Foundation

@MainActor
final class DriveBreakdownModel: ObservableObject {
  @Published private(set) var breakdown: DriveBreakdown?
  @Published private(set) var isScanning = false
  @Published private(set) var visited = 0
  @Published private(set) var busyID: String?
  /// The removal in progress, step by step; nil when nothing is being deleted.
  @Published private(set) var removal: DriveRemovalProgress?
  /// iOS downloads no longer registered with the simulator service. macOS protects them, and removing one
  /// means registering it again, which macOS refuses while the disk is nearly full.
  @Published private(set) var protectedRuntimePaths: Set<String> = []
  @Published private(set) var message: BlitzStatusMessage?
  /// Display order from the last complete scan, so rows keep their place while sizes change.
  @Published private(set) var rank: [String: Int] = [:]

  private static let freshInterval: TimeInterval = 10 * 60
  private let history: CleanupOverviewModel
  private let catalog: DriveCatalog
  private let store = AppData.file("drive-breakdown.json")
  private var progress: DriveScanner.Progress?

  init(history: CleanupOverviewModel) {
    self.history = history
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
      .standardizedFileURL.path
    catalog = DriveCatalog(
      .init(
        home: FileManager.default.homeDirectoryForCurrentUser.path, temporary: temporary,
        systemRoots: DriveCatalog.systemRoots))
    if let data = try? Data(contentsOf: store),
      let saved = try? JSONDecoder().decode(DriveBreakdown.self, from: data)
    {
      breakdown = saved
      rank = Self.rank(saved)
    }
    refreshRuntimes()
  }

  /// Marks which iOS downloads the simulator service still lists, so only those count as deletable.
  func refreshRuntimes() {
    let paths = (breakdown?.units ?? []).filter { $0.removal == .simulatorRuntime }
      .compactMap(\.paths.first)
    guard !paths.isEmpty else { return }
    Task {
      let protected = await Task.detached(priority: .utility) {
        SimulatorRuntimeCopies.list().map { copies in
          let builds = Set(copies.map(\.build))
          return Set(
            paths.filter { path in
              SimulatorRuntimeAsset.read(path).map { !builds.contains($0.build) } ?? false
            })
        }
      }.value
      switch protected {
      case .success(let protected):
        if protected != protectedRuntimePaths { protectedRuntimePaths = protected }
      case .failure(let error):
        // Keep the last known protection rather than marking every version protected or deletable.
        if message == nil {
          message = .init(
            text: "Couldn't read installed iOS simulator versions: \(error.reason).",
            tone: .warning)
        }
      }
    }
  }

  func scanIfNeeded() {
    guard !isScanning else { return }
    if let breakdown, Date.now.timeIntervalSince(breakdown.scannedAt) < Self.freshInterval {
      refreshCapacity()
      return
    }
    scan()
  }

  func scan() {
    guard !isScanning, busyID == nil else { return }
    isScanning = true
    visited = 0
    let progress = DriveScanner.Progress()
    self.progress = progress
    let scanner = DriveScanner(catalog: catalog)
    let catalog = catalog
    Task {
      let ticker = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(500))
          guard let self, self.isScanning, self.progress === progress else { return }
          let snapshot = progress.snapshot
          self.visited = snapshot.visited
          if self.rank.isEmpty {
            self.breakdown = Self.assemble(
              .init(snapshot: snapshot, catalog: catalog, capacity: .read(home: catalog.home)))
          }
        }
      }
      let snapshot = await Task.detached(priority: .utility) { scanner.scan(progress) }.value
      ticker.cancel()
      let result = await Task.detached(priority: .utility) {
        Self.assemble(
          .init(snapshot: snapshot, catalog: catalog, capacity: .read(home: catalog.home)))
      }.value
      guard !progress.isCancelled else { return }
      breakdown = result
      rank = Self.rank(result)
      visited = snapshot.visited
      isScanning = false
      self.progress = nil
      save()
      refreshRuntimes()
    }
  }

  func cancelScan() {
    progress?.cancel()
    progress = nil
    isScanning = false
    if rank.isEmpty { breakdown = nil }
  }

  private struct AssembleInput: Sendable {
    let snapshot: DriveScanner.Progress.Snapshot
    let catalog: DriveCatalog
    let capacity: DriveCapacity
  }

  nonisolated private static func assemble(_ input: AssembleInput) -> DriveBreakdown {
    let units = input.snapshot.bytes.compactMap { id, bytes -> DriveUnit? in
      guard bytes > 0 else { return nil }
      let spec = input.catalog.describe(id)
      return DriveUnit(
        id: id, title: spec.title, detail: spec.detail, group: spec.group, paths: spec.paths,
        removal: spec.removal, minimumAge: spec.minimumAge, bytes: bytes,
        folders: input.snapshot.folders[id] ?? 0,
        partial: input.snapshot.partial.contains(id))
    }
    return DriveBreakdown(units: units, capacity: input.capacity, scannedAt: .now).withSystem()
  }

  nonisolated private static func rank(_ breakdown: DriveBreakdown) -> [String: Int] {
    var rank: [String: Int] = [:]
    for (index, unit) in breakdown.units.sorted(by: { $0.bytes > $1.bytes }).enumerated() {
      rank[unit.id] = index
    }
    let groups = DriveGroup.allCases.sorted { breakdown.bytes($0) > breakdown.bytes($1) }
    for (index, group) in groups.enumerated() { rank["group:" + group.rawValue] = index }
    return rank
  }

  private func refreshCapacity() {
    guard var breakdown else { return }
    breakdown.capacity = .read(home: catalog.home)
    self.breakdown = breakdown.withSystem()
  }

  private func save() {
    guard let breakdown, let data = try? JSONEncoder().encode(breakdown) else { return }
    try? FileManager.default.createDirectory(
      at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: store, options: .atomic)
  }

  /// Frees the units' space one after another. Every path is re-validated against the catalog first.
  func remove(_ units: [DriveUnit]) {
    guard busyID == nil else { return }
    if isScanning {
      progress?.cancel()
      progress = nil
      isScanning = false
    }
    let valid = units.filter { unit in
      let spec = catalog.describe(unit.id)
      return unit.removal.isDestructive && spec.removal == unit.removal && spec.paths == unit.paths
    }
    guard let first = valid.first else { return }
    busyID = first.id
    message = nil
    let before = ResourceReading.now()
    Task {
      var total: UInt64 = 0
      var combined = DriveRemovalOutcome()
      var last: BlitzStatusMessage?
      for (index, unit) in valid.enumerated() {
        busyID = unit.id
        removal = .init(current: unit.title, done: index, total: valid.count, freed: total)
        let result = await perform(unit)
        total += result.freed
        combined.removed += result.outcome.removed
        combined.skippedOpen += result.outcome.skippedOpen
        combined.skippedRecent += result.outcome.skippedRecent
        combined.failed += result.outcome.failed
        last = result.outcome.message(.init(unit: unit, freed: result.freed))
      }
      if valid.count == 1 {
        message = last
      } else {
        var summary = combined
        summary.note = nil
        message = summary.message(
          .init(
            unit: .system(
              .init(
                id: "batch", title: "\(valid.count) caches", detail: "", bytes: 0)),
            freed: total))
      }
      if let result = message {
        let after = await ResourceReading.settled()
        message = .init(
          text: result.text + " " + MeasuredResult.disk(.init(before: before, after: after)),
          tone: result.tone)
      }
      busyID = nil
      removal = nil
      refreshRuntimes()
    }
  }

  private struct Performed {
    let outcome: DriveRemovalOutcome
    let freed: UInt64
  }

  private func perform(_ unit: DriveUnit) async -> Performed {
    let before = CleanupVolume.read(catalog.home)
    let catalog = catalog
    let outcome: DriveRemovalOutcome
    if unit.removal == .uninstall {
      outcome = await DriveRemover.uninstall(unit)
    } else {
      outcome = await Task.detached(priority: .userInitiated) {
        DriveRemover.remove(.init(unit: unit, home: catalog.home))
      }.value
    }
    let measured = await Task.detached(priority: .userInitiated) {
      DriveScanner(catalog: catalog).measure(unit)
    }.value
    let freed = unit.bytes > measured.bytes ? unit.bytes - measured.bytes : 0
    if !outcome.removed.isEmpty {
      history.record(
        CleanupWin(
          id: UUID().uuidString, date: .now, title: "Deleted · \(unit.title)",
          paths: outcome.removed, before: before, after: CleanupVolume.read(catalog.home),
          bytes: freed))
    }
    update(.init(id: unit.id, bytes: measured.bytes, partial: measured.partial))
    if unit.removal == .uninstall { remeasure("trash") }
    if unit.removal == .simulatorRuntime { remeasure("simulators.runtimes") }
    return .init(outcome: outcome, freed: freed)
  }

  private struct UnitUpdate {
    let id: String
    let bytes: UInt64
    let partial: Bool
  }

  private func update(_ change: UnitUpdate) {
    guard var breakdown else { return }
    if let index = breakdown.units.firstIndex(where: { $0.id == change.id }) {
      breakdown.units[index].bytes = change.bytes
      breakdown.units[index].partial = change.partial
    }
    breakdown.capacity = .read(home: catalog.home)
    self.breakdown = breakdown.withSystem()
    save()
  }

  private func remeasure(_ id: String) {
    let spec = catalog.describe(id)
    let unit = DriveUnit(
      id: id, title: spec.title, detail: spec.detail, group: spec.group, paths: spec.paths,
      removal: spec.removal, minimumAge: spec.minimumAge, bytes: 0, folders: 0, partial: false)
    let catalog = catalog
    Task {
      let measured = await Task.detached(priority: .utility) {
        DriveScanner(catalog: catalog).measure(unit)
      }.value
      guard var breakdown else { return }
      if let index = breakdown.units.firstIndex(where: { $0.id == id }) {
        breakdown.units[index].bytes = measured.bytes
      } else if measured.bytes > 0 {
        var added = unit
        added.bytes = measured.bytes
        breakdown.units.append(added)
      }
      self.breakdown = breakdown.withSystem()
      save()
    }
  }
}

struct BlitzStatusMessage: Equatable {
  let text: String
  let tone: BlitzStatusTone
}

/// Where a removal batch is: the item being deleted, how many are done and what they freed so far.
struct DriveRemovalProgress: Equatable, Sendable {
  let current: String
  let done: Int
  let total: Int
  let freed: UInt64
}

struct DriveRemovalOutcome: Sendable {
  var removed: [String] = []
  var skippedRecent = 0
  var skippedOpen = 0
  var failed: [String] = []
  var note: String?

  struct MessageInput {
    let unit: DriveUnit
    let freed: UInt64
  }

  @MainActor func message(_ input: MessageInput) -> BlitzStatusMessage {
    if let note, removed.isEmpty { return .init(text: note, tone: .warning) }
    var parts: [String] = []
    if input.unit.removal == .uninstall {
      parts.append("\(input.unit.title) moved to Trash. Empty Trash to free its space.")
    } else {
      parts.append(
        input.freed > 0
          ? "Deleted \(ByteText.full(input.freed)) from \(input.unit.title)."
          : "\(input.unit.title): nothing could be deleted.")
    }
    if skippedOpen > 0 { parts.append("\(skippedOpen) in use by an app kept.") }
    if skippedRecent > 0 { parts.append("\(skippedRecent) used recently kept.") }
    if !failed.isEmpty { parts.append("\(failed.count) protected by macOS kept.") }
    if let note { parts.append(note) }
    return .init(text: parts.joined(separator: " "), tone: removed.isEmpty ? .warning : .working)
  }
}

enum DriveRemover {
  struct Request: Sendable {
    let unit: DriveUnit
    let home: String
  }

  static func remove(_ request: Request) -> DriveRemovalOutcome {
    switch request.unit.removal {
    case .deleteContents: deleteContents(.init(unit: request.unit, checksOpenFiles: true))
    case .emptyTrash: emptyTrash(request)
    case .deleteFolder: deleteFolder(request)
    case .simulators: deleteSimulators()
    case .simulatorRuntime: deleteRuntime(request)
    default: .init()
    }
  }

  private struct ContentsRequest {
    let unit: DriveUnit
    let checksOpenFiles: Bool
  }

  /// Deletes each top-level item inside the unit's folders, keeping recent and open ones.
  private static func deleteContents(_ request: ContentsRequest) -> DriveRemovalOutcome {
    var outcome = DriveRemovalOutcome()
    let open: Set<String>
    if request.checksOpenFiles {
      switch openFiles(under: request.unit.paths) {
      case .success(let files): open = files
      case .failure(let error):
        outcome.note =
          "Couldn't check which files apps have open: \(error.reason). Nothing was deleted."
        return outcome
      }
    } else {
      open = []
    }
    let cutoff = Date.now.addingTimeInterval(-request.unit.minimumAge)
    for root in request.unit.paths {
      var info = stat()
      guard lstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        ReviewFile.canonicalPath(root) == root,
        let names = try? FileManager.default.contentsOfDirectory(atPath: root)
      else { continue }
      for name in names {
        let path = root + "/" + name
        var child = stat()
        guard lstat(path, &child) == 0, child.st_dev == info.st_dev else { continue }
        if open.contains(path) {
          outcome.skippedOpen += 1
          continue
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(child.st_mtimespec.tv_sec))
        if request.unit.minimumAge > 0, modified > cutoff {
          outcome.skippedRecent += 1
          continue
        }
        do {
          try RemovalGate.remove(
            .init(
              path: path, expected: .init(device: child.st_dev, inode: child.st_ino),
              method: .permanent))
          outcome.removed.append(path)
        } catch {
          outcome.failed.append(path)
        }
      }
    }
    return outcome
  }

  /// Top-level items under the roots that any of the user's processes has open; fails when lsof does.
  private static func openFiles(under roots: [String]) -> Result<Set<String>, CommandReadError> {
    DeveloperCommand.run(
      .init(
        executable: "/usr/sbin/lsof", arguments: ["-nP", "-Fn", "-u", String(getuid())],
        timeout: 20, maximumBytes: 96 * 1_024 * 1_024)
    ).read { output in
      // This app always has files open, so an empty list means lsof did not really answer.
      guard !output.isEmpty, LsofFields.isWellFormed(output) else { return nil }
      return openItems(.init(output: output, roots: roots))
    }
  }

  struct OpenItemsInput {
    let output: String
    let roots: [String]
  }

  static func openItems(_ input: OpenItemsInput) -> Set<String> {
    let roots = input.roots
    var open: Set<String> = []
    for line in input.output.split(separator: "\n") where line.first == "n" {
      let path = line.dropFirst()
      for root in roots where path.hasPrefix(root + "/") {
        let rest = path.dropFirst(root.count + 1)
        let name = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        if !name.isEmpty { open.insert(root + "/" + name) }
      }
    }
    return open
  }

  private static func emptyTrash(_ request: Request) -> DriveRemovalOutcome {
    let trash = request.home + "/.Trash"
    guard (try? FileManager.default.contentsOfDirectory(atPath: trash)) != nil else {
      let result = DeveloperCommand.run(
        .init(
          executable: "/usr/bin/osascript",
          arguments: ["-e", "tell application \"Finder\" to empty the trash"],
          timeout: 120, maximumBytes: 64 * 1_024))
      var outcome = DriveRemovalOutcome()
      if result.status == 0 {
        outcome.removed = [trash]
      } else {
        outcome.note =
          "macOS blocked access to the Trash. Allow Full Disk Access in Settings, or empty it in Finder."
      }
      return outcome
    }
    return deleteContents(.init(unit: request.unit, checksOpenFiles: false))
  }

  /// Removes an app container whose app is gone; checked again right before deleting.
  private static func deleteFolder(_ request: Request) -> DriveRemovalOutcome {
    var outcome = DriveRemovalOutcome()
    for path in request.unit.paths {
      let bundleID = (path as NSString).lastPathComponent
      guard path.hasPrefix(request.home + "/Library/Containers/"),
        DriveCatalog.leftover(bundleID: bundleID) != nil,
        ReviewFile.canonicalPath(path) == path
      else {
        outcome.note = "The app for this data is installed again, so it was kept."
        continue
      }
      do {
        try RemovalGate.remove(.init(path: path, expected: nil, method: .permanent))
        outcome.removed.append(path)
      } catch {
        outcome.failed.append(path)
        outcome.note = "macOS kept it: \(error.localizedDescription)"
      }
    }
    return outcome
  }

  /// Shuts down running simulators, then deletes every device and devices whose iOS version is gone.
  private static func deleteSimulators() -> DriveRemovalOutcome {
    var outcome = DriveRemovalOutcome()
    guard let devices = try? SimulatorDeviceService().list() else {
      outcome.note = "Could not read simulator devices. Check that Xcode is installed."
      return outcome
    }
    let root = NSHomeDirectory() + "/Library/Developer/CoreSimulator/Devices/"
    for device in devices where UUID(uuidString: device.id) != nil {
      if device.state != "Shutdown" { _ = simctl(["shutdown", device.id]) }
      if simctl(["delete", device.id]).status == 0 {
        outcome.removed.append(root + device.id)
      } else {
        outcome.failed.append(root + device.id)
      }
    }
    _ = simctl(["delete", "unavailable"])
    return outcome
  }

  static func simctl(_ arguments: [String]) -> CleanupCommandResult {
    DeveloperCommand.run(
      .init(
        executable: "/usr/bin/xcrun", arguments: ["simctl"] + arguments, timeout: 300,
        maximumBytes: 4 * 1_024 * 1_024))
  }

  /// Deletes one iOS simulator version through `simctl`. System Integrity Protection guards these folders,
  /// so a version Xcode no longer lists is added back first and then deleted by the simulator service.
  private static func deleteRuntime(_ request: Request) -> DriveRemovalOutcome {
    var outcome = DriveRemovalOutcome()
    guard let path = request.unit.paths.first,
      (path as NSString).deletingLastPathComponent == DriveCatalog.runtimeRoot,
      path.hasSuffix(".asset"), ReviewFile.canonicalPath(path) == path,
      !path.contains("\""), !path.contains("\\"),
      let runtime = SimulatorRuntimeAsset.read(path)
    else {
      outcome.note = "This iOS version changed since the scan. Scan again."
      return outcome
    }
    // The same version can be installed twice: once from this download and once from a copy Xcode
    // fetched itself. Every copy goes, or the version stays listed and its space stays used.
    // Without the list, every next step would be a guess, so nothing is deleted or registered.
    let listed: [SimulatorRuntimeCopy]
    switch SimulatorRuntimeCopies.list() {
    case .success(let copies): listed = copies
    case .failure(let error):
      outcome.note =
        "Couldn't read installed iOS simulator versions: \(error.reason). Nothing was deleted."
      return outcome
    }
    let copies = listed.filter { $0.build == runtime.build }
    for copy in copies { _ = simctl(["runtime", "delete", copy.identifier]) }
    let ownsDownload = copies.contains { $0.uses(path) }
    if !(ownsDownload && waitUntilGone(path)), let image = diskImage(in: path) {
      // An unregistered download is protected by macOS. Registering it again hands it to the
      // simulator service, which deletes the download together with its registration.
      let added = simctl(["runtime", "add", image])
      let registered: [SimulatorRuntimeCopy]
      switch SimulatorRuntimeCopies.list() {
      case .success(let copies): registered = copies
      case .failure(let error):
        outcome.note =
          "macOS kept iOS \(runtime.version). Couldn't read installed iOS simulator versions "
          + "after registering it again: \(error.reason)."
        outcome.failed = [path]
        return outcome
      }
      for copy in registered where copy.build == runtime.build {
        _ = simctl(["runtime", "delete", copy.identifier])
      }
      if !waitUntilGone(path) {
        outcome.note =
          added.output.localizedCaseInsensitiveContains("almost full")
          ? "macOS protects iOS \(runtime.version). Removing it needs about "
            + "\(ByteText.compact(request.unit.bytes)) of free space first. Free some space, then try again."
          : "macOS kept iOS \(runtime.version). Remove it in Xcode › Settings › Components."
        outcome.failed = [path]
        return outcome
      }
    }
    if FileManager.default.fileExists(atPath: path) {
      outcome.note =
        "macOS kept iOS \(runtime.version). Remove it in Xcode › Settings › Components."
      outcome.failed = [path]
    } else {
      outcome.removed = [path]
    }
    return outcome
  }

  /// The simulator service deletes in the background after `simctl` returns.
  private static func waitUntilGone(_ path: String) -> Bool {
    for _ in 0..<60 {
      if !FileManager.default.fileExists(atPath: path) { return true }
      Thread.sleep(forTimeInterval: 0.5)
    }
    return !FileManager.default.fileExists(atPath: path)
  }

  /// The runtime's disk image inside its MobileAsset folder.
  private static func diskImage(in asset: String) -> String? {
    let enumerator = FileManager.default.enumerator(atPath: asset + "/AssetData")
    while let item = enumerator?.nextObject() as? String {
      if item.hasSuffix(".dmg") { return asset + "/AssetData/" + item }
    }
    return nil
  }

  /// Moves an app to the Trash through Finder, which asks for a password when macOS requires one.
  @MainActor static func uninstall(_ unit: DriveUnit) async -> DriveRemovalOutcome {
    var outcome = DriveRemovalOutcome()
    guard let path = unit.paths.first, path.hasSuffix(".app"),
      path.hasPrefix("/Applications/")
        || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/"),
      ReviewFile.canonicalPath(path) == path,
      path != Bundle.main.bundlePath
    else {
      outcome.note = "This app cannot be removed here."
      return outcome
    }
    if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == path }) {
      outcome.note = "Quit \(unit.title) first, then delete it."
      return outcome
    }
    do { try RemovalGate.check(.init(path: path, expected: nil, method: .trash)) } catch {
      outcome.note = "\(unit.title) was kept: \(error.localizedDescription)"
      return outcome
    }
    let url = URL(fileURLWithPath: path)
    let error: Error? = await withCheckedContinuation { continuation in
      NSWorkspace.shared.recycle([url]) { _, error in continuation.resume(returning: error) }
    }
    if let error {
      outcome.note = "\(unit.title) was kept: \(error.localizedDescription)"
    } else {
      outcome.removed = [path]
    }
    return outcome
  }
}
