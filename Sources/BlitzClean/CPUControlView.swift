import AppKit
import SwiftUI

struct CPUControlView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var memory: MemoryRescueModel
  @AppStorage("history.cpuSeconds") private var seconds = 86_400.0
  @State private var pending: PendingProcessAction?
  @State private var appResult: String?
  @State private var showsAll = false
  @StateObject private var forceQuit = ForceQuitModel()

  private static let rowLimit = 8
  private var commands: ConsumerCommands { .init(processes: processes, memory: memory) }

  private enum Item: Identifiable {
    case consumer(ResourceConsumer)
    case system(LiveCPUProcess)

    var id: String {
      switch self {
      case .consumer(let consumer): consumer.id
      case .system(let process): "pid:\(process.id)"
      }
    }

    var cpu: Double {
      switch self {
      case .consumer(let consumer): consumer.cpuPercent
      case .system(let process): process.percent
      }
    }
  }

  /// Consumers the user can act on, plus macOS processes explained in plain words, busiest first.
  private var items: [Item] {
    let actionable = processes.consumers.filter { $0.kind != .system }
    let consumers = actionable.filter { $0.cpuPercent >= 1 }
    let owned = Set(actionable.flatMap(\.processIDs))
    let own = getpid()
    let system = monitor.topCPUProcesses.filter {
      !owned.contains($0.id) && $0.id != own && $0.percent >= 3
    }
    return (consumers.map(Item.consumer) + system.map(Item.system)).sorted { $0.cpu > $1.cpu }
  }

  private var runaway: ResourceConsumer? {
    processes.consumers.filter {
      $0.kind != .system && !$0.isPaused
        && processes.activity.busy(.init(id: $0.id, now: .now)) >= ConsumerActivity.runawayAfter
    }.max { $0.cpuPercent < $1.cpuPercent }
  }

  var body: some View {
    let items = items
    let visible = showsAll ? items : Array(items.prefix(Self.rowLimit))
    let threads = processes.threadsByID
    let busiest = max(1, items.first?.cpu ?? 1)
    return ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        ResourceVerdictCard(
          verdict: verdict, gauge: monitor.snapshot.cpuUsage ?? 0,
          message: appResult ?? processes.consumerMessage ?? processes.threadMessage
        ) {
          VStack(alignment: .leading, spacing: 16) {
            HStack {
              BlitzGroupLabel(title: "History")
              Spacer()
              HistoryRangePicker(seconds: $seconds)
            }
            ResourcePlot(
              samples: monitor.resourceSamples, kind: .cpu, color: verdict.tone.meterColor,
              seconds: seconds, isDetailed: true
            )
            .frame(height: 130)
            .help("Total CPU usage across all cores, from 0 to 100%")
          }
        }
        VStack(alignment: .leading, spacing: 10) {
          BlitzSectionHeader(title: "Using CPU now", count: nil) {
            Button("Open Activity Monitor") {
              NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }.blitzButton(.quiet).controlSize(.small)
          }
          LazyVStack(spacing: 0) {
            if items.isEmpty {
              BlitzEmptyRow(
                text: processes.scannedAt == nil ? "Measuring CPU activity…" : "Nothing is busy",
                isLoading: processes.scannedAt == nil)
            }
            ForEach(visible) { item in
              switch item {
              case .consumer(let consumer):
                ConsumerRow(
                  consumer: consumer, metric: .cpu, commands: commands,
                  activity: processes.activity,
                  isBackground: processes.backgrounded.contains(consumer.id),
                  thread: consumer.threadID.flatMap { threads[$0] },
                  share: consumer.cpuPercent / busiest,
                  onConfirm: { pending = $0 }, onForceQuitApp: forceQuitApp)
              case .system(let process):
                SystemCPURow(process: process, share: process.percent / busiest)
              }
              if item.id != visible.last?.id { BlitzRowDivider(leading: 56) }
            }
          }.blitzTable()
          if items.count > Self.rowLimit {
            BlitzShowAllButton(total: items.count, noun: "items", isExpanded: $showsAll)
          }
          Text(
            "100% equals one core. Pause stops a task and keeps its state; Run in background lets it use only spare CPU."
          )
          .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        }
        ResourceLeadersSection(
          samples: monitor.resourceSamples, kind: .cpu, seconds: seconds, limit: 5,
          action: { leader in
            guard
              let consumer = processes.consumers.first(where: {
                $0.name == leader.name && $0.canSignal && !$0.isPaused && $0.cpuPercent >= 5
              })
            else { return nil }
            return .init(title: "Pause") {
              processes.signal(.init(consumer: consumer, signal: .pause))
            }
          })
      }.padding(BlitzUI.pagePadding)
    }
    .task { processes.refresh() }
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

  private var verdict: ResourceVerdict {
    let usage = monitor.snapshot.cpuUsage ?? 0
    let cores = ProcessInfo.processInfo.activeProcessorCount
    let tone = MenuBarTones.cpu(usage)
    let title =
      switch tone {
      case .critical: "CPU is maxed out"
      case .warning: "CPU is busy"
      default: usage >= 0.5 ? "CPU is working" : "CPU is calm"
      }
    let top = processes.consumers.filter { $0.kind != .system }
      .max { $0.cpuPercent < $1.cpuPercent }
    var summary = "\(PercentText.make(usage)) of \(cores) cores in use"
    if let top, top.cpuPercent >= 50 {
      summary += " · \(top.name) uses \(CPUText.cores(top.cpuPercent))"
    }
    let thermal = monitor.snapshot.thermalStatus
    let explanation: String? =
      thermal != .nominal
      ? "Your Mac is hot (\(thermal.title)). macOS slows the CPU until it cools; stopping busy work helps."
      : nil
    let target: ResourceConsumer? =
      runaway ?? (usage >= 0.5 && (top?.cpuPercent ?? 0) >= 100 ? top : nil)
    guard let target else {
      return .init(
        title: title, tone: tone, summary: summary, explanation: explanation,
        recommendation: nil, primary: nil, secondary: nil)
    }
    let busy = processes.activity.busy(.init(id: target.id, now: .now))
    let recommendation =
      busy >= ConsumerActivity.runawayAfter
      ? "\(target.name) has used \(CPUText.cores(target.cpuPercent)) for \(ResourceLeadersSection.duration(busy))."
      : "\(target.name) is using \(CPUText.cores(target.cpuPercent)) right now."
    let commands = commands
    let primary: ResourceVerdict.Action? =
      target.canSignal
      ? .init(title: "Pause") { processes.signal(.init(consumer: target, signal: .pause)) }
      : commands.canStop(target) ? .init(title: "Quit") { commands.stop(target) } : nil
    let background = processes.backgrounded.contains(target.id)
    return .init(
      title: title, tone: tone, summary: summary, explanation: explanation,
      recommendation: recommendation, primary: primary,
      secondary: background
        ? nil
        : .init(title: "Run in background") {
          processes.setBackground(.init(consumer: target, background: true))
        })
  }

  private func forceQuitApp(_ app: MemoryApp) {
    appResult = nil
    Task {
      if let message = await forceQuit.runAndDescribe(app) { appResult = message }
      memory.refresh()
      processes.refresh()
    }
  }
}
