import AppKit
import SwiftUI

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
