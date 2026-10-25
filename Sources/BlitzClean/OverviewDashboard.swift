import SwiftUI

/// Overview: each problem the Mac has right now, in plain words, with the one button that fixes it.
/// When nothing is wrong it says so and shows nothing else.
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
  @ObservedObject var restarts: RestartReportModel
  @Binding var pending: PendingProcessAction?

  private var commands: ConsumerCommands { .init(processes: processes, memory: memory) }

  var body: some View {
    let problems = OverviewProblems.make(input)
    let message = drive.message?.text ?? processes.consumerMessage ?? processes.threadMessage
    VStack(alignment: .leading, spacing: 14) {
      if let message { BlitzStatusLine(text: message, tone: .working) }
      if problems.isEmpty {
        allGood
      } else {
        ForEach(Array(problems.enumerated()), id: \.element.id) { index, problem in
          card(problem, isFirst: index == 0)
        }
      }
      if drive.isScanning {
        VStack(alignment: .leading, spacing: 6) {
          Text("Measuring your drive to find more space…").font(BlitzType.caption)
            .foregroundStyle(BlitzUI.tertiaryText)
          BlitzProgressBar(fraction: nil, height: 3).frame(maxWidth: 260)
        }
      }
    }
    .task {
      drive.scanIfNeeded()
      worktrees.loadIfNeeded()
    }
  }

  // MARK: Cards

  private func card(_ problem: OverviewProblem, isFirst: Bool) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 14) {
        BlitzIconTile(
          symbol: problem.symbol,
          tone: Self.tone(problem.urgency),
          size: 36)
        VStack(alignment: .leading, spacing: 4) {
          Text(problem.title).font(.system(size: 17, weight: .semibold))
          Text(problem.detail).font(BlitzType.callout).foregroundStyle(BlitzUI.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 12)
        if !(problem.id == "disk" && drive.removal != nil) {
          Button {
            perform(problem.fix)
          } label: {
            BlitzActionLabel(title: problem.fixTitle)
          }
          .blitzButton(isFirst ? .accent : .secondary).controlSize(.large)
          .disabled(drive.busyID != nil)
        }
      }
      if problem.id == "disk", let removal = drive.removal { removalProgress(removal) }
      if let includes = problem.includes {
        Text(includes).font(BlitzType.caption).foregroundStyle(BlitzUI.tertiaryText)
          .padding(.leading, 50).fixedSize(horizontal: false, vertical: true)
      }
      if !problem.more.isEmpty {
        HStack(spacing: 16) {
          ForEach(problem.more, id: \.title) { link in
            Button(link.title) { perform(link.fix) }.buttonStyle(.plain)
              .font(BlitzType.captionEmphasis).foregroundStyle(BlitzUI.supportingText)
              .blitzPointingHand()
          }
        }.padding(.leading, 50)
      }
    }.blitzCard(padding: 20)
  }

  /// Deleting takes a while (an iOS version can take a minute), so the card shows each step and the
  /// space it gave back instead of a button that silently stops working.
  private func removalProgress(_ removal: DriveRemovalProgress) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Deleting \(removal.current)").font(BlitzType.rowTitle).lineLimit(1)
        Spacer()
        Text("\(removal.done + 1) of \(removal.total)").font(BlitzType.numeric)
          .foregroundStyle(BlitzUI.secondaryText)
      }
      ProgressView(value: Double(removal.done) + 0.5, total: Double(removal.total))
        .progressViewStyle(.linear).tint(BlitzUI.mint)
      Text(
        removal.freed > 0
          ? "Freed \(ByteText.compact(removal.freed)) so far · \(ByteText.compact(monitor.snapshot.diskAvailable)) free now"
          : "\(ByteText.compact(monitor.snapshot.diskAvailable)) free now · iOS versions take up to a minute each"
      ).font(BlitzType.caption).monospacedDigit().foregroundStyle(BlitzUI.secondaryText)
    }.padding(.leading, 50)
  }

  private static func tone(_ urgency: Int) -> BlitzStatusTone {
    switch urgency {
    case 2: .critical
    case 1: .warning
    default: .muted
    }
  }

  private var allGood: some View {
    HStack(spacing: 14) {
      BlitzIconTile(symbol: "checkmark", tone: .good, size: 36)
      VStack(alignment: .leading, spacing: 4) {
        Text("Your Mac is fine").font(.system(size: 17, weight: .semibold))
        Text(
          "Nothing to do. BlitzClean keeps watching and warns you before disk or memory runs out."
        ).font(BlitzType.callout).foregroundStyle(BlitzUI.secondaryText)
      }
      Spacer()
    }.blitzCard(padding: 20)
  }

  // MARK: Problems

  private var input: OverviewProblems.Input {
    let commands = commands
    let largest = processes.consumers.first { commands.canStop($0) && !$0.isPaused }
    return .init(
      diskAvailable: monitor.snapshot.diskAvailable, diskTotal: monitor.snapshot.diskTotal,
      units: drive.breakdown?.units ?? [], protectedRuntimePaths: drive.protectedRuntimePaths,
      dependencyBytes: storage.readyItems.reduce(0) { $0 + $1.bytes },
      oldFileBytes: storage.oldFiles.totalBytes, ramAvailable: monitor.snapshot.ramAvailable,
      swapBytes: memory.sample?.swapUsed ?? 0, memory: processes.pressure.risk.tone,
      idle: FreeMemoryPlan.idle(
        .init(
          consumers: processes.consumers, activity: processes.activity,
          quittableApps: commands.quittableApps, now: .now)),
      largest: largest.map { ($0, commands.stopTitle($0)) },
      detachedAgents: processes.threads.filter { $0.isDetached && !$0.isPaused },
      agents: AgentBudget.make(
        .init(
          agents: processes.threads, availableBytes: monitor.snapshot.ramAvailable,
          pressure: processes.pressure.risk)),
      runaway: processes.consumers.filter {
        $0.kind != .system && !$0.isPaused && $0.canSignal
          && processes.activity.busy(.init(id: $0.id, now: .now)) >= ConsumerActivity.runawayAfter
      }.max { $0.cpuPercent < $1.cpuPercent },
      frozenApps: recovery.attentionCount, restart: restarts.current,
      stuckBuilds: processes.brakePaused.filter {
        Date.now.timeIntervalSince($0.pausedAt) >= BuildBrakePolicy.stuckAfter
          && processes.pressure.risk >= .warning
      })
  }

  private func perform(_ fix: OverviewFix) {
    switch fix {
    case .freeDisk(let units): confirm(units)
    case .closeIdle(let idle):
      let commands = commands
      pending = .init(
        title: "Close \(idle.count) idle items?",
        message: idle.map { "\($0.name) · \(ByteText.compact($0.memoryBytes))" }.joined(
          separator: "\n")
          + "\n\nNone of these used the CPU in the last 30 minutes. Apps can still show save dialogs.",
        confirmTitle: "Close \(idle.count)", perform: { commands.stopAll(idle) })
    case .stop(let consumer): commands.stop(consumer)
    case .pause(let consumer): processes.signal(.init(consumer: consumer, signal: .pause))
    case .quitAgents(let agents):
      for agent in agents { processes.stopThread(agent, force: false) }
    case .open(let page): navigation.page = page
    case .dismissRestart(let report): restarts.dismiss(report)
    case .stopBuild(let entry): processes.releaseBrake(.init(entry: entry, stop: true))
    case .openDrive: openDrive()
    case .openCleanup(let focus): openCleanup(focus)
    }
  }

  // MARK: Helpers

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

}
