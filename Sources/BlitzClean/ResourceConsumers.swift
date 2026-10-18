import Darwin
import Foundation

/// What a row on the Memory and CPU pages stands for, which decides the actions it offers.
enum ConsumerKind: String, Equatable, Sendable {
  /// A Claude, Codex or Cursor session with its tool servers.
  case aiSession
  /// An app with all its helpers.
  case app
  /// Tools started from a terminal, grouped by program and project, such as `node · fmx_ws`.
  case workload
  /// macOS services; shown for context, never stopped from here.
  case system
}

/// One thing the user recognizes as using memory or CPU, built from live processes.
struct ResourceConsumer: Identifiable, Equatable, Sendable {
  let id: String
  let kind: ConsumerKind
  let name: String
  /// App or tool name used to look up the row's icon.
  let iconName: String
  let processIDs: [Int32]
  let memoryBytes: UInt64
  /// Sum across processes; 100% equals one core.
  let cpuPercent: Double
  let directory: String?
  let isPaused: Bool
  /// The AI thread behind an AI session; absent for other kinds.
  let threadID: String?

  var project: String? { directory.map { URL(fileURLWithPath: $0).lastPathComponent } }
  var canSignal: Bool { kind == .aiSession || kind == .workload }
}

enum ResourceConsumers {
  struct Input {
    let threads: [AIThread]
    let resources: [ResourceProcess]
    /// Processes stopped with SIGSTOP.
    let stopped: Set<Int32>
  }

  private static let minimumBytes: UInt64 = 20 * 1_024 * 1_024

  /// Groups processes so each block of memory and CPU belongs to exactly one consumer.
  static func build(_ input: Input) -> [ResourceConsumer] {
    var seen: Set<String> = []
    let threads = input.threads.filter { seen.insert($0.id).inserted }
    var consumers = threads.map { thread in
      ResourceConsumer(
        id: "ai:" + thread.id, kind: .aiSession, name: thread.displayName,
        iconName: thread.tool.appName ?? thread.name, processIDs: thread.processIDs,
        memoryBytes: thread.memoryBytes, cpuPercent: thread.cpuPercent,
        directory: thread.directory, isPaused: thread.isPaused, threadID: thread.id)
    }
    let claimed = Set(threads.flatMap(\.processIDs))
    let own = getpid()
    let rest = input.resources.filter { !claimed.contains($0.processID) && $0.processID != own }
    let grouped = Dictionary(grouping: rest, by: key)
    for (key, items) in grouped {
      guard let first = items.first else { continue }
      let kind: ConsumerKind =
        key == systemKey ? .system : key.hasPrefix("app:") ? .app : .workload
      let ids = items.map(\.processID).sorted()
      let name: String =
        switch kind {
        case .system: "macOS services"
        case .app: first.bundleApp ?? first.name
        default:
          first.directory.map { "\(first.name) · \(URL(fileURLWithPath: $0).lastPathComponent)" }
            ?? first.name
        }
      consumers.append(
        ResourceConsumer(
          id: key, kind: kind, name: name,
          iconName: kind == .app ? name : kind == .system ? "Activity Monitor" : first.owner,
          processIDs: ids, memoryBytes: items.compactMap(\.memoryBytes).reduce(0, +),
          cpuPercent: items.reduce(0) { $0 + $1.cpuPercent },
          directory: kind == .workload ? first.directory : nil,
          isPaused: !ids.isEmpty && ids.allSatisfy(input.stopped.contains), threadID: nil))
    }
    return
      consumers
      .filter { $0.memoryBytes >= minimumBytes || $0.cpuPercent >= 1 }
      .filter { $0.name != "BlitzClean" }
      .sorted { $0.memoryBytes == $1.memoryBytes ? $0.id < $1.id : $0.memoryBytes > $1.memoryBytes }
  }

  static let systemKey = "system"

  private static func key(_ process: ResourceProcess) -> String {
    if let app = process.bundleApp { return "app:" + app }
    if process.isSystem { return systemKey }
    return "work:" + process.name + "|" + (process.directory ?? "")
  }
}

/// When each consumer last did work and how long it has been pegging the CPU, across refreshes and relaunches.
struct ConsumerActivity: Codable, Equatable, Sendable {
  var lastBusy: [String: Date] = [:]
  var busySince: [String: Date] = [:]

  /// CPU at or above this counts as doing work.
  static let busyCPU = 3.0
  /// Sustained CPU at or above this is a runaway candidate.
  static let runawayCPU = 80.0
  /// Below this the runaway clock resets.
  static let calmCPU = 40.0
  static let idleAfter: TimeInterval = 30 * 60
  static let runawayAfter: TimeInterval = 5 * 60

  struct Reading {
    let consumers: [ResourceConsumer]
    let date: Date
  }

  /// Unknown consumers start as active now, so nothing is called idle before it has been watched.
  mutating func record(_ reading: Reading) {
    var seen: Set<String> = []
    for consumer in reading.consumers {
      seen.insert(consumer.id)
      if consumer.cpuPercent >= Self.busyCPU || lastBusy[consumer.id] == nil {
        lastBusy[consumer.id] = reading.date
      }
      if consumer.cpuPercent >= Self.runawayCPU {
        if busySince[consumer.id] == nil { busySince[consumer.id] = reading.date }
      } else if consumer.cpuPercent < Self.calmCPU {
        busySince[consumer.id] = nil
      }
    }
    lastBusy = lastBusy.filter { seen.contains($0.key) }
    busySince = busySince.filter { seen.contains($0.key) }
  }

  struct Query {
    let id: String
    let now: Date
  }

  func idle(_ query: Query) -> TimeInterval {
    lastBusy[query.id].map { max(0, query.now.timeIntervalSince($0)) } ?? 0
  }

  /// How long the consumer has stayed above the runaway threshold; zero when it is calm.
  func busy(_ query: Query) -> TimeInterval {
    busySince[query.id].map { max(0, query.now.timeIntervalSince($0)) } ?? 0
  }

  static let key = "consumers.activity.v1"

  static func load(_ defaults: UserDefaults = .standard) -> Self {
    guard let data = defaults.data(forKey: key),
      let value = try? JSONDecoder().decode(Self.self, from: data)
    else { return .init() }
    return value
  }

  func save(_ defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
  }
}

/// Which consumers can go to free memory without interrupting work.
enum FreeMemoryPlan {
  struct Input {
    let consumers: [ResourceConsumer]
    let activity: ConsumerActivity
    /// Apps the user may quit here, by name; protected and frontmost apps are absent.
    let quittableApps: Set<String>
    let now: Date
  }

  static let minimumBytes: UInt64 = 300 * 1_024 * 1_024

  /// Idle for 30 minutes and large enough to matter, largest first.
  static func idle(_ input: Input) -> [ResourceConsumer] {
    input.consumers.filter { consumer in
      let allowed =
        consumer.kind == .app ? input.quittableApps.contains(consumer.name) : consumer.canSignal
      return allowed && consumer.memoryBytes >= minimumBytes
        && input.activity.idle(.init(id: consumer.id, now: input.now)) >= ConsumerActivity.idleAfter
    }.sorted { $0.memoryBytes > $1.memoryBytes }
  }
}

/// Plain names for macOS processes that show up in the CPU list.
enum SystemProcessNames {
  struct Description: Equatable {
    let title: String
    let detail: String
  }

  static func describe(_ name: String) -> Description {
    switch name {
    case "mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "corespotlightd":
      .init(title: "Spotlight indexing", detail: "Indexes new files · finishes on its own")
    case "kernel_task":
      .init(title: "macOS cooling", detail: "Holds the CPU back to cool the Mac · close heavy apps")
    case "WindowServer":
      .init(title: "Screen drawing", detail: "More windows, displays or animations raise it")
    case "photoanalysisd", "mediaanalysisd", "photolibraryd":
      .init(title: "Photos analysis", detail: "Scans the library while the Mac is idle")
    case "backupd", "backupd-helper":
      .init(title: "Time Machine backup", detail: "Stops when the backup finishes")
    case "cloudd", "bird", "fileproviderd", "nsurlsessiond":
      .init(title: "iCloud sync", detail: "Uploads or downloads files · finishes on its own")
    case "softwareupdated", "mobileassetd":
      .init(title: "Software update", detail: "Downloads macOS components")
    case "syspolicyd", "XProtect", "XprotectService":
      .init(title: "Security scan", detail: "Checks newly opened apps and downloads")
    case "deleted", "deleted_helper":
      .init(title: "Freeing purgeable space", detail: "macOS reclaims cached and deleted files")
    case "BackgroundShortcutRunner", "siriactionsd", "shortcutsd":
      .init(
        title: "Shortcuts automation", detail: "Runs a Shortcut or Siri action in the background")
    case "triald", "biomed", "knowledgeconstructiond", "intelligenceplatformd":
      .init(title: "Apple Intelligence and Siri", detail: "Learns from usage while the Mac is idle")
    case "trustd", "pkd", "amfid":
      .init(title: "Code signing checks", detail: "Verifies apps and extensions")
    case "coreaudiod", "audiomxd":
      .init(title: "Audio", detail: "Plays and records sound")
    default:
      name.localizedCaseInsensitiveContains("spotlight")
        ? .init(title: "Spotlight", detail: "Indexes files and suggestions · finishes on its own")
        : .init(title: name, detail: "Part of macOS")
    }
  }
}
