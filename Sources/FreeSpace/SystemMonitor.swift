import Darwin
import Foundation

enum CapacityStatus: Equatable, Sendable {
  case healthy
  case warning
  case critical
  case unknown

  var systemImage: String {
    switch self {
    case .healthy:
      "internaldrive"
    case .warning:
      "internaldrive.fill"
    case .critical:
      "exclamationmark.triangle.fill"
    case .unknown:
      "internaldrive"
    }
  }
}

enum ThermalStatus: Equatable, Sendable {
  case nominal
  case fair
  case serious
  case critical
  case unknown

  var title: String {
    switch self {
    case .nominal:
      "Normal"
    case .fair:
      "Warm"
    case .serious:
      "Hot"
    case .critical:
      "Critical"
    case .unknown:
      "Unknown"
    }
  }
}

enum MacHealthStatus: Equatable, Sendable {
  case healthy
  case warning
  case critical
  case unknown

  var title: String {
    switch self {
    case .healthy:
      "Healthy"
    case .warning:
      "Needs attention"
    case .critical:
      "Critical"
    case .unknown:
      "Checking"
    }
  }
}

struct SystemSnapshot: Equatable, Sendable {
  let diskAvailable: UInt64
  let diskTotal: UInt64
  let ramAvailable: UInt64
  let ramTotal: UInt64
  let memoryPressure: MemoryPressureLevel
  let cpuUsage: Double?
  let thermalStatus: ThermalStatus
  let updatedAt: Date
  let developerVolume: VolumeCapacity?

  var ramUsed: UInt64 {
    ramTotal - min(ramTotal, ramAvailable)
  }

  var ramUsedRatio: Double {
    guard ramTotal > 0 else {
      return 0
    }

    return Double(ramUsed) / Double(ramTotal)
  }

  var diskStatus: CapacityStatus {
    DiskSpacePolicy.status(DiskCapacityInput(available: diskAvailable, total: diskTotal))
  }

  var healthStatus: MacHealthStatus {
    guard diskTotal > 0, ramTotal > 0 else {
      return .unknown
    }

    if diskStatus == .critical || memoryPressure == .critical || thermalStatus == .critical {
      return .critical
    }

    let cpuNeedsAttention =
      cpuUsage.map { usage in
        usage >= 0.95
      } ?? false
    let thermalNeedsAttention = thermalStatus == .fair || thermalStatus == .serious

    if diskStatus == .warning
      || memoryPressure == .warning
      || cpuNeedsAttention
      || thermalNeedsAttention
    {
      return .warning
    }

    return .healthy
  }

  static let empty = SystemSnapshot(
    SystemSnapshotInput(
      diskAvailable: 0,
      diskTotal: 0,
      ramAvailable: 0,
      ramTotal: 0,
      memoryPressure: .unknown,
      cpuUsage: nil,
      thermalStatus: .unknown,
      updatedAt: .now,
      developerVolume: nil
    )
  )

  init(_ input: SystemSnapshotInput) {
    diskAvailable = input.diskAvailable
    diskTotal = input.diskTotal
    ramAvailable = input.ramAvailable
    ramTotal = input.ramTotal
    memoryPressure = input.memoryPressure
    cpuUsage = input.cpuUsage
    thermalStatus = input.thermalStatus
    updatedAt = input.updatedAt
    developerVolume = input.developerVolume
  }
}

struct MemorySample: Equatable, Identifiable, Sendable {
  let capturedAt: Date
  let used: UInt64
  let total: UInt64

  var id: Date {
    capturedAt
  }

  var usedRatio: Double {
    guard total > 0 else {
      return 0
    }

    return Double(used) / Double(total)
  }

  init(snapshot: SystemSnapshot) {
    capturedAt = snapshot.updatedAt
    used = snapshot.ramUsed
    total = snapshot.ramTotal
  }
}

struct MemoryHistory: Equatable, Sendable {
  private(set) var samples: [MemorySample] = []
  let capacity: Int

  init(capacity: Int = 61) {
    self.capacity = max(1, capacity)
  }

  mutating func append(snapshot: SystemSnapshot) {
    samples.append(MemorySample(snapshot: snapshot))

    if samples.count > capacity {
      samples.removeFirst(samples.count - capacity)
    }
  }
}

struct SystemSnapshotInput {
  let diskAvailable: UInt64
  let diskTotal: UInt64
  let ramAvailable: UInt64
  let ramTotal: UInt64
  let memoryPressure: MemoryPressureLevel
  let cpuUsage: Double?
  let thermalStatus: ThermalStatus
  let updatedAt: Date
  let developerVolume: VolumeCapacity?
}

struct VolumeCapacity: Equatable, Sendable {
  let name: String
  let path: String
  let available: UInt64
  let total: UInt64

  var used: UInt64 {
    total > available ? total - available : 0
  }

  var availableRatio: Double {
    guard total > 0 else {
      return 0
    }

    return Double(available) / Double(total)
  }
}

final class SystemMetricsProvider {
  private var previousCPUTicks: CPUTicks?

  func snapshot() -> SystemSnapshot {
    let disk = diskCapacity()
    let ram = ramCapacity()

    return SystemSnapshot(
      SystemSnapshotInput(
        diskAvailable: disk.available,
        diskTotal: disk.total,
        ramAvailable: ram.available,
        ramTotal: ram.total,
        memoryPressure: MemoryPressureReader().current(),
        cpuUsage: cpuUsage(),
        thermalStatus: thermalStatus(),
        updatedAt: .now,
        developerVolume: DeveloperLocations.volumePath.flatMap { volumeCapacity($0) }
      )
    )
  }

  private func cpuUsage() -> Double? {
    guard let currentTicks = cpuTicks() else {
      return nil
    }

    defer {
      previousCPUTicks = currentTicks
    }

    guard let previousCPUTicks else {
      return nil
    }

    let delta = currentTicks.delta(from: previousCPUTicks)
    guard delta.total > 0 else {
      return nil
    }

    return min(1, Double(delta.active) / Double(delta.total))
  }

  private func cpuTicks() -> CPUTicks? {
    var loadInfo = host_cpu_load_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
    )

    let result = withUnsafeMutablePointer(to: &loadInfo) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &count)
      }
    }

    guard result == KERN_SUCCESS else {
      return nil
    }

    return CPUTicks(
      user: loadInfo.cpu_ticks.0,
      system: loadInfo.cpu_ticks.1,
      idle: loadInfo.cpu_ticks.2,
      nice: loadInfo.cpu_ticks.3
    )
  }

  private func thermalStatus() -> ThermalStatus {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:
      .nominal
    case .fair:
      .fair
    case .serious:
      .serious
    case .critical:
      .critical
    @unknown default:
      .unknown
    }
  }

  private func diskCapacity() -> (available: UInt64, total: UInt64) {
    guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/") else {
      return (0, 0)
    }

    let available = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
    let total = (attributes[.systemSize] as? NSNumber)?.uint64Value ?? 0

    return (available, total)
  }

  private func ramCapacity() -> (available: UInt64, total: UInt64) {
    guard let stats = VMMemoryStatsReader.current() else { return (0, 0) }
    return (stats.available, stats.total)
  }

  private func volumeCapacity(_ path: String) -> VolumeCapacity? {
    guard
      FileManager.default.fileExists(atPath: path),
      let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path)
    else {
      return nil
    }

    let available = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
    let total = (attributes[.systemSize] as? NSNumber)?.uint64Value ?? 0
    return VolumeCapacity(
      name: URL(fileURLWithPath: path).lastPathComponent,
      path: path,
      available: available,
      total: total
    )
  }
}

private struct CPUTicks {
  let user: UInt32
  let system: UInt32
  let idle: UInt32
  let nice: UInt32

  var active: UInt64 {
    UInt64(user) + UInt64(system) + UInt64(nice)
  }

  var total: UInt64 {
    active + UInt64(idle)
  }

  func delta(from previous: CPUTicks) -> CPUTicks {
    CPUTicks(
      user: user &- previous.user,
      system: system &- previous.system,
      idle: idle &- previous.idle,
      nice: nice &- previous.nice
    )
  }
}

@MainActor
final class SystemMonitor: NSObject, ObservableObject {
  @Published private(set) var snapshot: SystemSnapshot
  @Published private(set) var memorySamples: [MemorySample]

  private let provider: SystemMetricsProvider
  private var memoryHistory = MemoryHistory(capacity: 151)
  private var history = ResourceHistory(capacity: 451)
  @Published private(set) var resourceSamples: [ResourceSample] = []
  @Published private(set) var topCPUProcesses: [LiveCPUProcess] = []
  @Published private(set) var memoryStats: VMMemoryStats?
  private var previousCounters: [CPUCounter] = []
  private var previousCounterTime: TimeInterval?
  private var samplingProcesses = false
  private var timer: Timer?

  override convenience init() {
    self.init(provider: SystemMetricsProvider())
  }

  init(provider: SystemMetricsProvider) {
    self.provider = provider
    let initialSnapshot = provider.snapshot()
    snapshot = initialSnapshot
    memoryHistory.append(snapshot: initialSnapshot)
    memorySamples = memoryHistory.samples
    super.init()
    let timer = Timer(
      timeInterval: 2,
      target: self,
      selector: #selector(refreshFromTimer),
      userInfo: nil,
      repeats: true
    )
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func refresh() {
    let refreshedSnapshot = provider.snapshot()
    snapshot = refreshedSnapshot
    memoryHistory.append(snapshot: refreshedSnapshot)
    memorySamples = memoryHistory.samples
    history.append(refreshedSnapshot)
    resourceSamples = history.samples
    memoryStats = VMMemoryStatsReader.current()
    sampleProcesses()
  }

  private func sampleProcesses() {
    guard !samplingProcesses else { return }
    samplingProcesses = true
    Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        (CPUProcessReader.counters(), ProcessInfo.processInfo.systemUptime)
      }.value
      guard let self else { return }
      if let previousCounterTime, let scale = CPUProcessReader.nanosecondsPerTick {
        topCPUProcesses = Array(
          CPUProcessReader.usage(
            .init(
              previous: previousCounters, current: result.0,
              seconds: result.1 - previousCounterTime, nanosecondsPerTick: scale)
          ).prefix(30))
      }
      previousCounters = result.0
      previousCounterTime = result.1
      samplingProcesses = false
    }
  }

  @objc private func refreshFromTimer() {
    refresh()
  }
}
