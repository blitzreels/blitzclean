import Foundation

/// Why the Mac last restarted, read from the kernel's panic report. macOS deletes that report within about
/// half an hour, so BlitzClean summarizes it as soon as it appears and keeps the summary. On October 25 the
/// report showed a watchdog timeout with 14 MB free and agent typechecks holding 25 GB.
struct RestartReport: Codable, Equatable, Identifiable, Sendable {
  struct Process: Codable, Equatable, Sendable {
    let name: String
    let bytes: UInt64
    /// The agent or app that started it, such as "Claude Code"; nil when nothing recognizable did.
    let startedBy: String?
    /// The project folder it ran in, from BlitzClean's own history; nil when that history had no match.
    var project: String?

    var label: String { project.map { "\(name) · \($0)" } ?? name }
  }

  let id: String
  let date: Date
  let memoryRanOut: Bool
  /// The kernel's first line, such as "watchdog timeout: no checkins from watchdogd in 91 seconds".
  let reason: String
  let residentBytes: UInt64
  var top: [Process]
  /// How many times macOS closed apps for memory in the six hours before.
  var memoryKills: Int

  var title: String {
    let time = date.formatted(
      date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    return memoryRanOut
      ? "Your Mac restarted at \(time) because memory ran out"
      : "Your Mac restarted at \(time) after a system error"
  }

  var summary: String {
    top.prefix(3).map { process in
      let owner = process.startedBy.map { " (\($0))" } ?? ""
      return "\(process.label) \(ByteText.compact(process.bytes))\(owner)"
    }.joined(separator: ", ")
  }
}

enum RestartReportParser {
  struct Input {
    let id: String
    let text: String
    let physicalMemory: UInt64
  }

  static func panic(_ input: Input) -> RestartReport? {
    let parts = input.text.split(separator: "\n", maxSplits: 1)
    guard parts.count == 2,
      let header = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
      let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any],
      let date = timestamp(header["timestamp"] as? String)
    else { return nil }
    let panicString = body["panicString"] as? String ?? ""
    let reason = String(
      (panicString.split(separator: "\n").first ?? "")
        .replacingOccurrences(
          of: #"^panic\(cpu \d+ caller 0x[0-9a-f]+\): "#, with: "", options: .regularExpression))
    let processes = body["processByPid"] as? [String: [String: Any]] ?? [:]
    let resident = processes.values.reduce(UInt64(0)) {
      $0 + UInt64(max(0, ($1["residentMemoryBytes"] as? Int) ?? 0))
    }
    let status = body["memoryStatus"] as? [String: Any]
    let pages = status?["memoryPages"] as? [String: Any]
    let pageSize = UInt64(status?["pageSize"] as? Int ?? 16_384)
    let free = UInt64(pages?["free"] as? Int ?? Int.max / 2) * pageSize
    let memoryRanOut =
      free < 256 * 1_024 * 1_024
      || (input.physicalMemory > 0 && Double(resident) > Double(input.physicalMemory) * 1.3)
    let top = processes.compactMap { pid, process -> RestartReport.Process? in
      guard let name = process["procname"] as? String, name != "kernel_task",
        let bytes = process["residentMemoryBytes"] as? Int, bytes > 0
      else { return nil }
      return .init(
        name: name, bytes: UInt64(bytes), startedBy: owner(.init(pid: pid, processes: processes)))
    }.sorted { $0.bytes > $1.bytes }.prefix(5)
    return RestartReport(
      id: input.id, date: date, memoryRanOut: memoryRanOut, reason: reason,
      residentBytes: resident, top: Array(top), memoryKills: 0)
  }

  struct OwnerInput {
    let pid: String
    let processes: [String: [String: Any]]
  }

  /// Claude Code runs as a binary named after its version, such as `2.1.310`.
  static func owner(_ input: OwnerInput) -> String? {
    var current = input.processes[input.pid]?["parentPid"] as? Int
    var hops = 0
    while let pid = current, pid > 1, hops < 20, let process = input.processes[String(pid)] {
      let name = process["procname"] as? String ?? ""
      if name == "claude" || name.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
      {
        return "Claude Code"
      }
      if name == "codex" { return "Codex" }
      current = process["parentPid"] as? Int
      hops += 1
    }
    return nil
  }

  struct AttachInput {
    let report: RestartReport
    let events: [MemoryIncident]
  }

  /// Panic reports name processes but not their folders. BlitzClean's history from the ten minutes before
  /// the restart does, so each process takes the project of the largest unclaimed group with its name and
  /// owner.
  static func attachProjects(_ input: AttachInput) -> RestartReport {
    guard
      let last = input.events.filter({
        $0.resources != nil && $0.date <= input.report.date
          && input.report.date.timeIntervalSince($0.date) <= 600
      }).max(by: { $0.date < $1.date }),
      var groups = last.resources
    else { return input.report }
    var report = input.report
    report.top = report.top.map { process in
      var named = process
      guard
        let index = groups.indices.filter({
          groups[$0].name == process.name && groups[$0].project != nil
            && (process.startedBy == nil || groups[$0].owner == process.startedBy)
        }).max(by: { groups[$0].memoryBytes < groups[$1].memoryBytes })
      else { return named }
      named.project = groups[index].project
      groups.remove(at: index)
      return named
    }
    return report
  }

  /// The date of a JetsamEvent report, from its one-line header.
  static func header(_ text: String) -> Date? {
    guard let line = text.split(separator: "\n", maxSplits: 1).first,
      let header = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    else { return nil }
    return timestamp(header["timestamp"] as? String)
  }

  static func timestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
    return formatter.date(from: value)
  }
}

enum RestartReportScanner {
  static let directories = [
    "/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports/Retired",
  ]

  struct Input: Sendable {
    let known: Set<String>
    let directories: [String]
  }

  /// New panic reports from the last week; panic files run to a few MB, so known ones are skipped by name.
  static func scan(_ input: Input) -> [RestartReport] {
    let weekAgo = Date.now.addingTimeInterval(-7 * 86_400)
    var reports: [RestartReport] = []
    var jetsams: [Date] = []
    for directory in input.directories {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
      for name in names {
        let path = directory + "/" + name
        if name.hasPrefix("JetsamEvent"), let handle = FileHandle(forReadingAtPath: path) {
          let head = String(decoding: handle.readData(ofLength: 1_024), as: UTF8.self)
          try? handle.close()
          if let date = RestartReportParser.header(head) { jetsams.append(date) }
          continue
        }
        guard name.hasSuffix(".panic"), !input.known.contains(name),
          let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[
            .modificationDate] as? Date, modified > weekAgo,
          let data = FileManager.default.contents(atPath: path), data.count <= 32 * 1_024 * 1_024,
          let report = RestartReportParser.panic(
            .init(
              id: name, text: String(decoding: data, as: UTF8.self),
              physicalMemory: ProcessInfo.processInfo.physicalMemory))
        else { continue }
        reports.append(report)
      }
    }
    return reports.map { report in
      var counted = report
      counted.memoryKills =
        jetsams.filter {
          $0 <= report.date && report.date.timeIntervalSince($0) <= 6 * 3_600
        }.count
      return counted
    }
  }
}

/// Keeps restart summaries after macOS deletes the panic reports they came from.
struct RestartReportStore {
  let url: URL
  static let dismissedKey = "restart.dismissed.v1"

  func load() -> [RestartReport] {
    guard let data = try? Data(contentsOf: url),
      let reports = try? JSONDecoder().decode([RestartReport].self, from: data)
    else { return [] }
    return reports
  }

  func save(_ reports: [RestartReport]) {
    let kept = Array(reports.sorted { $0.date > $1.date }.prefix(20))
    guard let data = try? JSONEncoder().encode(kept) else { return }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

@MainActor
final class RestartReportModel: ObservableObject {
  @Published private(set) var reports: [RestartReport] = []
  @Published private(set) var dismissed: Set<String>
  private let store: RestartReportStore?
  private var timer: Timer?
  private var scanning = false

  init() {
    store = AppBrand.isInstalledApp ? .init(url: AppData.file("restart-reports.json")) : nil
    dismissed = Set(
      UserDefaults.standard.stringArray(forKey: RestartReportStore.dismissedKey) ?? [])
    reports = store?.load() ?? []
    scan()
    let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.scan() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// The latest restart from the last three days that nobody dismissed.
  var current: RestartReport? {
    reports.filter {
      !dismissed.contains($0.id) && Date.now.timeIntervalSince($0.date) < 3 * 86_400
    }.max { $0.date < $1.date }
  }

  func dismiss(_ report: RestartReport) {
    dismissed.insert(report.id)
    UserDefaults.standard.set(Array(dismissed), forKey: RestartReportStore.dismissedKey)
  }

  /// Adds newly read restarts and keeps them on disk.
  func record(_ found: [RestartReport]) {
    guard !found.isEmpty else { return }
    reports = (reports + found).sorted { $0.date > $1.date }
    store?.save(reports)
  }

  func scan() {
    guard !scanning else { return }
    scanning = true
    let input = RestartReportScanner.Input(
      known: Set(reports.map(\.id)), directories: RestartReportScanner.directories)
    let history = store.map { _ in MemoryIncidentStore(url: AppData.file("memory-history.json")) }
    Task {
      var found = await Task.detached(priority: .utility) { RestartReportScanner.scan(input) }.value
      if !found.isEmpty, let history {
        let events = await history.load().events
        found = found.map { RestartReportParser.attachProjects(.init(report: $0, events: events)) }
      }
      record(found)
      scanning = false
    }
  }
}
