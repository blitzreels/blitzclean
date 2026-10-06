import Foundation
import Testing

@testable import FreeSpace

struct SystemSnapshotTests {
  @Test
  func criticalAtFifteenGiBAvailable() {
    let snapshot = makeSnapshot(
      SnapshotInput(available: DiskSpacePolicy.criticalBytes, total: 500_000_000_000))

    #expect(snapshot.diskStatus == .critical)
  }

  @Test
  func warningBelowThirtyGBAvailable() {
    let snapshot = makeSnapshot(SnapshotInput(available: 29_999_999_999, total: 500_000_000_000))

    #expect(snapshot.diskStatus == .warning)
  }

  @Test
  func healthyAtThirtyGBAvailable() {
    let snapshot = makeSnapshot(SnapshotInput(available: 30_000_000_000, total: 500_000_000_000))

    #expect(snapshot.diskStatus == .healthy)
  }

  @Test
  func storageHealthAndColorsStayHealthyOnLargeDrives() {
    for total: UInt64 in [500_000_000_000, 2_000_000_000_000] {
      for available: UInt64 in [30_000_000_000, 50_000_000_000, 78_000_000_000] {
        let snapshot = makeSnapshot(
          SnapshotInput(
            available: available, total: total, ramAvailable: 40, ramTotal: 64, cpuUsage: 0.2))
        #expect(snapshot.diskStatus == .healthy)
        #expect(snapshot.healthStatus == .healthy)
        #expect(MenuBarTones.disk(snapshot) == .good)
        #expect(MetricTone.forDisk(DiskCapacityInput(available: available, total: total)) == .good)
      }
    }
  }

  @Test
  func unknownWithoutDiskSize() {
    let snapshot = makeSnapshot(SnapshotInput(available: 0, total: 0))

    #expect(snapshot.diskStatus == .unknown)
    #expect(MenuBarTones.disk(snapshot) == .neutral)
  }

  @Test
  func calculatesUsedRAMWithoutUnderflow() {
    let regular = makeSnapshot(
      SnapshotInput(
        available: 50_000_000_000,
        total: 500_000_000_000,
        ramAvailable: 24,
        ramTotal: 64
      )
    )
    let inconsistent = makeSnapshot(
      SnapshotInput(
        available: 50_000_000_000,
        total: 500_000_000_000,
        ramAvailable: 80,
        ramTotal: 64
      )
    )

    #expect(regular.ramUsed == 40)
    #expect(regular.ramUsedRatio == 0.625)
    #expect(inconsistent.ramUsed == 0)
  }

  @Test
  func healthIsHealthyWhenCoreMetricsAreNormal() {
    let snapshot = makeSnapshot(
      SnapshotInput(
        available: 50_000_000_000,
        total: 500_000_000_000,
        ramAvailable: 40,
        ramTotal: 64,
        cpuUsage: 0.4
      )
    )

    #expect(snapshot.healthStatus == .healthy)
  }

  @Test
  func healthWarnsForHighCurrentCPU() {
    let snapshot = makeSnapshot(
      SnapshotInput(
        available: 50_000_000_000,
        total: 500_000_000_000,
        ramAvailable: 40,
        ramTotal: 64,
        cpuUsage: 0.96
      )
    )

    #expect(snapshot.healthStatus == .warning)
  }

  @Test
  func healthIsCriticalForCriticalThermalState() {
    let snapshot = makeSnapshot(
      SnapshotInput(
        available: 50_000_000_000,
        total: 500_000_000_000,
        ramAvailable: 40,
        ramTotal: 64,
        thermalStatus: .critical
      )
    )

    #expect(snapshot.healthStatus == .critical)
  }

  @Test
  func trayTextPrioritizesFreeDiskSpace() {
    let snapshot = makeSnapshot(
      SnapshotInput(
        available: 36_400_000_000,
        total: 500_000_000_000,
        ramAvailable: 13,
        ramTotal: 39,
        cpuUsage: 0.44
      )
    )
    let text = MenuBarStatusText.make(
      MenuBarStatusTextInput(
        snapshot: snapshot,
        showDisk: true,
        showCPU: true,
        showMemory: true,
        memoryDisplay: .percentage
      )
    )

    #expect(text.hasPrefix(ByteText.compact(snapshot.diskAvailable)))
    #expect(text.contains("free"))
    #expect(text.firstRange(of: "free")!.lowerBound < text.firstRange(of: "CPU 44%")!.lowerBound)
  }

  @Test
  func memoryHistoryKeepsNewestSamplesWithinCapacity() {
    var history = MemoryHistory(capacity: 2)
    history.append(
      snapshot: makeMemorySnapshot(MemorySnapshotInput(ramAvailable: 30, updatedAt: 1)))
    history.append(
      snapshot: makeMemorySnapshot(MemorySnapshotInput(ramAvailable: 20, updatedAt: 2)))
    history.append(
      snapshot: makeMemorySnapshot(MemorySnapshotInput(ramAvailable: 10, updatedAt: 3)))

    #expect(
      history.samples.map(\.capturedAt) == [
        Date(timeIntervalSince1970: 2),
        Date(timeIntervalSince1970: 3),
      ])
  }

  private func makeMemorySnapshot(_ input: MemorySnapshotInput) -> SystemSnapshot {
    makeSnapshot(
      SnapshotInput(
        available: 10,
        total: 500_000_000_000,
        ramAvailable: input.ramAvailable,
        ramTotal: 64,
        updatedAt: Date(timeIntervalSince1970: input.updatedAt)
      )
    )
  }

  private struct MemorySnapshotInput {
    let ramAvailable: UInt64
    let updatedAt: TimeInterval
  }

  private func makeSnapshot(_ input: SnapshotInput) -> SystemSnapshot {
    SystemSnapshot(
      SystemSnapshotInput(
        diskAvailable: input.available,
        diskTotal: input.total,
        ramAvailable: input.ramAvailable,
        ramTotal: input.ramTotal,
        memoryPressure: .normal,
        cpuUsage: input.cpuUsage,
        thermalStatus: input.thermalStatus,
        updatedAt: input.updatedAt
      )
    )
  }

  private struct SnapshotInput {
    let available: UInt64
    let total: UInt64
    let ramAvailable: UInt64
    let ramTotal: UInt64
    let cpuUsage: Double?
    let thermalStatus: ThermalStatus
    let updatedAt: Date

    init(
      available: UInt64,
      total: UInt64,
      ramAvailable: UInt64 = 0,
      ramTotal: UInt64 = 0,
      cpuUsage: Double? = nil,
      thermalStatus: ThermalStatus = .nominal,
      updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
      self.available = available
      self.total = total
      self.ramAvailable = ramAvailable
      self.ramTotal = ramTotal
      self.cpuUsage = cpuUsage
      self.thermalStatus = thermalStatus
      self.updatedAt = updatedAt
    }
  }
}
