import Foundation
import Testing

@testable import BlitzClean

struct ResourceConsumerTests {
  private func process(
    _ input: (
      pid: Int32, executable: String, owner: String, directory: String?, mb: UInt64, cpu: Double
    )
  ) -> ResourceProcess {
    ResourceProcess(
      processID: input.pid, parentProcessID: 1, name: ResourceOwnership.label(input.executable),
      owner: input.owner, directory: input.directory, memoryBytes: input.mb * 1_048_576,
      cpuPercent: input.cpu, isTool: false, executable: input.executable)
  }

  @Test func groupsHelpersIntoAppsAndTerminalToolsByProject() {
    let resources = [
      process(
        (
          10, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "Google Chrome", nil,
          400, 2
        )),
      process(
        (
          11,
          "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
          "Google Chrome", nil, 600, 1
        )),
      process((20, "/usr/local/bin/node", "cmux", "/Users/me/dev/fmx_ws", 800, 30)),
      process((21, "/usr/local/bin/node", "cmux", "/Users/me/dev/fmx_ws", 200, 0)),
      process((30, "/usr/libexec/cloudd", "Background service", nil, 100, 4)),
    ]
    let consumers = ResourceConsumers.build(
      .init(threads: [], resources: resources, stopped: [20, 21]))
    let chrome = consumers.first { $0.name == "Google Chrome" }
    #expect(chrome?.kind == .app)
    #expect(chrome?.memoryBytes == 1_000 * 1_048_576)
    let node = consumers.first { $0.name == "node · fmx_ws" }
    #expect(node?.kind == .workload)
    #expect(node?.processIDs == [20, 21])
    #expect(node?.isPaused == true)
    #expect(consumers.first { $0.id == ResourceConsumers.systemKey }?.canSignal == false)
  }

  @Test func versionedToolsUseTheirToolName() {
    #expect(ResourceOwnership.label("/Users/me/.local/share/claude/versions/2.1.302") == "claude")
    #expect(ResourceOwnership.label("/usr/local/bin/node") == "node")
  }

  @Test func idleAndRunawayNeedToBeObservedOverTime() {
    let consumer = ResourceConsumer(
      id: "work:node|/x", kind: .workload, name: "node", iconName: "node", processIDs: [1],
      memoryBytes: 2_000_000_000, cpuPercent: 0, directory: "/x", isPaused: false, threadID: nil)
    var hot = consumer
    hot = .init(
      id: hot.id, kind: hot.kind, name: hot.name, iconName: hot.iconName,
      processIDs: hot.processIDs, memoryBytes: hot.memoryBytes, cpuPercent: 300,
      directory: hot.directory, isPaused: false, threadID: nil)
    let start = Date(timeIntervalSince1970: 1_000_000)
    var activity = ConsumerActivity()
    activity.record(.init(consumers: [consumer], date: start))
    #expect(activity.idle(.init(id: consumer.id, now: start)) == 0)
    let later = start.addingTimeInterval(40 * 60)
    #expect(activity.idle(.init(id: consumer.id, now: later)) >= ConsumerActivity.idleAfter)
    let plan = FreeMemoryPlan.idle(
      .init(consumers: [consumer], activity: activity, quittableApps: [], now: later))
    #expect(plan.map(\.id) == [consumer.id])

    activity.record(.init(consumers: [hot], date: later))
    #expect(activity.idle(.init(id: hot.id, now: later)) == 0)
    activity.record(.init(consumers: [hot], date: later.addingTimeInterval(6 * 60)))
    #expect(
      activity.busy(.init(id: hot.id, now: later.addingTimeInterval(6 * 60)))
        >= ConsumerActivity.runawayAfter)
    activity.record(.init(consumers: [consumer], date: later.addingTimeInterval(7 * 60)))
    #expect(activity.busy(.init(id: consumer.id, now: later.addingTimeInterval(7 * 60))) == 0)
  }

  @Test func appsOnlyGoWhenTheyCanBeQuit() {
    let app = ResourceConsumer(
      id: "app:Safari", kind: .app, name: "Safari", iconName: "Safari", processIDs: [5],
      memoryBytes: 2_000_000_000, cpuPercent: 0, directory: nil, isPaused: false, threadID: nil)
    var activity = ConsumerActivity()
    let start = Date(timeIntervalSince1970: 0)
    activity.record(.init(consumers: [app], date: start))
    let later = start.addingTimeInterval(3_600)
    #expect(
      FreeMemoryPlan.idle(
        .init(consumers: [app], activity: activity, quittableApps: [], now: later)
      )
      .isEmpty)
    #expect(
      FreeMemoryPlan.idle(
        .init(consumers: [app], activity: activity, quittableApps: ["Safari"], now: later)
      ).count == 1)
  }

  @Test func macOSProcessesGetPlainNames() {
    #expect(SystemProcessNames.describe("mds_stores").title == "Spotlight indexing")
    #expect(SystemProcessNames.describe("something").title == "something")
  }
}

struct SystemProcessClassificationTests {
  @Test func commandsInUsrBinAreTheUsersWork() {
    let command = ResourceProcess(
      processID: 1, parentProcessID: 1, name: "yes", owner: "Background service", directory: nil,
      memoryBytes: 1, cpuPercent: 99, isTool: false, executable: "/usr/bin/yes")
    let daemon = ResourceProcess(
      processID: 2, parentProcessID: 1, name: "cloudd", owner: "Background service",
      directory: nil, memoryBytes: 1, cpuPercent: 1, isTool: false,
      executable: "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd")
    #expect(!command.isSystem)
    #expect(daemon.isSystem)
  }
}

struct DuplicateThreadTests {
  @Test func aSessionReportedTwiceBecomesOneRow() {
    let thread = AIThread(
      id: "same", tool: .claudeCode, name: "claude", directory: "/tmp/p", terminal: nil,
      startedAt: nil, processIDs: [10], memoryBytes: 100_000_000, cpuPercent: 0, isPaused: false,
      isDetached: false)
    let consumers = ResourceConsumers.build(
      .init(threads: [thread, thread], resources: [], stopped: []))
    #expect(consumers.filter { $0.id == "ai:same" }.count == 1)
  }
}
