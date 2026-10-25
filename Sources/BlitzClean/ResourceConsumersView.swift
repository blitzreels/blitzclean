import AppKit
import SwiftUI

/// An action waiting for inline confirmation at the bottom of the page.
struct PendingProcessAction {
  let title: String
  let message: String
  let confirmTitle: String
  let perform: () -> Void
}

enum ConsumerMetric {
  case memory, cpu
}

/// Runs the actions offered on consumer rows, routing apps through their quit flow and the rest through signals.
@MainActor
struct ConsumerCommands {
  let processes: DevProcessModel
  let memory: MemoryRescueModel

  func app(_ consumer: ResourceConsumer) -> MemoryCandidate? {
    guard consumer.kind == .app else { return nil }
    return memory.candidates.first { $0.app.name == consumer.name }
  }

  var quittableApps: Set<String> {
    Set(
      memory.candidates.filter { $0.app.isTerminationEligible && !$0.app.isActive }
        .map(\.app.name))
  }

  func canStop(_ consumer: ResourceConsumer) -> Bool {
    consumer.canSignal || app(consumer)?.app.isTerminationEligible == true
  }

  func stopTitle(_ consumer: ResourceConsumer) -> String {
    consumer.kind == .app ? "Quit" : "Stop"
  }

  func stop(_ consumer: ResourceConsumer) {
    if let app = app(consumer)?.app {
      Task {
        await memory.quit(app)
        processes.refresh()
      }
    } else {
      processes.signal(.init(consumer: consumer, signal: .quit))
    }
  }

  /// Stops several consumers in turn; app quits run one after another because each waits for its app.
  /// Stops every consumer, waits for them to finish, then reports how many closed and what memory came back.
  func stopAll(_ consumers: [ResourceConsumer]) {
    let apps = consumers.compactMap { app($0)?.app }
    let before = ResourceReading.now()
    for consumer in consumers where consumer.canSignal {
      processes.signal(.init(consumer: consumer, signal: .quit))
    }
    let processes = processes
    Task {
      for app in apps { await memory.quit(app) }
      for _ in 0..<60 where consumers.contains(where: { processes.actingConsumers.contains($0.id) })
      {
        try? await Task.sleep(for: .milliseconds(250))
      }
      let after = await ResourceReading.settled()
      processes.refresh()
      let running = Set(
        consumers.flatMap(\.processIDs).filter { kill($0, 0) == 0 || errno == EPERM })
      let closed = consumers.filter { $0.processIDs.allSatisfy { !running.contains($0) } }.count
      processes.report(
        "Closed \(closed) of \(consumers.count). "
          + MeasuredResult.memory(.init(before: before, after: after)))
    }
  }

  func isBusy(_ consumer: ResourceConsumer) -> Bool {
    if let id = consumer.threadID { return processes.stoppingThreads.contains(id) }
    if let app = app(consumer)?.app { return memory.isActing(on: app) }
    return processes.actingConsumers.contains(consumer.id)
  }
}

struct ConsumerBadge: Identifiable {
  let title: String
  let tone: BlitzStatusTone
  var id: String { title }
}

/// One consumer with its value, state badges, one primary action and a menu for the rest.
struct ConsumerRow: View {
  let consumer: ResourceConsumer
  let metric: ConsumerMetric
  let commands: ConsumerCommands
  let activity: ConsumerActivity
  let isBackground: Bool
  let thread: AIThread?
  /// The row's amount against the scale of its list, drawn as a meter under the value.
  let share: Double
  let onConfirm: (PendingProcessAction) -> Void
  let onForceQuitApp: (MemoryApp) -> Void

  var body: some View {
    let candidate = commands.app(consumer)
    let busy = commands.isBusy(consumer)
    HStack(spacing: 12) {
      if consumer.kind == .workload, let directory = consumer.directory {
        ProjectIcon(directory: directory, processName: "", size: 28, fallbackSymbol: symbol)
      } else {
        ApplicationIcon(source: .name(consumer.iconName), size: 28, fallback: symbol)
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(consumer.name).font(BlitzType.rowTitle).lineLimit(1).truncationMode(.middle)
          ForEach(badges) { BlitzStatusBadge(title: $0.title, tone: $0.tone) }
        }
        Text(detail(candidate)).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.middle)
      }.frame(maxWidth: .infinity, alignment: .leading)
        .help(consumer.directory ?? consumer.name)
      VStack(alignment: .trailing, spacing: 5) {
        BlitzTrailingValue(value: value, detail: valueDetail)
        BlitzMeter(fraction: share, tone: .muted, height: 3).frame(width: 64)
      }.frame(width: 84, alignment: .trailing)
      primary(candidate: candidate, busy: busy).frame(width: 96, alignment: .trailing)
      if consumer.kind == .system {
        Color.clear.frame(width: 34, height: 1)
      } else {
        BlitzActionMenu(label: "More actions for \(consumer.name)") {
          menu(candidate)
        }.disabled(busy)
      }
    }.blitzRow()
  }

  private var symbol: String {
    switch consumer.kind {
    case .aiSession: "sparkles"
    case .app: "app"
    case .workload: "terminal"
    case .system: "applelogo"
    }
  }

  private var now: Date { .now }

  private var badges: [ConsumerBadge] {
    var result: [ConsumerBadge] = []
    if consumer.isPaused { result.append(.init(title: "Paused", tone: .warning)) }
    if thread?.isDetached == true, !consumer.isPaused {
      result.append(.init(title: "Detached", tone: .warning))
    }
    let busy = activity.busy(.init(id: consumer.id, now: now))
    if busy >= ConsumerActivity.runawayAfter {
      result.append(.init(title: "Busy \(ResourceLeadersSection.duration(busy))", tone: .warning))
    }
    let idle = activity.idle(.init(id: consumer.id, now: now))
    if !consumer.isPaused, consumer.kind != .system, idle >= ConsumerActivity.idleAfter {
      result.append(.init(title: "Idle \(ResourceLeadersSection.duration(idle))", tone: .muted))
    }
    if isBackground { result.append(.init(title: "Background", tone: .muted)) }
    return result
  }

  private var value: String {
    switch metric {
    case .memory: ByteText.full(consumer.memoryBytes)
    case .cpu: CPUText.percent(consumer.cpuPercent)
    }
  }

  private var valueDetail: String? {
    metric == .cpu && consumer.cpuPercent >= 100 ? CPUText.cores(consumer.cpuPercent) : nil
  }

  private func detail(_ candidate: MemoryCandidate?) -> String {
    var parts: [String] = []
    switch consumer.kind {
    case .aiSession:
      if let thread { parts.append(thread.identityDetail) }
      if let started = thread?.startedAt {
        parts.append("up \(MemoryControlView.uptime(since: started))")
      }
    case .app:
      if let reason = candidate?.app.protectionReason { parts.append(reason) }
      parts.append(count)
    case .workload:
      if let directory = consumer.directory {
        parts.append(
          directory.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
      }
      parts.append(count)
    case .system:
      parts.append("Spotlight, iCloud, Photos and other services · macOS manages them")
    }
    switch metric {
    case .memory where consumer.cpuPercent >= 5 && !consumer.isPaused:
      parts.append("\(CPUText.percent(consumer.cpuPercent)) CPU")
    case .cpu where consumer.memoryBytes > 0:
      parts.append(ByteText.compact(consumer.memoryBytes))
    default: break
    }
    return parts.joined(separator: " · ")
  }

  private var count: String {
    consumer.processIDs.count == 1 ? "1 process" : "\(consumer.processIDs.count) processes"
  }

  @ViewBuilder private func primary(candidate: MemoryCandidate?, busy: Bool) -> some View {
    switch consumer.kind {
    case .aiSession, .workload:
      if consumer.isPaused {
        BlitzProcessButton(title: "Resume", label: "Resume \(consumer.name)", isBusy: busy) {
          commands.processes.signal(.init(consumer: consumer, signal: .resume))
        }
      } else if metric == .cpu {
        BlitzProcessButton(title: "Pause", label: "Pause \(consumer.name)", isBusy: busy) {
          commands.processes.signal(.init(consumer: consumer, signal: .pause))
        }.help("Stops using CPU at once and keeps its state. Resume continues where it was.")
      } else {
        BlitzProcessButton(title: "Stop", label: "Stop \(consumer.name)", isBusy: busy) {
          commands.stop(consumer)
        }.help("Ends these processes to release their memory.")
      }
    case .app:
      if let app = candidate?.app, app.isTerminationEligible {
        BlitzProcessButton(title: "Quit", label: "Quit \(consumer.name)", isBusy: busy) {
          commands.stop(consumer)
        }.help("Asks \(consumer.name) to quit. Its save dialogs can still appear.")
      } else {
        Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(BlitzUI.tertiaryText)
          .help(candidate?.app.protectionReason ?? "macOS keeps this app open")
      }
    case .system:
      EmptyView()
    }
  }

  @ViewBuilder private func menu(_ candidate: MemoryCandidate?) -> some View {
    if consumer.canSignal {
      if consumer.isPaused || metric == .cpu {
        Button("Stop") { commands.stop(consumer) }
      } else {
        Button("Pause — keeps memory") {
          commands.processes.signal(.init(consumer: consumer, signal: .pause))
        }
      }
    }
    if consumer.canSignal || candidate != nil {
      Button(isBackground ? "Normal priority" : "Run in background") {
        commands.processes.setBackground(.init(consumer: consumer, background: !isBackground))
      }
    }
    if consumer.canSignal {
      Button("Force Quit…", role: .destructive) {
        onConfirm(
          .init(
            title: "Force quit \(consumer.name)?",
            message:
              "Ends \(count) immediately, including unsaved work. Frees \(ByteText.full(consumer.memoryBytes)).",
            confirmTitle: "Force Quit",
            perform: {
              commands.processes.signal(.init(consumer: consumer, signal: .forceQuit))
            }))
      }
    } else if let app = candidate?.app, app.isTerminationEligible {
      Button("Force Quit…", role: .destructive) {
        onConfirm(
          .init(
            title: "Force quit \(app.name)?",
            message: "\(app.name) ends immediately. Unsaved changes are lost.",
            confirmTitle: "Force Quit", perform: { onForceQuitApp(app) }))
      }
    }
    if let app = candidate?.app {
      Button("Show in Finder") { Finder.reveal(app.bundleURL.path) }
      if app.protectionReason == nil {
        Divider()
        ForEach(MemoryAppPolicy.allCases, id: \.self) { policy in
          Button {
            commands.memory.setPolicy(.init(app: app, policy: policy))
          } label: {
            MenuCheckLabel(title: policy.title, isOn: candidate?.policy == policy)
          }
        }
      }
    } else if let directory = consumer.directory {
      Button("Show project in Finder") { Finder.reveal(directory) }
    }
    if consumer.canSignal {
      Button("Copy process IDs") {
        Pasteboard.copy(consumer.processIDs.map(String.init).joined(separator: " "))
      }
    }
  }
}

/// A macOS process using CPU; it explains itself instead of offering actions.
struct SystemCPURow: View {
  let process: LiveCPUProcess
  let share: Double

  var body: some View {
    let description = SystemProcessNames.describe(
      .init(name: process.name, executable: process.executable))
    HStack(spacing: 12) {
      if let bundle = ResourceOwnership.appBundle(process.executable) {
        ApplicationIcon(source: .file(bundle), size: 28, fallback: "app")
      } else {
        Image(
          systemName: SystemProcessNames.isSystem(process.executable) ? "applelogo" : "terminal"
        ).frame(width: 28).foregroundStyle(BlitzUI.secondaryText)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(description.title).font(BlitzType.rowTitle).lineLimit(1)
        Text(
          description.title == process.name
            ? description.detail : "\(process.name) · \(description.detail)"
        )
        .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText).lineLimit(1)
      }.frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .trailing, spacing: 5) {
        BlitzTrailingValue(
          value: CPUText.percent(process.percent),
          detail: process.percent >= 100 ? CPUText.cores(process.percent) : nil)
        BlitzMeter(fraction: share, tone: .muted, height: 3).frame(width: 64)
      }.frame(width: 84, alignment: .trailing)
      Color.clear.frame(width: 96 + 12 + 34, height: 1)
    }.blitzRow()
  }
}

enum CPUText {
  static func percent(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))) + "%"
  }

  static func cores(_ value: Double) -> String {
    (value / 100).formatted(.number.precision(.fractionLength(1))) + " cores"
  }
}

/// The answer at the top of a resource page: what is wrong, why, and the one thing to do now.
struct ResourceVerdict {
  struct Action {
    let title: String
    let perform: () -> Void
  }

  let title: String
  let tone: BlitzStatusTone
  let summary: String
  let explanation: String?
  let recommendation: String?
  let primary: Action?
  let secondary: Action?
}

struct ResourceVerdictCard<Chart: View>: View {
  let verdict: ResourceVerdict
  /// Share of the resource in use, drawn as the ring beside the verdict.
  let gauge: Double
  let message: String?
  @ViewBuilder let chart: () -> Chart

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 16) {
        BlitzRingGauge(fraction: gauge, tone: verdict.tone, size: 64, lineWidth: 7) {
          Text(PercentText.make(gauge)).font(BlitzNumberFont.value(15)).monospacedDigit()
            .contentTransition(.numericText())
            .animation(.snappy, value: gauge)
        }
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 8) {
            Text(verdict.title).font(.system(size: 20, weight: .semibold))
            BlitzStatusDot(tone: verdict.tone, diameter: 7)
          }
          Text(verdict.summary).font(BlitzType.callout).foregroundStyle(BlitzUI.secondaryText)
            .monospacedDigit()
        }
      }
      if let explanation = verdict.explanation {
        Text(explanation).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let recommendation = verdict.recommendation {
        HStack(spacing: 12) {
          Image(systemName: "arrow.turn.down.right").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(BlitzUI.tertiaryText)
          Text(recommendation).font(BlitzType.rowTitle)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          if let secondary = verdict.secondary {
            Button(action: secondary.perform) { BlitzActionLabel(title: secondary.title) }
              .blitzButton(.secondary)
              .controlSize(.small)
          }
          if let primary = verdict.primary {
            Button(action: primary.perform) { BlitzActionLabel(title: primary.title) }
              .blitzButton(.accent)
              .controlSize(.small)
          }
        }.padding(.horizontal, 14).padding(.vertical, 10)
          .background(
            Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      if let message { BlitzStatusLine(text: message, tone: .working) }
      Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
      chart()
    }.blitzCard(padding: 20)
  }
}
