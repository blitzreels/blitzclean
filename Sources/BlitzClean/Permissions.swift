import AppKit
import SwiftUI

enum SystemSettingsPane: String {
  case accessibility =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  case fullDiskAccess = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
  case notifications = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

  @MainActor func open() {
    if let url = URL(string: rawValue) { NSWorkspace.shared.open(url) }
  }
}

/// Full Disk Access has no query API; opening a TCC-protected file is the reliable probe.
enum FullDiskAccessProbe {
  static func isGranted() -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let protected = [
      home + "/Library/Application Support/com.apple.TCC/TCC.db",
      home + "/Library/Safari/Bookmarks.plist",
      "/Library/Application Support/com.apple.TCC/TCC.db",
    ]
    for path in protected where FileManager.default.fileExists(atPath: path) {
      return FileHandle(forReadingAtPath: path) != nil
    }
    return false
  }
}

@MainActor final class PermissionsModel: ObservableObject {
  @Published private(set) var fullDiskAccess = FullDiskAccessProbe.isGranted()

  func refresh() {
    let granted = FullDiskAccessProbe.isGranted()
    if granted != fullDiskAccess { fullDiskAccess = granted }
  }
}

/// Inputs every permission surface reads, so the sidebar badge and Settings agree.
struct PermissionState {
  let notifications: Bool
  let accessibility: Bool
  let fullDiskAccess: Bool

  var missingCount: Int { [notifications, accessibility, fullDiskAccess].filter { !$0 }.count }
}

/// Settings onboarding: lists only permissions that are still missing and disappears once all are granted.
struct PermissionSetupSection: View {
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var recovery: AppRecoveryModel
  @ObservedObject var permissions: PermissionsModel

  private var state: PermissionState {
    .init(
      notifications: memory.notificationsAllowed, accessibility: recovery.accessibilityEnabled,
      fullDiskAccess: permissions.fullDiskAccess)
  }

  var body: some View {
    let state = state
    if state.missingCount > 0 {
      VStack(alignment: .leading, spacing: 10) {
        BlitzSectionHeader(title: "Finish setup", count: nil) {
          Text("\(3 - state.missingCount) of 3 allowed").font(BlitzType.caption).monospacedDigit()
            .foregroundStyle(BlitzUI.secondaryText)
        }
        VStack(spacing: 0) {
          let rows = rows(state)
          ForEach(rows, id: \.title) { row in
            permissionRow(row)
            if row.title != rows.last?.title { BlitzRowDivider(leading: 56) }
          }
        }.blitzTable()
      }
    }
  }

  private struct Row {
    let symbol: String
    let title: String
    let reason: String
    let action: () -> Void
  }

  private func rows(_ state: PermissionState) -> [Row] {
    var rows: [Row] = []
    if !state.notifications {
      rows.append(
        .init(
          symbol: "bell.badge", title: "Notifications",
          reason: "Warn you before memory or disk runs out.",
          action: {
            Task {
              await memory.configureNotifications(requestPermission: true)
              if !memory.notificationsAllowed { SystemSettingsPane.notifications.open() }
            }
          }))
    }
    if !state.accessibility {
      rows.append(
        .init(
          symbol: "hand.raised", title: "Accessibility",
          reason: "Detect frozen app windows on Revive apps.",
          action: { recovery.openAccessibilitySettings() }))
    }
    if !state.fullDiskAccess {
      rows.append(
        .init(
          symbol: "internaldrive", title: "Full Disk Access",
          reason: "Measure protected folders such as Mail, Safari and other users' data.",
          action: { SystemSettingsPane.fullDiskAccess.open() }))
    }
    return rows
  }

  private func permissionRow(_ row: Row) -> some View {
    HStack(spacing: 12) {
      Image(systemName: row.symbol).font(.system(size: 14))
        .foregroundStyle(BlitzUI.secondaryText).frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.title).font(BlitzType.rowTitle)
        Text(row.reason).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      }
      Spacer(minLength: 12)
      Button("Allow…", action: row.action).blitzButton(.secondary).controlSize(.small)
    }.blitzRow()
  }
}
