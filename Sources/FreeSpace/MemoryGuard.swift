import Darwin
import Foundation

struct MemoryGuardSample: Codable, Equatable, Sendable {
  let date: Date
  let pressure: MemoryPressureLevel
  let available: UInt64
  let total: UInt64
  let compressed: UInt64
  let swapUsed: UInt64?
  let swapOutBytes: UInt64

  static func read(pressure: MemoryPressureLevel) -> Self? {
    guard let stats = VMMemoryStatsReader.current() else { return nil }
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    let result = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
    return Self(
      date: .now, pressure: pressure, available: stats.available, total: stats.total,
      compressed: stats.compressed, swapUsed: result == 0 ? swap.xsu_used : nil,
      swapOutBytes: stats.swapOutBytes
    )
  }
}

enum MemoryRisk: Int, Codable, Comparable, Sendable {
  case normal, growing, warning, critical

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  var title: String {
    switch self {
    case .normal: "Memory stable"
    case .growing: "Memory demand rising"
    case .warning: "Memory needs attention"
    case .critical: "Memory pressure critical"
    }
  }
}

struct MemoryRiskEvaluator {
  private var samples: [MemoryGuardSample] = []
  private var recoveryStartedAt: Date?
  private(set) var risk = MemoryRisk.normal

  mutating func evaluate(_ sample: MemoryGuardSample) -> MemoryRisk {
    if let last = samples.last,
      sample.date.timeIntervalSince(last.date) > 90 || sample.date < last.date
    {
      samples.removeAll()
      recoveryStartedAt = nil
    }
    samples.append(sample)
    samples.removeAll { sample.date.timeIntervalSince($0.date) > 60 }
    let candidate: MemoryRisk
    switch sample.pressure {
    case .critical: candidate = .critical
    case .warning: candidate = .warning
    case .unknown: candidate = risk
    case .normal:
      let first = samples.first ?? sample
      let elapsed = sample.date.timeIntervalSince(first.date)
      let swapOut =
        sample.swapOutBytes >= first.swapOutBytes ? sample.swapOutBytes - first.swapOutBytes : 0
      let constrained =
        sample.total > 0
        && (Double(sample.available) / Double(sample.total) < 0.15
          || Double(sample.compressed) / Double(sample.total) >= 0.25)
      candidate =
        elapsed >= 30 && swapOut >= 128 * 1_024 * 1_024 && constrained ? .growing : .normal
    }
    if candidate >= risk {
      risk = candidate
      recoveryStartedAt = nil
    } else {
      if recoveryStartedAt == nil { recoveryStartedAt = sample.date }
      if let recoveryStartedAt, sample.date.timeIntervalSince(recoveryStartedAt) >= 30 {
        risk = candidate
        self.recoveryStartedAt = nil
      }
    }
    return risk
  }
}

struct MemoryAlertGate {
  struct Input {
    let risk: MemoryRisk
    let date: Date
  }

  private var lastSentAt: Date?
  private var highestSent = MemoryRisk.normal

  mutating func shouldSend(_ input: Input) -> Bool {
    guard input.risk > .normal else { return false }
    let cooledDown = lastSentAt.map { input.date.timeIntervalSince($0) >= 600 } ?? true
    guard cooledDown || input.risk > highestSent else { return false }
    highestSent = cooledDown ? input.risk : max(highestSent, input.risk)
    lastSentAt = input.date
    return true
  }
}

enum MemoryAppPolicy: String, CaseIterable, Codable, Sendable {
  case review, keepRunning, disposable

  var title: String {
    switch self {
    case .review: "Review before quitting"
    case .keepRunning: "Keep running"
    case .disposable: "OK to suggest closing"
    }
  }
}

struct MemoryCandidate: Identifiable {
  let app: MemoryApp
  let policy: MemoryAppPolicy
  let reason: String
  let protected: Bool
  let growth: Int64?

  var id: Int32 { app.id }
}

enum MemoryCandidateRanker {
  struct Input {
    let apps: [MemoryApp]
    let policies: [String: MemoryAppPolicy]
    let lastActive: [String: Date]
    let growth: [Int32: Int64]
    let date: Date
  }

  static func rank(_ input: Input) -> [MemoryCandidate] {
    input.apps.map { app in
      let policy = input.policies[app.policyKey, default: .review]
      let protected = app.protectionReason != nil || app.isActive || policy == .keepRunning
      let reason: String
      if let protection = app.protectionReason {
        reason = protection
      } else if app.isActive {
        reason = "Currently in use"
      } else if policy == .keepRunning {
        reason = "You pinned this app"
      } else if policy == .disposable {
        reason = "You marked this app as a closing candidate"
      } else if let lastActive = input.lastActive[app.policyKey] {
        let minutes = max(0, Int(input.date.timeIntervalSince(lastActive) / 60))
        reason = "Last used \(minutes)m ago · check ongoing work"
      } else {
        reason = "Activity unknown · check unsaved and ongoing work"
      }
      return MemoryCandidate(
        app: app, policy: policy, reason: reason, protected: protected, growth: input.growth[app.id]
      )
    }.sorted { left, right in
      if left.protected != right.protected { return !left.protected }
      if (left.policy == .disposable) != (right.policy == .disposable) {
        return left.policy == .disposable
      }
      return left.app.memoryBytes > right.app.memoryBytes
    }
  }
}

struct MemoryIncident: Codable, Identifiable, Sendable {
  struct App: Codable, Sendable {
    let name: String
    let bytes: UInt64
    let protected: Bool
  }

  let id: UUID
  let date: Date
  let kind: String
  let detail: String
  let sample: MemoryGuardSample?
  let apps: [App]
  var resources: [ResourceGroup]? = nil
}

struct MemoryIncidentHistory: Codable, Sendable {
  private(set) var events: [MemoryIncident] = []
  static let capacity = 1_440

  mutating func append(_ event: MemoryIncident) {
    events.append(event)
    events.removeAll { event.date.timeIntervalSince($0.date) > 86_400 }
    if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
  }

  func boundedData(maximumBytes: Int) throws -> Data {
    var copy = self
    var data = try JSONEncoder().encode(copy)
    while data.count > maximumBytes && !copy.events.isEmpty {
      copy.events.removeFirst(max(1, copy.events.count / 4))
      data = try JSONEncoder().encode(copy)
    }
    return data
  }
}

actor MemoryIncidentStore {
  let url: URL

  init(url: URL) { self.url = url }

  func load() -> MemoryIncidentHistory {
    guard let data = try? Data(contentsOf: url), data.count <= 8 * 1_024 * 1_024,
      let history = try? JSONDecoder().decode(MemoryIncidentHistory.self, from: data)
    else { return MemoryIncidentHistory() }
    return history
  }

  func save(_ history: MemoryIncidentHistory) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try history.boundedData(maximumBytes: 6 * 1_024 * 1_024)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
