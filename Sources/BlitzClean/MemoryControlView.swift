import AppKit
import SwiftUI

struct MemoryControlView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var model: MemoryRescueModel
  @ObservedObject var processes: DevProcessModel
  @AppStorage("history.memorySeconds") private var seconds = 86_400.0
  @State private var query = ""
  @State private var listingMode = MemoryListingMode.apps
  @State private var showsAll = false
  @State private var pending: PendingProcessAction?
  @State private var appResult: String?
  @StateObject private var forceQuit = ForceQuitModel()
  @StateObject private var background = BackgroundLoadModel()

  private static let rowLimit = 10

  private var commands: ConsumerCommands { .init(processes: processes, memory: model) }

  private var consumers: [ResourceConsumer] {
    let all = processes.consumers.sorted { $0.memoryBytes > $1.memoryBytes }
    guard !query.isEmpty else { return all }
    let threads = processes.threadsByID
    return all.filter { consumer in
      consumer.name.localizedCaseInsensitiveContains(query)
        || consumer.directory?.localizedCaseInsensitiveContains(query) == true
        || consumer.threadID.flatMap { threads[$0] }?.matches(query) == true
    }
  }

  var body: some View {
    let consumers = consumers
    let idle = FreeMemoryPlan.idle(
      .init(
        consumers: processes.consumers, activity: processes.activity,
        quittableApps: commands.quittableApps, now: .now))
    return ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        let verdict = verdict(idle)
        ResourceVerdictCard(
          verdict: verdict, gauge: monitor.snapshot.ramUsedRatio,
          message: appResult ?? processes.threadMessage
            ?? processes.consumerMessage ?? model.statusMessage
        ) {
          VStack(alignment: .leading, spacing: 16) {
            MemoryComposition(
              total: monitor.snapshot.ramTotal, available: monitor.snapshot.ramAvailable,
              compressed: model.sample?.compressed, swap: model.sample?.swapUsed,
              tone: verdict.tone)
            HStack {
              BlitzGroupLabel(title: "History")
              Spacer()
              HistoryRangePicker(seconds: $seconds)
            }
            ResourcePlot(
              samples: monitor.resourceSamples, kind: .memory, color: verdict.tone.meterColor,
              seconds: seconds, isDetailed: true
            ).frame(height: 130)
          }
        }
        PausedBuildsSection(processes: processes)
        HStack {
          BlitzSegmentedPicker(
            title: "Memory breakdown", options: MemoryListingMode.allCases,
            selection: $listingMode, label: { $0.rawValue }
          ).frame(maxWidth: 280)
          Spacer()
          detachedButton
        }
        if listingMode == .processes {
          MemoryProcessesView(
            processes: processes.resources, isLoading: processes.scannedAt == nil,
            query: query, scanMessage: processes.statusMessage)
        } else {
          consumerList(consumers)
        }
        ResourceLeadersSection(
          samples: monitor.resourceSamples, kind: .memory, seconds: seconds, limit: 3,
          action: { leader in
            let commands = commands
            guard
              let consumer = processes.consumers.first(where: {
                $0.name == leader.name && commands.canStop($0) && !$0.isPaused
              })
            else { return nil }
            return .init(title: commands.stopTitle(consumer)) { commands.stop(consumer) }
          })
        BackgroundLoadSection(
          model: background, resources: processes.resources, onConfirm: { pending = $0 })
        pressureSection
      }.padding(BlitzUI.pagePadding)
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      PageSearchBar(
        title: listingMode == .processes
          ? "Search processes, apps or PID" : "Search apps, AI sessions or projects",
        text: $query)
    }
    .task {
      model.refresh()
      processes.refresh()
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let action = pending {
        BlitzConfirmation(
          title: action.title, message: action.message, confirmTitle: action.confirmTitle,
          onConfirm: {
            pending = nil
            action.perform()
          }, onCancel: { pending = nil })
      }
    }
  }

  // MARK: Verdict

  private func verdict(_ idle: [ResourceConsumer]) -> ResourceVerdict {
    let snapshot = monitor.snapshot
    let swap = model.sample?.swapUsed ?? 0
    let risk = processes.pressure.risk
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    let title =
      switch risk {
      case .normal: "Memory is fine"
      case .growing: "Memory use is rising"
      case .warning: "Memory is short"
      case .critical: "Memory is critically short"
      }
    var summary =
      "\(ByteText.compact(snapshot.ramUsed)) of \(ByteText.compact(snapshot.ramTotal)) in use · \(ByteText.compact(snapshot.ramAvailable)) free"
    if swap >= gib { summary += " · \(ByteText.compact(swap)) moved to disk" }
    let explanation: String? =
      if risk >= .warning {
        "macOS is moving memory to disk, which slows every app. Close what you are not using."
      } else if swap >= snapshot.ramTotal / 4, swap >= 4 * gib {
        "\(ByteText.compact(swap)) is still on disk from earlier. It drains as memory frees up; a restart clears it at once."
      } else { nil }
    let commands = commands
    if let first = idle.first {
      let total = idle.reduce(0) { $0 + $1.memoryBytes }
      let idleFor = processes.activity.idle(.init(id: first.id, now: .now))
      return ResourceVerdict(
        title: title, tone: risk.tone, summary: summary, explanation: explanation,
        recommendation:
          "\(first.name) has been idle \(ResourceLeadersSection.duration(idleFor)) and holds \(ByteText.compact(first.memoryBytes)).",
        primary: .init(title: "\(commands.stopTitle(first)) \(short(first.name))") {
          commands.stop(first)
        },
        secondary: idle.count > 1
          ? .init(title: "Free \(ByteText.compact(total))") {
            pending = .init(
              title: "Stop \(idle.count) idle items?",
              message: idle.map { "\($0.name) · \(ByteText.compact($0.memoryBytes))" }.joined(
                separator: "\n")
                + "\n\nNone of these used the CPU in the last 30 minutes. Apps are asked to quit, so their save dialogs can still appear.",
              confirmTitle: "Free \(ByteText.compact(total))",
              perform: { commands.stopAll(idle) })
          } : nil)
    }
    if risk >= .warning,
      let top = processes.consumers.first(where: { commands.canStop($0) && !$0.isPaused })
    {
      return ResourceVerdict(
        title: title, tone: risk.tone, summary: summary, explanation: explanation,
        recommendation:
          "\(top.name) uses the most memory: \(ByteText.compact(top.memoryBytes)).",
        primary: .init(title: "\(commands.stopTitle(top)) \(short(top.name))") {
          commands.stop(top)
        }, secondary: nil)
    }
    return ResourceVerdict(
      title: title, tone: risk.tone, summary: summary, explanation: explanation,
      recommendation: nil, primary: nil, secondary: nil)
  }

  private func short(_ name: String) -> String {
    name.count > 22 ? String(name.prefix(21)) + "…" : name
  }

  // MARK: List

  @ViewBuilder private var detachedButton: some View {
    let detached = processes.threads.filter { $0.isDetached && !$0.isPaused }
    if !detached.isEmpty {
      Button("Quit \(detached.count) detached…") {
        pending = .init(
          title: "Quit \(detached.count) detached AI agents?",
          message:
            "Their app or terminal already closed, so nothing is using them. \(detached.map { $0.project ?? $0.name }.joined(separator: ", ")) · \(ByteText.full(detached.reduce(0) { $0 + $1.memoryBytes })).",
          confirmTitle: "Quit detached",
          perform: { for thread in detached { processes.stopThread(thread, force: false) } })
      }.blitzButton(.secondary).controlSize(.small)
        .help("Agents whose app or terminal already closed")
    }
  }

  private func consumerList(_ consumers: [ResourceConsumer]) -> some View {
    let visible =
      showsAll || !query.isEmpty ? consumers : Array(consumers.prefix(Self.rowLimit))
    let threads = processes.threadsByID
    return VStack(alignment: .leading, spacing: 10) {
      BlitzSectionHeader(title: "Using memory", count: consumers.count) {
        Text("Helpers count toward their app").font(BlitzType.caption)
          .foregroundStyle(BlitzUI.tertiaryText)
      }
      LazyVStack(spacing: 0) {
        if consumers.isEmpty {
          BlitzEmptyRow(
            text: processes.scannedAt == nil
              ? "Reading what uses memory…" : query.isEmpty ? "Nothing to show" : "No matches",
            isLoading: processes.scannedAt == nil)
        }
        ForEach(visible) { consumer in
          ConsumerRow(
            consumer: consumer, metric: .memory, commands: commands,
            activity: processes.activity,
            isBackground: processes.backgrounded.contains(consumer.id),
            thread: consumer.threadID.flatMap { threads[$0] },
            share: Double(consumer.memoryBytes) / Double(max(1, monitor.snapshot.ramTotal)),
            onConfirm: { pending = $0 }, onForceQuitApp: forceQuitApp)
          if consumer.id != visible.last?.id { BlitzRowDivider(leading: 56) }
        }
      }.blitzTable()
      if consumers.count > Self.rowLimit, query.isEmpty {
        BlitzShowAllButton(total: consumers.count, noun: "items", isExpanded: $showsAll)
      }
    }
  }

  @ViewBuilder private var pressureSection: some View {
    let since = Date.now.addingTimeInterval(-86_400)
    let events = Array(
      model.incidents.filter { $0.kind == "pressure" && $0.date > since }.prefix(8))
    if !events.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        BlitzSectionHeader(title: "Pressure in the last 24 hours", count: nil) {}
        VStack(spacing: 0) {
          ForEach(events) { event in
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 2) {
                Text(event.displayTitle).font(BlitzType.rowTitle)
                if !event.apps.isEmpty {
                  Text(
                    event.apps.prefix(3).map { "\($0.name) \(ByteText.compact($0.bytes))" }
                      .joined(separator: " · ")
                  ).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText).lineLimit(1)
                }
              }
              Spacer()
              Text(event.date, format: .dateTime.hour().minute()).font(BlitzType.numeric)
                .foregroundStyle(BlitzUI.tertiaryText)
            }.blitzRow()
            if event.id != events.last?.id { BlitzRowDivider(leading: 16) }
          }
        }.blitzTable()
      }
    }
  }

  nonisolated static func uptime(since date: Date, now: Date = .now) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 24 * 60 { return "\(minutes / 60)h \(minutes % 60)m" }
    return "\(minutes / (24 * 60))d \(minutes / 60 % 24)h"
  }

  // MARK: Actions

  private func forceQuitApp(_ app: MemoryApp) {
    appResult = nil
    Task {
      if let message = await forceQuit.runAndDescribe(app) { appResult = message }
      model.refresh()
      monitor.refresh()
      processes.refresh()
    }
  }
}

struct AIThreadRow: View {
  let thread: AIThread
  let isBusy: Bool
  let onPause: () -> Void
  let onResume: () -> Void
  let onQuit: () -> Void
  let onForceQuit: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      ApplicationIcon(
        source: .name(thread.tool.appName ?? thread.name), size: 28, fallback: "sparkles")
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(thread.displayName)
            .font(BlitzType.rowTitle).lineLimit(1)
          if thread.isPaused {
            BlitzStatusBadge(title: "Paused", tone: .warning)
          } else if thread.isDetached {
            BlitzStatusBadge(title: "Detached", tone: .warning)
          }
        }
        Text(thread.identityDetail).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.middle)
        Text(detail).font(BlitzType.caption).foregroundStyle(BlitzUI.tertiaryText)
          .lineLimit(1).truncationMode(.middle)
      }.frame(maxWidth: .infinity, alignment: .leading)
        .help(
          [thread.displayName, thread.identityDetail, thread.directory].compactMap { $0 }.joined(
            separator: "\n"))
      BlitzTrailingValue(value: ByteText.full(thread.memoryBytes), detail: nil)
        .frame(width: 80, alignment: .trailing)
      primaryButton
        .frame(width: 96, alignment: .trailing)
        .help(
          thread.isPaused
            ? "Resume these suspended local workers."
            : "End these local workers to release their memory. Remote generation may continue.")
      BlitzActionMenu(label: "More actions for \(thread.displayName)") {
        if thread.isPaused {
          Button("Stop", action: onQuit)
        } else {
          Button("Suspend — keeps memory", action: onPause)
        }
        Button("Force Quit…", role: .destructive) { onForceQuit() }
        if let directory = thread.directory {
          Button("Show project in Finder") { Finder.reveal(directory) }
        }
        Button("Copy process IDs") {
          Pasteboard.copy(thread.processIDs.map(String.init).joined(separator: " "))
        }
      }.disabled(isBusy)
    }.blitzRow()
  }

  var primaryButton: BlitzProcessButton {
    BlitzProcessButton(
      title: thread.isPaused ? "Resume" : "Stop",
      label: "\(thread.isPaused ? "Resume" : "Stop") \(thread.displayName)",
      isBusy: isBusy, action: thread.isPaused ? onResume : onQuit)
  }

  private var detail: String {
    var parts: [String] = []
    if thread.isPaused { parts.append("CPU stopped · RAM still held") }
    if let terminal = thread.terminal { parts.append(terminal) }
    if let startedAt = thread.startedAt {
      parts.append("up \(MemoryControlView.uptime(since: startedAt))")
    }
    parts.append(
      thread.processIDs.count == 1 ? "1 process" : "\(thread.processIDs.count) processes")
    if !thread.isPaused, thread.cpuPercent >= 5 {
      parts.append("\(thread.cpuPercent.formatted(.number.precision(.fractionLength(0))))% CPU")
    }
    return parts.joined(separator: " · ")
  }
}

extension MemoryRisk {
  /// Rising memory is reported in gray; amber and red start at warning.
  var tone: BlitzStatusTone {
    switch self {
    case .normal: .good
    case .growing: .working
    case .warning: .warning
    case .critical: .critical
    }
  }
}

/// What the memory is doing right now: apps, compressed and free as one bar, with what spilled to disk.
struct MemoryComposition: View {
  let total: UInt64
  let available: UInt64
  let compressed: UInt64?
  let swap: UInt64?
  let tone: BlitzStatusTone

  private struct Part: Identifiable {
    let id: String
    let color: Color
    let bytes: UInt64
  }

  private var parts: [Part] {
    let free = min(total, available)
    let squeezed = min(compressed ?? 0, total - free)
    let ink = tone.meterColor
    return [
      .init(id: "Apps", color: ink, bytes: total - free - squeezed),
      .init(id: "Compressed", color: ink.opacity(0.45), bytes: squeezed),
      .init(id: "Free", color: Color.white.opacity(0.16), bytes: free),
    ]
  }

  var body: some View {
    let parts = parts
    VStack(alignment: .leading, spacing: 12) {
      SegmentedBar(
        segments: parts.map {
          .init(
            id: $0.id, color: $0.color, fraction: total > 0 ? Double($0.bytes) / Double(total) : 0)
        }, height: 10
      )
      .animation(.spring(response: 0.5, dampingFraction: 0.9), value: available)
      HStack(spacing: 18) {
        ForEach(parts) { part in
          HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 8, height: 8)
            Text(part.id).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
            Text(ByteText.compact(part.bytes)).font(BlitzType.captionEmphasis).monospacedDigit()
              .contentTransition(.numericText())
          }
        }
        Spacer(minLength: 0)
        if let swap, swap > 0 {
          Label("\(ByteText.compact(swap)) moved to disk", systemImage: "arrow.down.to.line")
            .font(BlitzType.captionEmphasis).monospacedDigit()
            .foregroundStyle(swap >= total / 4 ? BlitzUI.warning : BlitzUI.secondaryText)
            .help("Memory macOS moved to disk (swap). Reading it back is slow.")
        }
      }
    }
  }
}
