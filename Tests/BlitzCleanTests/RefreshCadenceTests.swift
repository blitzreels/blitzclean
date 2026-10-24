import Foundation
import Testing

@testable import BlitzClean

struct RefreshCadenceTests {
  @Test func readersSlowDownInTheBackgroundAndUnderPressure() {
    for reader in RefreshCadence.Reader.allCases {
      let front = RefreshCadence.interval(reader, .init(foreground: true, pressure: .normal))
      let back = RefreshCadence.interval(reader, .init(foreground: false, pressure: .normal))
      let warning = RefreshCadence.interval(reader, .init(foreground: true, pressure: .warning))
      let critical = RefreshCadence.interval(reader, .init(foreground: true, pressure: .critical))
      #expect(back >= front)
      #expect(warning > front)
      #expect(critical > warning)
    }
  }

  @Test func processScanUnderCriticalPressureWaitsAtLeastFifteenSeconds() {
    #expect(
      RefreshCadence.interval(.processes, .init(foreground: true, pressure: .critical)) >= 15)
  }
}

struct MeasuredResultTests {
  private static let gigabyte: UInt64 = 1_000_000_000

  private func change(before: UInt64, after: UInt64) -> MeasuredResult.Change {
    .init(
      before: .init(diskFree: before * Self.gigabyte, memoryFree: before * Self.gigabyte),
      after: .init(diskFree: after * Self.gigabyte, memoryFree: after * Self.gigabyte))
  }

  @Test func reportsTheMeasuredRise() {
    #expect(
      MeasuredResult.disk(change(before: 12, after: 26))
        == "Free disk space went from 12 GB to 26 GB.")
  }

  @Test func saysPlainlyWhenNothingCameBack() {
    #expect(
      MeasuredResult.memory(change(before: 7, after: 7)).hasPrefix("Free memory is still 7 GB"))
  }
}
