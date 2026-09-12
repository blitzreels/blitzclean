import AppKit
import SwiftUI

struct AppRecoveryView: View {
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var model: AppRecoveryModel
  @State private var search = ""

  private var apps: [MemoryApp] {
    memory.apps.filter {
      $0.processID != ProcessInfo.processInfo.processIdentifier
        && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        && $0.bundleIdentifier != AppBrand.bundleIdentifier
        && $0.bundleIdentifier != "com.apple.finder"
        && !$0.bundleURL.resolvingSymlinksInPath().path.hasPrefix("/System/")
    }.sorted {
      let left = $0.protectionReason == "AI app and its workers stay running"
      let right = $1.protectionReason == "AI app and its workers stay running"
      return left == right ? $0.memoryBytes > $1.memoryBytes : left
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Recover a frozen app").font(.title2.bold())
          Text("Try to resume it while keeping it open.").foregroundStyle(.secondary)
        }
        Spacer()
        Button("Refresh") {
          memory.refresh()
          model.refreshPermission()
        }.disabled(memory.isRefreshing || model.activeApp != nil)
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("One resume request per attempt. No app is closed or restarted.").font(.callout)
        Text("An app that has already crashed or been killed by OOM cannot be resumed.")
          .font(.caption).foregroundStyle(.secondary)
        if !model.accessibilityEnabled {
          HStack {
            Text("Enable Accessibility to verify whether the window responds.")
              .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Enable response checks") { model.openAccessibilitySettings() }
          }
        }
      }.panelCard()
      if let app = model.activeApp {
        HStack {
          ProgressView().controlSize(.small)
          Text("Checking \(app.name)… response checks take up to about 10 seconds.")
            .font(.callout)
        }
      }
      if let status = model.status {
        Text(status).font(.callout).foregroundStyle(.secondary)
      }
      TextField("Find an app", text: $search).textFieldStyle(.roundedBorder)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if let report = model.reports.first {
            RecoveryReportView(report: report, model: model)
          }
          Text("Running apps").font(.headline)
          if apps.isEmpty {
            Text(memory.isRefreshing ? "Reading apps…" : "No eligible running apps found.")
              .foregroundStyle(.secondary)
          }
          ForEach(apps) { app in
            HStack(spacing: 12) {
              Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
                .resizable().frame(width: 28, height: 28)
              VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.headline)
                Text("\(ByteText.full(app.memoryBytes)) · \(app.childProcessCount) helpers")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Check response") { run(.init(app: app, attemptResume: false)) }
              Button("Try recovery") { run(.init(app: app, attemptResume: true)) }
                .buttonStyle(.borderedProminent)
            }
            .disabled(model.activeApp != nil || memory.actionProcessID != nil)
            .padding(12)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
          }
        }.padding(.vertical, 4)
      }
      Text(
        "Resume can help a stopped process. Other freezes may persist; it does not repair memory leaks or restore lost work."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    .padding(20)
    .frame(minWidth: 760, minHeight: 600)
    .task {
      memory.refresh()
      model.refreshPermission()
    }
  }

  private func run(_ request: AppRecoveryRequest) {
    Task {
      if let report = await model.run(request) {
        memory.recordRecovery(report)
      }
    }
  }
}

private struct RecoveryReportView: View {
  let report: RecoveryReport
  @ObservedObject var model: AppRecoveryModel

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("\(report.app.name) · \(report.outcome.title)").font(.headline)
          Text(report.date, style: .time).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Show app") { model.showApp(report.app) }.disabled(model.activeApp != nil)
      }
      Text(report.detail).font(.callout).textSelection(.enabled)
      DisclosureGroup("Check details") {
        VStack(alignment: .leading, spacing: 6) {
          Text(
            "PID \(report.app.processID) · \(report.resumeSent ? "SIGCONT sent once" : "No signal sent")"
          )
          ForEach(Array(report.before.enumerated()), id: \.offset) { item in
            Text(
              "Before \(item.offset + 1): \(item.element.process.stateLabel) · \(item.element.response.rawValue)"
            )
          }
          ForEach(Array(report.after.enumerated()), id: \.offset) { item in
            Text(
              "After \(item.offset + 1): \(item.element.process.stateLabel) · \(item.element.response.rawValue)"
            )
          }
        }
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .panelCard()
  }
}
