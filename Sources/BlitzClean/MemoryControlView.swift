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

  /// Filtered and sorted once per render; sections read these instead of refiltering.
  private struct Listing {
    let threads: [AIThread]
    let apps: [MemoryCandidate]
    let codexThreadsByApp: [String: Int]
  }

  private var listing: Listing {
    let threads = query.isEmpty ? processes.threads : processes.threads.filter { $0.matches(query) }
    let apps = model.candidates
      .filter { query.isEmpty || $0.app.name.localizedCaseInsensitiveContains(query) }
      .sorted { $0.app.memoryBytes > $1.app.memoryBytes }
    var codex: [String: Int] = [:]
    for thread in processes.threads where thread.tool == .codexDesktop {
      if let name = thread.tool.appName { codex[name, default: 0] += 1 }
    }
    return Listing(threads: threads, apps: apps, codexThreadsByApp: codex)
  }

  var body: some View {
    let listing = listing
    return ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        summaryCard
        if query.isEmpty || !listing.threads.isEmpty { threadSection(listing.threads) }
        if query.isEmpty || !listing.apps.isEmpty { appSection(listing) }
        if !query.isEmpty && listing.apps.isEmpty && listing.threads.isEmpty {
          Text("No matching apps or threads").font(BlitzType.body)
            .foregroundStyle(BlitzUI.secondaryText)
        }
        pressureSection
      }.padding(BlitzUI.pagePadding)
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      PageSearchBar(title: "Search apps or AI threads", text: $query)
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

  private func threadSection(_ threads: [AIThread]) -> some View {
    let visible =
      showsAllThreads || !query.isEmpty ? threads : Array(threads.prefix(Self.threadLimit))
    let detached = threads.filter(\.isDetached)
    let running = processes.threads.filter { !$0.isPaused }
      .sorted { $0.memoryBytes > $1.memoryBytes }
    let stopping = !processes.stoppingThreads.isEmpty
    return VStack(alignment: .leading, spacing: 10) {
      BlitzSectionHeader(title: "AI threads", count: threads.count) {
        if !detached.isEmpty {
          Button("Quit \(detached.count) detached…") {
            pending = .quitThreads(detached)
          }.blitzButton(.secondary).controlSize(.small).disabled(stopping)
            .help("Agents whose app or terminal already closed")
        }
        if running.count > 1 {
          Button("Pause \(running.count - 1) others") {
            for thread in running.dropFirst() { processes.pauseThread(thread) }
          }.blitzButton(.secondary).controlSize(.small).disabled(stopping)
            .help("Keeps the largest thread running. Paused threads keep their RAM.")
        }
      }
      if let message = processes.threadMessage {
        BlitzStatusLine(text: message, tone: .working)
      }
      LazyVStack(spacing: 0) {
        if threads.isEmpty {
          BlitzEmptyRow(
            text: processes.scannedAt == nil
              ? "Reading AI processes…"
              : query.isEmpty ? "No AI threads running" : "No matching threads",
            isLoading: processes.scannedAt == nil)
        }
        ForEach(visible) { thread in
          threadRow(thread)
          if thread.id != visible.last?.id { BlitzRowDivider(leading: 56) }
        }
      }.blitzTable()
      if threads.count > Self.threadLimit, query.isEmpty {
        BlitzShowAllButton(total: threads.count, noun: "threads", isExpanded: $showsAllThreads)
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

  private func appSection(_ listing: Listing) -> some View {
    let apps = listing.apps
    let lastID = apps.last?.id
    return VStack(alignment: .leading, spacing: 10) {
      BlitzSectionHeader(title: "Apps", count: apps.count) {
        Text("Memory includes helpers").font(BlitzType.caption)
          .foregroundStyle(BlitzUI.tertiaryText)
      }
      if let message = appResult ?? model.statusMessage {
        BlitzStatusLine(text: message, tone: .working)
      }
      LazyVStack(spacing: 0) {
        if apps.isEmpty {
          BlitzEmptyRow(
            text: model.isRefreshing
              ? "Reading running apps…" : query.isEmpty ? "No apps to review" : "No matching apps",
            isLoading: model.isRefreshing)
        }
        ForEach(apps) { candidate in
          appRow((candidate: candidate, codexThreads: listing.codexThreadsByApp))
          if candidate.id != lastID { BlitzRowDivider(leading: 56) }
        }
      }.blitzTable()
    }
  }

  private func appRow(_ input: (candidate: MemoryCandidate, codexThreads: [String: Int]))
    -> some View
  {
    let candidate = input.candidate
    let app = candidate.app
    let busy = model.isActing(on: app) || forceQuit.activeApp?.id == app.id
    let detail = appDetail((candidate: candidate, codexThreads: input.codexThreads[app.name] ?? 0))
    return HStack(spacing: 12) {
      AppRowIdentity(
        app: app, detail: detail.isEmpty ? nil : detail, warning: model.quitMessages[app.id])
      BlitzTrailingValue(value: ByteText.full(app.memoryBytes), detail: nil)
        .frame(width: 80, alignment: .trailing)
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
        Button("Show in Finder") { Finder.reveal(app.bundleURL.path) }
        if app.protectionReason == nil {
          Divider()
          ForEach(MemoryAppPolicy.allCases, id: \.self) { policy in
            Button {
              model.setPolicy(.init(app: app, policy: policy))
            } label: {
              MenuCheckLabel(title: policy.title, isOn: candidate.policy == policy)
            }
          }
        }
      }.disabled(busy)
    }.blitzRow()
  }

  private func appDetail(_ input: (candidate: MemoryCandidate, codexThreads: Int)) -> String {
    let candidate = input.candidate
    let helpers = candidate.app.childProcessCount
    let helperText = helpers == 0 ? nil : helpers == 1 ? "1 helper" : "\(helpers) helpers"
    let aiThreads = input.codexThreads
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
        if let message = await forceQuit.runAndDescribe(app) { appResult = message }
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
    thread.displayName
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
      BlitzProcessButton(
        title: thread.isPaused ? "Resume" : "Pause",
        label: "\(thread.isPaused ? "Resume" : "Pause") \(thread.displayName)",
        isBusy: isBusy, action: thread.isPaused ? onResume : onPause
      )
      .frame(width: 96, alignment: .trailing)
      .help(
        thread.isPaused
          ? "Resume this thread and its local tools."
          : "Pause this thread’s local processes. RAM stays allocated; remote work may continue.")
      BlitzActionMenu(label: "More actions for \(thread.displayName)") {
        Button("Quit", action: onQuit)
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
