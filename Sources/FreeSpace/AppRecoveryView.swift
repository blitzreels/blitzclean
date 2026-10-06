import AppKit
import SwiftUI

struct AppRecoveryView: View {
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var model: AppRecoveryModel
  @State private var search = ""
  @State private var liveApps: [MemoryApp] = []
  @State private var scanTask: Task<Void, Never>?
  @State private var forceQuitCandidate: MemoryApp?
  @StateObject private var forceQuit = ForceQuitModel()

  private var eligibleApps: [MemoryApp] {
    liveApps
  }

  /// Built once per render: every row needs three model lookups, and the page redraws every 2 seconds.
  private struct Listing {
    let attention: [ReviveRow]
    let others: [ReviveRow]
    let crashes: [RecentCrash]
    let stoppedApps: [MemoryApp]
    let isReviving: Bool
  }

  private var listing: Listing {
    let rows = eligibleApps.map { ReviveRow(app: $0, model: model) }
    let visible =
      search.isEmpty ? rows : rows.filter { $0.app.name.localizedCaseInsensitiveContains(search) }
    return Listing(
      attention: visible.filter(\.needsAttention),
      others: visible.filter { !$0.needsAttention },
      crashes: search.isEmpty
        ? model.crashes
        : model.crashes.filter { $0.name.localizedCaseInsensitiveContains(search) },
      stoppedApps: rows.filter(\.isStopped).map(\.app),
      isReviving: rows.contains(where: \.isReviving))
  }

  var body: some View {
    let listing = listing
    return VStack(spacing: 0) {
      BlitzPageHeader(title: "Revive apps", detail: summary) {
        Button {
          scan(force: true)
        } label: {
          Label("Check again", systemImage: "arrow.clockwise")
        }.blitzButton(.quiet).disabled(model.isScanning)
        if listing.stoppedApps.count > 1 {
          Button("Revive \(listing.stoppedApps.count) stopped") {
            reviveAll(listing.stoppedApps)
          }.blitzButton(.accent).disabled(listing.isReviving)
        }
      }
      Rectangle().fill(BlitzUI.separator).frame(height: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          if let status = model.status { BlitzStatusLine(text: status, tone: .working) }
          if !listing.attention.isEmpty {
            section((title: "Stopped or frozen", count: listing.attention.count)) {
              appRows(listing.attention)
            }
          }
          if !listing.others.isEmpty {
            section(
              (
                title: listing.attention.isEmpty && listing.crashes.isEmpty ? nil : "Running",
                count: listing.others.count
              )
            ) { appRows(listing.others) }
          } else if listing.attention.isEmpty && listing.crashes.isEmpty {
            Text(search.isEmpty ? "No running apps to check" : "No matching apps")
              .font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
              .frame(maxWidth: .infinity, minHeight: 56)
          }
          if !listing.crashes.isEmpty {
            let lastID = listing.crashes.last?.id
            section((title: "Quit or crashed", count: listing.crashes.count)) {
              ForEach(listing.crashes) { crash in
                crashRow(crash)
                if crash.id != lastID { BlitzRowDivider() }
              }
            }
          }
        }
        .padding(BlitzUI.pagePadding)
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        PageSearchBar(title: "Search apps", text: $search)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let app = forceQuitCandidate {
        BlitzConfirmation(
          title: "Force quit \(app.name)?",
          message: "Unsaved changes in \(app.name) will be lost.",
          confirmTitle: "Force Quit",
          onConfirm: { runForceQuit(app) },
          onCancel: { forceQuitCandidate = nil })
      }
    }
    .task {
      memory.refresh()
      while !Task.isCancelled {
        refreshLiveApps()
        await model.noteProcessStates(eligibleApps)
        scheduleScan(force: false)
        do { try await Task.sleep(for: .seconds(2)) } catch { break }
      }
    }
    .onDisappear {
      scanTask?.cancel()
      scanTask = nil
    }
    .onChange(of: memory.scannedAt) { refreshLiveApps() }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.didLaunchApplicationNotification)
    ) { _ in
      refreshLiveApps()
      scheduleScan(force: false)
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.didTerminateApplicationNotification)
    ) { _ in
      refreshLiveApps()
      scheduleScan(force: false)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      refreshLiveApps()
      scheduleScan(force: true)
    }
  }

  private var summary: String? {
    model.isScanning ? "Checking \(model.scannedCount) of \(model.scanTotal) apps…" : nil
  }

  private func section<Content: View>(
    _ header: (title: String?, count: Int), @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if let title = header.title {
        BlitzSectionHeader(title: title, count: header.count) {}
      }
      LazyVStack(spacing: 0) { content() }.blitzTable()
    }
  }

  private func appRows(_ rows: [ReviveRow]) -> some View {
    let lastID = rows.last?.id
    return ForEach(rows) { row in
      appRow(row)
      if row.id != lastID { BlitzRowDivider() }
    }
  }

  private func appRow(_ row: ReviveRow) -> some View {
    let app = row.app
    return HStack(spacing: 12) {
      AppRowIdentity(app: app, detail: row.detail, warning: memory.quitMessages[app.id])
      BlitzTrailingValue(
        value: app.memoryBytes == 0 ? "—" : ByteText.full(app.memoryBytes), detail: nil
      ).frame(width: 80, alignment: .trailing)
      ReviveStatusView(row: row).frame(width: 136, alignment: .trailing)
        .help(row.help(accessibilityEnabled: model.accessibilityEnabled))
      BlitzProcessButton(title: "Revive", label: "Revive \(app.name)", isBusy: row.isReviving) {
        revive(app)
      }.disabled(forceQuit.activeApp?.id == app.id || memory.isActing(on: app))
      Button("Force Quit…", role: .destructive) { forceQuitCandidate = app }
        .blitzButton(.quiet)
        .disabled(row.isReviving || forceQuit.activeApp != nil || memory.isActing(on: app))
        .accessibilityLabel("Force Quit \(app.name)")
    }.blitzRow()
  }

  private func crashRow(_ crash: RecentCrash) -> some View {
    HStack(spacing: 12) {
      ApplicationIcon(source: .file(crash.bundleURL.path), size: 28, fallback: "app")
      VStack(alignment: .leading, spacing: 2) {
        Text(crash.name).font(BlitzType.rowTitle).lineLimit(1)
        Text(
          "\(crash.report == nil ? "Quit" : "Crashed") \(crash.date.formatted(.relative(presentation: .named)))"
        ).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText).lineLimit(1)
      }.frame(maxWidth: .infinity, alignment: .leading)
      BlitzStatusBadge(
        title: crash.report == nil ? "Quit" : "Crashed",
        tone: crash.report == nil ? .muted : .critical
      ).frame(width: 136, alignment: .trailing)
      Button("Reopen") { model.reopen(crash) }.blitzButton(.accent).controlSize(.small)
        .frame(width: 104, alignment: .trailing)
      Button("Dismiss") { model.dismiss(crash) }.blitzButton(.quiet)

    }.blitzRow()
  }

  private func refreshLiveApps() {
    liveApps = RecoveryAppRoster.merge(
      .init(descriptors: MemoryAppProvider().descriptors(), measured: memory.apps))
    model.refreshPermission()
  }

  private func scheduleScan(force: Bool) {
    let apps = eligibleApps
    if scanTask == nil || !model.isScanning {
      scanTask = Task { await model.scan(apps, force: force) }
    } else if force {
      Task { await model.scan(apps, force: true) }
    }
  }

  private func scan(force: Bool) {
    refreshLiveApps()
    scheduleScan(force: force)
  }

  private func revive(_ app: MemoryApp) {
    Task {
      if let report = await model.revive(app) { memory.recordRecovery(report) }
    }
  }

  private func reviveAll(_ apps: [MemoryApp]) {
    Task {
      for report in await model.reviveAll(apps) { memory.recordRecovery(report) }
    }
  }

  private func runForceQuit(_ app: MemoryApp) {
    forceQuitCandidate = nil
    Task {
      if let message = await forceQuit.runAndDescribe(app) { model.status = message }
      memory.refresh()
      refreshLiveApps()
      scheduleScan(force: true)
    }
  }
}

private struct ReviveRow: Identifiable {
  let app: MemoryApp
  let title: String
  let tone: BlitzStatusTone
  let detail: String?
  let needsAttention: Bool
  let isStopped: Bool
  let isReviving: Bool
  let isChecking: Bool
  let health: RecoveryHealth?

  var id: Int32 { app.processID }
  var isBusy: Bool { isReviving || isChecking }
  var showsStatus: Bool { !["Running", "Not checked", "Unknown"].contains(title) }

  @MainActor
  init(app: MemoryApp, model: AppRecoveryModel) {
    self.app = app
    let activity = model.activity(for: app)
    let check = model.check(for: app)
    let result = model.result(for: app)
    isReviving = activity == .reviving
    isChecking = activity == .checking && check == nil
    health = check?.health
    detail = result?.detail
    switch (result?.outcome, check?.health) {
    case (.revived?, _):
      (title, tone, needsAttention, isStopped) = ("Revived", .good, false, false)
    case (.alreadyRunning?, _):
      (title, tone, needsAttention, isStopped) =
        health == .responsive
        ? ("Responding", .good, false, false) : ("Window unchecked", .muted, false, false)
    case (.notResponding?, _):
      (title, tone, needsAttention, isStopped) = (
        "Not responding", .critical, true, false
      )
    case (.stillStopped?, _):
      (title, tone, needsAttention, isStopped) = (
        "Still stopped", .warning, true, true
      )
    case (.failed?, _):
      (title, tone, needsAttention, isStopped) = (
        "Couldn't revive", .critical, true, false
      )
    case (_, .stopped?):
      (title, tone, needsAttention, isStopped) = ("Stopped", .warning, true, true)
    case (_, .unresponsive?):
      (title, tone, needsAttention, isStopped) = (
        "Not responding", .critical, true, false
      )
    case (_, .responsive?), (_, .running?):
      (title, tone, needsAttention, isStopped) = ("Running", .good, false, false)
    case (_, .unknown?), (_, .exited?):
      (title, tone, needsAttention, isStopped) = ("Unknown", .muted, false, false)
    default:
      (title, tone, needsAttention, isStopped) = (
        "Not checked", .muted, false, false
      )
    }
  }

  func help(accessibilityEnabled: Bool) -> String {
    if isReviving { return "Reviving and watching the app" }
    if isChecking { return "Checking whether the window responds" }
    if health == .running && !accessibilityEnabled {
      return "The process is running. Allow Accessibility to detect frozen windows."
    }
    return detail ?? title
  }
}

private struct ReviveStatusView: View {
  let row: ReviveRow

  var body: some View {
    if row.isBusy {
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text(row.isReviving ? "Reviving…" : "Checking…").font(BlitzType.captionEmphasis)
          .foregroundStyle(BlitzUI.secondaryText)
      }.frame(height: 24)
    } else if row.showsStatus {
      BlitzStatusBadge(title: row.title, tone: row.tone)
    }
  }
}
