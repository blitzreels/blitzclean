import Testing

@testable import BlitzClean

struct MemoryProcessTests {
  @Test func ranksIndividualFootprintsWithoutAggregatingHelpers() {
    let rows = MemoryProcessRanking.ranked(
      .init(
        processes: [
          row(.init(pid: 5, bytes: nil)), row(.init(pid: 3, bytes: 100)),
          row(.init(pid: 2, bytes: 500)), row(.init(pid: 4, bytes: 0)),
        ], query: ""))
    #expect(rows.map(\.processID) == [2, 3, 4, 5])
    #expect(rows.map(\.memoryBytes) == [500, 100, 0, nil])
  }

  @Test func filtersByProcessOwnerPIDAndDirectory() {
    let rows = [row(.init(pid: 456, bytes: 100))]
    for query in [" helper ", "BROWSER", "456", "project"] {
      #expect(MemoryProcessRanking.ranked(.init(processes: rows, query: query)).count == 1)
    }
    #expect(MemoryProcessRanking.ranked(.init(processes: rows, query: "absent")).isEmpty)
  }

  @Test func tiesStayInPIDOrderAndUnknownDoesNotMeanZero() {
    let rows = MemoryProcessRanking.ranked(
      .init(
        processes: [
          row(.init(pid: 7, bytes: nil)), row(.init(pid: 6, bytes: 0)),
          row(.init(pid: 3, bytes: 0)), row(.init(pid: 2, bytes: nil)),
        ], query: ""))
    #expect(rows.map(\.processID) == [3, 6, 2, 7])
  }

  private struct Input {
    let pid: Int32
    let bytes: UInt64?
  }

  private func row(_ input: Input) -> ResourceProcess {
    .init(
      processID: input.pid, parentProcessID: 1, name: "Helper", owner: "Browser",
      directory: "/dev/project", memoryBytes: input.bytes, cpuPercent: 0, isTool: false)
  }
}
