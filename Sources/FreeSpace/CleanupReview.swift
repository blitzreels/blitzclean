import Darwin
import Foundation

struct ReviewFile: Equatable, Identifiable, Sendable {
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

struct ReviewScanRequest: Sendable {
  let roots: [String]
  let minimumBytes: UInt64
  let maxEntries: Int
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
            includingPropertiesForKeys: nil,
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
              directory.depth < 3
            {
              queue.append((url, directory.depth + 1))
            }
            continue
          }
          guard let file = ReviewFile.read(url.path), file.bytes >= request.minimumBytes,
            file.path.hasPrefix(physicalRoot + "/"),
            CleanupVolume.read(file.path)?.isInternal == true
          else { continue }
          files[file.path] = file
        }
      }
      if cursor < queue.count { limited = true }
    }
    return ReviewScanResult(
      files: Array(files.values.sorted { $0.bytes > $1.bytes }.prefix(60)), limited: limited)
  }
}

struct CleanupCommandResult: Sendable {
  let status: Int32
  let output: String
}

enum CleanupActivity {
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
    DispatchQueue.global().asyncAfter(deadline: .now() + request.timeout, execute: timeout)
    DispatchQueue.global().asyncAfter(deadline: .now() + request.timeout + 1, execute: deadline)
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
  case busy([String])

  var errorDescription: String? {
    switch self {
    case .changed: "This file changed. Review its updated details, then try again."
    case .missing: "This file is already gone. The list has been updated."
    case .busy(let apps):
      "This file is open\(apps.isEmpty ? " in another app" : " in " + apps.joined(separator: ", ")). Close the file there, then try again."
    case .unverified: "The open-file check could not finish safely. Try again, or use Finder."
    case .outsideRoots: "This path is outside the file review locations."
    }
  }
}

struct ReviewDeleteRequest: Sendable {
  let file: ReviewFile
  let roots: [String]
}

enum ReviewFileDeletion {
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
    guard CleanupVolume.read(request.file.path)?.isInternal == true else {
      throw ReviewDeleteError.outsideRoots
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
  private let store: CleanupHistoryStore
  private var scanRequest: ReviewScanRequest
  private var scanTask: Task<(ReviewScanResult, Set<String>?), Never>?
  private var scanTimeout: Task<Void, Never>?
  private var scanGeneration = UUID()
  @Published private(set) var scanStatus: String?
  private var synchronizationTask: Task<Void, Never>?
  private var hasUnsavedHistory = false

  init(_ configuration: CleanupOverviewConfiguration) {
    store = configuration.store
    scanRequest = configuration.scanRequest
    do { ledger = try store.load() } catch {
      historyError = "Cleanup history could not be read. Existing history is preserved."
    }
    if configuration.synchronizesInBackground {
      synchronizationTask = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(3)) } catch { break }
          self?.synchronize()
        }
      }
    }
  }

  deinit { synchronizationTask?.cancel() }

  func synchronize() {
    let current = files.compactMap(\.currentVersion)
    if current != files { files = current }
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
  }

  var reviewRoots: [String] { scanRequest.roots }
  var reviewMinimumBytes: UInt64 { scanRequest.minimumBytes }

  func configureReview(_ request: ReviewScanRequest) {
    guard !isScanning, deletingPath == nil, queuedFiles.isEmpty else { return }
    scanRequest = request
    files = []
    refresh()
  }

  func refreshIfNeeded() {
    synchronize()
    if scannedAt.map({ Date().timeIntervalSince($0) < 60 }) == true { return }
    refresh()
  }

  func refresh() {
    guard !isScanning else { return }
    isScanning = true
    scanStatus = nil
    let request = scanRequest
    let generation = UUID()
    scanGeneration = generation
    let worker = Task.detached(priority: .utility) {
      let scan = CleanupReviewScanner.scan(request)
      return (scan, Task.isCancelled ? nil : CleanupActivity.workingDirectories())
    }
    scanTask = worker
    scanTimeout = Task {
      do { try await Task.sleep(for: .seconds(20)) } catch { return }
      guard scanGeneration == generation else { return }
      stopScan("Scan stopped after 20 seconds. Choose a folder to narrow the search.")
    }
    Task {
      let result = await worker.value
      guard scanGeneration == generation else { return }
      scanTimeout?.cancel()
      scanTask = nil
      applyScan(result.0)
      activeWorkingDirectories = result.1
      isScanning = false
    }
  }

  func cancelScan() {
    stopScan("Scan cancelled. Choose a folder or scan again when ready.")
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
  }

  func applyScan(_ result: ReviewScanResult) {
    files = result.files.compactMap(\.currentVersion)
    scanLimited = result.limited
    scannedAt = .now
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
        roots: CleanupReviewScanner.roots, minimumBytes: 256 * 1_024 * 1_024, maxEntries: 80_000),
      synchronizesInBackground: true)
  }
}
