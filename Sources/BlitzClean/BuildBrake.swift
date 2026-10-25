import Darwin
import Foundation

/// A compiler, bundler or agent script runtime. On October 25 two agent typechecks and a test run held
/// 45 GB on this 36 GB Mac and the kernel watchdog restarted it, so the brake covers processes that agents
/// started, which project auto-pause leaves alone.
struct BuildBrakeProcess: Codable, Equatable, Sendable {
  let identity: DevProcessIdentity
  let name: String
  let project: String?
  let footprint: UInt64
  /// The agent that started it, such as "Claude Code"; nil when a person did.
  let agent: String?

  var label: String { project.map { "\(name) · \($0)" } ?? name }
}

/// A build seen this sample, with how fast its memory grew over the last few seconds.
struct BuildBrakeCandidate: Equatable, Sendable {
  let process: BuildBrakeProcess
  /// Bytes per second; negative while it shrinks.
  let growth: Double
}

struct BuildBrakeEntry: Codable, Equatable, Sendable {
  let process: BuildBrakeProcess
  let pausedAt: Date
}

enum BuildBrakeDecision: Equatable, Sendable {
  case none
  case pause(BuildBrakeProcess)
  case resume(BuildBrakeEntry)
}

enum BuildBrakePolicy {
  static let key = "pressure.buildBrake.v1"
  static let backgroundKey = "pressure.backgroundBuilds.v1"
  /// The smallest build worth pausing: 1/32 of RAM, never under 512 MB, so 1.1 GB on a 36 GB Mac and
  /// 512 MB on an 8 or 16 GB one.
  static func minimumBytes(_ total: UInt64) -> UInt64 { max(512 * 1_024 * 1_024, total / 32) }
  /// Memory macOS needs for itself; projections count it as already gone.
  static func reserve(_ total: UInt64) -> UInt64 { total / 10 }
  /// While memory is calm (normal, a fifth of RAM free, nothing paused, no build growing fast at the last
  /// pass) the process pass runs this often instead of every 2 seconds. A build that starts growing is
  /// seen within 6 seconds, and from then on every 2.
  static let calmInterval: TimeInterval = 6
  /// A build restarted this soon after being stopped while paused counts as a retry.
  static let retryWindow: TimeInterval = 180
  static let pauseSpacing: TimeInterval = 4
  static let resumeSpacing: TimeInterval = 15
  /// Memory projected to run out sooner than this pauses the fastest-growing build.
  static let exhaustionHorizon: TimeInterval = 60
  static let fastGrowth: Double = 50 * 1_024 * 1_024
  /// A pause that has not been released after this long while memory stays short needs a person.
  static let stuckAfter: TimeInterval = 120

  static let compilers: Set<String> = [
    "tsc", "tsgo", "esbuild", "swc", "rustc", "cargo", "swift-frontend", "swift-build", "clang",
    "clang++", "ld", "go",
  ]
  static let runtimes: Set<String> = ["node", "bun", "deno"]
  static let agents: Set<String> = ["claude", "codex"]

  static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
  static var backgroundEnabled: Bool {
    UserDefaults.standard.object(forKey: backgroundKey) as? Bool ?? true
  }

  struct QualifyInput {
    let name: String
    let startedByAgent: Bool
  }

  /// Compilers always count; script runtimes only when an agent started them, so a dev server or editor
  /// helper someone runs by hand keeps its speed.
  static func qualifies(_ input: QualifyInput) -> Bool {
    compilers.contains(input.name) || (runtimes.contains(input.name) && input.startedByAgent)
  }

  struct Input {
    let risk: MemoryRisk
    let total: UInt64
    let available: UInt64
    let date: Date
    let candidates: [BuildBrakeCandidate]
    let paused: [BuildBrakeEntry]
    let lastAction: Date
  }

  /// Warning or worse pauses the largest running build; rising swap pauses one that holds a quarter of RAM.
  /// Before either, memory projected to run out within a minute pauses the build growing fastest. Paused
  /// builds resume smallest first, one at a time, once memory is normal with a third of RAM free and no
  /// running build would exhaust it within two minutes.
  static func decide(_ input: Input) -> BuildBrakeDecision {
    let elapsed = input.date.timeIntervalSince(input.lastAction)
    let running = input.candidates.filter { !$0.process.identity.process.stopped }
    let threshold: UInt64? =
      switch input.risk {
      case .critical, .warning: minimumBytes(input.total)
      case .growing: max(minimumBytes(input.total), input.total / 4)
      case .normal: nil
      }
    if elapsed >= pauseSpacing {
      if let threshold,
        let largest = running.filter({ $0.process.footprint >= threshold })
          .max(by: { $0.process.footprint < $1.process.footprint })
      {
        return .pause(largest.process)
      }
      if secondsLeft(.init(available: input.available, total: input.total, candidates: running))
        < exhaustionHorizon,
        let fastest = running.filter({
          $0.process.footprint >= minimumBytes(input.total) && $0.growth >= fastGrowth
        }).max(by: { $0.growth < $1.growth })
      {
        return .pause(fastest.process)
      }
    }
    guard input.risk == .normal, elapsed >= resumeSpacing, input.available >= input.total / 3,
      secondsLeft(.init(available: input.available, total: input.total, candidates: running))
        >= 2 * exhaustionHorizon,
      let smallest = input.paused.filter({ input.date.timeIntervalSince($0.pausedAt) >= 30 })
        .min(by: { $0.process.footprint < $1.process.footprint })
    else { return .none }
    return .resume(smallest)
  }

  struct ProjectionInput {
    let available: UInt64
    let total: UInt64
    let candidates: [BuildBrakeCandidate]
  }

  /// Seconds until running builds use up the memory still available above the reserve, at their
  /// current combined growth.
  static func secondsLeft(_ input: ProjectionInput) -> TimeInterval {
    let growth = input.candidates.reduce(0) { $0 + max(0, $1.growth) }
    let usable = input.available > reserve(input.total) ? input.available - reserve(input.total) : 0
    return growth > 0 ? Double(usable) / growth : .infinity
  }

  struct StuckInput {
    let entry: BuildBrakeEntry
    let risk: MemoryRisk
    let total: UInt64
    let available: UInt64
    let date: Date
  }

  /// Pausing keeps a build's memory, so while memory stays short the brake can never resume it.
  static func isStuck(_ input: StuckInput) -> Bool {
    input.date.timeIntervalSince(input.entry.pausedAt) >= stuckAfter
      && (input.risk >= .warning || input.available < input.total / 4)
  }
}

/// One native pass over this user's processes every sample, with no `ps` or `lsof`, so it keeps working
/// when memory is too short to start a command. Names, paths and folders are read once per process.
struct BuildWatch {
  private struct Key: Hashable {
    let pid: Int32
    let start: UInt64
  }

  private struct Known {
    /// The kernel's short name, which changes on exec while the PID and start time stay.
    let command: String
    let executable: String
    let name: String
    let isApp: Bool
    var project: String??
    var kept: Bool?
  }

  private var known: [Key: Known] = [:]
  private var samples: [Key: [(date: Date, bytes: UInt64)]] = [:]
  private var backgrounded: [Key: DevProcessIdentity] = [:]

  struct Sample {
    let candidates: [BuildBrakeCandidate]
    let backgrounded: Int
  }

  mutating func sample(_ date: Date) -> Sample {
    let rows = Self.rows()
    let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    var seen: Set<Key> = []
    var candidates: [BuildBrakeCandidate] = []
    func info(_ row: Row) -> Known? {
      let key = Key(pid: row.pid, start: row.start)
      if let cached = known[key], cached.command == row.command { return cached }
      guard let executable = Self.path(row.pid) else { return nil }
      let value = Known(
        command: row.command, executable: executable, name: ResourceOwnership.label(executable),
        isApp: ResourceOwnership.appName(executable) != nil)
      known[key] = value
      return value
    }
    for row in rows where row.pid != getpid() {
      let key = Key(pid: row.pid, start: row.start)
      seen.insert(key)
      guard var process = info(row), !process.isApp,
        BuildBrakePolicy.compilers.contains(process.name)
          || BuildBrakePolicy.runtimes.contains(process.name)
      else { continue }
      var ancestor = byPID[row.parent]
      var hops = 0
      var agent: String?
      while let parent = ancestor, hops < 16 {
        if let name = info(parent)?.name, BuildBrakePolicy.agents.contains(name) {
          agent = name == "codex" ? "Codex" : "Claude Code"
          break
        }
        ancestor = byPID[parent.parent]
        hops += 1
      }
      guard
        BuildBrakePolicy.qualifies(.init(name: process.name, startedByAgent: agent != nil))
      else { continue }
      if process.project == nil {
        let directory = ProcessWorkingDirectory.read(row.pid)
        process.project = .some(directory.map { PathName.last($0) })
        process.kept = WorkspacePreferences.isKeptRunning(directory)
        known[key] = process
      }
      guard process.kept != true else { continue }
      let identity = DevProcessIdentity(
        process: .init(
          processID: row.pid, owner: getuid(), startSeconds: row.startSeconds,
          startMicroseconds: row.startMicroseconds, state: row.state),
        executable: process.executable)
      if BuildBrakePolicy.backgroundEnabled, backgrounded[key] == nil,
        Self.matches(identity), setpriority(PRIO_DARWIN_PROCESS, id_t(row.pid), PRIO_DARWIN_BG) == 0
      {
        backgrounded[key] = identity
      }
      guard let footprint = ProcessFootprint.bytes(row.pid) else { continue }
      var history = samples[key, default: []]
      history.append((date, footprint))
      history.removeAll { date.timeIntervalSince($0.date) > 12 }
      samples[key] = history
      let growth: Double
      if let first = history.first, date.timeIntervalSince(first.date) >= 4 {
        growth = (Double(footprint) - Double(first.bytes)) / date.timeIntervalSince(first.date)
      } else {
        growth = 0
      }
      candidates.append(
        .init(
          process: .init(
            identity: identity, name: process.name, project: process.project ?? nil,
            footprint: footprint, agent: agent),
          growth: growth))
    }
    known = known.filter { seen.contains($0.key) }
    samples = samples.filter { seen.contains($0.key) }
    backgrounded = backgrounded.filter { seen.contains($0.key) }
    if !BuildBrakePolicy.backgroundEnabled { restorePriority() }
    return Sample(candidates: candidates, backgrounded: backgrounded.count)
  }

  /// Gives every build this watch moved to background priority its normal priority back.
  mutating func restorePriority() {
    for (key, identity) in backgrounded where Self.matches(identity) {
      setpriority(PRIO_DARWIN_PROCESS, id_t(key.pid), 0)
    }
    backgrounded.removeAll()
  }

  private static func matches(_ identity: DevProcessIdentity) -> Bool {
    DevProcessIdentity.read(identity.process.processID).map(identity.matches) == true
  }

  private typealias Row = NativeProcessList.Row

  private static func rows() -> [Row] {
    NativeProcessList.rows(.init(owner: getuid()))
  }

  private static func path(_ pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}

/// Notices an agent that starts a build again after it ended while paused. Each restart starts from zero
/// and climbs back to the same size, so pausing it again only repeats the cycle; a person has to step in.
struct BuildRetryTracker {
  private var ended: [String: Date] = [:]
  private var retries: [String: (count: Int, last: Date)] = [:]
  private var notified: [String: Date] = [:]

  struct EndInput {
    let label: String
    let date: Date
  }

  mutating func ended(_ input: EndInput) {
    ended[input.label] = input.date
  }

  struct PauseInput {
    let process: BuildBrakeProcess
    let date: Date
  }

  /// The warning to show when this pause is the second retry or later, at most once an hour per build.
  mutating func paused(_ input: PauseInput) -> String? {
    let label = input.process.label
    guard let end = ended[label],
      input.date.timeIntervalSince(end) <= BuildBrakePolicy.retryWindow
    else { return nil }
    ended[label] = nil
    let previous = retries[label].flatMap {
      input.date.timeIntervalSince($0.last) < 3_600 ? $0 : nil
    }
    let count = (previous?.count ?? 0) + 1
    retries[label] = (count, input.date)
    guard count >= 2,
      notified[label].map({ input.date.timeIntervalSince($0) >= 3_600 }) ?? true
    else { return nil }
    notified[label] = input.date
    let who = input.process.agent ?? "Something"
    return
      "\(who) restarted \(label) \(count) times after it ended while paused. Each run climbs back to "
      + "\(ByteText.compact(input.process.footprint)) or more. Ask it to stop running \(input.process.name), "
      + "or to run one at a time."
  }
}

/// Owns the processes the brake paused, saved to disk so a crash or quit never leaves a build stopped.
struct BuildBrake {
  private(set) var paused: [BuildBrakeEntry] = []
  private var lastAction = Date.distantPast
  private var notifiedStuck: Set<Int32> = []
  private var notifiedPause: Set<Int32> = []
  private var watch = BuildWatch()
  private var lastWatch = Date.distantPast
  private var lastSampleRising = false
  private var retries = BuildRetryTracker()
  private let url: URL?

  init(url: URL?) {
    self.url = url
    guard let url, let data = try? Data(contentsOf: url),
      let saved = try? JSONDecoder().decode([BuildBrakeEntry].self, from: data)
    else { return }
    paused = saved
  }

  struct StepInput {
    let risk: MemoryRisk
    let total: UInt64
    let available: UInt64
    let date: Date
  }

  struct Outcome: Equatable, Sendable {
    let message: String?
    /// Set the first time a given build is paused, so a build paused again after resuming stays quiet.
    let notifyPause: Bool
    /// A pause that memory can no longer release, reported once.
    let stuck: BuildBrakeEntry?
    /// An agent that keeps starting a build again after it ended while paused.
    let loop: String?
  }

  /// What the brake changed this step; nil when nothing did.
  mutating func step(_ input: StepInput) -> Outcome? {
    pruneReleased(input.date)
    let calm =
      input.risk == .normal && input.available >= input.total / 5 && paused.isEmpty
      && !lastSampleRising
    if calm && input.date.timeIntervalSince(lastWatch) < BuildBrakePolicy.calmInterval {
      return nil
    }
    lastWatch = input.date
    let sample = watch.sample(input.date)
    lastSampleRising = sample.candidates.contains { $0.growth >= BuildBrakePolicy.fastGrowth / 2 }
    var stuck: BuildBrakeEntry?
    for entry in paused
    where !notifiedStuck.contains(entry.process.identity.process.processID)
      && BuildBrakePolicy.isStuck(
        .init(
          entry: entry, risk: input.risk, total: input.total, available: input.available,
          date: input.date))
    {
      notifiedStuck.insert(entry.process.identity.process.processID)
      stuck = entry
    }
    guard BuildBrakePolicy.enabled || !paused.isEmpty else {
      return stuck.map { .init(message: nil, notifyPause: false, stuck: $0, loop: nil) }
    }
    let decision = BuildBrakePolicy.decide(
      .init(
        risk: BuildBrakePolicy.enabled ? input.risk : .normal, total: input.total,
        available: BuildBrakePolicy.enabled ? input.available : input.total,
        date: input.date, candidates: BuildBrakePolicy.enabled ? sample.candidates : [],
        paused: paused, lastAction: BuildBrakePolicy.enabled ? lastAction : .distantPast))
    switch decision {
    case .none:
      return stuck.map { .init(message: nil, notifyPause: false, stuck: $0, loop: nil) }
    case .pause(let process):
      guard
        case .sent = ProcessSignal.send(.init(expected: process.identity, signal: SIGSTOP))
      else { return nil }
      paused.append(.init(process: process, pausedAt: input.date))
      lastAction = input.date
      save()
      let loop = retries.paused(.init(process: process, date: input.date))
      let first = notifiedPause.insert(process.identity.process.processID).inserted
      return .init(
        message:
          "Paused \(process.label) (\(ByteText.compact(process.footprint))) before memory ran out. "
          + "It resumes when memory recovers.",
        notifyPause: first, stuck: stuck, loop: loop)
    case .resume(let entry):
      lastAction = input.date
      let resumed = release(.init(entry: entry, signal: SIGCONT))
      return .init(
        message: resumed ? "Resumed \(entry.process.label)." : nil, notifyPause: false,
        stuck: stuck, loop: nil)
    }
  }

  struct ReleaseRequest {
    let entry: BuildBrakeEntry
    /// SIGCONT resumes; SIGTERM stops the build and frees its memory.
    let signal: Int32
  }

  /// Resumes or stops one paused build at a person's request or when memory recovers.
  @discardableResult
  mutating func release(_ request: ReleaseRequest) -> Bool {
    paused.removeAll { $0 == request.entry }
    notifiedStuck.remove(request.entry.process.identity.process.processID)
    if request.signal == SIGTERM {
      retries.ended(.init(label: request.entry.process.label, date: .now))
    }
    save()
    return ProcessSignal.send(
      .init(expected: request.entry.process.identity, signal: request.signal)
    )
    .wasSent
  }

  /// Resumes everything the brake paused and restores build priority; used at quit.
  mutating func releaseAll() {
    for entry in paused {
      _ = ProcessSignal.send(.init(expected: entry.process.identity, signal: SIGCONT))
    }
    paused.removeAll()
    watch.restorePriority()
    save()
  }

  /// Drops pauses someone else released. A build that ended while still paused, usually because the
  /// agent that started it gave up waiting, is remembered so a restart can be recognized.
  private mutating func pruneReleased(_ date: Date) {
    let before = paused.count
    paused.removeAll { entry in
      guard let current = DevProcessIdentity.read(entry.process.identity.process.processID),
        entry.process.identity.matches(current)
      else {
        retries.ended(.init(label: entry.process.label, date: date))
        return true
      }
      return !current.process.stopped
    }
    if paused.count != before { save() }
  }

  private func save() {
    guard let url else { return }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(paused) else { return }
    try? data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
