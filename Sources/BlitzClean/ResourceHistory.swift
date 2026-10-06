import Darwin
import Foundation

struct ResourceSample: Codable, Identifiable, Equatable, Sendable {
  let date: Date
  let cpu: Double?
  let memory: Double
  var id: Date { date }
}

struct ResourceHistory: Sendable {
  private(set) var samples: [ResourceSample] = []
  let capacity: Int
  private let archiveInterval: TimeInterval
  private let archiveRetention: TimeInterval

  init(capacity: Int) {
    self.capacity = capacity
    archiveInterval = 0
    archiveRetention = 0
  }

  private init(_ configuration: Configuration) {
    capacity = configuration.recentCapacity
    archiveInterval = configuration.archiveInterval
    archiveRetention = configuration.archiveRetention
  }

  private struct Configuration {
    let recentCapacity: Int
    let archiveInterval: TimeInterval
    let archiveRetention: TimeInterval
  }

  static var persisted: Self {
    .init(
      .init(recentCapacity: 451, archiveInterval: 300, archiveRetention: 7 * 86_400))
  }

  mutating func restore(_ saved: [ResourceSample]) {
    samples = saved
    compact(now: .now)
  }

  mutating func append(_ snapshot: SystemSnapshot) {
    samples.append(
      .init(date: snapshot.updatedAt, cpu: snapshot.cpuUsage, memory: snapshot.ramUsedRatio))
    compact(now: snapshot.updatedAt)
  }

  private mutating func compact(now: Date) {
    guard archiveInterval > 0 else {
      samples = Array(samples.suffix(max(1, capacity)))
      return
    }
    let oldest = now.addingTimeInterval(-archiveRetention)
    let recentCutoff = now.addingTimeInterval(-900)
    var archive: [Int: ResourceSample] = [:]
    var recent: [ResourceSample] = []
    for sample in samples where sample.date >= oldest && sample.date <= now {
      if sample.date >= recentCutoff {
        recent.append(sample)
      } else {
        let bucket = Int(sample.date.timeIntervalSince1970 / archiveInterval)
        if let previous = archive[bucket], previous.date >= sample.date { continue }
        archive[bucket] = sample
      }
    }
    samples =
      archive.values.sorted { $0.date < $1.date }
      + recent.sorted { $0.date < $1.date }.suffix(max(1, capacity))
  }
}

struct LiveCPUProcess: Identifiable, Sendable {
  let id: Int32
  let name: String
  let percent: Double
}

struct CPUCounter: Sendable {
  let id: Int32
  let name: String
  let start: UInt64
  let ticks: UInt64
}

struct CPUInterval: Sendable {
  let previous: [CPUCounter]
  let current: [CPUCounter]
  let seconds: Double
  let nanosecondsPerTick: Double
}

enum CPUProcessReader {
  static var nanosecondsPerTick: Double? {
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return nil }
    return Double(info.numer) / Double(info.denom)
  }

  static func usage(_ input: CPUInterval) -> [LiveCPUProcess] {
    guard input.seconds > 0, input.nanosecondsPerTick > 0 else { return [] }
    let previous = Dictionary(
      input.previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return input.current.compactMap { current in
      guard let old = previous[current.id], old.start == current.start,
        current.ticks >= old.ticks
      else { return nil }
      let percent =
        Double(current.ticks - old.ticks) * input.nanosecondsPerTick
        / (input.seconds * 1_000_000_000) * 100
      return LiveCPUProcess(id: current.id, name: current.name, percent: percent)
    }.filter { $0.percent >= 0.1 }.sorted { $0.percent > $1.percent }
  }

  static func counters() -> [CPUCounter] {
    var pids = [Int32](repeating: 0, count: max(64, Int(proc_listallpids(nil, 0)) + 128))
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard count > 0 else { return [] }
    return pids.prefix(min(Int(count), pids.count)).compactMap { pid in
      guard pid > 0 else { return nil }
      var info = rusage_info_v4()
      let status = withUnsafeMutablePointer(to: &info) {
        proc_pid_rusage(
          pid, RUSAGE_INFO_V4,
          UnsafeMutableRawPointer($0)
            .assumingMemoryBound(to: Optional<UnsafeMutableRawPointer>.self))
      }
      guard status == 0 else { return nil }
      var name = [CChar](repeating: 0, count: 256)
      let length = proc_name(pid, &name, UInt32(name.count))
      guard length > 0 else { return nil }
      return CPUCounter(
        id: pid,
        name: String(
          decoding: name.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self),
        start: info.ri_proc_start_abstime, ticks: info.ri_user_time &+ info.ri_system_time)
    }
  }
}
