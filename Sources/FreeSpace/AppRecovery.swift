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
  case responding = "Window interface responded"
  case noReply = "Window interface did not reply"
  case permissionNeeded = "Accessibility permission needed to check the window"
  case unsupported = "Window response check unavailable"
}

struct RecoveryObservation: Sendable {
  let process: RecoveryProcess
  let response: RecoveryResponse
}

enum RecoveryOutcome: Sendable {
  case alreadyResponding
  case respondingNow
  case resumed
  case noReply
  case unverified
  case checked
  case failed

  var title: String {
    switch self {
    case .alreadyResponding: "App is responding"
    case .respondingNow: "Responding after resume"
    case .resumed: "Process resumed · check the window"
    case .noReply: "No window response"
    case .unverified: "Resume sent · check the app"
    case .checked: "Response not verified"
    case .failed: "Recovery unavailable"
    }
  }
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
}

struct RecoveryFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

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
      return "\(AppBrand.name) and system processes cannot be recovery targets."
    }
    guard let current = input.current, let process = input.process, !process.exited else {
      return
        "This app has exited. A resume request cannot restore an app after it closes or is killed by OOM."
    }
    guard current.processID == input.expected.processID,
      process.processID == input.expected.processID,
      current.bundleURL == input.expected.bundleURL,
      current.bundleIdentifier == input.expected.bundleIdentifier,
      let launch = current.launchDate, launch == input.expected.launchDate
    else { return "The app restarted or changed. Refresh the list before trying again." }
    guard process.owner == input.ownUserID else {
      return "Only apps owned by your macOS user can be resumed."
    }
    guard current.bundleIdentifier != AppBrand.bundleIdentifier,
      current.bundleIdentifier != "com.apple.finder",
      !current.bundleURL.resolvingSymlinksInPath().path.hasPrefix("/System/")
    else { return "macOS system apps and \(AppBrand.name) are excluded from recovery." }
    return nil
  }
}

protocol AppRecoveryDriver: Sendable {
  func resolve(_ app: MemoryApp) async throws -> RecoveryTarget
  func observe(_ target: RecoveryTarget) async throws -> RecoveryObservation
  func resume(_ target: RecoveryTarget) async throws
  func pause() async throws
}

struct AppRecoveryRequest: Sendable {
  let app: MemoryApp
  let attemptResume: Bool
}

struct AppRecoveryEngine: Sendable {
  let driver: any AppRecoveryDriver

  func run(_ request: AppRecoveryRequest) async -> RecoveryReport {
    var before: [RecoveryObservation] = []
    var after: [RecoveryObservation] = []
    var resumeSent = false
    do {
      try Task.checkCancellation()
      let target = try await driver.resolve(request.app)
      before.append(try await driver.observe(target))
      try await driver.pause()
      before.append(try await driver.observe(target))
      if before.contains(where: { $0.response == .responding && !$0.process.stopped }) {
        return RecoveryReport(
          app: request.app, outcome: .alreadyResponding,
          detail:
            "The window interface answered a check. No resume request was sent. A frozen conversation or renderer can still need attention.",
          before: before, after: after, resumeSent: false)
      }
      guard request.attemptResume else {
        return RecoveryReport(
          app: request.app, outcome: .checked,
          detail:
            "\(before.last?.response.rawValue ?? "Check unavailable"). No resume request was sent. Sleeping or low CPU alone does not establish a freeze.",
          before: before, after: after, resumeSent: false)
      }
      try Task.checkCancellation()
      try await driver.resume(target)
      resumeSent = true
      for _ in 0..<2 {
        try await driver.pause()
        after.append(try await driver.observe(target))
      }
      let outcome: RecoveryOutcome
      let detail: String
      if after.allSatisfy({ $0.response == .responding && !$0.process.stopped }) {
        outcome = .respondingNow
        detail =
          "The window interface answered both checks after one resume request. Check your conversation or document too; this does not verify every renderer or pending task."
      } else if before.last?.process.stopped == true,
        after.allSatisfy({ !$0.process.stopped })
      {
        outcome = .resumed
        detail =
          "The process is no longer stopped. Window recovery is unverified; check the app before continuing."
      } else if after.allSatisfy({ $0.response == .noReply }) {
        outcome = .noReply
        detail =
          "The window interface did not answer either check. It may still be frozen or its response checks may have failed. The app remains open."
      } else {
        outcome = .unverified
        detail =
          "One resume request was sent, but window recovery could not be verified. Check the app; enabling Accessibility allows response checks."
      }
      return RecoveryReport(
        app: request.app, outcome: outcome, detail: detail,
        before: before, after: after, resumeSent: resumeSent)
    } catch {
      return RecoveryReport(
        app: request.app, outcome: .failed,
        detail: error is CancellationError
          ? "Recovery check cancelled." : error.localizedDescription,
        before: before, after: after, resumeSent: resumeSent)
    }
  }
}

struct NativeAppRecoveryDriver: AppRecoveryDriver {
  func resolve(_ app: MemoryApp) async throws -> RecoveryTarget {
    try await MainActor.run {
      let process = try validatedProcess(app)
      return RecoveryTarget(app: app, process: process)
    }
  }

  func observe(_ target: RecoveryTarget) async throws -> RecoveryObservation {
    _ = try await MainActor.run { try validate(target) }
    let response = await Task.detached(priority: .utility) {
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
          message: "macOS refused the resume request: \(String(cString: strerror(errno))).")
      }
    }
  }

  func pause() async throws {
    try await Task.sleep(for: .seconds(1))
  }

  @MainActor
  private func validatedProcess(_ app: MemoryApp) throws -> RecoveryProcess {
    let current = MemoryAppProvider().descriptors().first { $0.processID == app.processID }
    let process = Self.readProcess(app.processID)
    if let refusal = RecoverySafety.refusal(
      .init(
        expected: app, current: current, process: process,
        ownProcessID: getpid(), ownUserID: geteuid()))
    {
      throw RecoveryFailure(message: refusal)
    }
    guard let process else { throw RecoveryFailure(message: "Process identity is unavailable.") }
    return process
  }

  @MainActor
  private func validate(_ target: RecoveryTarget) throws -> RecoveryProcess {
    let current = try validatedProcess(target.app)
    guard target.process.isSameInstance(current) else {
      throw RecoveryFailure(
        message: "The process changed during recovery. No further action was taken.")
    }
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
    guard AXUIElementSetMessagingTimeout(element, 1.5) == .success else { return .unsupported }
    var value: CFTypeRef?
    switch AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) {
    case .success: return .responding
    case .cannotComplete: return .noReply
    case .apiDisabled: return .permissionNeeded
    default: return .unsupported
    }
  }
}
