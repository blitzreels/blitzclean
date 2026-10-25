import Foundation
import Testing

@testable import BlitzClean

struct OldFilesTests {
  private struct Fixture {
    let root: URL
    var downloads: URL { root.appendingPathComponent("Downloads") }
    var desktop: URL { root.appendingPathComponent("Desktop") }
  }

  private let now = Date(timeIntervalSince1970: 1_790_000_000)
  private var old: Date { now.addingTimeInterval(-300 * 86_400) }

  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("old-files-test-\(UUID())")
    let fixture = Fixture(root: root)
    for folder in [fixture.downloads, fixture.desktop] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    return fixture
  }

  private func write(_ url: URL, modified: Date) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 8_192).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
  }

  private func request(_ fixture: Fixture, limit: Int = 100) -> OldFileScanRequest {
    OldFileScanRequest(
      downloads: fixture.downloads.path, screenshotFolders: [fixture.desktop.path],
      cutoff: OldFileAge.sixMonths.cutoff(from: now), folderEntryLimit: limit,
      eligible: { _ in true },
      usageDates: { url in
        [
          (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        ].compactMap { $0 }
      })
  }

  @Test func findsOldDownloadsAndScreenshotsButKeepsRecentWork() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try write(fixture.downloads.appendingPathComponent("invoice.pdf"), modified: old)
    try write(fixture.downloads.appendingPathComponent("fresh.zip"), modified: now)
    try write(fixture.downloads.appendingPathComponent("movie.mp4.crdownload"), modified: old)
    let project = fixture.downloads.appendingPathComponent("unzipped")
    try write(project.appendingPathComponent("a.txt"), modified: old)
    try write(project.appendingPathComponent("nested/b.txt"), modified: now)
    let stale = fixture.downloads.appendingPathComponent("stale-folder")
    try write(stale.appendingPathComponent("c.txt"), modified: old)
    try write(stale.appendingPathComponent("nested/d.txt"), modified: old)
    for folder in [stale.appendingPathComponent("nested"), stale] {
      try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
    }
    try write(
      fixture.desktop.appendingPathComponent("Screenshot 2025-01-02 at 10.00.00.png"), modified: old
    )
    try write(fixture.desktop.appendingPathComponent("Contract.png"), modified: old)

    let result = OldFileScanner.scan(request(fixture))
    let names = Set(result.items.map(\.name))
    #expect(names == ["invoice.pdf", "stale-folder", "Screenshot 2025-01-02 at 10.00.00.png"])
    #expect(result.items.first { $0.name == "stale-folder" }?.isFolder == true)
    #expect(result.items.first { $0.name == "stale-folder" }!.bytes >= 16_384)
    #expect(result.items.first { $0.name.hasPrefix("Screenshot") }?.source == .screenshots)
  }

  @Test func leavesOutFoldersItCannotReadCompletely() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let folder = fixture.downloads.appendingPathComponent("huge")
    for index in 0..<5 {
      try write(folder.appendingPathComponent("\(index).bin"), modified: old)
    }
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
    let result = OldFileScanner.scan(request(fixture, limit: 3))
    #expect(result.items.isEmpty)
    #expect(result.unmeasured == 1)
  }

  @Test func screenshotNamesNeedAMediaExtension() {
    #expect(OldFileScanner.isScreenshot("Screenshot 2026-01-01 at 09.41.00.png"))
    #expect(OldFileScanner.isScreenshot("Screen Recording 2026-01-01 at 09.41.00.mov"))
    #expect(!OldFileScanner.isScreenshot("Screenshot notes.txt"))
    #expect(!OldFileScanner.isScreenshot("Holiday.png"))
  }

  @Test func undoPutsTrashedItemsBackWithoutOverwriting() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let trash = fixture.root.appendingPathComponent("Trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let original = fixture.downloads.appendingPathComponent("a.pdf")
    let replaced = fixture.downloads.appendingPathComponent("b.pdf")
    try write(trash.appendingPathComponent("a.pdf"), modified: old)
    try write(trash.appendingPathComponent("b.pdf"), modified: old)
    try write(replaced, modified: now)
    let restored = PersonalTrash.restore([
      .init(original: original.path, trashed: trash.appendingPathComponent("a.pdf")),
      .init(original: replaced.path, trashed: trash.appendingPathComponent("b.pdf")),
    ])
    #expect(restored == 1)
    #expect(FileManager.default.fileExists(atPath: original.path))
    #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("b.pdf").path))
  }

  @Test func overviewOffersOldFilesAsAReviewedFinding() {
    var progress = AuditProgress()
    progress.begin(at: now)
    progress.finish(.init(check: .oldFiles, warnings: [], date: now))
    let findings = AuditFindings(
      progress: progress,
      cleanup: .init(
        .init(items: [], dockerBytes: 0, hasSkippedLocations: false, dockerUnavailable: false)),
      quickBytes: 0, canClean: false, pressure: .checking, detachedCount: 0, detachedBytes: 0,
      recoveryCount: 0,
      personalFiles: .init(
        oldCount: 12, oldBytes: 3_000_000_000, oldAge: "6 months", largeCount: 2,
        largeBytes: 900_000_000))
    let finding = findings.recommendations.first { $0.id == "old-files" }
    #expect(finding?.action == .cleanup(.oldFiles))
    #expect(finding?.reward == 3_000_000_000)
  }
}

struct ResourceLeaderTests {
  private let start = Date(timeIntervalSince1970: 1_790_000_000)

  private func sample(_ offset: TimeInterval, cpu: Double, lead: ResourceLead?) -> ResourceSample {
    ResourceSample(
      date: start.addingTimeInterval(offset), cpu: cpu, memory: 0.5, cpuLead: lead,
      memoryLead: nil)
  }

  @Test func helpersCountTowardTheirApp() {
    let previous = [
      CPUCounter(id: 1, name: "Renderer", start: 1, ticks: 0, footprint: 0, group: "Chrome"),
      CPUCounter(id: 2, name: "GPU", start: 1, ticks: 0, footprint: 0, group: "Chrome"),
      CPUCounter(id: 3, name: "node", start: 1, ticks: 0, footprint: 0, group: "node"),
    ]
    let current = [
      CPUCounter(id: 1, name: "Renderer", start: 1, ticks: 600, footprint: 400, group: "Chrome"),
      CPUCounter(id: 2, name: "GPU", start: 1, ticks: 600, footprint: 400, group: "Chrome"),
      CPUCounter(id: 3, name: "node", start: 1, ticks: 1_000, footprint: 700, group: "node"),
    ]
    let leads = CPUProcessReader.leads(
      .init(previous: previous, current: current, seconds: 1, nanosecondsPerTick: 1_000_000))
    #expect(leads.cpu?.name == "Chrome")
    #expect(leads.cpu.map { abs($0.value - 120) < 0.001 } == true)
    #expect(leads.memory == ResourceLead(name: "Chrome", value: 800))
  }

  @Test func appBundlesAndClaudeVersionsGetReadableNames() {
    let chrome =
      "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper.app"
      + "/Contents/MacOS/Google Chrome Helper"
    #expect(
      CPUProcessReader.group(.init(executable: chrome, name: "Google Chrome He", project: "x"))
        == "Google Chrome")
    #expect(
      CPUProcessReader.group(
        .init(
          executable: "/Users/me/.local/share/claude/versions/2.1.90", name: "2.1.90",
          project: nil)) == "Claude Code")
    #expect(
      CPUProcessReader.group(
        .init(executable: "/opt/homebrew/bin/node", name: "node", project: "affonso"))
        == "node · affonso")
    #expect(
      CPUProcessReader.group(
        .init(executable: "/opt/homebrew/bin/node", name: "node", project: nil))
        == "node")
  }

  @Test func projectNamesComeFromTheRepositoryRoot() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("leader-\(UUID())/shop")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("apps/web"), withIntermediateDirectories: true)
    #expect(ProjectNameCache.resolve(root.appendingPathComponent("apps/web").path) == "shop")
  }

  @Test func archiveKeepsTheSpikeAndWhoCausedIt() {
    var history = ResourceHistory.persisted
    let now = Date.now
    let old = now.addingTimeInterval(-3_600)
    let bucket = Double(Int(old.timeIntervalSince1970 / 300)) * 300
    let base = Date(timeIntervalSince1970: bucket + 10)
    history.restore([
      .init(
        date: base, cpu: 0.95, memory: 0.4, cpuLead: .init(name: "Xcode", value: 700),
        memoryLead: .init(name: "Xcode", value: 1)),
      .init(
        date: base.addingTimeInterval(60), cpu: 0.1, memory: 0.8,
        cpuLead: .init(name: "Finder", value: 3), memoryLead: .init(name: "Chrome", value: 9)),
      .init(date: now, cpu: 0.1, memory: 0.5),
    ])
    let archived = history.samples.first!
    #expect(archived.cpu == 0.95)
    #expect(archived.cpuLead?.name == "Xcode")
    #expect(archived.memory == 0.8)
    #expect(archived.memoryLead?.name == "Chrome")
  }

  @Test func ranksByPeakAndTotalsLeadTime() {
    let samples = [
      sample(0, cpu: 0.3, lead: .init(name: "Chrome", value: 80)),
      sample(2, cpu: 0.9, lead: .init(name: "Xcode", value: 650)),
      sample(4, cpu: 0.3, lead: .init(name: "Chrome", value: 90)),
      sample(6, cpu: 0.3, lead: .init(name: "Chrome", value: 85)),
      sample(8, cpu: 0.3, lead: nil),
    ]
    let leaders = ResourceLeaders.rank(.init(samples: samples, kind: .cpu, seconds: 3_600))
    #expect(leaders.map(\.name) == ["Xcode", "Chrome"])
    #expect(leaders[0].systemAtPeak == 0.9)
    #expect(leaders[1].peak == 90)
    #expect(leaders[1].leadDuration == 6)
  }

  @Test func oldHistoryFilesWithoutLeadsStillLoad() throws {
    let json = Data(#"[{"date":800000000,"cpu":0.2,"memory":0.4}]"#.utf8)
    let samples = try JSONDecoder().decode([ResourceSample].self, from: json)
    #expect(samples.first?.cpuLead == nil)
  }
}

struct LargeFileTests {
  @Test func findsBigMediaAndFoldersWithoutCountingNestedFilesTwice() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("large-files-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let downloads = root.appendingPathComponent("Downloads")
    let movies = root.appendingPathComponent("Movies")
    let project = downloads.appendingPathComponent("repo")
    for folder in [downloads.appendingPathComponent("shoot"), movies, project] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(
      at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let big = Data(repeating: 7, count: 300_000)
    try big.write(to: movies.appendingPathComponent("clip.mov"))
    try big.write(to: downloads.appendingPathComponent("photo.jpg"))
    try big.write(to: downloads.appendingPathComponent("shoot/a.mov"))
    try big.write(to: downloads.appendingPathComponent("shoot/b.mov"))
    try big.write(to: project.appendingPathComponent("asset.mov"))
    try Data(repeating: 1, count: 1_000).write(to: downloads.appendingPathComponent("small.png"))
    let result = LargeFileScanner.scan(
      .init(
        fileRoots: [downloads.path, movies.path], folderRoots: [downloads.path],
        minimumFileBytes: 200_000, minimumFolderBytes: 500_000, folderEntryLimit: 100,
        eligible: { _ in true }))
    let kinds = Dictionary(uniqueKeysWithValues: result.items.map { ($0.name, $0.kind) })
    #expect(kinds["shoot"] == .folders)
    #expect(kinds["clip.mov"] == .videos)
    #expect(kinds["photo.jpg"] == .images)
    #expect(kinds["a.mov"] == nil)
    #expect(kinds["repo"] == nil)
    #expect(kinds["asset.mov"] == nil)
    #expect(kinds["small.png"] == nil)
    #expect(result.items.first?.name == "shoot")
  }
}

struct SidebarInsightTests {
  private func snapshot(cpu: Double, diskFree: UInt64) -> SystemSnapshot {
    let gib: UInt64 = 1 << 30
    return SystemSnapshot(
      .init(
        diskAvailable: diskFree * gib, diskTotal: 494 * gib, ramAvailable: 12 * gib,
        ramTotal: 39 * gib, memoryPressure: .normal, cpuUsage: cpu, thermalStatus: .nominal,
        updatedAt: .now))
  }

  @Test func namesWhatIsBusyAndFlagsOnlyProblems() {
    let insights = SidebarInsights.make(
      .init(
        snapshot: snapshot(cpu: 1, diskFree: 6), memoryTone: .good,
        leads: .init(
          cpu: .init(name: "Google Chrome", value: 409),
          memory: .init(name: "ChatGPT", value: 12e9)),
        pressure: .checking, recoveryCount: 2, projectProcesses: [], leftoverCount: 0))
    #expect(insights[.cpu]?.text == "100% · Chrome")
    #expect(insights[.cpu]?.needsAttention == true)
    #expect(insights[.memory]?.text.hasSuffix("· ChatGPT") == true)
    #expect(insights[.memory]?.needsAttention == false)
    #expect(insights[.storage]?.needsAttention == true)
    #expect(insights[.recovery] == .init(text: "2 not responding", tone: .warning))
    #expect(insights[.overview] == nil)
    #expect(insights[.projects]?.text == "None running")
  }

  @Test func usesTheNewestRecordedLeads() {
    let now = Date.now
    let leads = SidebarInsights.latestLeads([
      .init(
        date: now, cpu: 0.2, memory: 0.5, cpuLead: .init(name: "Xcode", value: 300),
        memoryLead: nil),
      .init(date: now.addingTimeInterval(2), cpu: 0.2, memory: 0.5),
    ])
    #expect(leads.cpu?.name == "Xcode")
    #expect(leads.memory == nil)
  }
}

struct BackgroundCostTests {
  private let group = ResourceGroup(
    id: "node", name: "node", owner: "Terminal", project: nil, processCount: 1,
    memoryBytes: 1, unknownMemoryCount: 0)

  private func incident(_ input: (kind: String, age: TimeInterval, now: Date)) -> MemoryIncident {
    MemoryIncident(
      id: UUID(), date: input.now.addingTimeInterval(-input.age), kind: input.kind,
      detail: "", sample: nil, apps: [], resources: [group])
  }

  @Test
  func routineSamplesDropProcessDetailAfterAnHourButIncidentsKeepIt() {
    let now = Date.now
    var history = MemoryIncidentHistory()
    history.append(incident((kind: "sample", age: 7_200, now: now)))
    history.append(incident((kind: "pressure", age: 7_200, now: now)))
    history.append(incident((kind: "sample", age: 60, now: now)))
    history.append(incident((kind: "sample", age: 0, now: now)))
    #expect(history.events.map { $0.resources != nil } == [false, true, true, true])
  }

  @Test
  func historyStampChangesOnlyWhenTheFileChanges() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("stamp-test-\(UUID())/cleanup-history.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = CleanupHistoryStore(url: url)
    #expect(store.stamp() == nil)
    try store.save(CleanupLedger())
    let first = store.stamp()
    #expect(first != nil)
    #expect(store.stamp() == first)
    var ledger = CleanupLedger()
    ledger.record(
      CleanupWin(
        id: "a", date: .now, title: "Removed", paths: ["/tmp/a"], before: nil, after: nil,
        bytes: 1))
    try store.save(ledger)
    #expect(store.stamp() != first)
  }

  @Test
  func processIdentityIsReadOncePerProcessLifetime() {
    let cache = ProcessGroupCache()
    let key = ProcessGroupCache.Key(pid: 42, start: 7)
    #expect(cache.identity(key) == nil)
    #expect(cache.store(.init(key: key, identity: nil)) == nil)
    let stored = cache.store(
      .init(
        key: key,
        identity: .init(name: "node", executable: "/usr/local/bin/node", group: "node · app")
      ))
    #expect(stored?.group == "node · app")
    #expect(cache.identity(key)?.name == "node")
    #expect(cache.identity(.init(pid: 42, start: 8)) == nil)
  }
}

struct PressurePublishingTests {
  private func assessment(_ input: (risk: MemoryRisk, seconds: TimeInterval)) -> PressureAssessment
  {
    PressureAssessment(
      risk: input.risk, limit: .memory, title: input.risk == .normal ? "Fine" : "Short",
      detail: "Swap \(input.seconds)", action: "", date: Date(timeIntervalSince1970: input.seconds))
  }

  @Test
  func backgroundSkipsUnchangedReadingsButNeverAChangedVerdict() {
    let shown = assessment((risk: .normal, seconds: 100))
    #expect(!shown.publishes(.init(next: assessment((risk: .normal, seconds: 102)), active: false)))
    #expect(shown.publishes(.init(next: assessment((risk: .normal, seconds: 102)), active: true)))
    #expect(shown.publishes(.init(next: assessment((risk: .warning, seconds: 102)), active: false)))
    #expect(shown.publishes(.init(next: assessment((risk: .normal, seconds: 106)), active: false)))
  }
}
