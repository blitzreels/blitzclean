import Foundation
import Testing

@testable import BlitzClean

struct RepoWorkspaceTests {
  private static let gigabyte: UInt64 = 1_073_741_824

  private struct AgentFixture {
    let id: String
    let directory: String?
    let gigabytes: UInt64
  }

  private func agent(_ fixture: AgentFixture) -> AIThread {
    AIThread(
      id: fixture.id, tool: .claudeCode, name: fixture.id, directory: fixture.directory,
      terminal: nil, startedAt: nil, processIDs: [], memoryBytes: fixture.gigabytes * Self.gigabyte,
      cpuPercent: 0, isPaused: false, isDetached: false)
  }

  private func project(_ directory: String) -> WorkspaceProject {
    WorkspaceProject(
      directory: directory,
      preference: .init(
        directory: directory, name: URL(fileURLWithPath: directory).lastPathComponent,
        keepRunning: false, startCommand: nil),
      resources: [
        ResourceProcess(
          processID: 10, parentProcessID: 1, name: "node", owner: "Terminal", directory: directory,
          memoryBytes: Self.gigabyte, cpuPercent: 1, isTool: true, executable: "/opt/node")
      ], servers: [])
  }

  private func checkout(_ path: String) -> GitCheckout {
    GitCheckout(
      path: path, commonDirectory: "/dev/app/.git", branch: "main", changes: 0, ahead: 0,
      behind: 0)
  }

  @Test func statusHeaderGivesBranchUpstreamDistanceAndChanges() throws {
    let checkout = try #require(
      GitCheckoutReader.parse(
        .init(
          path: "/dev/app", commonDirectory: "/dev/app/.git",
          status: "## feat/x...origin/feat/x [ahead 2, behind 1]\n M a.swift\n?? b.swift\n")))
    #expect(checkout.branch == "feat/x")
    #expect(checkout.ahead == 2)
    #expect(checkout.behind == 1)
    #expect(checkout.changes == 2)
  }

  @Test func detachedAndUnbornHeadsAreReadable() throws {
    let detached = try #require(
      GitCheckoutReader.parse(
        .init(path: "/a", commonDirectory: "/a/.git", status: "## HEAD (no branch)\n")))
    #expect(detached.branch == nil)
    let unborn = try #require(
      GitCheckoutReader.parse(
        .init(path: "/a", commonDirectory: "/a/.git", status: "## No commits yet on main\n")))
    #expect(unborn.branch == "main")
  }

  @Test func worktreesOfOneRepositoryShareAGroupWithTheirAgents() {
    let output = RepoGrouping.group(
      .init(
        projects: [project("/dev/app"), project("/dev/app-wt"), project("/opt/homebrew")],
        agents: [
          agent(.init(id: "a", directory: "/dev/app/src", gigabytes: 2)),
          agent(.init(id: "b", directory: "/dev/app-wt", gigabytes: 1)),
        ],
        checkouts: ["/dev/app": checkout("/dev/app"), "/dev/app-wt": checkout("/dev/app-wt")],
        worktrees: [
          "/dev/app/.git": [
            .init(
              path: "/dev/app", head: "", branch: "refs/heads/main", locked: false, bare: false,
              prunable: false, primary: true),
            .init(
              path: "/dev/app-wt", head: "", branch: "refs/heads/feat", locked: false,
              bare: false, prunable: false, primary: false),
            .init(
              path: "/dev/app-old", head: "", branch: "refs/heads/old", locked: false,
              bare: false, prunable: false, primary: false),
          ]
        ]))
    #expect(output.repos.count == 1)
    let repo = output.repos[0]
    #expect(repo.name == "app")
    #expect(repo.active.map(\.path) == ["/dev/app", "/dev/app-wt"])
    #expect(repo.active[0].isPrimary)
    #expect(repo.agentCount == 2)
    #expect(repo.idle.map(\.path) == ["/dev/app-old"])
    #expect(output.others.map(\.directory) == ["/opt/homebrew"])
  }

  @Test func agentInAQuietWorktreeStillShowsUp() {
    let output = RepoGrouping.group(
      .init(
        projects: [],
        agents: [agent(.init(id: "a", directory: "/dev/app/pkg", gigabytes: 2))],
        checkouts: ["/dev/app": checkout("/dev/app")], worktrees: [:]))
    #expect(output.repos.first?.active.first?.agents.map(\.id) == ["a"])
    #expect(output.repos.first?.memoryBytes == 2 * Self.gigabyte)
  }

  @Test func budgetLeavesAReserveAndUsesTheMedianSession() {
    let agents = [1, 2, 3].map {
      agent(.init(id: "\($0)", directory: nil, gigabytes: UInt64($0)))
    }
    let roomy = AgentBudget.make(
      .init(agents: agents, availableBytes: 10 * Self.gigabyte, pressure: .normal))
    #expect(roomy.typicalBytes == 2 * Self.gigabyte)
    #expect(roomy.room == 3)
    let full = AgentBudget.make(
      .init(agents: agents, availableBytes: 5 * Self.gigabyte, pressure: .normal))
    #expect(full.room == 0)
    #expect(full.mix == ["Claude Code ×3"])
    let swapping = AgentBudget.make(
      .init(agents: agents, availableBytes: 20 * Self.gigabyte, pressure: .warning))
    #expect(swapping.room == 0)
  }

  @Test func guardWarnsOnlyWhenANewSessionStartsWithoutRoom() {
    func budget(_ sessions: Int, room: Int) -> AgentBudget {
      AgentBudget(
        sessions: sessions, memoryBytes: 0, room: room, typicalBytes: Self.gigabyte, mix: [])
    }
    var gate = AgentGuardGate()
    let start = Date(timeIntervalSince1970: 0)
    let readings: [(sessions: Int, room: Int, seconds: TimeInterval)] = [
      (5, 0, 0), (6, 0, 0), (7, 0, 60), (7, 0, 3600), (8, 0, 3600), (9, 2, 9000),
    ]
    var sent: [Bool] = []
    for reading in readings {
      sent.append(
        gate.shouldSend(
          .init(
            budget: budget(reading.sessions, room: reading.room),
            date: start.addingTimeInterval(reading.seconds))))
    }
    #expect(sent == [false, true, false, false, true, false])
  }

  @Test func runtimeCopiesKnowWhichDownloadTheyCameFrom() throws {
    let asset = "/System/Library/AssetsV2/x/abc.asset"
    let copies = try #require(
      SimulatorRuntimeCopies.read(
        """
        {"A": {"identifier": "A", "build": "22G86", "parentImagePath": "\(asset)/AssetData/a.dmg"},
         "B": {"identifier": "B", "build": "22E238", "path": "/Library/Developer/CoreSimulator/Cryptex/b.dmg"}}
        """))
    #expect(copies.count == 2)
    #expect(copies.first { $0.identifier == "A" }?.uses(asset) == true)
    #expect(copies.first { $0.identifier == "B" }?.uses(asset) == false)
    #expect(SimulatorRuntimeCopies.read("not json") == nil)
  }
}
