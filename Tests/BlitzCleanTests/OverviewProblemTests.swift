import Foundation
import Testing

@testable import BlitzClean

struct OverviewProblemTests {
  private func problem(_ id: String, urgency: Int) -> OverviewProblem {
    OverviewProblem(
      id: id, symbol: "", title: id, detail: "", urgency: urgency, fixTitle: "Fix",
      fix: .openDrive, includes: nil, more: [])
  }

  @Test func worstProblemComesFirstAndTiesKeepTheirOrder() {
    let ordered = OverviewProblems.order([
      problem("disk", urgency: 1), problem("memory", urgency: 2), problem("agents", urgency: 1),
      problem("apps", urgency: 0),
    ])
    #expect(ordered.map(\.id) == ["memory", "disk", "agents", "apps"])
  }

  @Test func toneMapsToUrgency() {
    #expect(OverviewProblems.urgency(.critical) == 2)
    #expect(OverviewProblems.urgency(.warning) == 1)
    #expect(OverviewProblems.urgency(.working) == 0)
  }
}

struct OverviewNameTests {
  @Test func repeatedNamesAreCounted() {
    #expect(
      OverviewProblems.namesWithCounts(["a", "b", "a", "c", "b", "a"]) == "a ×3, b ×2, c")
    #expect(
      OverviewProblems.namesWithCounts(["a", "b", "c", "d", "e"]) == "a, b, c, d and 1 more")
  }
}

struct OverviewBuilderTests {
  private static let gigabyte: UInt64 = 1_000_000_000

  private struct UnitFixture {
    let id: String
    let title: String
    let removal: DriveRemoval
    let group: DriveGroup
    let gigabytes: UInt64
  }

  private func unit(_ fixture: UnitFixture) -> DriveUnit {
    DriveUnit(
      id: fixture.id, title: fixture.title, detail: "", group: fixture.group,
      paths: ["/fixture/\(fixture.id)"], removal: fixture.removal, minimumAge: 0,
      bytes: fixture.gigabytes * Self.gigabyte, folders: 0, partial: false)
  }

  private struct InputFixture {
    let diskFree: UInt64
    let units: [DriveUnit]
    let protected: Set<String>
    let memory: BlitzStatusTone
    let sessions: Int
    let frozen: Int
  }

  private func input(_ fixture: InputFixture) -> OverviewProblems.Input {
    .init(
      diskAvailable: fixture.diskFree * Self.gigabyte, diskTotal: 500 * Self.gigabyte,
      units: fixture.units, protectedRuntimePaths: fixture.protected, dependencyBytes: 0,
      oldFileBytes: 0, ramAvailable: 4 * Self.gigabyte, swapBytes: 0, memory: fixture.memory,
      idle: [], largest: nil, detachedAgents: [],
      agents: AgentBudget(
        sessions: fixture.sessions, memoryBytes: 0, room: 0, typicalBytes: 1, mix: []),
      runaway: nil, frozenApps: fixture.frozen)
  }

  private var simulators: [DriveUnit] {
    [
      unit(
        .init(
          id: "18.4", title: "iOS 18.4", removal: .simulatorRuntime, group: .simulators,
          gigabytes: 9)),
      unit(
        .init(
          id: "18.6", title: "iOS 18.6", removal: .simulatorRuntime, group: .simulators,
          gigabytes: 9)),
      unit(
        .init(
          id: "26.5", title: "iOS 26.5", removal: .simulatorRuntime, group: .simulators,
          gigabytes: 8)),
      unit(.init(id: "npm", title: "npm", removal: .deleteContents, group: .caches, gigabytes: 3)),
    ]
  }

  @Test func fullDiskOffersOldListedSimulatorsAndCachesButNotProtectedOnes() throws {
    let problems = OverviewProblems.make(
      input(
        .init(
          diskFree: 10, units: simulators, protected: ["/fixture/18.4"], memory: .good,
          sessions: 0, frozen: 0)))
    let disk = try #require(problems.first)
    #expect(disk.id == "disk")
    #expect(disk.fixTitle == "Free up to 12 GB")
    guard case .freeDisk(let units) = disk.fix else {
      Issue.record("Expected a disk fix")
      return
    }
    #expect(units.map(\.id) == ["18.6", "npm"])
    #expect(disk.detail.contains("Old downloads of iOS 18.4"))
  }

  @Test func healthyDiskWithLittleToFreeShowsNothing() {
    let problems = OverviewProblems.make(
      input(
        .init(
          diskFree: 300, units: Array(simulators.suffix(2)), protected: [], memory: .good,
          sessions: 0, frozen: 0)))
    #expect(problems.isEmpty)
  }

  @Test func frozenAppsLeadAndAgentsWithoutRoomAppear() {
    let problems = OverviewProblems.make(
      input(
        .init(
          diskFree: 300, units: [], protected: [], memory: .good, sessions: 6, frozen: 1)))
    #expect(problems.map(\.id) == ["apps", "agents"])
  }
}
