import AppKit
import Foundation

enum MemoryQuitSafety {
  struct Input {
    let expected: MemoryApp
    let current: MemoryAppDescriptor?
    let policy: MemoryAppPolicy
  }

  static func refusal(_ input: Input) -> String? {
    guard let current = input.current else { return "App is no longer running; refresh the list" }
    guard current.processID == input.expected.processID,
      current.bundleURL == input.expected.bundleURL,
      current.bundleIdentifier == input.expected.bundleIdentifier,
      let launchDate = current.launchDate, launchDate == input.expected.launchDate
    else { return "App changed since the scan; refresh before quitting" }
    if let reason = current.protectionReason { return reason }
    if input.policy == .keepRunning { return "You pinned this app to keep running" }
    if current.isActive { return "This app is currently in use" }
    return nil
  }
}

@MainActor
final class MemoryRescueModel: NSObject, ObservableObject {
  @Published private(set) var pressure: MemoryPressureLevel
  @Published private(set) var risk = MemoryRisk.normal
  @Published private(set) var apps: [MemoryApp] = []
  @Published private(set) var candidates: [MemoryCandidate] = []
  @Published private(set) var sample: MemoryGuardSample?
  @Published private(set) var isRefreshing = false
  @Published private(set) var actionProcessID: Int32?
  @Published private(set) var statusMessage: String?
  @Published private(set) var scannedAt: Date?
  @Published private(set) var incidents: [MemoryIncident] = []
  @Published private(set) var notificationStatus = "Checking notification permission"
  @Published private(set) var alertsEnabled: Bool
  @Published private(set) var diskAlertsEnabled: Bool
  @Published private(set) var diskAssessment: DiskAssessment?

  let historyURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/FreeSpace/memory-history.json")
  private let appProvider = MemoryAppProvider()
  private let scanner = NativeProcessMemoryScanner()
  private let notifications = MemoryNotifications()
  private var timer: Timer?
  private var pressureSource: DispatchSourceMemoryPressure?
  private var evaluator = MemoryRiskEvaluator()
  private var alertGate = MemoryAlertGate()
  private var policies: [String: MemoryAppPolicy] = [:]
  private var lastActive: [String: Date] = [:]
  private var growthSamples: [(date: Date, apps: [MemoryApp])] = []
  private var growth: [Int32: Int64] = [:]
  private var history = MemoryIncidentHistory()
  private var lastRecordedAt = Date.distantPast
  private var isSaving = false
  private var needsSave = false
  private var isSendingAlert = false
  private var lastPermissionCheck = Date.distantPast
  private var diskEvaluator = DiskRiskEvaluator()
  private var diskAlertGate = DiskAlertGate()
  private var isSendingDiskAlert = false
  private lazy var store = MemoryIncidentStore(url: historyURL)
  private var persists: Bool { Bundle.main.bundleIdentifier == AppBrand.bundleIdentifier }

  override init() {
    pressure = MemoryPressureReader().current()
    alertsEnabled = UserDefaults.standard.object(forKey: "memory.alertsEnabled") as? Bool ?? true
    diskAlertsEnabled = UserDefaults.standard.object(forKey: "disk.alertsEnabled") as? Bool ?? true
    if let data = UserDefaults.standard.data(forKey: "memory.appPolicies"),
      let saved = try? JSONDecoder().decode([String: MemoryAppPolicy].self, from: data)
    {
      policies = saved
    }
    super.init()
    Task { [weak self] in await self?.start() }
  }

  var suggestions: [MemoryCandidate] { candidates.filter { !$0.protected } }
  var protectedCount: Int { candidates.filter(\.protected).count }

  private func start() async {
    if persists { history = await store.load() }
    record(
      .init(
        kind: "started", detail: "Monitoring started; app exits do not establish a crash or OOM"))
    sampleMemory(event: nil)
    refresh()
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let source = self.pressureSource else { return }
        let level: MemoryPressureLevel =
          source.data.contains(.critical)
          ? .critical
          : source.data.contains(.warning) ? .warning : .normal
        self.sampleMemory(event: level)
        self.refresh()
      }
    }
    pressureSource = source
    source.resume()
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.sampleMemory(event: nil)
        if self.scannedAt.map({ Date.now.timeIntervalSince($0) >= 15 }) ?? true { self.refresh() }
      }
    }
    if let timer { RunLoop.main.add(timer, forMode: .common) }
    await configureNotifications(requestPermission: false)
  }

  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    let descriptors = appProvider.descriptors()
    let scanner = scanner
    Task { [weak self] in
      let scanned = await Task.detached(priority: .utility) { scanner.scan(descriptors) }.value
      guard let self else { return }
      let now = Date.now
      let previousApps = apps
      apps = scanned
      for previous in previousApps where previous.protectionReason != nil {
        if !scanned.contains(where: { $0.id == previous.id && $0.launchDate == previous.launchDate }
        ) {
          record(
            .init(
              kind: "app-exit", detail: "\(previous.name) exited or restarted; cause unconfirmed"))
        }
      }
      growthSamples.removeAll { now.timeIntervalSince($0.date) > 300 }
      growth = [:]
      if let baseline = growthSamples.first, now.timeIntervalSince(baseline.date) >= 15 {
        for app in scanned {
          if let old = baseline.apps.first(where: {
            $0.id == app.id && $0.launchDate == app.launchDate
          }) {
            growth[app.id] = Int64(clamping: app.memoryBytes) - Int64(clamping: old.memoryBytes)
          }
        }
      }
      growthSamples.append((now, scanned))
      if growthSamples.count > 21 { growthSamples.removeFirst(growthSamples.count - 21) }
      for app in scanned where app.isActive { lastActive[app.policyKey] = now }
      scannedAt = now
      isRefreshing = false
      updateCandidates()
    }
  }

  private func sampleMemory(event: MemoryPressureLevel?) {
    pressure = event ?? MemoryPressureReader().current()
    guard let next = MemoryGuardSample.read(pressure: pressure) else {
      statusMessage = "Memory readings unavailable; the last reading may be stale"
      return
    }
    sample = next
    if let disk = DiskGuardSample.read(memory: next) {
      diskAssessment = diskEvaluator.evaluate(disk)
      sendDiskAlertIfNeeded()
    }
    let previousRisk = risk
    risk = evaluator.evaluate(next)
    if risk != previousRisk {
      record(.init(kind: "pressure", detail: risk.title))
    } else if next.date.timeIntervalSince(lastRecordedAt) >= 60 {
      record(.init(kind: "sample", detail: risk.title))
    }
    if Date.now.timeIntervalSince(lastPermissionCheck) >= 60 {
      lastPermissionCheck = .now
      Task { await configureNotifications(requestPermission: false) }
    }
    sendAlertIfNeeded()
  }

  private func sendAlertIfNeeded() {
    guard alertsEnabled, notifications.authorized, !isSendingAlert else { return }
    var nextGate = alertGate
    guard nextGate.shouldSend(.init(risk: risk, date: .now)) else { return }
    let alertRisk = risk
    let detail: String
    if let first = suggestions.first {
      detail =
        "AI apps stay protected. Review \(first.app.name) (\(ByteText.full(first.app.memoryBytes)) footprint). Check its work before quitting."
    } else {
      detail =
        "AI apps stay protected. Review running apps and projects to free memory; nothing closes automatically."
    }
    isSendingAlert = true
    Task { [weak self] in
      guard let self else { return }
      let sent = await notifications.send(.init(risk: alertRisk, detail: detail, isTest: false))
      if sent {
        alertGate = nextGate
        record(.init(kind: "alert", detail: "\(alertRisk.title) · notification scheduled"))
      }
      notificationStatus = notifications.status
      isSendingAlert = false
    }
  }

  func configureNotifications(requestPermission: Bool) async {
    await notifications.prepare(requestPermission: requestPermission)
    notificationStatus = notifications.status
    sendAlertIfNeeded()
    sendDiskAlertIfNeeded()
  }

  private func sendDiskAlertIfNeeded() {
    guard diskAlertsEnabled, notifications.authorized, !isSendingDiskAlert,
      let assessment = diskAssessment
    else { return }
    var nextGate = diskAlertGate
    guard nextGate.shouldSend(assessment) else { return }
    isSendingDiskAlert = true
    Task { [weak self] in
      guard let self else { return }
      if await notifications.sendDisk(assessment) {
        diskAlertGate = nextGate
        record(.init(kind: "disk-alert", detail: assessment.detail + " · notification scheduled"))
      }
      notificationStatus = notifications.status
      isSendingDiskAlert = false
    }
  }

  func setDiskAlertsEnabled(_ enabled: Bool) {
    diskAlertsEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: "disk.alertsEnabled")
    Task { await configureNotifications(requestPermission: enabled) }
  }

  func setAlertsEnabled(_ enabled: Bool) {
    alertsEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: "memory.alertsEnabled")
    Task { await configureNotifications(requestPermission: enabled) }
  }

  func testNotification() async {
    await configureNotifications(requestPermission: true)
    let sent = await notifications.send(
      .init(
        risk: .warning,
        detail:
          "Test notification. Click Review memory to open your protected apps and suggestions.",
        isTest: true
      ))
    statusMessage =
      sent
      ? "Test notification scheduled; check your macOS banners or Notification Center"
      : notifications.status
  }

  struct PolicyChange {
    let app: MemoryApp
    let policy: MemoryAppPolicy
  }

  func setPolicy(_ change: PolicyChange) {
    guard change.app.protectionReason == nil else { return }
    policies[change.app.policyKey] = change.policy
    if let data = try? JSONEncoder().encode(policies) {
      UserDefaults.standard.set(data, forKey: "memory.appPolicies")
    }
    updateCandidates()
  }

  private func updateCandidates() {
    candidates = MemoryCandidateRanker.rank(
      .init(
        apps: apps, policies: policies, lastActive: lastActive, growth: growth, date: .now
      ))
  }

  func quitAndKeepClosed(_ app: MemoryApp) async {
    guard actionProcessID == nil else { return }
    let current = appProvider.descriptors().first { $0.processID == app.processID }
    if let refusal = MemoryQuitSafety.refusal(
      .init(
        expected: app, current: current, policy: policies[app.policyKey, default: .review]
      ))
    {
      statusMessage = refusal
      return
    }
    guard let runningApp = NSRunningApplication(processIdentifier: app.processID),
      runningApp.launchDate == app.launchDate, runningApp.bundleURL == app.bundleURL
    else {
      statusMessage = "App changed since the scan; refresh before quitting"
      return
    }
    actionProcessID = app.id
    defer {
      actionProcessID = nil
      refresh()
    }
    let before = MemoryGuardSample.read(pressure: MemoryPressureReader().current())
    record(.init(kind: "quit-request", detail: "Requested normal quit of \(app.name)"))
    guard runningApp.terminate() else {
      statusMessage = "\(app.name) declined the quit request; its work stays open"
      record(.init(kind: "quit-declined", detail: statusMessage ?? "Quit declined"))
      return
    }
    statusMessage = "Waiting for \(app.name); respond to any save dialog"
    for _ in 0..<60 {
      if runningApp.isTerminated { break }
      try? await Task.sleep(for: .milliseconds(250))
    }
    guard runningApp.isTerminated else {
      statusMessage =
        "\(app.name) is still open; quit was cancelled, delayed, or needs a save response"
      record(.init(kind: "quit-pending", detail: statusMessage ?? "Quit pending"))
      return
    }
    try? await Task.sleep(for: .seconds(2))
    sampleMemory(event: nil)
    let change = before.flatMap { before in
      sample.map { Int64(clamping: $0.available) - Int64(clamping: before.available) }
    }
    let measured =
      change.map {
        " · system available memory \($0 >= 0 ? "+" : "−")\(ByteText.full(UInt64(abs($0))))"
      } ?? ""
    statusMessage =
      "\(app.name) quit; kept closed\(measured) · pressure \(pressure.title.lowercased()). Other activity affects this reading."
    record(.init(kind: "quit-completed", detail: statusMessage ?? "Quit completed"))
  }

  func isActing(on app: MemoryApp) -> Bool { actionProcessID == app.processID }

  func recordRecovery(_ report: RecoveryReport) {
    record(
      .init(
        kind: "app-recovery",
        detail:
          "\(report.app.name): \(report.outcome.title). \(report.resumeSent ? "One resume request sent." : "No resume request sent.") \(report.detail)"
      ))
    refresh()
  }

  func recordShutdown() {
    record(.init(kind: "stopped", detail: "\(AppBrand.name) stopped normally"))
  }

  private struct RecordInput {
    let kind: String
    let detail: String
  }

  private func record(_ input: RecordInput) {
    let event = MemoryIncident(
      id: UUID(), date: .now, kind: input.kind, detail: input.detail, sample: sample,
      apps: apps.prefix(8).map { app in
        MemoryIncident.App(
          name: app.name, bytes: app.memoryBytes,
          protected: app.protectionReason != nil || policies[app.policyKey] == .keepRunning
            || app.isActive
        )
      }, resources: ResourceSnapshotCache.recentGroups
    )
    history.append(event)
    incidents = history.events.reversed().filter { $0.kind != "sample" }
    lastRecordedAt = event.date
    persistHistory()
  }

  private func persistHistory() {
    guard persists else { return }
    needsSave = true
    guard !isSaving else { return }
    isSaving = true
    Task { [weak self] in
      guard let self else { return }
      while needsSave {
        needsSave = false
        do {
          try await store.save(history)
          if statusMessage?.hasPrefix("Could not save memory history:") == true {
            statusMessage = nil
          }
        } catch {
          statusMessage = "Could not save memory history: \(error.localizedDescription)"
        }
      }
      isSaving = false
    }
  }
}
