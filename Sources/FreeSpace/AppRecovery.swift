import AppKit
import ApplicationServices
import Darwin
import Foundation

struct RecoveryProcess: Equatable, Sendable {
  let processID: Int32
  let owner: UInt32
  let startSeconds: UInt64
  let startMicroseconds: UInt64
  let state: UInt32

  var stopped: Bool { state == SSTOP }
  var exited: Bool { state == SZOMB }
  var stateLabel: String {
    switch Int32(state) {
    case SSTOP: "Stopped"
    case SSLEEP: "Sleeping (normal for idle apps)"
    case SRUN: "Running"
    case SZOMB: "Exited"
    default: "State unavailable"
    }
  }

  func isSameInstance(_ other: Self) -> Bool {
    processID == other.processID && owner == other.owner
      && startSeconds == other.startSeconds && startMicroseconds == other.startMicroseconds
  }
}

struct RecoveryTarget: Sendable {
  let app: MemoryApp
  let process: RecoveryProcess
}

enum RecoveryResponse: String, Sendable {
  case responding = "Window responded"
  case noReply = "Window did not reply"
  case permissionNeeded = "Accessibility permission needed to check the window"
  case unsupported = "Window check unavailable"
}

struct RecoveryObservation: Sendable {
  let process: RecoveryProcess
  let response: RecoveryResponse
}

enum RecoveryHealth: Equatable, Sendable {
  case stopped
  case unresponsive
  case responsive
  case running
  case exited
  case unknown

  static func assess(_ observations: [RecoveryObservation]) -> Self {
    guard let latest = observations.last else { return .unknown }
    if latest.process.exited { return .exited }
    if latest.process.stopped { return .stopped }
    switch latest.response {
    case .responding: return .responsive
    case .permissionNeeded, .unsupported: return .running
    case .noReply:
      return observations.count >= 2 && observations.allSatisfy { $0.response == .noReply }
        ? .unresponsive : .unknown
    }
  }

  var needsAttention: Bool { self == .stopped || self == .unresponsive }
}

enum RecoveryOutcome: Equatable, Sendable {
  case alreadyRunning
  case revived
  case notResponding
  case stillStopped
  case crashed
  case quit
  case failed

  var title: String {
    switch self {
    case .alreadyRunning: "Running"
    case .revived: "Revived"
    case .notResponding: "Not responding"
    case .stillStopped: "Still stopped"
    case .crashed: "Crashed"
    case .quit: "Quit"
    case .failed: "Couldn't revive"
    }
  }

  var appExited: Bool { self == .crashed || self == .quit }
}

struct RecoveryReport: Identifiable, Sendable {
  let id = UUID()
  let app: MemoryApp
  let date = Date.now
  let outcome: RecoveryOutcome
  let detail: String
  let before: [RecoveryObservation]
  let after: [RecoveryObservation]
  let resumeSent: Bool
  var crashReport: URL? = nil
}

struct RecoveryFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

struct RecoveryExit: Error {}

enum RecoverySafety {
  struct Input {
    let expected: MemoryApp
    let current: MemoryAppDescriptor?
    let process: RecoveryProcess?
    let ownProcessID: Int32
    let ownUserID: UInt32
  }

  static func refusal(_ input: Input) -> String? {
    guard input.expected.processID > 1, input.expected.processID != input.ownProcessID else {
      return "\(AppBrand.name) and system processes cannot be revived."
    }
    guard let current = input.current, let process = input.process, !process.exited else {
      return "This app has exited."
    }
    guard current.processID == input.expected.processID,
      process.processID == input.expected.processID,
      current.bundleURL == input.expected.bundleURL,
      current.bundleIdentifier == input.expected.bundleIdentifier,
      let launch = current.launchDate, launch == input.expected.launchDate
    else { return "The app restarted. Check again before reviving it." }
    guard process.owner == input.ownUserID else {
      return "Only apps owned by your macOS user can be revived."
    }
    guard current.bundleIdentifier != AppBrand.bundleIdentifier,
      current.bundleIdentifier != "com.apple.finder",
      !current.bundleURL.resolvingSymlinksInPath().path.hasPrefix("/System/")
    else { return "macOS system apps and \(AppBrand.name) cannot be revived." }
    return nil
  }
}

protocol AppRecoveryDriver: Sendable {
  func resolve(_ app: MemoryApp) async throws -> RecoveryTarget
  func observe(_ target: RecoveryTarget) async throws -> RecoveryObservation
  func resume(_ target: RecoveryTarget) async throws
  func pause(_ duration: Duration) async throws
  func crashReport(for app: MemoryApp, since: Date) async -> URL?
}

struct AppRecoveryEngine: Sendable {
  let driver: any AppRecoveryDriver
  var crashReportWaits = 6

  func processState(_ app: MemoryApp) async -> RecoveryHealth? {
    do {
      let target = try await driver.resolve(app)
      return target.process.stopped ? .stopped : nil
    } catch is RecoveryExit {
      return .exited
    } catch {
      return nil
    }
  }

  func check(_ app: MemoryApp) async -> RecoveryHealth {
    do {
      let target = try await driver.resolve(app)
      if target.process.stopped { return .stopped }
      let first = try await driver.observe(target)
      guard !first.process.stopped, first.response == .noReply else {
        return RecoveryHealth.assess([first])
      }
      try await driver.pause(.milliseconds(250))
      return RecoveryHealth.assess([first, try await driver.observe(target)])
    } catch is RecoveryExit {
      return .exited
    } catch {
      return .unknown
    }
  }

  func revive(_ app: MemoryApp) async -> RecoveryReport {
    let started = Date.now
    var before: [RecoveryObservation] = []
    var after: [RecoveryObservation] = []
    var resumeSent = false
    func report(_ outcome: RecoveryOutcome, _ detail: String) -> RecoveryReport {
      RecoveryReport(
        app: app, outcome: outcome, detail: detail, before: before, after: after,
        resumeSent: resumeSent)
    }
    do {
      try Task.checkCancellation()
      let target = try await driver.resolve(app)
      let first = try await driver.observe(target)
      before.append(first)
      if !first.process.stopped, first.response == .responding {
        return report(.alreadyRunning, "The window responded. No restart was needed.")
      }
      try Task.checkCancellation()
      try await driver.resume(target)
      resumeSent = true
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      for attempt in 0..<8 {
        guard ContinuousClock.now < deadline else { break }
        try await driver.pause(.milliseconds(attempt == 0 ? 150 : 500))
        let observation = try await driver.observe(target)
        after.append(observation)
        guard !observation.process.stopped else { continue }
        switch observation.response {
        case .responding:
          return report(.revived, "Resumed. Its window responds again.")
        case .permissionNeeded, .unsupported:
          return first.process.stopped
            ? report(.revived, "The process resumed. Window responsiveness could not be checked.")
            : report(
              .alreadyRunning, "The process is running. Allow Accessibility to check its window.")
        case .noReply:
          continue
        }
      }
      if after.last?.process.stopped == true {
        return report(
          .stillStopped,
          "Something stopped it again right after it resumed, such as a debugger or another tool.")
      }
      return report(
        .notResponding,
        "The window still isn't responding. Force Quit is available if it stays frozen."
      )
    } catch is RecoveryExit {
      let since = resumeSent ? started.addingTimeInterval(-2) : started.addingTimeInterval(-600)
      var crash: URL?
      for attempt in 0..<crashReportWaits {
        crash = await driver.crashReport(for: app, since: since)
        if crash != nil { break }
        if attempt + 1 < crashReportWaits { try? await driver.pause(.milliseconds(500)) }
      }
      var exited = report(
        crash == nil ? .quit : .crashed,
        crash == nil
          ? (resumeSent
            ? "It quit after resuming. macOS saved no crash report." : "It had already quit.")
          : (resumeSent
            ? "It crashed after resuming. macOS saved a crash report." : "It had already crashed."))
      exited.crashReport = crash
      return exited
    } catch {
      return report(
        .failed, error is CancellationError ? "Cancelled." : error.localizedDescription)
    }
  }
}

struct NativeAppRecoveryDriver: AppRecoveryDriver {
  func resolve(_ app: MemoryApp) async throws -> RecoveryTarget {
    try await MainActor.run {
      RecoveryTarget(app: app, process: try validatedProcess(app))
    }
  }

  func observe(_ target: RecoveryTarget) async throws -> RecoveryObservation {
    let initial = try await MainActor.run { try validate(target) }
    if initial.stopped {
      return RecoveryObservation(process: initial, response: .noReply)
    }
    let response = await Task.detached(priority: .userInitiated) {
      windowResponse(target.app.processID)
    }.value
    let current = try await MainActor.run { try validate(target) }
    return RecoveryObservation(process: current, response: response)
  }

  func resume(_ target: RecoveryTarget) async throws {
    try await MainActor.run {
      try Task.checkCancellation()
      _ = try validate(target)
      guard Darwin.kill(target.app.processID, SIGCONT) == 0 else {
        throw RecoveryFailure(
          message: "macOS refused to revive it: \(String(cString: strerror(errno))).")
      }
    }
  }

  func pause(_ duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }

  func crashReport(for app: MemoryApp, since: Date) async -> URL? {
    let executable = Bundle(url: app.bundleURL)?.executableURL?.lastPathComponent
    return await Task.detached(priority: .utility) {
      CrashReports.recent(since: since).first {
        $0.matches(bundleIdentifier: app.bundleIdentifier, names: [app.name, executable])
      }?.url
    }.value
  }

  @MainActor
  private func validatedProcess(_ app: MemoryApp) throws -> RecoveryProcess {
    let current = NSRunningApplication(processIdentifier: app.processID).flatMap {
      running -> MemoryAppDescriptor? in
      guard !running.isTerminated, let url = running.bundleURL else { return nil }
      return MemoryAppDescriptor(
        processID: running.processIdentifier, name: running.localizedName ?? app.name,
        bundleIdentifier: running.bundleIdentifier, bundleURL: url,
        protectionReason: nil, isActive: running.isActive, launchDate: running.launchDate)
    }
    let process = Self.readProcess(app.processID)
    if current == nil || process == nil || process?.exited == true
      || current?.launchDate != app.launchDate
    {
      throw RecoveryExit()
    }
    if let refusal = RecoverySafety.refusal(
      .init(
        expected: app, current: current, process: process,
        ownProcessID: getpid(), ownUserID: geteuid()))
    {
      throw RecoveryFailure(message: refusal)
    }
    guard let process else { throw RecoveryExit() }
    return process
  }

  @MainActor
  func validate(_ target: RecoveryTarget) throws -> RecoveryProcess {
    let current = try validatedProcess(target.app)
    guard target.process.isSameInstance(current) else { throw RecoveryExit() }
    return current
  }

  static func readProcess(_ processID: Int32) -> RecoveryProcess? {
    guard processID > 1 else { return nil }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, $0, Int32(size))
    }
    guard read == size, info.pbi_pid == UInt32(processID) else { return nil }
    return RecoveryProcess(
      processID: processID, owner: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
      startMicroseconds: info.pbi_start_tvusec, state: info.pbi_status)
  }

  private func windowResponse(_ processID: Int32) -> RecoveryResponse {
    guard AXIsProcessTrusted() else { return .permissionNeeded }
    let element = AXUIElementCreateApplication(processID)
    guard AXUIElementSetMessagingTimeout(element, 0.5) == .success else { return .unsupported }
    var value: CFTypeRef?
    switch AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) {
    case .success: return .responding
    case .cannotComplete: return .noReply
    case .apiDisabled: return .permissionNeeded
    default: return .unsupported
    }
  }
}

struct CrashReport: Equatable, Sendable {
  let url: URL
  let appName: String
  let bundleIdentifier: String?
  let date: Date

  func matches(bundleIdentifier: String?, names: [String?]) -> Bool {
    if let bundleIdentifier, let own = self.bundleIdentifier { return own == bundleIdentifier }
    return names.compactMap { $0 }.contains(appName)
  }
}

enum CrashReports {
  static let directory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

  static func recent(since: Date, in directory: URL = directory) -> [CrashReport] {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]))
      ?? []
    return files.compactMap { url -> CrashReport? in
      guard url.pathExtension == "ips",
        let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
        let modified = values.contentModificationDate, modified >= since
      else { return nil }
      return parse(url, modified: modified)
    }.sorted { $0.date > $1.date }
  }

  static func parse(_ url: URL, modified: Date) -> CrashReport? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 4096),
      let header = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
      let object = try? JSONSerialization.jsonObject(with: Data(header)) as? [String: Any],
      object["bug_type"] as? String == "309",
      let name = object["app_name"] as? String ?? object["name"] as? String
    else { return nil }
    return CrashReport(
      url: url, appName: name, bundleIdentifier: object["bundleID"] as? String, date: modified)
  }
}
