import AppKit
import Darwin
import Foundation

@MainActor
final class DevProcessModel: ObservableObject {
  @Published private(set) var processes: [DevProcess] = []
  @Published private(set) var cpuProcesses: [CPUProcess] = []
  @Published private(set) var resources: [ResourceProcess] = []
  @Published private(set) var workspaceRoots: [Int32: String] = [:]
  @Published private(set) var threads: [AIThread] = []
  @Published private(set) var stoppingThreads: Set<String> = []
  @Published private(set) var threadMessage: String?
  @Published private(set) var stoppingIDs: Set<Int32> = []
  @Published private(set) var consumers: [ResourceConsumer] = []
  @Published private(set) var activity = ConsumerActivity.load()
  /// Consumers the user moved to background priority in this session.
  @Published private(set) var backgrounded: Set<String> = []
  @Published private(set) var actingConsumers: Set<String> = []
  @Published private(set) var consumerMessage: String?
  private var identities: [Int32: DevProcessIdentity] = [:]
  @Published private(set) var isRefreshing = false
  /// Set when an action asks for a refresh while one is running; that scan started before the
  /// action, so another runs right after it.
  private var refreshRequested = false
  @Published private(set) var scannedAt: Date?
  @Published private(set) var statusMessage: String?
  @Published private(set) var probes: [Int: PortProbe] = [:]

  @Published private(set) var pressure = PressureAssessment.checking
  @Published private(set) var autoPauseDirectories = Set(
    UserDefaults.standard.stringArray(forKey: ProjectPausePolicy.key) ?? [])
  @Published private(set) var projectTargets: [String: ProjectPauseTarget] = [:]
  @Published private(set) var projectAction: String?
  @Published private(set) var actingProjects: Set<String> = []
  @Published private(set) var projectMessages: [String: String] = [:]
  @Published private(set) var scanDuration: TimeInterval = 0
  @Published private(set) var leftovers: [LeftoverProcess] = []
  @Published private(set) var stoppingLeftovers: Set<Int32> = []
  @Published private(set) var leftoverMessage: String?
  @Published private(set) var hiddenLeftoverNames =
    UserDefaults.standard.stringArray(forKey: LeftoverProcessFinder.hiddenKey) ?? []
  private let sentinel = PressureSentinel()
  private let scanner = DevProcessScanner()
  private let prober = PortProber()
  private var timer: Timer?
  private var probing: Set<Int> = []
  private var portOwners: [Int: Set<Int32>] = [:]

  init() {
    sentinel.start { [weak self] update in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if self.pressure.publishes(.init(next: update.assessment, active: NSApp?.isActive == true))
        {
          self.pressure = update.assessment
        }
        ResourceSnapshotCache.pressure = update.assessment
        if let action = update.action {
          self.projectAction = action
          self.refresh()
        }
      }
    }
    startAutoRefresh()
    refresh()
  }

  var summary: DevProcessSummary {
    DevProcessSummary(processes: processes)
  }

  func startAutoRefresh() {
    guard timer == nil else {
      return
    }

    let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.refreshIfStale()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func refreshIfStale() {
    guard !isRefreshing else { return }
    let interval: TimeInterval = pressure.risk >= .warning ? 12 : NSApp?.isActive == true ? 5 : 15
    if let scannedAt, Date().timeIntervalSince(scannedAt) < interval {
      return
    }

    refresh()
  }

  func refresh() {
    guard !isRefreshing else {
      refreshRequested = true
      return
    }

    isRefreshing = true
    let scanner = scanner
    let started = Date.now

    Task { [weak self] in
      let scanned = await Task.detached(priority: .utility) {
        scanner.snapshot()
      }.value

      guard let self else {
        return
      }

      if processes != scanned.processes { processes = scanned.processes }
      if cpuProcesses != scanned.cpuProcesses { cpuProcesses = scanned.cpuProcesses }
      if resources != scanned.resources { resources = scanned.resources }
      if workspaceRoots != scanned.workspaceRoots { workspaceRoots = scanned.workspaceRoots }
      if threads != scanned.threads { threads = scanned.threads }
      if leftovers != scanned.leftovers { leftovers = scanned.leftovers }
      ResourceSnapshotCache.groups = ResourceOwnership.groups(scanned.resources)
      ResourceSnapshotCache.scannedAt = .now
      identities = scanned.identities
      let stopped = Set(
        scanned.identities.values.filter(\.process.stopped).map(\.process.processID))
      let built = ResourceConsumers.build(
        .init(threads: scanned.threads, resources: scanned.resources, stopped: stopped))
      if consumers != built { consumers = built }
      var next = activity
      next.record(.init(consumers: built, date: .now))
      if next != activity {
        activity = next
        next.save()
      }
      scannedAt = .now
      isRefreshing = false
      scanDuration = Date.now.timeIntervalSince(started)
      statusMessage =
        scanned.incomplete
        ? "Process scan incomplete; some processes or ports could not be read." : nil
      updateProjectTargets()
      if pressure.risk < .warning { probeStalePorts() }
      if refreshRequested {
        refreshRequested = false
        refresh()
      }
    }
  }

  private struct ProjectCacheKey: Equatable {
    let scannedAt: Date?
    let preferences: [WorkspacePreference]
  }

  private var projectCache: (key: ProjectCacheKey, projects: [WorkspaceProject])?

  /// Resolved projects for the latest scan, reused until a new scan or preference change.
  func projects(_ preferences: [WorkspacePreference]) -> [WorkspaceProject] {
    let key = ProjectCacheKey(scannedAt: scannedAt, preferences: preferences)
    if let projectCache, projectCache.key == key { return projectCache.projects }
    let projects = WorkspaceCatalog.resolvedProjects(
      .init(
        input: .init(resources: resources, processes: processes, preferences: preferences),
        roots: workspaceRoots))
    projectCache = (key, projects)
    return projects
  }

  func updateProjectTargets() {
    let projects = WorkspaceCatalog.resolvedProjects(
      .init(
        input: .init(
          resources: resources, processes: processes, preferences: WorkspacePreferences.load()),
        roots: workspaceRoots))
    projectTargets = Dictionary(
      projects.compactMap { project in
        ProjectPausePolicy.target(
          .init(
            project: project, identities: identities, excludedIDs: [],
            date: scannedAt ?? .distantPast)
        )
        .map { (project.directory, $0) }
      }, uniquingKeysWith: { first, _ in first })
    updateSentinelTargets()
  }

  private func updateSentinelTargets() {
    let excluded = Set(threads.flatMap(\.processIDs))
    sentinel.update(
      projectTargets.values.compactMap { target in
        guard !actingProjects.contains(target.directory) else { return nil }
        var value = target
        value.identities = target.identities.filter { !excluded.contains($0.process.processID) }
        return value.identities.isEmpty ? nil : value
      })
  }

  struct AutoPauseRequest {
    let directory: String
    let enabled: Bool
  }

  func setAutoPause(_ request: AutoPauseRequest) {
    if request.enabled {
      autoPauseDirectories.insert(request.directory)
    } else {
      autoPauseDirectories.remove(request.directory)
    }
    UserDefaults.standard.set(Array(autoPauseDirectories), forKey: ProjectPausePolicy.key)
    updateProjectTargets()
  }

  func pauseProject(_ target: ProjectPauseTarget) {
    guard actingProjects.insert(target.directory).inserted else { return }
    projectMessages[target.directory] = nil
    updateSentinelTargets()
    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        guard target.isPaused || !WorkspacePreferences.isKeptRunning(target.directory) else {
          return WorkloadControl.Result(affected: 0, remaining: 0, retainedBytes: 0, identities: [])
        }
        return await WorkloadControl.execute(
          .init(
            identities: target.identities,
            signal: target.isPaused ? .resume : .pause))
      }.value
      self?.projectMessages[target.directory] =
        result.completed
        ? "\(target.name): \(result.affected) processes \(target.isPaused ? "resumed" : "suspended; RAM is still held")."
        : "Action incomplete. \(result.remaining) processes remain; refresh and review."
      self?.actingProjects.remove(target.directory)
      self?.refresh()
    }
  }

  func stopProjectWorkers(_ target: ProjectPauseTarget) {
    guard actingProjects.insert(target.directory).inserted else { return }
    projectAction = nil
    projectMessages[target.directory] = nil
    updateSentinelTargets()
    Task { [weak self] in
      let message = await Task.detached(priority: .userInitiated) {
        guard !target.keepRunning, !WorkspacePreferences.isKeptRunning(target.directory) else {
          return "This project is set to Keep running."
        }
        let result = await WorkloadControl.execute(
          .init(identities: target.identities, signal: .quit))
        guard result.affected > 0 else {
          return "Processes changed or are protected. Refresh to try again."
        }
        let scan = DevProcessScanner().snapshot()
        let project = WorkspaceCatalog.resolvedProjects(
          .init(
            input: .init(resources: scan.resources, processes: scan.processes, preferences: []),
            roots: scan.workspaceRoots)
        ).first { $0.directory == target.directory }
        let replacement = project.flatMap {
          ProjectPausePolicy.target(
            .init(project: $0, identities: scan.identities, excludedIDs: [], date: .now))
        }
        let remaining = max(result.remaining, replacement?.identities.count ?? 0)
        return remaining == 0
          ? "Stopped \(result.affected) development processes."
          : "Partially stopped: \(remaining) workers remain or restarted."
      }.value
      if message.hasPrefix("Stopped ") {
        self?.projectAction = "\(target.name): \(message)"
      } else {
        self?.projectMessages[target.directory] = message
      }
      self?.actingProjects.remove(target.directory)
      self?.refresh()
    }
  }

  func probe(_ probeFor: DevProcess) -> PortProbe? {
    probeFor.listeningPorts.lazy.compactMap { port in self.probes[port] }.first { probe in
      probe.kind != .silent
    }
  }

  private func probeStalePorts() {
    var owners: [Int: Set<Int32>] = [:]
    for process in processes {
      for port in process.listeningPorts {
        owners[port, default: []].insert(process.processID)
      }
    }
    let livePorts = Set(owners.keys)
    probes = probes.filter { port, _ in
      livePorts.contains(port) && portOwners[port] == owners[port]
    }
    portOwners = owners
    let stale = livePorts.filter { port in
      guard !probing.contains(port) else {
        return false
      }

      guard let existing = probes[port] else {
        return true
      }

      let maxAge: TimeInterval = existing.kind == .silent ? 15 * 60 : 5 * 60
      return Date().timeIntervalSince(existing.probedAt) > maxAge
    }.sorted()

    guard !stale.isEmpty else {
      return
    }

    probing.formUnion(stale)
    let prober = prober
    let expectedOwners = owners
    Task { [weak self] in
      await withTaskGroup(of: PortProbe.self) { group in
        var nextIndex = 0
        while nextIndex < min(6, stale.count) {
          let port = stale[nextIndex]
          nextIndex += 1
          group.addTask {
            await prober.probe(port: port)
          }
        }

        for await probe in group {
          if self?.portOwners[probe.port] == expectedOwners[probe.port] {
            self?.probes[probe.port] = probe
          }
          self?.probing.remove(probe.port)
          if nextIndex < stale.count {
            let port = stale[nextIndex]
            nextIndex += 1
            group.addTask {
              await prober.probe(port: port)
            }
          }
        }
      }
    }
  }

  func stop(_ request: DevStopRequest) {
    guard !WorkspacePreferences.isKeptRunning(request.process.workingDirectory) else {
      statusMessage =
        "This project is set to Keep running. Change it in Projects before stopping a process."
      return
    }
    guard stoppingIDs.insert(request.process.processID).inserted else { return }
    statusMessage = DevProcessStopper.stop(request)
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(800))
      self?.stoppingIDs.remove(request.process.processID)
      self?.refresh()
    }
  }

  /// AI threads by ID; the scanner can report one session twice, so the first wins instead of trapping.
  var threadsByID: [String: AIThread] {
    Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  struct ConsumerSignal {
    let consumer: ResourceConsumer
    let signal: AIThreadSignal
  }

  /// Pauses, resumes or stops an AI session or terminal workload, checking each process's identity first.
  func signal(_ request: ConsumerSignal) {
    let consumer = request.consumer
    if let id = consumer.threadID, let thread = threads.first(where: { $0.id == id }) {
      signalThread(thread, request.signal)
      return
    }
    guard consumer.kind == .workload, actingConsumers.insert(consumer.id).inserted else { return }
    consumerMessage = nil
    let expected = consumer.processIDs.compactMap { identities[$0] }
    let signal = request.signal
    Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        await WorkloadControl.execute(.init(identities: expected, signal: signal))
      }.value
      guard let self else { return }
      let name = consumer.name
      consumerMessage =
        if result.affected == 0 {
          "\(name) already exited or changed. The list is refreshed."
        } else if result.remaining > 0 {
          signal == .quit || signal == .forceQuit
            ? "\(name) is still running. Use Force Quit to end it now."
            : "\(name) has processes that did not respond yet."
        } else {
          switch signal {
          case .pause:
            "\(name) paused · CPU stopped, \(ByteText.full(consumer.memoryBytes)) still held."
          case .resume: "\(name) resumed."
          case .quit, .forceQuit:
            "\(name) stopped · \(ByteText.full(consumer.memoryBytes)) released."
          }
        }
      actingConsumers.remove(consumer.id)
      refresh()
    }
  }

  struct ConsumerPriority {
    let consumer: ResourceConsumer
    let background: Bool
  }

  /// Background priority gives a consumer CPU only when nothing else needs it; it is reversible.
  func setBackground(_ request: ConsumerPriority) {
    let consumer = request.consumer
    var changed = 0
    for pid in consumer.processIDs {
      guard let expected = identities[pid], let current = DevProcessIdentity.read(pid),
        expected.matches(current), current.process.owner == getuid(), pid != getpid()
      else { continue }
      if setpriority(PRIO_DARWIN_PROCESS, id_t(pid), request.background ? PRIO_DARWIN_BG : 0) == 0 {
        changed += 1
      }
    }
    guard changed > 0 else {
      consumerMessage = "\(consumer.name) changed or exited. The list is refreshed."
      refresh()
      return
    }
    if request.background {
      backgrounded.insert(consumer.id)
      consumerMessage =
        "\(consumer.name) now runs in the background: it only gets CPU that nothing else needs."
    } else {
      backgrounded.remove(consumer.id)
      consumerMessage = "\(consumer.name) runs at normal priority again."
    }
  }

  func pauseThread(_ thread: AIThread) {
    signalThread(thread, .pause)
  }

  func resumeThread(_ thread: AIThread) {
    signalThread(thread, .resume)
  }

  func stopThread(_ thread: AIThread, force: Bool) {
    signalThread(thread, force ? .forceQuit : .quit)
  }

  private func signalThread(_ thread: AIThread, _ signal: AIThreadSignal) {
    guard stoppingThreads.insert(thread.id).inserted else { return }
    let request = AIThreadStopRequest(
      thread: thread, expected: identities.filter { thread.processIDs.contains($0.key) },
      force: signal == .forceQuit)
    let label = thread.displayName
    Task { [weak self] in
      let outcome = await Task.detached(priority: .userInitiated) { () async -> String? in
        let result = await WorkloadControl.execute(
          .init(identities: Array(request.expected.values), signal: signal))
        guard result.affected > 0 else { return nil }
        if result.remaining > 0 {
          return signal == .pause
            ? "pause-pending" : signal == .resume ? "resume-pending" : "still-running"
        }
        switch signal {
        case .pause:
          for _ in 0..<8 {
            if AIThreadStopper.paused(request) { return "paused" }
            try? await Task.sleep(for: .milliseconds(50))
          }
          return "pause-pending"
        case .resume:
          for _ in 0..<8 {
            if !AIThreadStopper.paused(request), AIThreadStopper.running(request) {
              return "resumed"
            }
            try? await Task.sleep(for: .milliseconds(50))
          }
          return "resume-pending"
        case .quit, .forceQuit:
          for _ in 0..<12 {
            guard AIThreadStopper.running(request) else { return "quit" }
            try? await Task.sleep(for: .milliseconds(250))
          }
          return "still-running"
        }
      }.value
      guard let self else { return }
      threadMessage =
        switch (signal, outcome) {
        case (_, nil): "\(label) already exited or changed. The list is refreshed."
        case (.pause, "paused"):
          "\(label) paused · CPU stopped, \(ByteText.full(thread.memoryBytes)) RAM still held. Resume when you want it back."
        case (.pause, "pause-pending"):
          "Pause requested for \(label). Some local processes have not stopped yet."
        case (.resume, "resumed"): "\(label) resumed"
        case (.resume, "resume-pending"):
          "Resume requested for \(label). Checking the local processes."
        case (.forceQuit, "quit"):
          "\(label) force quit · it was using \(ByteText.full(thread.memoryBytes))"
        case (.quit, "quit"):
          "\(label) quit · it was using \(ByteText.full(thread.memoryBytes))"
        case (.quit, "still-running"), (.forceQuit, "still-running"):
          "\(label) is still running. Use Force Quit to end it now."
        default: nil
        }
      stoppingThreads.remove(thread.id)
      refresh()
    }
  }

  var visibleLeftovers: [LeftoverProcess] {
    let hidden = Set(hiddenLeftoverNames)
    return leftovers.filter { !hidden.contains($0.executableName) }
  }

  struct LeftoverVisibility {
    let name: String
    let hidden: Bool
  }

  func setLeftoverName(_ input: LeftoverVisibility) {
    let name = input.name
    hiddenLeftoverNames.removeAll { $0 == name }
    if input.hidden { hiddenLeftoverNames.append(name) }
    UserDefaults.standard.set(hiddenLeftoverNames, forKey: LeftoverProcessFinder.hiddenKey)
  }

  func showHiddenLeftovers() {
    hiddenLeftoverNames = []
    UserDefaults.standard.removeObject(forKey: LeftoverProcessFinder.hiddenKey)
  }

  struct LeftoverQuit {
    let targets: [LeftoverProcess]
    let force: Bool
  }

  func quitLeftovers(_ input: LeftoverQuit) {
    let requests = input.targets.compactMap { process -> LeftoverStopRequest? in
      guard !stoppingLeftovers.contains(process.processID) else { return nil }
      return LeftoverStopRequest(process: process, force: input.force)
    }
    guard !requests.isEmpty else { return }
    let ids = requests.map(\.process.processID)
    stoppingLeftovers.formUnion(ids)
    leftoverMessage = nil
    Task { [weak self] in
      let outcome = await Task.detached(priority: .userInitiated) {
        () async -> (signaled: [LeftoverStopRequest], running: Int) in
        let signaled = LeftoverProcessStopper.signals(requests)
        for _ in 0..<12 {
          if !signaled.contains(where: LeftoverProcessStopper.isCurrent) { break }
          try? await Task.sleep(for: .milliseconds(250))
        }
        return (signaled, signaled.filter(LeftoverProcessStopper.isCurrent).count)
      }.value
      guard let self else { return }
      leftoverMessage = Self.leftoverMessage(
        .init(requested: requests, signaled: outcome.signaled, running: outcome.running))
      stoppingLeftovers.subtract(ids)
      refresh()
    }
  }

  struct LeftoverOutcome {
    let requested: [LeftoverStopRequest]
    let signaled: [LeftoverStopRequest]
    let running: Int
  }

  nonisolated static func leftoverMessage(_ outcome: LeftoverOutcome) -> String {
    let skipped = outcome.requested.count - outcome.signaled.count
    let ended = outcome.signaled.count - outcome.running
    let force = outcome.requested.first?.force == true
    guard outcome.requested.count > 1 else {
      let title = outcome.requested.first?.process.title ?? "The process"
      if skipped > 0 {
        return "\(title) was not quit: it exited, changed, or is protected. The list is refreshed."
      }
      if outcome.running > 0 { return "\(title) is still running. Use Force Quit to end it now." }
      let memory = outcome.requested.first?.process.memoryBytes.map {
        " · it was using \(ByteText.full($0))"
      }
      return "\(title) \(force ? "force quit" : "quit")\(memory ?? "")"
    }
    var parts = ["Quit \(ended) of \(outcome.requested.count) leftover processes"]
    if outcome.running > 0 { parts.append("\(outcome.running) still running") }
    if skipped > 0 { parts.append("\(skipped) exited, changed, or protected") }
    return parts.joined(separator: " · ")
  }

  func stopRequest(_ process: DevProcess) -> DevStopRequest {
    DevStopRequest(
      process: process, expected: identities[process.processID], force: false)
  }

  func stopProject(_ requests: [DevStopRequest]) {
    guard
      !requests.contains(where: { WorkspacePreferences.isKeptRunning($0.process.workingDirectory) })
    else {
      statusMessage =
        "This project is set to Keep running. Change it in Projects before stopping servers."
      return
    }
    let candidates = requests.filter {
      $0.process.canStopWithProject && !stoppingIDs.contains($0.process.processID)
    }
    guard !candidates.isEmpty else { return }
    stoppingIDs.formUnion(candidates.map { $0.process.processID })
    Task { [weak self] in
      let messages = await Task.detached(priority: .userInitiated) {
        candidates.map { DevProcessStopper.stop($0) }
      }.value
      guard let self else { return }
      statusMessage = messages.joined(separator: " · ")
      try? await Task.sleep(for: .milliseconds(800))
      stoppingIDs.subtract(candidates.map { $0.process.processID })
      refresh()
    }
  }

  func openPort(_ port: Int) {
    guard let url = URL(string: "http://localhost:\(port)") else {
      return
    }

    NSWorkspace.shared.open(url)
  }
}
