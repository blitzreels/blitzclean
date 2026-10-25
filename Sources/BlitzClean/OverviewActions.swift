import Foundation

/// What an Overview button does. The view performs it; building problems never touches a model.
enum OverviewFix {
  case freeDisk([DriveUnit])
  case closeIdle([ResourceConsumer])
  case stop(ResourceConsumer)
  case pause(ResourceConsumer)
  case quitAgents([AIThread])
  case open(CleanPage)
  case dismissRestart(RestartReport)
  case stopBuild(BuildBrakeEntry)
  case openDrive
  case openCleanup(StorageCleanupFocus)
}

struct OverviewLink {
  let title: String
  let fix: OverviewFix
}

/// One problem on Overview, said plainly, with the one button that fixes it.
struct OverviewProblem: Identifiable {
  let id: String
  let symbol: String
  /// The problem, such as "Your disk is almost full".
  let title: String
  /// Why it matters and what the button does, in one sentence.
  let detail: String
  /// 2 when the Mac is already struggling, 1 when it soon will, 0 when it is only worth doing.
  let urgency: Int
  let fixTitle: String
  let fix: OverviewFix
  /// What the fix touches, such as "Old iOS simulators (iOS 18.4) · 9 GB"; nil when it is obvious.
  let includes: String?
  /// Smaller follow-ups that need a look first, shown as quiet links.
  let more: [OverviewLink]
}

enum OverviewProblems {
  /// Everything Overview decides from, read once per render.
  struct Input {
    let diskAvailable: UInt64
    let diskTotal: UInt64
    let units: [DriveUnit]
    /// iOS downloads macOS protects; named, never offered.
    let protectedRuntimePaths: Set<String>
    let dependencyBytes: UInt64
    let oldFileBytes: UInt64
    let ramAvailable: UInt64
    let swapBytes: UInt64
    let memory: BlitzStatusTone
    let idle: [ResourceConsumer]
    /// The largest memory user that can be stopped, with its verb (Quit or Stop).
    let largest: (consumer: ResourceConsumer, verb: String)?
    let detachedAgents: [AIThread]
    let agents: AgentBudget
    /// A program pinned at high CPU for minutes.
    let runaway: ResourceConsumer?
    let frozenApps: Int
    /// The last restart nobody dismissed, from the kernel's panic report.
    let restart: RestartReport?
    /// Builds paused so long that memory can no longer release them.
    let stuckBuilds: [BuildBrakeEntry]
  }

  static func make(_ input: Input) -> [OverviewProblem] {
    order(
      [
        restart(input), stuckBuild(input), disk(input), memory(input), agents(input), cpu(input),
        apps(input),
      ].compactMap { $0 })
  }

  /// The worst problem first; ties keep the order they were found in (disk, memory, agents, CPU, apps).
  static func order(_ problems: [OverviewProblem]) -> [OverviewProblem] {
    problems.enumerated().sorted {
      $0.element.urgency != $1.element.urgency
        ? $0.element.urgency > $1.element.urgency : $0.offset < $1.offset
    }.map(\.element)
  }

  private static func restart(_ input: Input) -> OverviewProblem? {
    guard let report = input.restart else { return nil }
    let kills =
      report.memoryKills > 0
      ? " macOS had already closed apps \(report.memoryKills) times in the hours before." : ""
    let brake =
      BuildBrakePolicy.enabled
      ? " The build brake now pauses builds like these before memory runs out."
      : " Turn on \"Pause builds before memory runs out\" in Settings to stop builds like these first."
    return OverviewProblem(
      id: "restart", symbol: "exclamationmark.arrow.triangle.2.circlepath", title: report.title,
      detail: (report.memoryRanOut
        ? "These held the most memory: \(report.summary)." : "\(report.reason).") + kills
        + (report.memoryRanOut ? brake : ""),
      urgency: 1, fixTitle: "Got It", fix: .dismissRestart(report),
      includes: report.memoryRanOut ? "Kernel: \(report.reason)" : nil,
      more: [.init(title: "See what uses memory now", fix: .open(.memory))])
  }

  private static func stuckBuild(_ input: Input) -> OverviewProblem? {
    guard let entry = input.stuckBuilds.max(by: { $0.process.footprint < $1.process.footprint })
    else { return nil }
    let size = ByteText.compact(entry.process.footprint)
    return OverviewProblem(
      id: "stuck-build", symbol: "pause.circle",
      title: "\(entry.process.label) is paused and holds \(size)",
      detail:
        "BlitzClean paused it before memory ran out. Memory is still short, so it can't resume. "
        + "Stop frees its memory; whatever it was building is lost.",
      urgency: 2, fixTitle: "Stop · \(size)", fix: .stopBuild(entry), includes: nil,
      more: [.init(title: "Resume or stop on Memory", fix: .open(.memory))])
  }

  static func urgency(_ tone: BlitzStatusTone) -> Int {
    switch tone {
    case .critical: 2
    case .warning: 1
    case .good, .working, .muted: 0
    }
  }

  static func diskTone(_ input: Input) -> BlitzStatusTone {
    diskTone(available: input.diskAvailable, total: input.diskTotal)
  }

  /// The same rule as the menu bar and sidebar: free bytes against the 30 GB reserve, not a percentage.
  static func diskTone(available: UInt64, total: UInt64) -> BlitzStatusTone {
    let tone = BlitzStatusTone.forDisk(DiskCapacityInput(available: available, total: total))
    return tone == .muted ? .good : tone
  }

  /// Rebuildable things deleted together with one confirmation: old listed simulators, caches and the Trash.
  static func safeDiskUnits(_ input: Input) -> [DriveUnit] {
    let runtimes = input.units.filter {
      $0.removal == .simulatorRuntime && !input.protectedRuntimePaths.contains($0.paths.first ?? "")
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    let trash = input.units.filter { $0.removal == .emptyTrash && $0.bytes >= 100_000_000 }
    let cacheUnits = input.units.filter {
      $0.group == .caches && $0.removal == .deleteContents && $0.bytes > 0
    }
    let caches = total(cacheUnits) >= 500_000_000 ? cacheUnits : []
    return Array(runtimes.dropLast()) + caches + trash
  }

  private static func disk(_ input: Input) -> OverviewProblem? {
    let tone = diskTone(input)
    let safe = safeDiskUnits(input)
    let safeBytes = total(safe)
    guard tone != .good || safeBytes >= 10_000_000_000 else { return nil }
    let free = ByteText.compact(input.diskAvailable)
    let protected = input.units.filter {
      input.protectedRuntimePaths.contains($0.paths.first ?? "")
    }
    let protectedNote =
      protected.isEmpty
      ? ""
      : " Old downloads of \(protected.map(\.title).joined(separator: " and ")) "
        + "(\(ByteText.compact(total(protected)))) stay for now: macOS refused to remove them while "
        + "the disk was nearly full. Delete them on Storage to try again."
    var parts: [String] = []
    let runtimes = safe.filter { $0.removal == .simulatorRuntime }
    if !runtimes.isEmpty {
      parts.append(
        "Old iOS simulators (\(runtimes.map(\.title).joined(separator: ", "))) · "
          + ByteText.compact(total(runtimes)))
    }
    let caches = safe.filter { $0.group == .caches }
    if !caches.isEmpty {
      parts.append("\(caches.count) cache folders · " + ByteText.compact(total(caches)))
    }
    if let trash = safe.first(where: { $0.removal == .emptyTrash }) {
      parts.append("Trash · " + ByteText.compact(trash.bytes))
    }
    var more: [OverviewLink] = []
    if input.dependencyBytes >= 1_000_000_000 {
      more.append(
        .init(
          title: "Review unused node_modules · \(ByteText.compact(input.dependencyBytes))",
          fix: .openCleanup(.projects)))
    }
    if input.oldFileBytes >= 500_000_000 {
      more.append(
        .init(
          title: "Review old downloads · \(ByteText.compact(input.oldFileBytes))",
          fix: .openCleanup(.oldFiles)))
    }
    let title =
      switch tone {
      case .critical: "Your disk is almost full"
      case .warning: "Your disk is getting full"
      case .good, .working, .muted: "Free up disk space"
      }
    guard !safe.isEmpty else {
      return OverviewProblem(
        id: "disk", symbol: "internaldrive", title: title,
        detail: "\(free) left. Nothing can be deleted automatically, so look at what is largest."
          + protectedNote,
        urgency: urgency(tone), fixTitle: "See what fills the disk", fix: .openDrive,
        includes: nil, more: more)
    }
    return OverviewProblem(
      id: "disk", symbol: "internaldrive", title: title,
      detail: "\(free) left. Deleting things apps rebuild by themselves frees up to "
        + "\(ByteText.compact(safeBytes)). Your files are not touched." + protectedNote,
      urgency: urgency(tone),
      // Caches keep what apps have open or used recently, so their size is an upper bound.
      fixTitle: caches.isEmpty
        ? "Free \(ByteText.compact(safeBytes))" : "Free up to \(ByteText.compact(safeBytes))",
      fix: .freeDisk(safe), includes: "Deletes: " + parts.joined(separator: "  ·  "),
      more: more + [.init(title: "See what fills the disk", fix: .openDrive)])
  }

  private static func memory(_ input: Input) -> OverviewProblem? {
    let idleBytes = input.idle.reduce(0) { $0 + $1.memoryBytes }
    let isShort = input.memory == .warning || input.memory == .critical
    guard isShort || idleBytes >= 2_000_000_000 else { return nil }
    let title =
      switch input.memory {
      case .critical: "Memory is full"
      case .warning: "Memory is running low"
      case .good, .working, .muted: "Idle apps hold memory"
      }
    let state =
      input.swapBytes >= 1_073_741_824
      ? "\(ByteText.compact(input.ramAvailable)) free and \(ByteText.compact(input.swapBytes)) "
        + "pushed to disk, which slows every app."
      : "\(ByteText.compact(input.ramAvailable)) free."
    var more: [OverviewLink] = []
    if !input.detachedAgents.isEmpty {
      let bytes = input.detachedAgents.reduce(0) { $0 + $1.memoryBytes }
      more.append(
        .init(
          title:
            "Quit \(input.detachedAgents.count) AI sessions whose terminal closed · \(ByteText.compact(bytes))",
          fix: .quitAgents(input.detachedAgents)))
    }
    let seeMemory = OverviewLink(title: "See what uses memory", fix: .open(.memory))
    if !input.idle.isEmpty {
      return OverviewProblem(
        id: "memory", symbol: "memorychip", title: title,
        detail: state + " \(input.idle.count) apps and sessions have done nothing for 30 minutes.",
        urgency: urgency(input.memory), fixTitle: "Close idle · \(ByteText.compact(idleBytes))",
        fix: .closeIdle(input.idle), includes: "Closes: " + namesWithCounts(input.idle.map(\.name)),
        more: more + [seeMemory])
    }
    if let largest = input.largest {
      return OverviewProblem(
        id: "memory", symbol: "memorychip", title: title,
        detail: state
          + " \(largest.consumer.name) uses the most: \(ByteText.compact(largest.consumer.memoryBytes)).",
        urgency: urgency(input.memory), fixTitle: "\(largest.verb) \(short(largest.consumer.name))",
        fix: .stop(largest.consumer), includes: nil, more: more + [seeMemory])
    }
    return OverviewProblem(
      id: "memory", symbol: "memorychip", title: title, detail: state,
      urgency: urgency(input.memory), fixTitle: seeMemory.title, fix: seeMemory.fix,
      includes: nil, more: more)
  }

  private static func agents(_ input: Input) -> OverviewProblem? {
    let budget = input.agents
    guard budget.sessions > 0, budget.room == 0 else { return nil }
    return OverviewProblem(
      id: "agents", symbol: "person.2", title: "\(budget.sessions) AI agents are running",
      detail:
        "Together they hold \(ByteText.compact(budget.memoryBytes)). This Mac has no room for "
        + "another one. Finish or pause some before starting more.",
      urgency: 1, fixTitle: "See agents", fix: .open(.projects),
      includes: budget.mix.joined(separator: " · "), more: [])
  }

  private static func cpu(_ input: Input) -> OverviewProblem? {
    guard let busy = input.runaway else { return nil }
    return OverviewProblem(
      id: "cpu", symbol: "cpu", title: "\(busy.name) is maxing out the CPU",
      detail: "It has used \(CPUText.cores(busy.cpuPercent)) for over 5 minutes. "
        + "Pausing frees the CPU now and keeps its work; Resume it later.",
      urgency: 1, fixTitle: "Pause", fix: .pause(busy), includes: nil, more: [])
  }

  private static func apps(_ input: Input) -> OverviewProblem? {
    guard input.frozenApps > 0 else { return nil }
    return OverviewProblem(
      id: "apps", symbol: "waveform.path.ecg",
      title: input.frozenApps == 1 ? "An app is frozen" : "\(input.frozenApps) apps are frozen",
      detail: "Revive tries to wake them without losing their work.", urgency: 2,
      fixTitle: "Revive", fix: .open(.recovery), includes: nil, more: [])
  }

  private static func total(_ units: [DriveUnit]) -> UInt64 { units.reduce(0) { $0 + $1.bytes } }

  private static func short(_ name: String) -> String {
    name.count > 18 ? String(name.prefix(17)) + "…" : name
  }

  /// "blitzreels ×2, easymix ×2, Slack", most frequent first, at most four names.
  static func namesWithCounts(_ names: [String]) -> String {
    var order: [String] = []
    var counts: [String: Int] = [:]
    for name in names {
      if counts[name] == nil { order.append(name) }
      counts[name, default: 0] += 1
    }
    let ranked = order.enumerated().sorted {
      counts[$0.element]! != counts[$1.element]!
        ? counts[$0.element]! > counts[$1.element]! : $0.offset < $1.offset
    }.map(\.element)
    let shown = ranked.prefix(4).map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }
    return shown.joined(separator: ", ")
      + (ranked.count > 4 ? " and \(ranked.count - 4) more" : "")
  }
}
