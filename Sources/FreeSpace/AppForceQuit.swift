import AppKit
import Foundation

enum ForceQuitOutcome: Equatable, Sendable {
  case terminated
  case stillRunning
  case failed

  var title: String {
    switch self {
    case .terminated: "Force quit complete"
    case .stillRunning: "Exit not confirmed"
    case .failed: "Force quit unavailable"
    }
  }
}

struct ForceQuitReport: Sendable {
  let app: MemoryApp
  let date = Date.now
  let outcome: ForceQuitOutcome
  let detail: String
  let requestSent: Bool
}

protocol ForceQuitDriver: Sendable {
  func resolve(_ app: MemoryApp) async throws -> RecoveryTarget
  func forceQuit(_ target: RecoveryTarget) async throws
  func isTerminated(_ target: RecoveryTarget) async -> Bool
  func pause() async throws
}

struct ForceQuitEngine: Sendable {
  let driver: any ForceQuitDriver

  func run(_ app: MemoryApp) async -> ForceQuitReport {
    var requestSent = false
    do {
      try Task.checkCancellation()
      let target = try await driver.resolve(app)
      try await driver.forceQuit(target)
      requestSent = true
      if await driver.isTerminated(target) {
        return ForceQuitReport(
          app: app, outcome: .terminated, detail: "The app exited.", requestSent: true)
      }
      for _ in 0..<12 {
        try await driver.pause()
        if await driver.isTerminated(target) {
          return ForceQuitReport(
            app: app, outcome: .terminated, detail: "The app exited.", requestSent: true)
        }
      }
      return ForceQuitReport(
        app: app, outcome: .stillRunning,
        detail:
          "macOS accepted the request, but the app is still present. Refresh before trying again.",
        requestSent: true)
    } catch is RecoveryExit {
      return ForceQuitReport(
        app: app, outcome: .terminated, detail: "The app already exited.",
        requestSent: requestSent)
    } catch {
      return ForceQuitReport(
        app: app, outcome: .failed,
        detail: error is CancellationError ? "Force quit cancelled." : error.localizedDescription,
        requestSent: requestSent)
    }
  }
}

struct NativeForceQuitDriver: ForceQuitDriver {
  func resolve(_ app: MemoryApp) async throws -> RecoveryTarget {
    try await NativeAppRecoveryDriver().resolve(app)
  }

  func forceQuit(_ target: RecoveryTarget) async throws {
    try await MainActor.run {
      try Task.checkCancellation()
      _ = try NativeAppRecoveryDriver().validate(target)
      guard let running = NSRunningApplication(processIdentifier: target.app.processID),
        !running.isTerminated, running.launchDate == target.app.launchDate,
        running.bundleURL == target.app.bundleURL
      else {
        throw RecoveryFailure(message: "The app changed or exited. Refresh before trying again.")
      }
      guard running.forceTerminate() else {
        throw RecoveryFailure(message: "macOS refused the force quit request.")
      }
    }
  }

  func isTerminated(_ target: RecoveryTarget) async -> Bool {
    await MainActor.run {
      guard let running = NSRunningApplication(processIdentifier: target.app.processID),
        !running.isTerminated, running.launchDate == target.app.launchDate,
        running.bundleURL == target.app.bundleURL
      else { return true }
      guard let current = NativeAppRecoveryDriver.readProcess(target.app.processID) else {
        return false
      }
      return !target.process.isSameInstance(current) || current.exited
    }
  }

  func pause() async throws {
    try await Task.sleep(for: .milliseconds(250))
  }
}

@MainActor
final class ForceQuitModel: ObservableObject {
  @Published private(set) var activeApp: MemoryApp?
  @Published private(set) var lastReport: ForceQuitReport?
  private let engine: ForceQuitEngine

  init(driver: any ForceQuitDriver = NativeForceQuitDriver()) {
    engine = ForceQuitEngine(driver: driver)
  }

  func run(_ app: MemoryApp) async -> ForceQuitReport? {
    guard activeApp == nil else { return nil }
    activeApp = app
    defer { activeApp = nil }
    let report = await engine.run(app)
    lastReport = report
    return report
  }

  /// Runs a force quit and returns the line to show beside the action, or nil if one was already running.
  func runAndDescribe(_ app: MemoryApp) async -> String? {
    guard let report = await run(app) else { return nil }
    return report.outcome == .terminated
      ? "\(app.name) was force quit." : "\(app.name): \(report.detail)"
  }
}
