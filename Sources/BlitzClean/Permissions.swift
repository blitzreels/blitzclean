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

enum PermissionKind: String, CaseIterable {
  case notifications, accessibility, fullDiskAccess

  var title: String {
    switch self {
    case .notifications: "Notifications"
    case .accessibility: "Accessibility"
    case .fullDiskAccess: "Full Disk Access"
    }
  }
}

/// Permissions the user chose not to grant; they leave Finish setup and the sidebar badge.
enum PermissionSkips {
  static let key = "permissions.skipped"

  static func decode(_ value: String) -> Set<PermissionKind> {
    Set(value.split(separator: ",").compactMap { PermissionKind(rawValue: String($0)) })
  }

  static func encode(_ kinds: Set<PermissionKind>) -> String {
    PermissionKind.allCases.filter(kinds.contains).map(\.rawValue).joined(separator: ",")
  }
}

/// Inputs every permission surface reads, so the sidebar badge and Settings agree.
struct PermissionState {
  let notifications: Bool
  let accessibility: Bool
  let fullDiskAccess: Bool
  let skipped: Set<PermissionKind>

  func isGranted(_ kind: PermissionKind) -> Bool {
    switch kind {
    case .notifications: notifications
    case .accessibility: accessibility
    case .fullDiskAccess: fullDiskAccess
    }
  }

  var missing: [PermissionKind] { PermissionKind.allCases.filter { !isGranted($0) } }
  /// Missing and not skipped: what Finish setup lists and the badge counts.
  var pending: [PermissionKind] { missing.filter { !skipped.contains($0) } }
  var skippedMissing: [PermissionKind] { missing.filter(skipped.contains) }
  var missingCount: Int { pending.count }
}

/// Settings onboarding: lists permissions still missing and not skipped; disappears once none remain.
struct PermissionSetupSection: View {
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var recovery: AppRecoveryModel
  @ObservedObject var permissions: PermissionsModel
  @AppStorage(PermissionSkips.key) private var skippedValue = ""

  private var state: PermissionState {
    .init(
      notifications: memory.notificationsAllowed, accessibility: recovery.accessibilityEnabled,
      fullDiskAccess: permissions.fullDiskAccess, skipped: PermissionSkips.decode(skippedValue))
  }

  var body: some View {
    let state = state
    if !state.pending.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        BlitzSectionHeader(title: "Finish setup", count: nil) {
          Text("\(3 - state.missing.count) of 3 allowed").font(BlitzType.caption).monospacedDigit()
            .foregroundStyle(BlitzUI.secondaryText)
        }
        VStack(spacing: 0) {
          let rows = state.pending.map(row)
          ForEach(rows, id: \.kind) { row in
            permissionRow(row)
            if row.kind != rows.last?.kind { BlitzRowDivider(leading: 56) }
          }
        }.blitzTable()
        skippedLine(state)
      }
    } else if !state.skippedMissing.isEmpty {
      skippedLine(state)
    }
  }

  @ViewBuilder private func skippedLine(_ state: PermissionState) -> some View {
    let skipped = state.skippedMissing
    if !skipped.isEmpty {
      HStack(spacing: 6) {
        Text("Not needed: \(skipped.map(\.title).joined(separator: ", ")).")
          .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        Button("Ask again") { setSkipped(state.skipped.subtracting(skipped)) }
          .buttonStyle(.plain).font(BlitzType.caption).underline()
          .foregroundStyle(BlitzUI.supportingText).blitzPointingHand()
      }
    }
  }

  private func setSkipped(_ kinds: Set<PermissionKind>) {
    skippedValue = PermissionSkips.encode(kinds)
  }

  private struct Row {
    let kind: PermissionKind
    let symbol: String
    let reason: String
    let action: () -> Void
  }

  private func row(_ kind: PermissionKind) -> Row {
    switch kind {
    case .notifications:
      .init(
        kind: kind, symbol: "bell.badge", reason: "Warn you before memory or disk runs out.",
        action: {
          Task {
            await memory.configureNotifications(requestPermission: true)
            if !memory.notificationsAllowed { SystemSettingsPane.notifications.open() }
          }
        })
    case .accessibility:
      .init(
        kind: kind, symbol: "hand.raised", reason: "Detect frozen app windows on Revive apps.",
        action: { recovery.openAccessibilitySettings() })
    case .fullDiskAccess:
      .init(
        kind: kind, symbol: "internaldrive",
        reason: "Measure protected folders such as Mail, Safari and other users' data.",
        action: { SystemSettingsPane.fullDiskAccess.open() })
    }
  }

  private func permissionRow(_ row: Row) -> some View {
    HStack(spacing: 12) {
      Image(systemName: row.symbol).font(.system(size: 14))
        .foregroundStyle(BlitzUI.secondaryText).frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.kind.title).font(BlitzType.rowTitle)
        Text(row.reason).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      }
      Spacer(minLength: 12)
      Button("Not needed") { setSkipped(state.skipped.union([row.kind])) }
        .blitzButton(.quiet).controlSize(.small)
        .help("Hide this request and its badge. You can ask again later.")
      Button("Allow…", action: row.action).blitzButton(.secondary).controlSize(.small)
    }.blitzRow()
  }
}
