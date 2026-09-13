import AppKit
import SwiftUI

struct MemoryRescueView: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var model: MemoryRescueModel
  @State private var quitCandidate: MemoryApp?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Image(systemName: "shield.lefthalf.filled")
          .font(.title)
          .foregroundStyle(model.risk.tone.color)
        VStack(alignment: .leading, spacing: 3) {
          Text("Protect AI work").font(.title2.bold())
          Text(model.risk.title).foregroundStyle(model.risk.tone.color)
        }
        Spacer()
        Button("Recover app") { openWindow(id: "app-recovery") }
        Button("Refresh") { model.refresh() }.disabled(model.isRefreshing)
      }
      MemoryGuardControls(model: model)
      if let status = model.statusMessage {
        Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
      }
      TabView {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            Text("Review before quitting")
              .font(.headline)
            Text(
              "Footprint includes helpers; actual recovery varies. Check unsaved work, calls, and background jobs."
            )
            .font(.caption).foregroundStyle(.secondary)
            if model.suggestions.isEmpty {
              Text(
                model.isRefreshing
                  ? "Reading apps…" : "No closing candidates. Review projects in Processes."
              )
              .foregroundStyle(.secondary)
            }
            ForEach(model.suggestions) { candidate in
              MemoryCandidateRow(candidate: candidate, model: model) { app in quitCandidate = app }
            }
            Divider()
            Text("Keep running · \(model.protectedCount)").font(.headline)
            ForEach(model.candidates.filter(\.protected)) { candidate in
              MemoryCandidateRow(candidate: candidate, model: model) { app in quitCandidate = app }
            }
          }
          .padding(16)
        }
        .tabItem { Text("Apps") }
        MemoryIncidentView(model: model)
          .tabItem { Text("Last 24 hours") }
      }
    }
    .padding(20)
    .frame(minWidth: 740, minHeight: 600)
    .task {
      model.refresh()
      await model.configureNotifications(requestPermission: false)
    }
    .confirmationDialog(
      "Quit and keep closed?",
      isPresented: Binding(
        get: { quitCandidate != nil }, set: { if !$0 { quitCandidate = nil } }
      ), titleVisibility: .visible
    ) {
      if let app = quitCandidate {
        Button("Quit \(app.name)", role: .destructive) {
          Task { await model.quitAndKeepClosed(app) }
          quitCandidate = nil
        }
      }
      Button("Cancel", role: .cancel) { quitCandidate = nil }
    } message: {
      Text(
        "Check this app’s ongoing work first. Save dialogs are respected; the app will stay closed."
      )
    }
  }
}

struct MemoryGuardControls: View {
  @ObservedObject var model: MemoryRescueModel

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Toggle(
        "Memory alerts",
        isOn: Binding(
          get: { model.alertsEnabled }, set: { model.setAlertsEnabled($0) }
        ))
      Toggle(
        "Disk alerts · \(DiskSpacePolicy.reserveLabel) reserve",
        isOn: Binding(
          get: { model.diskAlertsEnabled }, set: { model.setDiskAlertsEnabled($0) }
        ))
      Text(
        model.alertsEnabled || model.diskAlertsEnabled
          ? model.notificationStatus : "Alerts paused; monitoring continues"
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Test alert") { Task { await model.testNotification() } }
        Button("Notification settings") {
          if let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
          {
            NSWorkspace.shared.open(url)
          }
        }
      }.padding(.top, 4).controlSize(.small)
    }
    .panelCard()
  }
}

private struct MemoryCandidateRow: View {
  let candidate: MemoryCandidate
  @ObservedObject var model: MemoryRescueModel
  let onQuit: (MemoryApp) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.app.bundleURL.path))
          .resizable().frame(width: 28, height: 28)
        VStack(alignment: .leading, spacing: 3) {
          Text(candidate.app.name).font(.headline)
          Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 3) {
          Text(ByteText.full(candidate.app.memoryBytes)).font(.callout.bold()).monospacedDigit()
          Text("\(candidate.app.childProcessCount) helpers").font(.caption).foregroundStyle(
            .secondary)
        }
      }
      HStack {
        if let growth = candidate.growth {
          Text(
            "\(growth >= 0 ? "+" : "−")\(ByteText.compact(UInt64(abs(growth)))) since first sample, up to 5m"
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if candidate.app.protectionReason == nil {
          Picker(
            "App preference",
            selection: Binding(
              get: { candidate.policy },
              set: { model.setPolicy(.init(app: candidate.app, policy: $0)) }
            )
          ) {
            ForEach(MemoryAppPolicy.allCases, id: \.self) { policy in
              Text(policy.title).tag(policy)
            }
          }
          .labelsHidden().frame(width: 205)
        }
        if candidate.protected {
          Label("Protected", systemImage: "shield.fill").font(.caption).foregroundStyle(.secondary)
        } else {
          Button(model.isActing(on: candidate.app) ? "Waiting…" : "Quit and keep closed") {
            onQuit(candidate.app)
          }
          .disabled(model.actionProcessID != nil)
        }
      }
    }
    .padding(12)
    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct MemoryIncidentView: View {
  @ObservedObject var model: MemoryRescueModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Local history · pressure, app exits, alerts, quit results")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Reveal log") { NSWorkspace.shared.activateFileViewerSelecting([model.historyURL]) }
      }
      Text("An app exit or recording gap does not confirm a crash or out-of-memory failure.")
        .font(.caption).foregroundStyle(.secondary)
      List(model.incidents.prefix(100)) { incident in
        VStack(alignment: .leading, spacing: 5) {
          Text(incident.detail).font(.callout)
          HStack {
            Text(incident.date, format: .dateTime.month().day().hour().minute().second())
            if let sample = incident.sample {
              Text(
                "· pressure \(sample.pressure.title.lowercased()) · swap \(sample.swapUsed.map(ByteText.compact) ?? "unknown")"
              )
            }
          }
          .font(.caption).foregroundStyle(.secondary)
          if !incident.apps.isEmpty {
            Text(
              incident.apps.prefix(3).map { "\($0.name) \(ByteText.compact($0.bytes))" }.joined(
                separator: " · ")
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 5)
      }
    }
    .padding(16)
  }
}

extension MemoryRisk {
  var tone: MetricTone {
    switch self {
    case .normal: .good
    case .growing, .warning: .warning
    case .critical: .critical
    }
  }
}

extension MemoryPressureLevel {
  var tone: MetricTone {
    switch self {
    case .normal: .good
    case .warning: .warning
    case .critical: .critical
    case .unknown: .neutral
    }
  }
}
