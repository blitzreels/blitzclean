import AppKit
@preconcurrency import ApplicationServices
import Foundation

struct RecoveryCheck: Sendable {
  let app: MemoryApp
  let date: Date
  let health: RecoveryHealth
}

struct RecentCrash: Identifiable, Equatable, Sendable {
  let name: String
  let bundleURL: URL
  let date: Date
  let report: URL?
  var id: String { bundleURL.path }
}

enum RecoveryAppRoster {
  struct Input {
    let descriptors: [MemoryAppDescriptor]
    let measured: [MemoryApp]
  }

  static func merge(_ input: Input) -> [MemoryApp] {
    let measured = Dictionary(
      input.measured.map { ($0.processID, $0) }, uniquingKeysWith: { first, _ in first })
    return input.descriptors.map { descriptor in
      let previous = measured[descriptor.processID].flatMap {
        $0.launchDate == descriptor.launchDate && $0.bundleURL == descriptor.bundleURL ? $0 : nil
      }
      return MemoryApp(
        processID: descriptor.processID, name: descriptor.name,
        bundleIdentifier: descriptor.bundleIdentifier, bundleURL: descriptor.bundleURL,
        memoryBytes: previous?.memoryBytes ?? 0, protectionReason: descriptor.protectionReason,
        isActive: descriptor.isActive, launchDate: descriptor.launchDate,
        childProcessCount: previous?.childProcessCount ?? 0)
    }.filter(\.isRecoveryEligible).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }
}

extension MemoryApp {
  var isRecoveryEligible: Bool {
    processID != ProcessInfo.processInfo.processIdentifier
      && bundleIdentifier != AppBrand.bundleIdentifier
      && bundleIdentifier != "com.apple.finder"
      && !bundleURL.resolvingSymlinksInPath().path.hasPrefix("/System/")
  }
}

enum RecoveryActivity: Equatable, Sendable {
  case checking, reviving
}

@MainActor
final class AppRecoveryModel: ObservableObject {
  @Published private(set) var checks: [Int32: RecoveryCheck] = [:]
  @Published private(set) var activity: [Int32: RecoveryActivity] = [:]
  @Published private(set) var results: [Int32: RecoveryReport] = [:]
  @Published private(set) var crashes: [RecentCrash] = []
  @Published private(set) var isScanning = false
  @Published private(set) var scannedCount = 0
  @Published private(set) var scanTotal = 0
  @Published private(set) var accessibilityEnabled = AXIsProcessTrusted()
  @Published var status: String?
  private let engine: AppRecoveryEngine
  private let defaults: UserDefaults
  private var queuedScan: [MemoryApp]?
  private var queuedForce = false
  private var lastCrashScan = Date.distantPast
  private var loadingCrashes = false
  static let refreshInterval: TimeInterval = 2
  private var permissionWait: Task<Void, Never>?
  private var dismissedCrashes: Set<String>

  init(
    driver: any AppRecoveryDriver = NativeAppRecoveryDriver(),
    defaults: UserDefaults = .standard
  ) {
    engine = AppRecoveryEngine(driver: driver)
    self.defaults = defaults
    dismissedCrashes = Set(defaults.stringArray(forKey: "recovery.dismissedCrashes") ?? [])
  }

  var isReviving: Bool { activity.values.contains(.reviving) }

  var attentionCount: Int {
    checks.values.filter { check in
      check.health.needsAttention || result(for: check.app)?.outcome == .failed
    }.count
  }

  func refreshPermission() {
    accessibilityEnabled = AXIsProcessTrusted()
  }

  func openAccessibilitySettings() {
    let options =
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    accessibilityEnabled = AXIsProcessTrustedWithOptions(options)
    guard !accessibilityEnabled else { return }
    SystemSettingsPane.accessibility.open()
    permissionWait?.cancel()
    permissionWait = Task { [weak self] in
      for _ in 0..<180 {
        try? await Task.sleep(for: .seconds(1))
        guard let self, !Task.isCancelled else { return }
        refreshPermission()
        if accessibilityEnabled { return }
      }
    }
  }

  func check(for app: MemoryApp) -> RecoveryCheck? {
    guard let check = checks[app.processID], check.app.launchDate == app.launchDate,
      check.app.bundleURL == app.bundleURL
    else { return nil }
    return check
  }

  func result(for app: MemoryApp) -> RecoveryReport? {
    guard let report = results[app.processID], report.app.launchDate == app.launchDate,
      report.app.bundleURL == app.bundleURL
    else { return nil }
    return report
  }

  func activity(for app: MemoryApp) -> RecoveryActivity? { activity[app.processID] }

  /// Reads process state only, so stopped apps surface without window checks.
  func noteProcessStates(_ apps: [MemoryApp]) async {
    prune(to: apps)
    for app in apps where activity[app.processID] == nil {
      switch await engine.processState(app) {
      case .stopped?:
        store(app, .stopped)
      case nil where check(for: app)?.health == .stopped:
        checks[app.processID] = nil
        results[app.processID] = nil
      case .exited?:
        checks[app.processID] = nil
        results[app.processID] = nil
      default:
        break
      }
    }
  }

  func scan(_ apps: [MemoryApp], force: Bool = false) async {
    guard !isScanning else {
      queuedScan = apps
      queuedForce = queuedForce || force
      return
    }
    defer {
      if let queued = queuedScan {
        let force = queuedForce
        queuedScan = nil
        queuedForce = false
        if !Task.isCancelled { Task { await scan(queued, force: force) } }
      }
    }
    prune(to: apps)
    let pending = apps.filter {
      activity[$0.processID] == nil
        && (force
          || check(for: $0).map { Date.now.timeIntervalSince($0.date) >= Self.refreshInterval }
            ?? true)
    }
    if !loadingCrashes, Date.now.timeIntervalSince(lastCrashScan) >= 30 {
      loadingCrashes = true
      lastCrashScan = .now
      Task {
        await loadCrashes(running: apps)
        loadingCrashes = false
      }
    }
    guard !pending.isEmpty else { return }
    isScanning = true
    scannedCount = 0
    scanTotal = pending.count
    defer {
      isScanning = false
      for app in pending where activity[app.processID] == .checking {
        activity[app.processID] = nil
      }
      refreshPermission()
    }
    for app in pending {
      activity[app.processID] = .checking
      if force { results[app.processID] = nil }
    }
    let engine = self.engine
    var windowChecks: [MemoryApp] = []
    for app in pending {
      switch await engine.processState(app) {
      case .stopped?:
        store(app, .stopped)
        finishCheck(app)
      case .exited?:
        checks[app.processID] = nil
        finishCheck(app)
      default:
        windowChecks.append(app)
      }
    }
    await withTaskGroup(of: (MemoryApp, RecoveryHealth).self) { group in
      var remaining = windowChecks.makeIterator()
      for _ in 0..<min(8, windowChecks.count) {
        if let app = remaining.next() { group.addTask { (app, await engine.check(app)) } }
      }
      while let (app, health) = await group.next() {
        if !Task.isCancelled, activity[app.processID] == .checking {
          if health == .exited { checks[app.processID] = nil } else { store(app, health) }
        }
        finishCheck(app)
        if Task.isCancelled {
          group.cancelAll()
        } else if let app = remaining.next() {
          group.addTask { (app, await engine.check(app)) }
        }
      }
    }
  }

  func revive(_ app: MemoryApp) async -> RecoveryReport? {
    guard activity[app.processID] != .reviving else { return nil }
    status = nil
    activity[app.processID] = .reviving
    let report = await engine.revive(app)
    activity[app.processID] = nil
    if report.outcome.appExited {
      checks[app.processID] = nil
      results[app.processID] = nil
      crashes.removeAll { $0.id == app.bundleURL.path }
      crashes.insert(
        RecentCrash(
          name: app.name, bundleURL: app.bundleURL, date: report.date,
          report: report.crashReport), at: 0)
      dismissedCrashes.remove(app.bundleURL.path)
    } else {
      results[app.processID] = report
      store(app, health(after: report))
    }
    refreshPermission()
    return report
  }

  func reviveAll(_ apps: [MemoryApp]) async -> [RecoveryReport] {
    await withTaskGroup(of: RecoveryReport?.self) { group in
      for app in apps { group.addTask { await self.revive(app) } }
      var reports: [RecoveryReport] = []
      for await report in group { if let report { reports.append(report) } }
      return reports
    }
  }

  func showApp(_ app: MemoryApp) {
    guard let running = NSRunningApplication(processIdentifier: app.processID),
      !running.isTerminated, running.bundleURL == app.bundleURL,
      let launch = running.launchDate, launch == app.launchDate
    else {
      status = "\(app.name) has quit or restarted."
      return
    }
    running.activate(options: [])
  }

  func reopen(_ crash: RecentCrash) {
    dismiss(crash)
    NSWorkspace.shared.openApplication(
      at: crash.bundleURL, configuration: NSWorkspace.OpenConfiguration()
    ) { [weak self] _, error in
      guard let error else { return }
      Task { @MainActor in
        self?.status = "Couldn't reopen \(crash.name): \(error.localizedDescription)"
      }
    }
  }

  func dismiss(_ crash: RecentCrash) {
    crashes.removeAll { $0.id == crash.id }
    dismissedCrashes.insert(crash.id)
    defaults.set(Array(dismissedCrashes.suffix(100)), forKey: "recovery.dismissedCrashes")
  }

  private func store(_ app: MemoryApp, _ health: RecoveryHealth) {
    if let report = results[app.processID],
      health != self.health(after: report) || Date.now.timeIntervalSince(report.date) > 8
    {
      results[app.processID] = nil
    }
    checks[app.processID] = RecoveryCheck(app: app, date: .now, health: health)
  }

  private func finishCheck(_ app: MemoryApp) {
    if activity[app.processID] == .checking { activity[app.processID] = nil }
    scannedCount += 1
  }

  private func health(after report: RecoveryReport) -> RecoveryHealth {
    switch report.outcome {
    case .alreadyRunning, .revived:
      (report.after.last ?? report.before.last)?.response == .responding ? .responsive : .running
    case .notResponding: .unresponsive
    case .stillStopped: .stopped
    case .failed, .crashed, .quit: check(for: report.app)?.health ?? .unknown
    }
  }

  private func prune(to apps: [MemoryApp]) {
    let live = Dictionary(apps.map { ($0.processID, $0) }, uniquingKeysWith: { first, _ in first })
    checks = checks.filter {
      live[$0.key]?.launchDate == $0.value.app.launchDate
        && live[$0.key]?.bundleURL == $0.value.app.bundleURL
    }
    results = results.filter {
      live[$0.key]?.launchDate == $0.value.app.launchDate
        && live[$0.key]?.bundleURL == $0.value.app.bundleURL
    }
  }

  private func loadCrashes(running apps: [MemoryApp]) async {
    let since = Date.now.addingTimeInterval(-24 * 60 * 60)
    let reports = await Task.detached(priority: .utility) { CrashReports.recent(since: since) }
      .value
    var found: [String: RecentCrash] = [:]
    for report in reports {
      guard let identifier = report.bundleIdentifier,
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
        !url.resolvingSymlinksInPath().path.hasPrefix("/System/"),
        identifier != AppBrand.bundleIdentifier,
        !dismissedCrashes.contains(url.path), found[url.path] == nil,
        !apps.contains(where: {
          $0.bundleURL == url && ($0.launchDate ?? .distantPast) > report.date
        })
      else { continue }
      let name =
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
      found[url.path] = RecentCrash(
        name: name, bundleURL: url, date: report.date, report: report.url)
    }
    let revivedExits = crashes.filter { crash in
      found[crash.id] == nil && !dismissedCrashes.contains(crash.id)
        && !apps.contains(where: { $0.bundleURL == crash.bundleURL })
    }
    crashes = (revivedExits + found.values).sorted { $0.date > $1.date }
  }
}
