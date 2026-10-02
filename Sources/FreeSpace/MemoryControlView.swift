import AppKit
import SwiftUI

struct MemoryControlView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var model: MemoryRescueModel
  @ObservedObject var processes: DevProcessModel
  @AppStorage("history.memorySeconds") private var seconds = 86_400.0
  @State private var query = ""
  @State private var showsAllThreads = false
  @State private var pending: MemoryAction?
  @State private var appResult: String?
  @StateObject private var forceQuit = ForceQuitModel()

  private static let threadLimit = 6

  private var threads: [AIThread] {
    processes.threads.filter {
      query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        || ($0.project?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }

  private var detachedThreads: [AIThread] { processes.threads.filter(\.isDetached) }

  private var apps: [MemoryCandidate] {
    model.candidates.filter { query.isEmpty || $0.app.name.localizedCaseInsensitiveContains(query) }
      .sorted { $0.app.memoryBytes > $1.app.memoryBytes }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        summaryCard
        if query.isEmpty || !apps.isEmpty { appSection }
        if query.isEmpty || !threads.isEmpty { threadSection }
        if !query.isEmpty && apps.isEmpty && threads.isEmpty {
          Text("No matching apps or threads").font(BlitzType.body)
            .foregroundStyle(BlitzUI.secondaryText)
        }
        pressureSection
      }.padding(BlitzUI.pagePadding)
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      BlitzSearchField(title: "Search apps or AI threads", text: $query)
        .padding(.horizontal, BlitzUI.pagePadding).padding(.vertical, 12)
        .background(BlitzUI.canvasBackground)
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
            run(action)
          }, onCancel: { pending = nil })
      }
    }
  }

  @ViewBuilder private var pressureSection: some View {
    let since = Date.now.addingTimeInterval(-86_400)
    let events = Array(
      model.incidents.filter { $0.kind == "pressure" && $0.date > since }.prefix(8))
    if !events.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text("Pressure in the last 24 hours").font(BlitzType.section)
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

  private var summaryCard: some View {
    VStack(spacing: 16) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(ByteText.full(monitor.snapshot.ramUsed)).font(BlitzUI.valueFont).monospacedDigit()
        Text("of \(ByteText.full(monitor.snapshot.ramTotal)) used")
          .foregroundStyle(BlitzUI.secondaryText).font(BlitzType.body)
        Spacer()
        HistoryRangePicker(seconds: $seconds)
      }
      ResourcePlot(
        samples: monitor.resourceSamples, kind: .memory, color: BlitzUI.mint, seconds: seconds
      ).frame(height: 100)
      HStack(spacing: 24) {
        stat("Available", ByteText.compact(monitor.snapshot.ramAvailable))
        stat("Swap", model.sample?.swapUsed.map(ByteText.compact) ?? "—")
        stat("Pressure", model.pressure.title)
        stat("AI threads", ByteText.compact(processes.threads.reduce(0) { $0 + $1.memoryBytes }))
      }
    }.panelCard(padding: 20)
  }

  private func stat(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
      Spacer()
      Text(value).font(BlitzType.label).monospacedDigit()
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: AI threads

  @ViewBuilder private var threadSection: some View {
    let visible =
      showsAllThreads || !query.isEmpty ? threads : Array(threads.prefix(Self.threadLimit))
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Text("AI threads").font(BlitzType.section)
        Text("\(threads.count)").font(BlitzType.caption).monospacedDigit()
          .foregroundStyle(BlitzUI.tertiaryText)
        Spacer()
        Text("Pause keeps RAM").font(BlitzType.caption).foregroundStyle(BlitzUI.tertiaryText)
        if !detachedThreads.isEmpty {
          Button("Quit \(detachedThreads.count) detached…") {
            pending = .quitThreads(detachedThreads)
          }.blitzButton(.secondary).controlSize(.small)
            .help("Agents whose app or terminal already closed")
        }
        let running = threads.filter { !$0.isPaused }
        if running.count > 1 {
          Button("Pause \(running.count - 1) others") {
            for thread in running.dropFirst() { processes.pauseThread(thread) }
          }.blitzButton(.secondary).controlSize(.small)
            .help("Keeps the largest thread running. Paused threads keep their RAM.")
        }
      }
      if let message = processes.threadMessage {
        Text(message).font(BlitzType.body).foregroundStyle(BlitzUI.supportingText)
          .textSelection(.enabled)
      }
      if threads.isEmpty {
        Text(
          processes.scannedAt == nil
            ? "Reading AI processes…"
            : query.isEmpty ? "No AI threads running" : "No matching threads"
        )
        .font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
        .frame(maxWidth: .infinity, minHeight: 56).panelCard()
      } else {
        LazyVStack(spacing: 0) {
          ForEach(visible) { thread in
            threadRow(thread)
            if thread.id != visible.last?.id { BlitzRowDivider(leading: 56) }
          }
        }.blitzTable()
        if threads.count > Self.threadLimit, query.isEmpty {
          Button(showsAllThreads ? "Show fewer" : "Show all \(threads.count) threads") {
            showsAllThreads.toggle()
          }.blitzButton(.quiet).controlSize(.small)
        }
      }
    }
  }

  private func threadRow(_ thread: AIThread) -> some View {
    AIThreadRow(
      thread: thread, isBusy: processes.stoppingThreads.contains(thread.id),
      onPause: { processes.pauseThread(thread) },
      onResume: { processes.resumeThread(thread) },
      onQuit: { processes.stopThread(thread, force: false) },
      onForceQuit: { pending = .forceQuitThread(thread) })
  }

  static func uptime(since date: Date, now: Date = .now) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 24 * 60 { return "\(minutes / 60)h \(minutes % 60)m" }
    return "\(minutes / (24 * 60))d \(minutes / 60 % 24)h"
  }

  // MARK: Apps

  private var appSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Text("Apps").font(BlitzType.section)
        Text("\(apps.count)").font(BlitzType.caption).monospacedDigit()
          .foregroundStyle(BlitzUI.tertiaryText)
        Spacer()
        Text("Memory includes helpers").font(BlitzType.caption)
          .foregroundStyle(BlitzUI.tertiaryText)
      }
      if let message = appResult ?? model.statusMessage {
        Text(message).font(BlitzType.body).foregroundStyle(BlitzUI.supportingText)
          .textSelection(.enabled)
      }
      if apps.isEmpty {
        Text(
          model.isRefreshing
            ? "Reading running apps…" : query.isEmpty ? "No apps to review" : "No matching apps"
        )
        .font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
        .frame(maxWidth: .infinity, minHeight: 56).panelCard()
      } else {
        LazyVStack(spacing: 0) {
          ForEach(apps) { candidate in
            appRow(candidate)
            if candidate.id != apps.last?.id { BlitzRowDivider(leading: 56) }
          }
        }.blitzTable()
      }
    }
  }

  private func appRow(_ candidate: MemoryCandidate) -> some View {
    let app = candidate.app
    let busy = model.isActing(on: app) || forceQuit.activeApp?.id == app.id
    return HStack(spacing: 12) {
      AppMemoryIcon(app: app)
      VStack(alignment: .leading, spacing: 2) {
        Text(app.name).font(BlitzType.rowTitle).lineLimit(1)
        Text(appDetail(candidate)).font(BlitzType.caption)
          .foregroundStyle(BlitzUI.secondaryText).lineLimit(1)
        if let message = model.quitMessages[app.id] {
          Text(message).font(BlitzType.caption).foregroundStyle(BlitzUI.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      Text(ByteText.full(app.memoryBytes)).font(BlitzType.numeric)
        .foregroundStyle(BlitzUI.supportingText).frame(width: 80, alignment: .trailing)
      Group {
        if app.isRecoveryEligible {
          BlitzProcessButton(title: "Quit", label: "Quit \(app.name)", isBusy: busy) { quit(app) }
            .disabled(model.actionProcessID != nil || forceQuit.activeApp != nil)
            .help("Ask \(app.name) to quit. Its save dialog can still appear.")
        } else {
          Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(BlitzUI.tertiaryText)
            .help(app.protectionReason ?? "Stays open")
        }
      }.frame(width: 96, alignment: .trailing)
      BlitzActionMenu(label: "More actions for \(app.name)") {
        if app.isRecoveryEligible {
          Button("Force Quit…", role: .destructive) { pending = .forceQuitApp(app) }
            .disabled(forceQuit.activeApp != nil)
        }
        Button("Show in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
        }
        if app.protectionReason == nil {
          Divider()
          ForEach(MemoryAppPolicy.allCases, id: \.self) { policy in
            Button {
              model.setPolicy(.init(app: app, policy: policy))
            } label: {
              HStack {
                Text(policy.title)
                Spacer()
                if candidate.policy == policy { Image(systemName: "checkmark") }
              }
            }
          }
        }
      }.disabled(busy)
    }.blitzRow()
  }

  private func appDetail(_ candidate: MemoryCandidate) -> String {
    let helpers = candidate.app.childProcessCount
    let helperText = helpers == 0 ? nil : helpers == 1 ? "1 helper" : "\(helpers) helpers"
    let aiThreads = processes.threads.filter {
      $0.tool == .codexDesktop && $0.tool.appName == candidate.app.name
    }.count
    let threadText =
      aiThreads == 0 ? nil : aiThreads == 1 ? "1 AI thread" : "\(aiThreads) AI threads"
    let usage: String? =
      if candidate.app.protectionReason != nil || candidate.reason.hasPrefix("Activity unknown") {
        nil
      } else if candidate.policy == .keepRunning {
        "Pinned"
      } else {
        candidate.reason.components(separatedBy: " · ").first
      }
    return [helperText, threadText, usage].compactMap { $0 }.joined(separator: " · ")
  }

  // MARK: Actions

  private func quit(_ app: MemoryApp) {
    appResult = nil
    Task {
      await model.quit(app)
      monitor.refresh()
      processes.refresh()
    }
  }

  private func run(_ action: MemoryAction) {
    switch action {
    case .forceQuitApp(let app):
      appResult = nil
      Task {
        if let report = await forceQuit.run(app) {
          appResult =
            report.outcome == .terminated
            ? "\(app.name) was force quit." : "\(app.name): \(report.detail)"
        }
        model.refresh()
        monitor.refresh()
        processes.refresh()
      }
    case .forceQuitThread(let thread):
      processes.stopThread(thread, force: true)
    case .quitThreads(let threads):
      for thread in threads { processes.stopThread(thread, force: false) }
    }
  }
}

private enum MemoryAction {
  case forceQuitApp(MemoryApp)
  case forceQuitThread(AIThread)
  case quitThreads([AIThread])

  var title: String {
    switch self {
    case .forceQuitApp(let app): "Force quit \(app.name)?"
    case .forceQuitThread(let thread): "Force quit \(Self.label(thread))?"
    case .quitThreads(let threads): "Quit \(threads.count) detached AI agents?"
    }
  }

  var message: String {
    switch self {
    case .forceQuitApp(let app):
      "\(app.name) ends immediately. Unsaved changes are lost."
    case .forceQuitThread(let thread):
      "Ends \(thread.processIDs.count) processes immediately, including a reply in progress. \(ByteText.full(thread.memoryBytes))."
    case .quitThreads(let threads):
      "Their app or terminal already closed, so nothing is using them. \(threads.map { $0.project ?? $0.name }.joined(separator: ", ")) · \(ByteText.full(threads.reduce(0) { $0 + $1.memoryBytes }))."
    }
  }

  var confirmTitle: String {
    switch self {
    case .forceQuitApp, .forceQuitThread: "Force Quit"
    case .quitThreads: "Quit detached"
    }
  }

  private static func label(_ thread: AIThread) -> String {
    thread.project.map { "\(thread.name) in \($0)" } ?? thread.name
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
          Text(thread.project.map { "\(thread.name) · \($0)" } ?? thread.name)
            .font(BlitzType.rowTitle).lineLimit(1)
          if thread.isPaused {
            BlitzStatusBadge(title: "Paused", tone: .warning)
          } else if thread.isDetached {
            BlitzStatusBadge(title: "Detached", tone: .warning)
          }
        }
        Text(detail).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.middle)
      }.frame(maxWidth: .infinity, alignment: .leading)
        .help(thread.directory ?? thread.name)
      Text(ByteText.full(thread.memoryBytes)).font(BlitzType.numeric)
        .foregroundStyle(BlitzUI.supportingText).frame(width: 80, alignment: .trailing)
      BlitzProcessButton(
        title: "Quit", label: "Quit \(thread.name)", isBusy: isBusy, action: onQuit
      )
      .frame(width: 96, alignment: .trailing)
      .help("End this thread and its tools to release memory.")
      BlitzActionMenu(label: "More actions for \(thread.name)") {
        if thread.isPaused {
          Button("Resume", action: onResume)
        } else {
          Button("Pause", action: onPause)
        }
        Button("Force Quit…", role: .destructive) { onForceQuit() }
        if let directory = thread.directory {
          Button("Show project in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
          }
        }
        Button("Copy process IDs") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(
            thread.processIDs.map(String.init).joined(separator: " "), forType: .string)
        }
      }.disabled(isBusy)
    }.blitzRow()
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
