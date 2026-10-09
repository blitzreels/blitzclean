import AppKit
import SwiftUI

enum CleanPage: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case memory = "Memory"
  case cpu = "CPU"
  case storage = "Storage"
  case recovery = "Revive apps"
  case projects = "Projects"
  case settings = "Settings"
  var id: Self { self }
  var symbol: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .memory: "memorychip"
    case .cpu: "cpu"
    case .storage: "internaldrive"
    case .recovery: "waveform.path.ecg"
    case .projects: "folder"
    case .settings: "gearshape"
    }
  }

  static let main: [Self] = [.overview, .memory, .cpu, .storage, .recovery, .projects]

  static func destination(for window: String) -> Self? {
    switch window {
    case "workspace": .projects
    case "storage-breakdown": .storage
    case "memory-rescue", "processes": .memory
    case "app-recovery": .recovery
    default: nil
    }
  }

  /// Pages removed in 1.0.12 open where their feature lives now.
  static func restored(_ value: String?) -> Self {
    switch value {
    case "AI workers", "Processes", "History": .memory
    case "Worktrees", "Developer storage": .storage
    case "Project folders": .settings
    default: value.flatMap(Self.init(rawValue:)) ?? .overview
    }
  }
}

enum CleanStoragePage: String, CaseIterable {
  case browse = "Browse"
  case mac = "Inventory"
  case cleanup = "Cleanup"

  static func restored(_ value: String?) -> Self {
    switch value {
    case "Mac": .mac
    case "Caches", "Dependencies": .cleanup
    case "Files & media", "Files": .browse
    default: value.flatMap(Self.init(rawValue:)) ?? .browse
    }
  }
}

@MainActor
extension OpenWindowAction {
  @MainActor func dashboard() {
    NSApp.setActivationPolicy(.regular)
    callAsFunction(id: "dashboard")
    NSApp.activate(ignoringOtherApps: true)
  }
}

final class CleanNavigation: ObservableObject {
  private let defaults: UserDefaults
  @Published var page: CleanPage {
    didSet { defaults.set(page.rawValue, forKey: "navigation.page") }
  }
  @Published var storagePage: CleanStoragePage {
    didSet { defaults.set(storagePage.rawValue, forKey: "navigation.storagePage") }
  }

  init(_ defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let savedPage = defaults.string(forKey: "navigation.page")
    page = CleanPage.restored(savedPage)
    storagePage =
      savedPage == "Developer storage" || savedPage == "Worktrees"
      ? .cleanup : CleanStoragePage.restored(defaults.string(forKey: "navigation.storagePage"))
    defaults.set(page.rawValue, forKey: "navigation.page")
    defaults.set(storagePage.rawValue, forKey: "navigation.storagePage")
  }

  /// Opens the page that resolves the limiting resource.
  func review(_ pressure: PressureAssessment) {
    if pressure.limit == .disk {
      storagePage = .cleanup
      page = .storage
    } else {
      page = .projects
    }
  }
}

struct DashboardServices {
  let recovery: AppRecoveryModel
  let permissions: PermissionsModel
  let docker: DockerStorageModel
  let folders: FolderExplorerModel
  let launchAtLogin: LaunchAtLoginController
  let updates: AppUpdateController
}

struct BlitzDashboardView: View {
  @StateObject private var audit = DashboardAuditModel()
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var cleanup: QuickCleanModel
  @ObservedObject var storage: StorageBreakdownModel
  @ObservedObject var navigation: CleanNavigation
  @ObservedObject var developerBrowser: DeveloperBrowserModel
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var workspaces: WorkspaceController
  let services: DashboardServices

  var body: some View {
    HStack(spacing: 0) {
      BlitzSidebar(
        navigation: navigation, recovery: services.recovery, memory: memory,
        permissions: services.permissions)
      Rectangle().fill(BlitzUI.separator).frame(width: 1)
      VStack(spacing: 0) {
        if navigation.page != .recovery {
          BlitzPageHeader(title: navigation.page.rawValue) {}
          Rectangle().fill(BlitzUI.separator).frame(height: 1)
        }
        pageContent
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BlitzUI.canvasBackground)
    }
    .ignoresSafeArea(.container, edges: .top)
    .toolbar(removing: .sidebarToggle)
    .navigationTitle(AppBrand.name)
    .blitzTheme()
    .frame(minWidth: 920, minHeight: 640)
    .blitzDropdownHost()
    .task {
      monitor.refresh()
      memory.refresh()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in
      services.permissions.refresh()
      services.recovery.refreshPermission()
      Task { await memory.configureNotifications(requestPermission: false) }
    }
    .onChange(of: memory.scannedAt) {
      guard navigation.page != .recovery else { return }
      let apps = memory.apps.filter(\.isRecoveryEligible)
      Task { await services.recovery.noteProcessStates(apps) }
    }
  }

  @ViewBuilder private var pageContent: some View {
    switch navigation.page {
    case .overview:
      BlitzOverviewView(
        monitor: monitor, memory: memory, repeats: storage.repeats, processes: processes,
        recovery: services.recovery, navigation: navigation, cleanup: cleanup,
        history: storage.overview, storage: storage, docker: services.docker, audit: audit)
    case .memory: MemoryControlView(monitor: monitor, model: memory, processes: processes)
    case .cpu: CPUControlView(monitor: monitor)
    case .storage:
      BlitzStorageView(
        monitor: monitor, cleanup: cleanup, storage: storage, navigation: navigation,
        docker: services.docker, folders: services.folders,
        worktrees: .init(model: developerBrowser, processes: processes, workspaces: workspaces))
    case .recovery:
      AppRecoveryView(memory: memory, model: services.recovery)
    case .projects:
      WorkspaceProjectsView(processes: processes, controller: workspaces)
    case .settings:
      BlitzSettingsView(
        memory: memory, launchAtLogin: services.launchAtLogin, storage: storage,
        recovery: services.recovery, permissions: services.permissions, updates: services.updates)
    }
  }

}

private struct BlitzSidebar: View {
  @ObservedObject var navigation: CleanNavigation
  @ObservedObject var recovery: AppRecoveryModel
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var permissions: PermissionsModel
  @AppStorage(PermissionSkips.key) private var skippedPermissions = ""

  private var missingPermissions: Int {
    PermissionState(
      notifications: memory.notificationsAllowed, accessibility: recovery.accessibilityEnabled,
      fullDiskAccess: permissions.fullDiskAccess,
      skipped: PermissionSkips.decode(skippedPermissions)
    ).missingCount
  }

  private var selection: CleanPage { navigation.page }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Color.clear.frame(height: BlitzUI.toolbarHeight).contentShape(Rectangle())
        .blitzWindowDrag()
      ForEach(Array(CleanPage.main.enumerated()), id: \.element) { index, page in
        item(page, shortcut: index + 1)
      }
      Spacer(minLength: 16)
      item(.settings, shortcut: nil)
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 14)
    .frame(width: 212)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(BlitzUI.panelBackground)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("App navigation")
  }

  @ViewBuilder private func item(_ page: CleanPage, shortcut: Int?) -> some View {
    let selected = selection == page
    let button = Button {
      if page == .storage { navigation.storagePage = .browse }
      navigation.page = page
    } label: {
      HStack(spacing: 10) {
        Image(systemName: page.symbol).symbolVariant(selected ? .fill : .none)
          .font(.system(size: 14, weight: .medium)).frame(width: 20)
          .foregroundStyle(selected ? BlitzUI.mint : BlitzUI.secondaryText)
        Text(page.rawValue).font(BlitzType.callout).lineLimit(1)
        Spacer(minLength: 4)
        if page == .recovery, recovery.attentionCount > 0 {
          BlitzCountBadge(
            count: recovery.attentionCount, label: "\(recovery.attentionCount) apps need attention")
        }
        if page == .settings, missingPermissions > 0 {
          BlitzCountBadge(
            count: missingPermissions, label: "\(missingPermissions) permissions to allow")
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
    .blitzButton(selected ? .secondary : .quiet)
    .accessibilityAddTraits(selected ? .isSelected : [])
    if let shortcut {
      button.keyboardShortcut(KeyEquivalent(Character("\(shortcut)")), modifiers: .command)
        .help("\(page.rawValue) · ⌘\(shortcut)")
    } else {
      button.help(page.rawValue)
    }
  }
}

struct AppMemoryIcon: View {
  let app: MemoryApp
  var body: some View {
    ApplicationIcon(source: .file(app.bundleURL.path), size: 28, fallback: "app")
  }
}
