import Darwin
import Foundation

struct ReviewFile: Codable, Equatable, Identifiable, Sendable {
  let path: String
  let bytes: UInt64
  let modifiedAt: Date
  let device: Int32
  let inode: UInt64
  let logicalBytes: Int64
  let modifiedNanoseconds: Int64

  var id: String { path }
  var name: String { URL(fileURLWithPath: path).lastPathComponent }
  var isTemporary: Bool { path.hasPrefix("/private/") }
  var kind: String {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    if ["mov", "mp4", "m4v", "mkv", "webm"].contains(ext) { return "Video" }
    if ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff"].contains(ext) { return "Image" }
    if ["zip", "tgz", "gz", "dmg", "pkg", "iso", "tar"].contains(ext) {
      return "Archive / installer"
    }
    return "Large file"
  }

  func matchesIdentity(_ other: ReviewFile) -> Bool {
    path == other.path && device == other.device && inode == other.inode
      && logicalBytes == other.logicalBytes && modifiedAt == other.modifiedAt
      && modifiedNanoseconds == other.modifiedNanoseconds
  }

  static func read(_ path: String) -> Self? {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      let physicalPath = canonicalPath(path)
    else { return nil }
    return Self(
      path: physicalPath, bytes: UInt64(max(0, info.st_blocks)) * 512,
      modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)),
      device: info.st_dev, inode: info.st_ino, logicalBytes: info.st_size,
      modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
  }

  static func canonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  var currentVersion: ReviewFile? {
    guard let current = Self.read(path), current.path == path else { return nil }
    return current
  }
}

struct ReviewScanRequest: Codable, Sendable {
  let roots: [String]
  let minimumBytes: UInt64
  let maxEntries: Int
  var entireHierarchy = false
}

extension ReviewScanRequest {
  private enum CodingKeys: String, CodingKey {
    case roots, minimumBytes, maxEntries, entireHierarchy
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    roots = try values.decode([String].self, forKey: .roots)
    minimumBytes = try values.decode(UInt64.self, forKey: .minimumBytes)
    maxEntries = try values.decode(Int.self, forKey: .maxEntries)
    entireHierarchy = try values.decodeIfPresent(Bool.self, forKey: .entireHierarchy) ?? false
  }
}

struct ReviewScanResult: Sendable {
  let files: [ReviewFile]
  let limited: Bool
}

enum CleanupReviewScanner {
  static var roots: [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return ["Downloads", "Movies", "Desktop", "Documents"].map {
      home.appendingPathComponent($0).path
    }
      + ["/private/tmp", FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path]
  }

  static func scan(_ request: ReviewScanRequest) -> ReviewScanResult {
    var files: [String: ReviewFile] = [:]
    var limited = false
    let deadline = Date.now.addingTimeInterval(20)
    let excluded: Set<String> = [
      "node_modules", ".git", ".next", ".build", "Pods", ".Trash", ".pnpm", ".venv",
    ]
    for root in request.roots {
      guard !Task.isCancelled, Date.now < deadline else {
        limited = true
        break
      }
      var remaining = max(1, request.maxEntries / max(1, request.roots.count))
      guard let physicalRoot = ReviewFile.canonicalPath(root) else {
        limited = true
        continue
      }
      guard CleanupVolume.read(physicalRoot)?.isInternal == true else {
        limited = true
        continue
      }
      let rootURL = URL(fileURLWithPath: physicalRoot)
      var queue: [(url: URL, depth: Int)] = [(rootURL, 0)]
      var cursor = 0
      while cursor < queue.count, remaining > 0, !Task.isCancelled, Date.now < deadline {
        let directory = queue[cursor]
        cursor += 1
        let children: [URL]
        do {
          children = try FileManager.default.contentsOfDirectory(
            at: directory.url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
            options: [.skipsHiddenFiles])
        } catch {
          limited = true
          continue
        }
        for url in children {
          remaining -= 1
          if remaining < 0 || Task.isCancelled || Date.now >= deadline {
            limited = true
            break
          }
          guard
            let values = try? url.resourceValues(forKeys: [
              .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
            ])
          else {
            limited = true
            continue
          }
          if values.isSymbolicLink == true { continue }
          if values.isDirectory == true {
            if !excluded.contains(url.lastPathComponent), values.isPackage != true,
              directory.depth < 32
            {
              queue.append((url, directory.depth + 1))
            } else if directory.depth >= 32 {
              limited = true
            }
            continue
          }
          guard let file = ReviewFile.read(url.path), file.bytes >= request.minimumBytes,
            file.path.hasPrefix(physicalRoot + "/"),
            CleanupVolume.read(file.path)?.isInternal == true
          else { continue }
          if files.count < 5_000 || files[file.path] != nil {
            files[file.path] = file
          } else {
            limited = true
          }
        }
      }
      if cursor < queue.count { limited = true }
    }
    return ReviewScanResult(
      files: files.values.sorted { $0.bytes > $1.bytes }, limited: limited)
  }
}

struct CleanupCommandResult: Sendable {
  let status: Int32
  let output: String
}

enum CleanupActivity {
  private static let deadlines = DispatchQueue(
    label: "com.blitzreels.BlitzClean.cleanup-deadlines", qos: .userInitiated)

  static func command(_ arguments: [String]) -> CleanupCommandResult {
    runCommand(
      CleanupCommandRequest(executable: "/usr/sbin/lsof", arguments: arguments, timeout: 8))
  }

  static func runCommand(_ request: CleanupCommandRequest) -> CleanupCommandResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: request.executable)
    process.arguments = request.arguments
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return CleanupCommandResult(status: -1, output: "") }
    let timeout = DispatchWorkItem {
      if process.isRunning { process.terminate() }
    }
    let deadline = DispatchWorkItem {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    deadlines.asyncAfter(deadline: .now() + request.timeout, execute: timeout)
    deadlines.asyncAfter(deadline: .now() + request.timeout + 1, execute: deadline)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeout.cancel()
    deadline.cancel()
    return CleanupCommandResult(
      status: process.terminationReason == .exit ? process.terminationStatus : -1,
      output: String(decoding: data, as: UTF8.self))
  }

  static func workingDirectories() -> Set<String>? {
    let result = command(["-nP", "-d", "cwd", "-Fpn"])
    guard result.status == 0, !result.output.isEmpty,
      result.output.split(separator: "\n").allSatisfy({
        $0.hasPrefix("p") || $0.hasPrefix("n") || $0 == "fcwd"
      })
    else { return nil }
    return Set(
      ProjectProcessParser.workingDirectories(result.output).values.compactMap(
        ReviewFile.canonicalPath))
  }

  static func revalidate(_ item: StorageItem) -> StorageCleanupAvailability {
    guard let active = workingDirectories() else {
      return .blocked("Could not verify current activity")
    }
    let target = URL(fileURLWithPath: item.path).standardized
    guard ReviewFile.canonicalPath(target.path) == target.path,
      FileManager.default.fileExists(atPath: target.path)
    else { return .blocked("Item moved, removed, or replaced by a link") }
    switch item.cleanupKind {
    case .nodeModules, .generatedBuildCache:
      let nodePath = item.cleanupKind == .nodeModules ? item.path : item.path + "/node_modules"
      let context = NodeModulesResolver.resolve(
        NodeModulesResolutionRequest(nodeModulesPath: nodePath, fileManager: .default))
      guard context.cleanupTargetPath == item.path else {
        return .blocked("Cleanup target changed")
      }
      return NodeModulesSafety.evaluate(
        NodeModulesSafetyRequest(
          context: context, activeWorkingDirectories: active, fileManager: .default))
    case .simulatorCache:
      let expected = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/CoreSimulator/Caches").path
      guard item.path == expected else { return .blocked("Unrecognized simulator cache") }
      return simulatorAvailability()
    case nil:
      return .blocked("No rebuild recipe")
    }
  }

  private static func simulatorAvailability() -> StorageCleanupAvailability {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "list", "devices", "booted", "--json"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return .blocked("Simulator state unavailable") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
      let list = try? JSONDecoder().decode(BootedSimulatorList.self, from: data)
    else { return .blocked("Simulator state unavailable") }
    return list.devices.values.joined().contains { $0.state == "Booted" }
      ? .blocked("Simulator is running") : .ready
  }
}

struct CleanupCommandRequest: Sendable {
  let executable: String
  let arguments: [String]
  let timeout: TimeInterval
}

private struct BootedSimulatorList: Decodable {
  struct Device: Decodable { let state: String }
  let devices: [String: [Device]]
}

enum ReviewDeleteError: LocalizedError {
  case changed, missing, unverified, outsideRoots
  case protected
  case busy([String])

  var errorDescription: String? {
    switch self {
    case .changed: "This file changed. Review its updated details, then try again."
    case .missing: "This file is already gone. The list has been updated."
    case .busy(let apps):
      "This file is open\(apps.isEmpty ? " in another app" : " in " + apps.joined(separator: ", ")). Close the file there, then try again."
    case .unverified: "The open-file check could not finish safely. Try again, or use Finder."
    case .outsideRoots: "This path is outside the file review locations."
    case .protected:
      "System and app files are view-only here. Use their dedicated cleanup or uninstall action."
    }
  }
}

struct ReviewDeleteRequest: Sendable {
  let file: ReviewFile
  let roots: [String]
}

enum ReviewFileDeletion {
  static func canTrashPath(_ path: String) -> Bool {
    let dataPrefix = "/System/Volumes/Data"
    let visible = path.hasPrefix(dataPrefix + "/") ? String(path.dropFirst(dataPrefix.count)) : path
    guard !visible.split(separator: "/").contains(where: { $0.hasSuffix(".app") }) else {
      return false
    }
    return visible.hasPrefix("/Users/") || visible.hasPrefix("/Volumes/")
  }

  static func validateIdentity(_ request: ReviewDeleteRequest) throws {
    let file = request.file
    var info = stat()
    if lstat(file.path, &info) != 0 {
      if errno == ENOENT { throw ReviewDeleteError.missing }
      if errno == EACCES {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
      }
      throw ReviewDeleteError.unverified
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw ReviewDeleteError.changed }
    guard ReviewFile.canonicalPath(file.path) == file.path,
      request.roots.contains(where: { root in
        guard let path = ReviewFile.canonicalPath(root) else { return false }
        return file.path.hasPrefix(path.hasSuffix("/") ? path : path + "/")
      })
    else { throw ReviewDeleteError.outsideRoots }
    guard let current = ReviewFile.read(file.path), current.matchesIdentity(file) else {
      throw ReviewDeleteError.changed
    }
  }

  static func trash(_ request: ReviewDeleteRequest) throws {
    try validateIdentity(request)
    guard canTrashPath(request.file.path) else { throw ReviewDeleteError.protected }
    let volume = try URL(fileURLWithPath: request.file.path)
      .resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey])
    guard volume.volumeIsLocal == true, volume.volumeIsReadOnly == false else {
      throw ReviewDeleteError.unverified
    }
    let result = CleanupActivity.command(["-nP", "-Fpc", "--", request.file.path])
    if result.status == 0 { throw ReviewDeleteError.busy([]) }
    guard result.status == 1, result.output.isEmpty else { throw ReviewDeleteError.unverified }
    try validateIdentity(request)
    try FileManager.default.trashItem(
      at: URL(fileURLWithPath: request.file.path), resultingItemURL: nil)
  }

  static func delete(_ request: ReviewDeleteRequest) throws -> CleanupWin {
    try validateIdentity(request)
    let result = CleanupActivity.command(["-nP", "-Fpc", "--", request.file.path])
    if result.status == 0 {
      let apps = result.output.split(separator: "\n").filter { $0.hasPrefix("c") }
        .map { String($0.dropFirst()) }
      throw ReviewDeleteError.busy(Array(Set(apps)).sorted().prefix(3).map { $0 })
    }
    guard result.status == 1, result.output.isEmpty else { throw ReviewDeleteError.unverified }
    try validateIdentity(request)
    let before = CleanupVolume.read(request.file.path)
    try FileManager.default.removeItem(atPath: request.file.path)
    return CleanupWin(
      id: UUID().uuidString, date: .now, title: "Deleted \(request.file.name)",
      paths: [request.file.path],
      before: before, after: before.flatMap { CleanupVolume.read($0.path) })
  }
}

@MainActor
final class CleanupOverviewModel: ObservableObject {
  @Published private(set) var ledger = CleanupLedger()
  @Published private(set) var files: [ReviewFile] = []
  @Published private(set) var isScanning = false
  @Published private(set) var scannedAt: Date?
  @Published private(set) var scanLimited = false
  @Published private(set) var activeWorkingDirectories: Set<String>?
  @Published private(set) var deletingPath: String?
  @Published private(set) var queuedFiles: [ReviewFile] = []
  @Published private(set) var deletionFailures: [String: String] = [:]
  @Published private(set) var message: String?
  @Published private(set) var deletionFailure: ReviewDeletionFailure?
  @Published private(set) var historyError: String?
  @Published var mediaFilter = MediaReviewFilter() {
    didSet {
      guard !isRestoringReview else { return }
      do { try reviewStore.saveFilter(mediaFilter) } catch {
        reviewPersistenceError = "Media filters could not be saved."
      }
    }
  }
  @Published private(set) var reviewPersistenceError: String?
  private var isRestoringReview = true
  private let reviewStore: MediaReviewStore
  private let store: CleanupHistoryStore
  private var scanRequest: ReviewScanRequest
  private struct ScanCompletion: Sendable {
    let result: ReviewScanResult
    let workingDirectories: Set<String>?
    let progress: DriveScanProgress?
  }

  private var scanTask: Task<ScanCompletion, Never>?
  private var scanTimeout: Task<Void, Never>?
  private var scanGeneration = UUID()
  @Published private(set) var scanStatus: String?
  @Published private(set) var driveProgress: DriveScanProgress?
  private var synchronizationTask: Task<Void, Never>?
  private var hasUnsavedHistory = false
  private var importedReports: [String: Date?] = [:]
  private var fileValidationTask: Task<[ReviewFile], Never>?
  private var lastFileValidation = Date.distantPast

  init(_ configuration: CleanupOverviewConfiguration) {
    store = configuration.store
    scanRequest = configuration.scanRequest
    reviewStore = MediaReviewStore(
      url: configuration.store.url.deletingLastPathComponent()
        .appendingPathComponent(".\(configuration.store.url.lastPathComponent).review.json"))
    do {
      if let saved = try reviewStore.load() {
        scanRequest = saved.request
        mediaFilter = saved.filter
        var identities = Set<String>()
        files = saved.files.filter { identities.insert("\($0.device):\($0.inode)").inserted }
        scannedAt = saved.scannedAt
        scanLimited = saved.limited
      }
      if let filter = try reviewStore.loadFilter() { mediaFilter = filter }
      if configuration.scanRequest.entireHierarchy && !scanRequest.entireHierarchy {
        scanRequest = configuration.scanRequest
        files = []
        scannedAt = nil
        scanLimited = false
        mediaFilter = MediaReviewFilter()
      }
    } catch {
      reviewPersistenceError = "Saved file review could not be read. Scan again to rebuild it."
    }
    isRestoringReview = false
    do { ledger = try store.load() } catch {
      historyError = "Cleanup history could not be read. Existing history is preserved."
    }
    importReports()
    if configuration.synchronizesInBackground {
      synchronizationTask = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(3)) } catch { break }
          self?.synchronize()
        }
      }
    }
  }

  deinit {
    synchronizationTask?.cancel()
    fileValidationTask?.cancel()
  }

  func synchronize() {
    if !isScanning, !scanRequest.entireHierarchy, files.count <= 100 {
      let current = files.compactMap(\.currentVersion)
      if current != files {
        files = current
        saveReview()
      }
    } else if !isScanning, fileValidationTask == nil,
      Date.now.timeIntervalSince(lastFileValidation) >= 30
    {
      let snapshot = files
      lastFileValidation = .now
      let worker = Task.detached(priority: .utility) { snapshot.compactMap(\.currentVersion) }
      fileValidationTask = worker
      Task {
        let current = await worker.value
        if files == snapshot, current != files {
          files = current
          saveReview()
        }
        fileValidationTask = nil
      }
    }
    do {
      var latest = try store.load()
      for win in ledger.wins { latest.record(win) }
      if hasUnsavedHistory {
        latest = try store.merge(latest)
        hasUnsavedHistory = false
      }
      if latest != ledger { ledger = latest }
      historyError = nil
    } catch {
      historyError = "Cleanup history could not be read. Existing history is preserved."
    }
    importReports()
  }

  /// JSON cleanup reports dropped here, for example by an agent, join the history once.
  var reportsDirectory: URL {
    store.url.deletingLastPathComponent().appendingPathComponent("reports", isDirectory: true)
  }

  func importReports() {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: reportsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    let known = Set(ledger.wins.map(\.id))
    for file in files where file.pathExtension == "json" {
      let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      guard importedReports[file.lastPathComponent] != modified else { continue }
      importedReports[file.lastPathComponent] = modified
      for win in CleanupReportImporter.wins(file) where !known.contains(win.id) {
        ledger.record(win)
        hasUnsavedHistory = true
      }
    }
    if hasUnsavedHistory {
      do {
        ledger = try store.merge(ledger)
        hasUnsavedHistory = false
      } catch {
        historyError = "Imported cleanup reports could not be saved yet. Retrying automatically."
      }
    }
  }

  var reviewRoots: [String] { scanRequest.roots }
  var reviewMinimumBytes: UInt64 { scanRequest.minimumBytes }

  func configureReview(_ request: ReviewScanRequest) {
    guard !isScanning, deletingPath == nil, queuedFiles.isEmpty else { return }
    scanRequest = request
    files = []
    scannedAt = nil
    saveReview()
    refresh()
  }

  func refreshIfNeeded() {
    synchronize()
    if let scannedAt, Date.now.timeIntervalSince(scannedAt) < 3_600,
      !files.isEmpty || !scanLimited
    {
      return
    }
    refresh()
  }

  func refresh() {
    guard !isScanning else { return }
    isScanning = true
    scanStatus = nil
    driveProgress = nil
    let request = scanRequest
    let generation = UUID()
    scanGeneration = generation
    let worker = Task.detached(priority: .utility) {
      [weak self] () -> ScanCompletion in
      if request.entireHierarchy {
        let result = DriveFileScanner.scan(
          .init(
            roots: request.roots, minimumBytes: request.minimumBytes, resultLimit: 5_000,
            progress: { [weak self] progress in
              Task { @MainActor [weak self] in
                guard let self, self.scanGeneration == generation, self.isScanning else { return }
                self.driveProgress = progress
                self.files = progress.files
              }
            }))
        return ScanCompletion(
          result: ReviewScanResult(
            files: result.files, limited: !result.complete || result.unreadable > 0),
          workingDirectories: nil, progress: result
        )
      }
      let scan = CleanupReviewScanner.scan(request)
      return ScanCompletion(
        result: scan,
        workingDirectories: Task.isCancelled ? nil : CleanupActivity.workingDirectories(),
        progress: nil)
    }
    scanTask = worker
    if !request.entireHierarchy {
      scanTimeout = Task {
        do { try await Task.sleep(for: .seconds(32)) } catch { return }
        guard scanGeneration == generation else { return }
        stopScan("Scan could not finish. Choose a folder to narrow the search.")
      }
    }
    Task {
      let result = await worker.value
      guard scanGeneration == generation else { return }
      scanTimeout?.cancel()
      scanTask = nil
      if request.entireHierarchy {
        driveProgress = result.progress
        files = result.result.files
        scanLimited = result.result.limited
        scannedAt = .now
        saveReview()
      } else {
        applyScan(result.result)
      }
      activeWorkingDirectories = result.workingDirectories
      isScanning = false
    }
  }

  func cancelScan() {
    stopScan("Scan stopped. Files already found remain available.")
  }

  private func stopScan(_ status: String) {
    scanGeneration = UUID()
    scanTask?.cancel()
    scanTask = nil
    scanTimeout?.cancel()
    isScanning = false
    scanLimited = true
    scannedAt = .now
    scanStatus = status
    saveReview()
  }

  func applyScan(_ result: ReviewScanResult) {
    files = result.files.compactMap(\.currentVersion)
    scanLimited = result.limited
    scannedAt = .now
    saveReview()
  }

  private func saveReview() {
    do {
      try reviewStore.save(
        .init(
          version: 1, request: scanRequest, filter: mediaFilter,
          files: files, scannedAt: scannedAt, limited: scanLimited))
      reviewPersistenceError = nil
    } catch {
      reviewPersistenceError = "File review could not be saved. Free disk space and scan again."
    }
  }

  func record(_ win: CleanupWin) {
    ledger.record(win)
    do {
      ledger = try store.merge(ledger)
      hasUnsavedHistory = false
      historyError = nil
    } catch {
      hasUnsavedHistory = true
      historyError = "Cleanup succeeded; history could not be saved. Retrying automatically."
    }
  }

  func delete(_ file: ReviewFile) {
    guard !isPending(file) else { return }
    deletionFailures[file.path] = nil
    queuedFiles.append(file)
    startNextDeletion()
  }

  func isPending(_ file: ReviewFile) -> Bool {
    deletingPath == file.path || queuedFiles.contains { $0.path == file.path }
  }

  func cancelQueuedDeletion(_ file: ReviewFile) {
    queuedFiles.removeAll { $0.path == file.path }
  }

  private func startNextDeletion() {
    guard deletingPath == nil, !queuedFiles.isEmpty else { return }
    let file = queuedFiles.removeFirst()
    deletingPath = file.path
    let roots = scanRequest.roots
    Task {
      do {
        let win = try await Task.detached(priority: .utility) {
          try ReviewFileDeletion.delete(
            ReviewDeleteRequest(file: file, roots: roots))
        }.value
        record(win)
        files.removeAll { $0.path == file.path }
        deletionFailure = nil
        message =
          win.measuredGain.map { "Deleted \(file.name) · \(ByteText.full($0)) measured gain" }
          ?? "Deleted \(file.name) · disk measurement unavailable"
      } catch {
        if let deletionError = error as? ReviewDeleteError, case .missing = deletionError {
          deletionFailure = nil
          message = "\(file.name) is already gone. The list has been updated."
        } else {
          let explanation = deletionErrorMessage(error)
          deletionFailures[file.path] = explanation
          deletionFailure = ReviewDeletionFailure(path: file.path, message: explanation)
          message = "Could not delete \(file.name). \(explanation)"
        }
      }
      deletingPath = nil
      synchronize()
      startNextDeletion()
    }
  }

  private func deletionErrorMessage(_ error: Error) -> String {
    let cocoa = error as NSError
    if cocoa.domain == NSCocoaErrorDomain,
      [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(cocoa.code)
    {
      return
        "macOS denied access. Allow \(AppBrand.name) in Privacy & Security → Files and Folders, or remove this file in Finder."
    }
    return error.localizedDescription
  }
}

struct ReviewDeletionFailure: Equatable {
  let path: String
  let message: String
}

struct CleanupOverviewConfiguration: Sendable {
  let store: CleanupHistoryStore
  let scanRequest: ReviewScanRequest
  let synchronizesInBackground: Bool

  static var application: Self {
    Self(
      store: .application,
      scanRequest: ReviewScanRequest(
        roots: StorageDrives.roots, minimumBytes: 100 * 1_024 * 1_024, maxEntries: 80_000,
        entireHierarchy: true),
      synchronizesInBackground: true)
  }
}
