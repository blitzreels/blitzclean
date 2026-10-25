import Foundation
import Testing

@testable import BlitzClean

struct RestartReportTests {
  private let gib = 1_073_741_824

  /// The shape of the October 25 watchdog panic, trimmed to the fields BlitzClean reads.
  private var panic: String {
    let header =
      #"{"bug_type":"210","timestamp":"2026-10-25 16:16:29.00 +0100","os_version":"macOS 27.0.1"}"#
    let body: [String: Any] = [
      "panicString":
        "panic(cpu 9 caller 0xfffffe0049072cd0): watchdog timeout: no checkins from watchdogd in 91 seconds\nDebugger message: panic",
      "memoryStatus": ["pageSize": 16_384, "memoryPages": ["free": 910]],
      "processByPid": [
        "1": ["procname": "launchd", "parentPid": 0, "residentMemoryBytes": 20_000_000],
        "37776": ["procname": "2.1.309", "parentPid": 1, "residentMemoryBytes": gib],
        "24190": ["procname": "zsh", "parentPid": 37776, "residentMemoryBytes": 1_000_000],
        "24796": ["procname": "node", "parentPid": 24190, "residentMemoryBytes": 16 * gib],
        "74762": ["procname": "tsc", "parentPid": 24190, "residentMemoryBytes": 14 * gib],
        "39218": [
          "procname": "com.apple.Virtualization.Virtua", "parentPid": 1,
          "residentMemoryBytes": 2 * gib,
        ],
      ],
    ]
    let data = try! JSONSerialization.data(withJSONObject: body)
    return header + "\n" + String(decoding: data, as: UTF8.self)
  }

  @Test func watchdogPanicWithNoFreeMemoryReadsAsMemoryRunningOut() throws {
    let report = try #require(
      RestartReportParser.panic(
        .init(id: "panic-full-1.panic", text: panic, physicalMemory: UInt64(36 * gib))))
    #expect(report.memoryRanOut)
    #expect(report.reason == "watchdog timeout: no checkins from watchdogd in 91 seconds")
    #expect(report.top.map(\.name).prefix(2) == ["node", "tsc"])
    #expect(report.top.first?.startedBy == "Claude Code")
    #expect(report.top.first { $0.name.hasPrefix("com.apple.Virtualization") }?.startedBy == nil)
    #expect(report.summary.hasPrefix("node 17 GB (Claude Code), tsc 15 GB (Claude Code)"))
    #expect(report.title.contains("because memory ran out"))
  }

  @Test func scannerKeepsSummariesAndCountsEarlierMemoryKills() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("panic-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try panic.write(
      to: folder.appendingPathComponent("panic-full-1.panic"), atomically: true, encoding: .utf8)
    for (name, time) in [("a", "14:55:46"), ("b", "11:42:45"), ("c", "08:00:00")] {
      try (#"{"bug_type":"298","timestamp":"2026-10-25 \#(time).00 +0100"}"# + "\n{}")
        .write(
          to: folder.appendingPathComponent("JetsamEvent-\(name).ips"), atomically: true,
          encoding: .utf8)
    }
    let reports = RestartReportScanner.scan(.init(known: [], directories: [folder.path]))
    #expect(reports.count == 1)
    #expect(reports.first?.memoryKills == 2)
    #expect(
      RestartReportScanner.scan(.init(known: ["panic-full-1.panic"], directories: [folder.path]))
        .isEmpty)
  }

  @Test func projectsComeFromTheHistoryBeforeTheRestart() throws {
    let report = try #require(
      RestartReportParser.panic(
        .init(id: "panic-full-1.panic", text: panic, physicalMemory: UInt64(36 * gib))))
    func group(_ input: (name: String, project: String, gib: Int)) -> ResourceGroup {
      .init(
        id: UUID().uuidString, name: input.name, owner: "Claude Code", project: input.project,
        processCount: 1, memoryBytes: UInt64(input.gib * gib), unknownMemoryCount: 0)
    }
    let before = MemoryIncident(
      id: UUID(), date: report.date.addingTimeInterval(-90), kind: "sample", detail: "",
      sample: nil, apps: [],
      resources: [
        group(("tsc", "open-seo", 1)), group(("tsc", "blitzreels", 9)),
        group(("node", "blitzreels", 12)),
      ])
    let stale = MemoryIncident(
      id: UUID(), date: report.date.addingTimeInterval(-3_600), kind: "sample", detail: "",
      sample: nil, apps: [], resources: [group(("node", "elsewhere", 30))])
    let named = RestartReportParser.attachProjects(.init(report: report, events: [stale, before]))
    #expect(named.top.map(\.label).prefix(2) == ["node · blitzreels", "tsc · blitzreels"])
    #expect(named.summary.hasPrefix("node · blitzreels 17 GB (Claude Code)"))
  }

  @Test func memoryHistoryJournalSurvivesWithoutAFullRewrite() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("memory-history-\(UUID()).json")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: MemoryIncidentStore.journal(url))
    }
    let store = MemoryIncidentStore(url: url)
    func event(_ kind: String) -> MemoryIncident {
      .init(id: UUID(), date: .now, kind: kind, detail: kind, sample: nil, apps: [])
    }
    var history = MemoryIncidentHistory()
    let first = event("started")
    history.append(first)
    try await store.save(history)
    try await store.append(first)
    try await store.append(event("pressure"))
    try await store.append(event("sample"))
    #expect(await store.load().events.map(\.kind) == ["started", "pressure", "sample"])
    try await store.save(await store.load())
    #expect(!FileManager.default.fileExists(atPath: MemoryIncidentStore.journal(url).path))
    #expect(await store.load().events.count == 3)
  }
}
