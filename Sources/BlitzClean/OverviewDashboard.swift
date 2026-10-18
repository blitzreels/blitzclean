import SwiftUI

/// The top of Overview: how the Mac is doing, one tile per resource, and the biggest wins one click away.
struct OverviewDashboard: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var recovery: AppRecoveryModel
  @ObservedObject var navigation: CleanNavigation
  @ObservedObject var storage: StorageBreakdownModel
  @ObservedObject var drive: DriveBreakdownModel
  @ObservedObject var history: CleanupOverviewModel
  @ObservedObject var worktrees: DeveloperBrowserModel
  @Binding var pending: PendingProcessAction?

  private var commands: ConsumerCommands { .init(processes: processes, memory: memory) }

  var body: some View {
    VStack(alignment: .leading, spacing: 28) {
      hero
      VStack(alignment: .leading, spacing: 10) {
        BlitzGroupLabel(title: "Resources")
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)],
          alignment: .leading, spacing: 12
        ) {
          storageTile
          memoryTile
          cpuTile
        }
      }
      quickWins
    }
    .task {
      drive.scanIfNeeded()
      worktrees.loadIfNeeded()
    }
  }

  // MARK: Health

  private struct Issue {
    let text: String
    let tone: BlitzStatusTone
  }

  private var diskFreeRatio: Double {
    let total = monitor.snapshot.diskTotal
    return total == 0 ? 1 : Double(monitor.snapshot.diskAvailable) / Double(total)
  }

  private var storageTone: BlitzStatusTone {
    diskFreeRatio < 0.05 ? .critical : diskFreeRatio < 0.15 ? .warning : .good
  }

  private var memoryTone: BlitzStatusTone {
    switch processes.pressure.risk {
    case .normal: .good
    case .growing: .working
    case .warning: .warning
    case .critical: .critical
    }
  }

  private var cpuTone: BlitzStatusTone {
    let usage = monitor.snapshot.cpuUsage ?? 0
    return usage >= 0.85 ? .critical : usage >= 0.5 ? .warning : .good
  }

  private var issues: [Issue] {
    var result: [Issue] = []
    if storageTone != .good {
      result.append(
        .init(text: "Disk is \(PercentText.make(1 - diskFreeRatio)) full", tone: storageTone))
    }
    if memoryTone == .warning || memoryTone == .critical {
      result.append(.init(text: "Memory is short", tone: memoryTone))
    }
    if cpuTone != .good { result.append(.init(text: "CPU is busy", tone: cpuTone)) }
    if recovery.attentionCount > 0 {
      result.append(
        .init(
          text:
            "\(recovery.attentionCount) \(recovery.attentionCount == 1 ? "app is" : "apps are") not responding",
          tone: .warning))
    }
    return result
  }

  private var hero: some View {
    let issues = issues
    let tone: BlitzStatusTone =
      issues.contains { $0.tone == .critical }
      ? .critical : issues.isEmpty ? .good : .warning
    let title =
      tone == .critical
      ? "Your Mac needs attention"
      : tone == .warning ? "A few things are slowing your Mac" : "Your Mac is in good shape"
    let ledger = history.ledger
    return HStack(alignment: .center, spacing: 16) {
      BlitzColorTile(
        symbol: tone == .good ? "checkmark" : "exclamationmark", color: BlitzPalette.tone(tone),
        size: 44)
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.system(size: 20, weight: .semibold))
        if issues.isEmpty {
          Text("Storage, memory and CPU all have room.").font(BlitzType.callout)
            .foregroundStyle(BlitzUI.secondaryText)
        } else {
          HStack(spacing: 14) {
            ForEach(issues, id: \.text) { issue in
              HStack(spacing: 6) {
                BlitzStatusDot(tone: issue.tone, diameter: 6)
                Text(issue.text).font(BlitzType.callout).foregroundStyle(BlitzUI.supportingText)
              }
            }
          }
        }
      }
      Spacer(minLength: 16)
      if !ledger.wins.isEmpty {
        VStack(alignment: .trailing, spacing: 2) {
          Text(ByteText.compact(ledger.internalGains)).font(BlitzNumberFont.value(20))
            .monospacedDigit()
          Text("freed by BlitzClean").font(BlitzType.caption)
            .foregroundStyle(BlitzUI.tertiaryText)
        }
      }
    }.blitzCard(padding: 20)
  }

  // MARK: Tiles

  private var storageTile: some View {
    let snapshot = monitor.snapshot
    let total = Double(max(1, snapshot.diskTotal))
    let segments: [SegmentedBar.Segment] =
      drive.breakdown.map { breakdown in
        DriveGroup.allCases.compactMap { group in
          let bytes = breakdown.bytes(group)
          return bytes == 0
            ? nil : .init(id: group.rawValue, color: group.color, fraction: Double(bytes) / total)
        }
      } ?? [
        .init(id: "used", color: BlitzPalette.storage, fraction: snapshot.diskUsedRatio)
      ]
    return ResourceTile(
      title: "Storage", symbol: "internaldrive.fill", color: BlitzPalette.storage,
      value: ByteText.compact(snapshot.diskAvailable),
      unit: "free of \(ByteText.compact(snapshot.diskTotal))",
      status: storageTone == .good
        ? "Healthy" : storageTone == .critical ? "Almost full" : "Getting full",
      tone: storageTone,
      detail: largestGroup.map {
        "Largest: \($0.group.shortTitle) · \(ByteText.compact($0.bytes))"
      },
      action: .init(title: "See breakdown") { openDrive() },
      onOpen: openDrive,
      visual:
        SegmentedBar(segments: segments, height: 6)
    )
  }

  private var memoryTile: some View {
    let snapshot = monitor.snapshot
    let swap = memory.sample?.swapUsed ?? 0
    let idle = idleConsumers
    let top = processes.consumers.first { commands.canStop($0) && !$0.isPaused }
    let action: ResourceVerdict.Action =
      if let first = idle.first {
        .init(
          title:
            "\(commands.stopTitle(first)) \(short(first.name)) · \(ByteText.compact(first.memoryBytes))"
        ) {
          commands.stop(first)
        }
      } else if memoryTone == .warning || memoryTone == .critical, let top {
        .init(
          title:
            "\(commands.stopTitle(top)) \(short(top.name)) · \(ByteText.compact(top.memoryBytes))"
        ) {
          commands.stop(top)
        }
      } else {
        .init(title: "See what uses memory") { navigation.page = .memory }
      }
    return ResourceTile(
      title: "Memory", symbol: "memorychip.fill", color: BlitzPalette.memory,
      value: ByteText.compact(snapshot.ramAvailable),
      unit: "free of \(ByteText.compact(snapshot.ramTotal))",
      status: memoryTone == .good
        ? "Healthy"
        : memoryTone == .critical ? "Critical" : memoryTone == .warning ? "Short" : "Rising",
      tone: memoryTone,
      detail: swap >= 1_073_741_824
        ? "\(ByteText.compact(swap)) moved to disk" : top.map { "Biggest: \($0.name)" },
      action: action, onOpen: { navigation.page = .memory },
      visual:
        SegmentedBar(
          segments: [
            .init(id: "used", color: BlitzPalette.memory, fraction: snapshot.ramUsedRatio)
          ], height: 6)
    )
  }

  private var cpuTile: some View {
    let usage = monitor.snapshot.cpuUsage ?? 0
    let busy = processes.consumers.filter {
      $0.kind != .system && !$0.isPaused
        && processes.activity.busy(.init(id: $0.id, now: .now)) >= ConsumerActivity.runawayAfter
    }.max { $0.cpuPercent < $1.cpuPercent }
    let top = processes.consumers.filter { $0.kind != .system }.max {
      $0.cpuPercent < $1.cpuPercent
    }
    let action: ResourceVerdict.Action =
      if let busy, busy.canSignal {
        .init(title: "Pause \(short(busy.name))") {
          processes.signal(.init(consumer: busy, signal: .pause))
        }
      } else {
        .init(title: "See what uses CPU") { navigation.page = .cpu }
      }
    return ResourceTile(
      title: "CPU", symbol: "cpu.fill", color: BlitzPalette.cpu, value: PercentText.make(usage),
      unit: "of \(ProcessInfo.processInfo.activeProcessorCount) cores",
      status: cpuTone == .good ? "Calm" : cpuTone == .critical ? "Maxed out" : "Busy",
      tone: cpuTone,
      detail: (busy ?? top).flatMap { consumer in
        consumer.cpuPercent >= 20
          ? "\(consumer.name) · \(CPUText.percent(consumer.cpuPercent))" : nil
      },
      action: action, onOpen: { navigation.page = .cpu },
      visual:
        ResourcePlot(
          samples: monitor.resourceSamples, kind: .cpu, color: BlitzPalette.cpu, seconds: 900
        ).frame(height: 36)
    )
  }

  // MARK: Quick wins

  private struct QuickWin: Identifiable {
    let id: String
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    let reward: String?
    let action: ResourceVerdict.Action
  }

  private var quickWins: some View {
    let wins = quickWinList
    return VStack(alignment: .leading, spacing: 10) {
      BlitzGroupLabel(title: wins.isEmpty ? "Quick wins" : "Quick wins · \(wins.count)")
      VStack(spacing: 0) {
        if wins.isEmpty {
          HStack(spacing: 12) {
            BlitzColorTile(symbol: "checkmark", color: BlitzPalette.good, size: 28)
            Text(
              drive.breakdown == nil
                ? "Measuring your drive to find space you can free…"
                : "Nothing worth doing right now. BlitzClean keeps watching."
            )
            .font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
            Spacer()
          }.padding(.horizontal, 16).frame(minHeight: 52)
        }
        ForEach(wins) { win in
          winRow(win)
          if win.id != wins.last?.id { BlitzRowDivider(leading: 56) }
        }
      }.blitzCard(padding: 0)
    }
  }

  private func winRow(_ win: QuickWin) -> some View {
    HStack(spacing: 12) {
      BlitzColorTile(symbol: win.symbol, color: win.color, size: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(win.title).font(BlitzType.rowTitle).lineLimit(1)
        Text(win.detail).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.tail)
      }.frame(maxWidth: .infinity, alignment: .leading)
      if let reward = win.reward {
        Text(reward).font(BlitzType.numeric).foregroundStyle(BlitzUI.supportingText)
      }
      Button(action: win.action.perform) { BlitzActionLabel(title: win.action.title) }
        .blitzButton(.secondary)
        .controlSize(.small).frame(minWidth: 72, alignment: .trailing)
        .disabled(drive.busyID != nil)
    }.padding(.horizontal, 16).frame(minHeight: 56)
  }

  private var quickWinList: [QuickWin] {
    var wins: [QuickWin] = []
    let units = drive.breakdown?.units ?? []
    if let trash = units.first(where: { $0.removal == .emptyTrash }), trash.bytes >= 100_000_000 {
      wins.append(
        .init(
          id: "trash", symbol: "trash.fill", color: DriveGroup.trash.color,
          title: "Empty the Trash",
          detail: "Deleted files still take space until the Trash is emptied",
          reward: ByteText.compact(trash.bytes),
          action: .init(title: "Empty") { confirm([trash]) }))
    }
    let caches = cacheUnits
    let cacheBytes = caches.reduce(0) { $0 + $1.bytes }
    if cacheBytes >= 500_000_000 {
      wins.append(
        .init(
          id: "caches", symbol: "sparkles", color: DriveGroup.caches.color,
          title: "Delete caches",
          detail: "\(caches.count) cache folders · apps and tools rebuild them",
          reward: ByteText.compact(cacheBytes), action: .init(title: "Delete") { confirm(caches) }))
    }
    let runtimes = units.filter { $0.removal == .simulatorRuntime }.sorted {
      $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
    if runtimes.count > 1 {
      let old = Array(runtimes.dropLast())
      wins.append(
        .init(
          id: "runtimes", symbol: "iphone.gen3", color: DriveGroup.simulators.color,
          title: "Delete old iOS simulators",
          detail: old.map(\.title).joined(separator: ", ")
            + " · keeps \(runtimes.last?.title ?? "the newest")",
          reward: ByteText.compact(old.reduce(0) { $0 + $1.bytes }),
          action: .init(title: "Delete") { confirm(old) }))
    }
    let allWorktrees = worktrees.artifacts.filter { $0.kind == .worktree }
    let merged = allWorktrees.filter { $0.blocker == nil }
    let mergedBytes = merged.reduce(0) { $0 + ($1.bytes ?? 0) }
    if mergedBytes >= 200_000_000 {
      let model = worktrees
      let history = history
      wins.append(
        .init(
          id: "worktrees", symbol: "arrow.triangle.branch",
          color: Color(red: 0.95, green: 0.42, blue: 0.20),
          title: "Remove merged worktrees",
          detail: "\(merged.count) project copies already merged · branches stay",
          reward: ByteText.compact(mergedBytes),
          action: .init(title: "Remove") {
            pending = .init(
              title: "Remove \(merged.count) merged worktrees?",
              message: merged.map(\.path).joined(separator: "\n")
                + "\n\nGit checks each again for local changes before removing it.",
              confirmTitle: "Remove \(ByteText.compact(mergedBytes))",
              perform: {
                for item in merged {
                  model.remove(.init(artifact: item, history: history, force: false))
                }
              })
          }))
    }
    let unmergedBytes = allWorktrees.filter { $0.blocker != nil }.reduce(0) { $0 + ($1.bytes ?? 0) }
    if unmergedBytes >= 2_000_000_000 {
      wins.append(
        .init(
          id: "worktrees-review", symbol: "arrow.triangle.branch", color: Color(white: 0.5),
          title: "Review unmerged worktrees",
          detail: "\(allWorktrees.count - merged.count) copies with unmerged or local changes",
          reward: ByteText.compact(unmergedBytes),
          action: .init(title: "Review") { openDrive() }))
    }
    let idle = idleConsumers
    if !idle.isEmpty {
      let bytes = idle.reduce(0) { $0 + $1.memoryBytes }
      let commands = commands
      wins.append(
        .init(
          id: "idle", symbol: "moon.zzz.fill", color: BlitzPalette.memory,
          title: "Close idle apps and sessions",
          detail: idle.prefix(3).map(\.name).joined(separator: ", ")
            + " · unused for 30 minutes",
          reward: "\(ByteText.compact(bytes)) RAM",
          action: .init(title: "Close") {
            pending = .init(
              title: "Close \(idle.count) idle items?",
              message: idle.map { "\($0.name) · \(ByteText.compact($0.memoryBytes))" }.joined(
                separator: "\n")
                + "\n\nNone of these used the CPU in the last 30 minutes. Apps can still show save dialogs.",
              confirmTitle: "Close \(idle.count)", perform: { commands.stopAll(idle) })
          }))
    }
    let detached = processes.threads.filter { $0.isDetached && !$0.isPaused }
    if !detached.isEmpty {
      wins.append(
        .init(
          id: "detached", symbol: "bolt.horizontal.circle.fill", color: BlitzPalette.apps,
          title: "Quit detached AI sessions",
          detail: "Their terminal already closed · \(detached.count) still running",
          reward: "\(ByteText.compact(detached.reduce(0) { $0 + $1.memoryBytes })) RAM",
          action: .init(title: "Quit") {
            for thread in detached { processes.stopThread(thread, force: false) }
          }))
    }
    if recovery.attentionCount > 0 {
      wins.append(
        .init(
          id: "recovery", symbol: "waveform.path.ecg", color: BlitzPalette.apps,
          title: "Revive frozen apps",
          detail: "\(recovery.attentionCount) not responding", reward: nil,
          action: .init(title: "Revive") { navigation.page = .recovery }))
    }
    let dependencies = storage.readyItems.reduce(0) { $0 + $1.bytes }
    if dependencies >= 1_000_000_000 {
      wins.append(
        .init(
          id: "dependencies", symbol: "shippingbox.fill", color: DriveGroup.home.color,
          title: "Remove unused dependencies",
          detail: "\(storage.readyItems.count) idle node_modules and build folders",
          reward: ByteText.compact(dependencies),
          action: .init(title: "Review") { openCleanup(.projects) }))
    }
    if storage.oldFiles.totalBytes >= 500_000_000 {
      wins.append(
        .init(
          id: "old", symbol: "clock.arrow.circlepath", color: DriveGroup.personal.color,
          title: "Old downloads and screenshots",
          detail:
            "\(storage.oldFiles.visibleItems.count) items unused for \(storage.oldFiles.age.title)",
          reward: ByteText.compact(storage.oldFiles.totalBytes),
          action: .init(title: "Review") { openCleanup(.oldFiles) }))
    }
    return wins
  }

  // MARK: Helpers

  private var cacheUnits: [DriveUnit] {
    (drive.breakdown?.units ?? []).filter {
      $0.group == .caches && $0.removal == .deleteContents && $0.bytes > 0
    }
  }

  private var idleConsumers: [ResourceConsumer] {
    FreeMemoryPlan.idle(
      .init(
        consumers: processes.consumers, activity: processes.activity,
        quittableApps: commands.quittableApps, now: .now))
  }

  private var largestGroup: (group: DriveGroup, bytes: UInt64)? {
    guard let breakdown = drive.breakdown else { return nil }
    return DriveGroup.allCases.filter { $0 != .system }.map { ($0, breakdown.bytes($0)) }
      .max { $0.1 < $1.1 }
  }

  private func confirm(_ units: [DriveUnit]) {
    let review = DriveConfirmation(units)
    let drive = drive
    pending = .init(
      title: review.title, message: review.message, confirmTitle: review.confirmTitle,
      perform: { drive.remove(units) })
  }

  private func openDrive() {
    navigation.storagePage = .drive
    navigation.page = .storage
  }

  private func openCleanup(_ focus: StorageCleanupFocus) {
    storage.cleanupFocus = focus
    navigation.storagePage = .cleanup
    navigation.page = .storage
  }

  private func short(_ name: String) -> String {
    name.count > 18 ? String(name.prefix(17)) + "…" : name
  }
}

/// One resource on Overview: icon, headline value, a visual, what is behind it and one action.
struct ResourceTile<Visual: View>: View {
  let title: String
  let symbol: String
  let color: Color
  let value: String
  let unit: String
  let status: String
  let tone: BlitzStatusTone
  let detail: String?
  let action: ResourceVerdict.Action
  let onOpen: () -> Void
  let visual: Visual
  @State private var hovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(action: onOpen) {
        HStack(spacing: 10) {
          BlitzColorTile(symbol: symbol, color: color, size: 26)
          Text(title).font(.system(size: 13, weight: .semibold))
            .foregroundStyle(BlitzUI.primaryText)
          Spacer()
          HStack(spacing: 5) {
            BlitzStatusDot(tone: tone, diameter: 6)
            Text(status).font(BlitzType.caption)
              .foregroundStyle(
                tone == .warning || tone == .critical ? tone.color : BlitzUI.secondaryText)
          }
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(hovered ? BlitzUI.secondaryText : BlitzUI.tertiaryText)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).blitzPointingHand().help("Open \(title)")
        .onHover { hovered = $0 }
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(value).font(BlitzNumberFont.value(30)).monospacedDigit()
        Text(unit).font(BlitzType.body).foregroundStyle(BlitzUI.tertiaryText)
      }.padding(.top, 2)
      visual.frame(height: 36).contentShape(Rectangle()).onTapGesture(perform: onOpen)
        .blitzPointingHand().help("Open \(title)")
      Text(detail ?? " ").font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        .lineLimit(1).truncationMode(.middle)
      Button(action: action.perform) {
        BlitzActionLabel(title: action.title).lineLimit(1).frame(maxWidth: .infinity)
      }.blitzButton(.secondary).controlSize(.small)
    }.blitzCard(padding: 16)
  }
}
