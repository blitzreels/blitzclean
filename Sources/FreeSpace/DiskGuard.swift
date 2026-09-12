import Darwin
import Foundation

struct DiskCapacityInput {
  let available: UInt64
  let total: UInt64
}

enum DiskSpacePolicy {
  static let reserveBytes: UInt64 = 30_000_000_000
  static let criticalBytes: UInt64 = 15 * 1_024 * 1_024 * 1_024
  static let emergencyBytes: UInt64 = 5 * 1_024 * 1_024 * 1_024
  static var reserveLabel: String { ByteText.compact(reserveBytes) }

  static func risk(_ available: UInt64) -> DiskRisk {
    if available >= reserveBytes { return .normal }
    if available <= emergencyBytes { return .emergency }
    if available <= criticalBytes { return .critical }
    return .warning
  }

  static func status(_ input: DiskCapacityInput) -> CapacityStatus {
    guard input.total > 0 else { return .unknown }
    switch risk(input.available) {
    case .normal: return .healthy
    case .warning: return .warning
    case .critical, .emergency: return .critical
    }
  }
}

struct DiskGuardSample: Sendable {
  let date: Date
  let available: UInt64
  let swapUsed: UInt64?

  static func read(memory: MemoryGuardSample) -> Self? {
    var capacity = statfs()
    guard statfs("/System/Volumes/Data", &capacity) == 0 else { return nil }
    return Self(
      date: memory.date, available: capacity.f_bavail * UInt64(capacity.f_bsize),
      swapUsed: memory.swapUsed)
  }
}

enum DiskRisk: Int, Comparable, Sendable {
  case normal, warning, critical, emergency

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  var title: String {
    switch self {
    case .normal: "Disk reserve ready"
    case .warning: "Disk reserve low"
    case .critical: "Disk filling up"
    case .emergency: "Disk almost full"
    }
  }
}

struct DiskAssessment: Sendable {
  let sample: DiskGuardSample
  let risk: DiskRisk
  let lostBytes: UInt64
  let elapsed: TimeInterval
  let swapGrowth: UInt64
  let minutesToReserve: Double?

  var detail: String {
    var parts = [
      "\(ByteText.full(sample.available)) free", "target \(DiskSpacePolicy.reserveLabel)",
    ]
    if elapsed >= 60 && lostBytes > 0 {
      parts.append("down \(ByteText.compact(lostBytes)) in \(Int(elapsed / 60))m")
    }
    if swapGrowth >= 512 * 1_024 * 1_024 {
      parts.append("swap grew \(ByteText.compact(swapGrowth))")
    }
    if let minutesToReserve {
      parts.append("10 GiB reserve in ~\(max(1, Int(minutesToReserve)))m at this rate")
    }
    return parts.joined(separator: " · ")
  }
}

struct DiskRiskEvaluator {
  private var samples: [DiskGuardSample] = []

  mutating func evaluate(_ sample: DiskGuardSample) -> DiskAssessment {
    if let last = samples.last,
      sample.date.timeIntervalSince(last.date) > 90 || sample.date <= last.date
    {
      samples.removeAll()
    }
    samples.removeAll { sample.date.timeIntervalSince($0.date) > 300 }
    samples.append(sample)
    if samples.count > 61 { samples.removeFirst(samples.count - 61) }
    let first = samples.first ?? sample
    let elapsed = sample.date.timeIntervalSince(first.date)
    let lost = first.available > sample.available ? first.available - sample.available : 0
    let swapGrowth: UInt64
    if let current = sample.swapUsed, let previous = first.swapUsed, current > previous {
      swapGrowth = current - previous
    } else {
      swapGrowth = 0
    }
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    let rate = elapsed >= 60 ? Double(lost) / elapsed * 60 : 0
    let minutes: Double? =
      rate >= Double(gib) / 2 && sample.available > 10 * gib
      ? Double(sample.available - 10 * gib) / rate : nil
    let capacityRisk = DiskSpacePolicy.risk(sample.available)
    let risk: DiskRisk =
      capacityRisk == .warning && minutes.map({ $0 <= 20 }) == true
      ? .critical : capacityRisk
    return DiskAssessment(
      sample: sample, risk: risk, lostBytes: lost, elapsed: elapsed, swapGrowth: swapGrowth,
      minutesToReserve: minutes)
  }
}

struct DiskAlertGate {
  private var lastSent: DiskAssessment?

  mutating func shouldSend(_ assessment: DiskAssessment) -> Bool {
    guard assessment.risk > .normal else { return false }
    if let lastSent {
      let cooldown: TimeInterval = assessment.risk >= .critical ? 600 : 1_800
      guard
        assessment.risk > lastSent.risk
          || assessment.sample.date.timeIntervalSince(lastSent.sample.date) >= cooldown
      else { return false }
    }
    lastSent = assessment
    return true
  }
}
