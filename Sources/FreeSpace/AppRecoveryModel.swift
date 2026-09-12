import AppKit
@preconcurrency import ApplicationServices
import Foundation

@MainActor
final class AppRecoveryModel: ObservableObject {
  @Published private(set) var activeApp: MemoryApp?
  @Published private(set) var reports: [RecoveryReport] = []
  @Published private(set) var accessibilityEnabled = AXIsProcessTrusted()
  @Published private(set) var status: String?
  private let engine = AppRecoveryEngine(driver: NativeAppRecoveryDriver())
  private var lastAttempts: [String: Date] = [:]

  func refreshPermission() {
    accessibilityEnabled = AXIsProcessTrusted()
  }

  func openAccessibilitySettings() {
    let options =
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    accessibilityEnabled = AXIsProcessTrustedWithOptions(options)
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(url)
    }
  }

  func run(_ request: AppRecoveryRequest) async -> RecoveryReport? {
    guard activeApp == nil else { return nil }
    if request.attemptResume, let last = lastAttempts[request.app.policyKey],
      Date.now.timeIntervalSince(last) < 30
    {
      status = "Wait 30 seconds between recovery attempts for this app."
      return nil
    }
    if request.attemptResume { lastAttempts[request.app.policyKey] = .now }
    activeApp = request.app
    status = nil
    defer {
      activeApp = nil
      refreshPermission()
    }
    let report = await engine.run(request)
    reports.insert(report, at: 0)
    reports = Array(reports.prefix(20))
    lastAttempts = lastAttempts.filter { Date.now.timeIntervalSince($0.value) < 60 }
    return report
  }

  func showApp(_ app: MemoryApp) {
    guard let running = NSRunningApplication(processIdentifier: app.processID),
      !running.isTerminated, running.bundleURL == app.bundleURL,
      let launch = running.launchDate, launch == app.launchDate
    else {
      status = "This app has exited or restarted. Refresh the list."
      return
    }
    running.activate(options: [])
  }
}
