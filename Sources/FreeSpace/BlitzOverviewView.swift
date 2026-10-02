import AppKit
import SwiftUI

struct BlitzOverviewView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var repeats: RepeatCleanupModel
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var recovery: AppRecoveryModel
  @ObservedObject var navigation: CleanNavigation
  @State private var forceQuitThread: AIThread?

  private struct Suggestion: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let open: () -> Void
  }

  private var hogThreads: [AIThread] { Array(processes.threads.prefix(8)) }

  private var suggestions: [Suggestion] {
    var result: [Suggestion] = []
    if recovery.attentionCount > 0 {
      result.append(
        .init(
          id: "revive", symbol: "waveform.path.ecg",
          title: recovery.attentionCount == 1
            ? "1 app is stopped or frozen"
            : "\(recovery.attentionCount) apps are stopped or frozen",
          detail: "Revive or force quit them", open: { navigation.page = .recovery }))
    }
    let regrown = repeats.ready
    if !regrown.isEmpty {
      result.append(
        .init(
          id: "regrown", symbol: "arrow.counterclockwise",
          title: regrown.count == 1
            ? "1 removed folder grew back" : "\(regrown.count) removed folders grew back",
          detail:
            "\(ByteText.full(regrown.reduce(0) { $0 + (repeats.statuses[$1.id]?.bytes ?? 0) })) to remove again",
          open: {
            navigation.storagePage = .cleanup
            navigation.page = .storage
          }))
    }
    return result
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        PressureBanner(
          assessment: processes.pressure, actionTitle: "Review projects",
          onReview: { navigation.page = .projects })
        if !memory.notificationsAllowed {
          HStack {
            Text("Desktop warnings need notification permission").font(BlitzType.caption)
              .foregroundStyle(BlitzUI.secondaryText)
            Spacer()
            Button("Enable alerts") {
              Task { await memory.configureNotifications(requestPermission: true) }
            }.blitzButton(.secondary).controlSize(.small)
          }
        }
        StorageHero(
          snapshot: monitor.snapshot,
          action: {
            navigation.storagePage = .browse
            navigation.page = .storage
          })
        HStack(alignment: .top, spacing: 16) {
          OverviewResourceCard(
            title: "Memory", value: ByteText.compact(monitor.snapshot.ramUsed),
            detail: "of \(ByteText.compact(monitor.snapshot.ramTotal)) used",
            footnote: "\(ByteText.compact(monitor.snapshot.ramAvailable)) available",
            samples: monitor.resourceSamples, kind: .memory,
            action: { navigation.page = .memory })
          OverviewResourceCard(
            title: "CPU", value: monitor.snapshot.cpuUsage.map(PercentText.make) ?? "—",
            detail: "across \(ProcessInfo.processInfo.activeProcessorCount) cores",
            footnote: "Thermals: \(monitor.snapshot.thermalStatus.title.lowercased())",
            samples: monitor.resourceSamples, kind: .cpu,
            action: { navigation.page = .cpu })
        }
        Button {
          navigation.page = .projects
        } label: {
          HStack {
            Label("Running projects", systemImage: "folder.fill")
            Spacer()
            let names = WorkspaceCatalog.resolvedProjects(
              .init(
                input: .init(
                  resources: processes.resources, processes: processes.processes, preferences: []),
                roots: processes.workspaceRoots)
            ).filter(\.isRunning)
            Text(
              names.prefix(3).map { "\($0.preference.name) · \(ByteText.compact($0.memoryBytes))" }
                .joined(separator: "   ")
            )
            .lineLimit(1).foregroundStyle(BlitzUI.secondaryText)
            Image(systemName: "chevron.right")
          }.blitzRow()
        }.buttonStyle(.plain).blitzTable()
        threadSection
        let suggestions = suggestions
        if !suggestions.isEmpty {
          VStack(spacing: 0) {
            ForEach(suggestions) { suggestion in
              suggestionRow(suggestion)
              if suggestion.id != suggestions.last?.id { BlitzRowDivider(leading: 56) }
            }
          }.blitzTable()
        }
        if let error = monitor.historyPersistenceError {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.orange)
        }
      }.padding(BlitzUI.pagePadding)
    }
    .task {
      processes.refreshIfStale()
      repeats.check()
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let thread = forceQuitThread {
        let name = thread.project.map { "\(thread.name) in \($0)" } ?? thread.name
        BlitzConfirmation(
          title: "Force quit \(name)?",
          message:
            "Ends \(thread.processIDs.count) processes immediately, including work in progress.",
          confirmTitle: "Force Quit",
          onConfirm: {
            forceQuitThread = nil
            processes.stopThread(thread, force: true)
          }, onCancel: { forceQuitThread = nil })
      }
    }
  }

  @ViewBuilder private var threadSection: some View {
    let threads = hogThreads
    let running = processes.threads.filter { !$0.isPaused }
    let ram = processes.threads.reduce(0) { $0 + $1.memoryBytes }
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Text("AI threads").font(BlitzType.section)
        Text("\(processes.threads.count)").font(BlitzType.caption).monospacedDigit()
          .foregroundStyle(BlitzUI.tertiaryText)
        Spacer()
        if ram > 0 {
          Text(ByteText.full(ram)).font(BlitzType.numeric).foregroundStyle(BlitzUI.secondaryText)
        }
        if running.count > 1 {
          Button("Pause \(running.count - 1) others") {
            for thread in running.dropFirst() { processes.pauseThread(thread) }
          }.blitzButton(.accent).controlSize(.small)
            .help("Keeps the largest thread. Paused threads keep their RAM until you Quit.")
        }
      }
      Text("Quit releases memory. Pause is available in each row’s menu.")
        .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      if let message = processes.threadMessage {
        Text(message).font(BlitzType.body).foregroundStyle(BlitzUI.supportingText)
          .textSelection(.enabled)
      }
      if threads.isEmpty {
        Text(processes.scannedAt == nil ? "Reading AI processes…" : "No AI threads running")
          .font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
          .frame(maxWidth: .infinity, minHeight: 56).panelCard()
      } else {
        VStack(spacing: 0) {
          ForEach(threads) { thread in
            AIThreadRow(
              thread: thread, isBusy: processes.stoppingThreads.contains(thread.id),
              onPause: { processes.pauseThread(thread) },
              onResume: { processes.resumeThread(thread) },
              onQuit: { processes.stopThread(thread, force: false) },
              onForceQuit: { forceQuitThread = thread })
            if thread.id != threads.last?.id { BlitzRowDivider(leading: 56) }
          }
        }.blitzTable()
        if processes.threads.count > threads.count {
          Button("Show all \(processes.threads.count) on Memory") { navigation.page = .memory }
            .blitzButton(.quiet).controlSize(.small)
        }
      }
    }
  }

  private func suggestionRow(_ suggestion: Suggestion) -> some View {
    Button(action: suggestion.open) {
      HStack(spacing: 12) {
        Image(systemName: suggestion.symbol).font(.system(size: 14))
          .foregroundStyle(BlitzUI.secondaryText).frame(width: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(suggestion.title).font(BlitzType.rowTitle)
          Text(suggestion.detail).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        }
        Spacer()
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(BlitzUI.tertiaryText)
      }.blitzRow().contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}

private struct OverviewResourceCard: View {
  let title: String
  let value: String
  let detail: String
  let footnote: String
  let samples: [ResourceSample]
  let kind: ResourceKind
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(action: action) {
        HStack {
          Text(title).font(.system(size: 13, weight: .medium))
          Spacer()
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).help("Open \(title.lowercased())")
      VStack(alignment: .leading, spacing: 4) {
        Text(value).font(BlitzUI.valueFont).tracking(-0.8).monospacedDigit()
        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      ResourcePlot(samples: samples, kind: kind, color: BlitzUI.mint, seconds: 300)
        .frame(height: 48)
      HStack {
        Text(footnote)
        Spacer()
        Text("5 min")
      }.font(.system(size: 11)).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading).panelCard(padding: 20)
  }
}

struct StorageHero: View {
  let snapshot: SystemSnapshot
  let action: () -> Void

  private var used: UInt64 { snapshot.diskTotal - min(snapshot.diskTotal, snapshot.diskAvailable) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("Internal storage", systemImage: "internaldrive")
          .font(.system(size: 13, weight: .medium))
        Spacer()
        Button("Review storage", action: action).buttonStyle(BlitzButtonStyle(.accent))
      }
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(snapshot.diskTotal > 0 ? ByteText.full(snapshot.diskAvailable) : "—")
          .font(.system(size: 36, weight: .medium)).tracking(-1).monospacedDigit()
        Text("available").font(.system(size: 13)).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 10) {
        CapacityBar(
          usedRatio: Double(used) / Double(max(1, snapshot.diskTotal)),
          tone: MenuBarTones.disk(snapshot))
        HStack {
          Text("\(ByteText.full(used)) used")
          Spacer()
          Text("\(ByteText.full(snapshot.diskTotal)) total")
        }.font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
      }
    }.panelCard(padding: 20)
  }
}
