import AppKit
import SwiftUI

struct MemoryGuardControls: View {
  @ObservedObject var model: MemoryRescueModel
  @AppStorage(BuildBrakePolicy.key) private var buildBrake = true
  @AppStorage(BuildBrakePolicy.backgroundKey) private var backgroundBuilds = true

  var body: some View {
    let anyAlert = model.alertsEnabled || model.diskAlertsEnabled
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
      Toggle("Run builds at background priority", isOn: $backgroundBuilds)
      Text(
        backgroundBuilds
          ? "Typechecks, compilers and agents' scripts use efficiency cores, so apps stay responsive."
          : "Builds compete with your apps for every core."
      ).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      Toggle("Pause builds before memory runs out", isOn: $buildBrake)
      Text(
        buildBrake
          ? "Typechecks, bundlers and scripts over 1 GB, agents' included. They resume on their own."
          : "Builds run unchecked; a runaway typecheck can restart this Mac."
      ).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      Text(anyAlert ? model.notificationStatus : "Alerts paused; monitoring continues")
        .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      HStack {
        Button("Send test alert") { Task { await model.testNotification() } }
          .disabled(!anyAlert)
        Button("Notification settings…") { SystemSettingsPane.notifications.open() }
      }.blitzButton(.quiet).controlSize(.small).padding(.top, 4)
    }
    .toggleStyle(BlitzSwitchStyle()).font(BlitzType.callout)
    .blitzCard(padding: 16)
  }
}

extension MemoryPressureLevel {
  var tone: BlitzStatusTone {
    switch self {
    case .normal: .good
    case .warning: .warning
    case .critical: .critical
    case .unknown: .muted
    }
  }
}
