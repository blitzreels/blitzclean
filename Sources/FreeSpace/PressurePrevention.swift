import Darwin
import Foundation
import UserNotifications

enum PressureLimit: Equatable, Sendable {
  case none, memory, disk, cpu
}

struct PressureAssessment: Equatable, Sendable {
  let risk: MemoryRisk
  let limit: PressureLimit
  let title: String
  let detail: String
  let action: String
  let date: Date

  var reviewTitle: String { limit == .disk ? "Free up space" : "Review projects" }

  static let checking = Self(
    risk: .normal, limit: .none, title: "Checking capacity",
    detail: "Reading memory, swap, CPU and disk reserve",
    action: "", date: .distantPast)
}

struct PressureEvaluator {
  struct Input {
    let memory: MemoryGuardSample
    let disk: DiskGuardSample
    let cpu: Double?
  }

  private var memoryEvaluator = MemoryRiskEvaluator()
  private var diskEvaluator = DiskRiskEvaluator()
  private var busySince: Date?

  mutating func evaluate(_ input: Input) -> PressureAssessment {
    let memory = input.memory
    let disk = diskEvaluator.evaluate(input.disk)
    let memoryRisk = memoryEvaluator.evaluate(memory)
    let swap = memory.swapUsed ?? 0
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    if input.cpu.map({ $0 >= 0.9 }) == true {
      if busySince == nil { busySince = memory.date }
    } else {
      busySince = nil
    }
    let swapConstrained =
      swap >= max(8 * gib, memory.total / 3)
      && (memory.compressed >= memory.total / 5 || memory.available < memory.total / 8)
    let bottleneck: (MemoryRisk, PressureLimit, String, String)
    if disk.risk >= .critical && (swapConstrained || memoryRisk >= .warning) {
      bottleneck = (
        .critical, .memory, "Memory and disk under pressure",
        "Avoid starting new threads or builds. Quit unused projects; swap is competing with a low disk reserve."
      )
    } else if memoryRisk >= .warning || swapConstrained {
      bottleneck = (
        max(memoryRisk, .warning), .memory, "Memory is the bottleneck",
        "Avoid starting new threads or builds. Quit an unused project to release RAM; Pause only slows it."
      )
    } else if disk.risk > .normal {
      bottleneck = (
        disk.risk >= .critical ? .critical : .warning, .disk, "Disk reserve is the bottleneck",
        "Avoid large downloads and builds. Remove rebuildable data in Storage."
      )
    } else if memoryRisk == .growing {
      bottleneck = (
        .growing, .memory, "Swap activity is rising",
        "Avoid starting new threads or builds while memory moves to swap."
      )
    } else if let busySince, memory.date.timeIntervalSince(busySince) >= 15 {
      bottleneck = (
        .warning, .cpu, "CPU is the bottleneck", "Pause unused projects to let active work finish."
      )
    } else {
      bottleneck = (.normal, .none, "Capacity available", "")
    }
    let memoryMetrics =
      "\(ByteText.compact(memory.available)) RAM available · \(ByteText.compact(swap)) swap"
    return PressureAssessment(
      risk: bottleneck.0, limit: bottleneck.1, title: bottleneck.2,
      detail: bottleneck.1 == .disk
        ? "\(disk.detail) · \(memoryMetrics)"
        : "\(memoryMetrics) · \(ByteText.compact(input.disk.available)) disk free",
      action: bottleneck.3,
      date: memory.date)
  }
}

struct ProjectPauseTarget: Sendable {
  let directory: String
  let name: String
  let cpuPercent: Double
  let memoryBytes: UInt64
  let identities: [DevProcessIdentity]
  let capturedAt: Date
  var keepRunning = false

  var isPaused: Bool { !identities.isEmpty && identities.allSatisfy { $0.process.stopped } }
}

enum ProjectPausePolicy {
  static let key = "pressure.autoPauseProjects.v1"

  struct Input {
    let project: WorkspaceProject
    let identities: [Int32: DevProcessIdentity]
    let excludedIDs: Set<Int32>
    let date: Date
  }

  static func target(_ input: Input) -> ProjectPauseTarget? {
    let allowed = input.project.resources.filter {
      !$0.isTool && !input.excludedIDs.contains($0.id)
        && ["node", "bun", "deno", "npm", "pnpm", "yarn", "next-server", "tsx", "ffmpeg"].contains(
          $0.name)
    }
    let identities = allowed.compactMap { input.identities[$0.id] }.filter {
      !$0.executable.contains(".app/") && $0.process.owner == getuid()
        && $0.process.processID != getpid()
    }
    guard !identities.isEmpty else { return nil }
    return ProjectPauseTarget(
      directory: input.project.directory, name: input.project.preference.name,
      cpuPercent: input.project.cpuPercent, memoryBytes: input.project.memoryBytes,
      identities: identities, capturedAt: input.date,
      keepRunning: input.project.preference.keepRunning)
  }

  struct SignalRequest: Sendable {
    let target: ProjectPauseTarget
    let resume: Bool
  }

  static func signal(_ request: SignalRequest) -> Int {
    let target = request.target
    guard
      request.resume
        || (!target.keepRunning && !WorkspacePreferences.isKeptRunning(target.directory)),
      request.resume || Date.now.timeIntervalSince(target.capturedAt) < 20
    else { return 0 }
    var changed: [DevProcessIdentity] = []
    for expected in target.identities {
      guard let current = DevProcessIdentity.read(expected.process.processID),
        expected.matches(current),
        current.process.owner == getuid(), current.process.processID > 1,
        current.process.processID != getpid()
      else { continue }
      guard request.resume ? current.process.stopped : !current.process.stopped else { continue }
      if kill(current.process.processID, request.resume ? SIGCONT : SIGSTOP) == 0 {
        changed.append(current)
      }
    }
    return changed.count
  }

  static func stop(_ target: ProjectPauseTarget) -> Int {
    guard !target.keepRunning, !WorkspacePreferences.isKeptRunning(target.directory),
      Date.now.timeIntervalSince(target.capturedAt) < 20
    else { return 0 }
    var count = 0
    for expected in target.identities {
      guard let current = DevProcessIdentity.read(expected.process.processID),
        expected.matches(current), current.process.owner == getuid(),
        current.process.processID > 1, current.process.processID != getpid(),
        kill(current.process.processID, SIGTERM) == 0
      else { continue }
      count += 1
      if current.process.stopped,
        let stillCurrent = DevProcessIdentity.read(current.process.processID),
        expected.matches(stillCurrent)
      {
        kill(stillCurrent.process.processID, SIGCONT)
      }
    }
    return count
  }

  static func remaining(_ target: ProjectPauseTarget) -> Int {
    target.identities.filter { expected in
      DevProcessIdentity.read(expected.process.processID).map(expected.matches) == true
    }.count
  }
}

struct PressureUpdate: Sendable {
  let assessment: PressureAssessment
  let action: String?
}

final class PressureSentinel: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "com.blitzreels.BlitzClean.pressure", qos: .userInitiated)
  private var timer: DispatchSourceTimer?
  private var evaluator = PressureEvaluator()
  private let metrics = SystemMetricsProvider()
  private var alertGate = MemoryAlertGate()
  private var targets: [ProjectPauseTarget] = []
  private var lastPause = Date.distantPast
  private var elevatedSince: Date?
  private var lastSaved = Date.distantPast
  private var events: [[String: String]] = []
  private let installed = Bundle.main.bundleIdentifier == AppBrand.bundleIdentifier

  deinit { timer?.cancel() }

  func start(_ receive: @escaping @Sendable (PressureUpdate) -> Void) {
    queue.async { [self] in
      guard timer == nil else { return }
      if installed {
        let url = FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Library/Application Support/FreeSpace/pressure-latest.json")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 524_288,
          let data = try? Data(contentsOf: url),
          let saved = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        {
          events = Array(saved.suffix(239))
        }
      }
      let source = DispatchSource.makeTimerSource(queue: queue)
      source.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(200))
      source.setEventHandler { [weak self] in self?.sample(receive) }
      timer = source
      source.resume()
    }
  }

  func update(_ targets: [ProjectPauseTarget]) {
    queue.async { [self] in self.targets = targets }
  }

  func stop() {
    queue.async { [self] in
      timer?.cancel()
      timer = nil
    }
  }

  private func sample(_ receive: @Sendable (PressureUpdate) -> Void) {
    guard let memory = MemoryGuardSample.read(pressure: MemoryPressureReader().current()),
      let disk = DiskGuardSample.read(memory: memory)
    else { return }
    let assessment = evaluator.evaluate(
      .init(memory: memory, disk: disk, cpu: metrics.snapshot().cpuUsage))
    if assessment.risk >= .warning {
      if elevatedSince == nil { elevatedSince = memory.date }
    } else {
      elevatedSince = nil
    }
    var action: String?
    let permitted = Set(UserDefaults.standard.stringArray(forKey: ProjectPausePolicy.key) ?? [])
    if installed, let elevatedSince, memory.date.timeIntervalSince(elevatedSince) >= 6,
      memory.date.timeIntervalSince(lastPause) >= 30,
      let target = targets.filter({
        permitted.contains($0.directory) && !$0.isPaused
          && memory.date.timeIntervalSince($0.capturedAt) < 20
          && !WorkspacePreferences.isKeptRunning($0.directory)
      }).max(by: { $0.cpuPercent < $1.cpuPercent })
    {
      let count = ProjectPausePolicy.signal(.init(target: target, resume: false))
      if count > 0 {
        lastPause = memory.date
        action =
          "Paused \(target.name) (\(count) processes). RAM is still held. Resume it in Projects."
        targets.removeAll { $0.directory == target.directory }
      }
    }
    if installed {
      let enabled = UserDefaults.standard.object(forKey: "memory.alertsEnabled") as? Bool ?? true
      if enabled && alertGate.shouldSend(.init(risk: assessment.risk, date: memory.date)) {
        let content = UNMutableNotificationContent()
        content.title = assessment.title
        content.body = assessment.action + " " + assessment.detail
        content.categoryIdentifier = "memory"
        content.sound = .default
        UNUserNotificationCenter.current().add(
          UNNotificationRequest(identifier: "capacity-guard", content: content, trigger: nil))
      }
      if action != nil || memory.date.timeIntervalSince(lastSaved) >= 15 {
        lastSaved = memory.date
        events.append([
          "at": ISO8601DateFormatter().string(from: memory.date), "risk": assessment.title,
          "detail": assessment.detail, "action": action ?? "",
          "projects": targets.largest(.init(count: 8, key: \.memoryBytes))
            .map { "\($0.name): \(ByteText.compact($0.memoryBytes))" }.joined(separator: "; "),
        ])
        if events.count > 240 { events.removeFirst(events.count - 240) }
        let url = FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Library/Application Support/FreeSpace/pressure-latest.json")
        try? FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if var data = try? JSONSerialization.data(withJSONObject: events) {
          while data.count > 524_288 && events.count > 1 {
            events.removeFirst(max(1, events.count / 4))
            data = (try? JSONSerialization.data(withJSONObject: events)) ?? Data("[]".utf8)
          }
          try? data.write(to: url, options: .atomic)
          try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
      }
    }
    receive(PressureUpdate(assessment: assessment, action: action))
  }
}
