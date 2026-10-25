import Darwin
import Foundation

/// The app or process group using the most of one resource at a sample.
struct ResourceLead: Codable, Equatable, Sendable {
  let name: String
  /// CPU percent where 100 is one core, or physical footprint in bytes.
  let value: Double
}

struct ResourceLeads: Equatable, Sendable {
  let cpu: ResourceLead?
  let memory: ResourceLead?
}

struct ResourceSample: Codable, Identifiable, Equatable, Sendable {
  let date: Date
  let cpu: Double?
  let memory: Double
  var cpuLead: ResourceLead? = nil
  var memoryLead: ResourceLead? = nil
  var id: Date { date }

  /// Keeps each resource's peak, with the lead measured at that peak.
  func peak(_ other: ResourceSample) -> ResourceSample {
    let cpuSource = (other.cpu ?? -1) > (cpu ?? -1) ? other : self
    let memorySource = other.memory > memory ? other : self
    return ResourceSample(
      date: max(date, other.date), cpu: cpuSource.cpu, memory: memorySource.memory,
      cpuLead: cpuSource.cpuLead, memoryLead: memorySource.memoryLead)
  }
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

  /// Process readings finish after the system sample they describe.
  mutating func attribute(_ leads: ResourceLeads) {
    guard let last = samples.indices.last else { return }
    samples[last].cpuLead = leads.cpu
    samples[last].memoryLead = leads.memory
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
        archive[bucket] = archive[bucket].map { $0.peak(sample) } ?? sample
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
  /// Path of the running binary; empty when macOS did not report it.
  let executable: String
  let percent: Double
}

struct CPUCounter: Sendable {
  let id: Int32
  let name: String
  let start: UInt64
  let ticks: UInt64
  var footprint: UInt64 = 0
  /// App name for processes inside an app bundle, otherwise the process name.
  var group: String = ""
  var executable: String = ""
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
      return LiveCPUProcess(
        id: current.id, name: current.name, executable: current.executable, percent: percent)
    }.filter { $0.percent >= 0.1 }.sorted { $0.percent > $1.percent }
  }

  /// Sums helpers into their app so a spike names Chrome, not one of forty renderers.
  static func leads(_ input: CPUInterval) -> ResourceLeads {
    let current = Dictionary(
      input.current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var cpu: [String: Double] = [:]
    for process in usage(input) {
      cpu[groupName(current[process.id]), default: 0] += process.percent
    }
    var memory: [String: UInt64] = [:]
    for counter in input.current where counter.footprint > 0 {
      memory[groupName(counter), default: 0] += counter.footprint
    }
    let topCPU = cpu.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }
    let topMemory = memory.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }
    return ResourceLeads(
      cpu: topCPU.map { ResourceLead(name: $0.key, value: $0.value) },
      memory: topMemory.map { ResourceLead(name: $0.key, value: Double($0.value)) })
  }

  private static func groupName(_ counter: CPUCounter?) -> String {
    guard let counter else { return "Unknown" }
    return String((counter.group.isEmpty ? counter.name : counter.group).prefix(40))
  }

  struct GroupInput {
    let executable: String
    let name: String
    /// Project folder name for command-line tools, so node in two projects stays separate.
    let project: String?
  }

  static func group(_ input: GroupInput) -> String {
    if let app = ResourceOwnership.appName(input.executable) { return app }
    if input.executable.contains("/claude/versions/") { return "Claude Code" }
    return input.project.map { "\(input.name) · \($0)" } ?? input.name
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
      let start = info.ri_proc_start_abstime
      let identity =
        ProcessGroupCache.shared.identity(.init(pid: pid, start: start))
        ?? ProcessGroupCache.shared.store(
          .init(key: .init(pid: pid, start: start), identity: identity(pid)))
      guard let identity else { return nil }
      return CPUCounter(
        id: pid, name: identity.name, start: start,
        ticks: info.ri_user_time &+ info.ri_system_time,
        footprint: info.ri_phys_footprint, group: identity.group,
        executable: identity.executable)
    }
  }

  /// Name and group change only when a process execs, so they are read once per process lifetime.
  private static func identity(_ pid: Int32) -> ProcessGroupCache.Identity? {
    var name = [CChar](repeating: 0, count: 256)
    let length = proc_name(pid, &name, UInt32(name.count))
    guard length > 0 else { return nil }
    let processName = String(
      decoding: name.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let executable =
      proc_pidpath(pid, &path, UInt32(path.count)) > 0
      ? String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      : ""
    return .init(
      name: processName, executable: executable,
      group: group(
        .init(
          executable: executable, name: processName,
          project: ResourceOwnership.appName(executable) == nil
            ? ProcessWorkingDirectory.read(pid).flatMap(ProjectNameCache.shared.name) : nil)))
  }
}

final class ProcessGroupCache: @unchecked Sendable {
  struct Key: Hashable {
    let pid: Int32
    let start: UInt64
  }

  struct Identity {
    let name: String
    let executable: String
    let group: String
  }

  static let shared = ProcessGroupCache()
  private let lock = NSLock()
  private var identities: [Key: Identity] = [:]

  func identity(_ key: Key) -> Identity? {
    lock.withLock { identities[key] }
  }

  struct Entry {
    let key: Key
    /// Absent when the process exited before its name could be read.
    let identity: Identity?
  }

  func store(_ entry: Entry) -> Identity? {
    guard let identity = entry.identity else { return nil }
    lock.withLock {
      if identities.count > 4_000 { identities = [:] }
      identities[entry.key] = identity
    }
    return identity
  }
}

/// Maps a working directory to its repository folder name; cached because it runs every two seconds.
final class ProjectNameCache: @unchecked Sendable {
  static let shared = ProjectNameCache()
  private let lock = NSLock()
  private var names: [String: String?] = [:]

  func name(_ directory: String) -> String? {
    lock.lock()
    if let cached = names[directory] {
      lock.unlock()
      return cached
    }
    lock.unlock()
    let name = Self.resolve(directory)
    lock.lock()
    if names.count > 2_000 { names = [:] }
    names[directory] = name
    lock.unlock()
    return name
  }

  static func resolve(_ directory: String) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var url = URL(fileURLWithPath: directory)
    for _ in 0..<8 {
      let path = url.path
      guard path != "/", path != home, path.hasPrefix("/") else { return nil }
      if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
        return url.lastPathComponent
      }
      url.deleteLastPathComponent()
    }
    return nil
  }
}
