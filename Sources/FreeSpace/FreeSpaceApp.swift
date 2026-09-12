import AppKit
import SwiftUI

struct FreeSpaceApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var monitor = SystemMonitor()
  @StateObject private var launchAtLogin = LaunchAtLoginController()
  @StateObject private var storageBreakdown = StorageBreakdownModel()
  @StateObject private var dockerStorage = DockerStorageModel()
  @StateObject private var storageNavigation = StorageNavigationModel()
  @StateObject private var memoryRescue = MemoryRescueModel()
  @StateObject private var appRecovery = AppRecoveryModel()
  @StateObject private var devProcesses = DevProcessModel()
  @StateObject private var folderExplorer = FolderExplorerModel()
  @StateObject private var workspaces = WorkspaceController()
  @StateObject private var developerBrowser = DeveloperBrowserModel()

  @StateObject private var quickClean = QuickCleanModel()
  @StateObject private var cleanNavigation = CleanNavigation()

  var body: some Scene {
    MenuBarExtra {
      BlitzTrayView(
        monitor: monitor, memory: memoryRescue, cleanup: quickClean,
        navigation: cleanNavigation, launchAtLogin: launchAtLogin)
    } label: {
      MenuBarHealthLabel(snapshot: monitor.snapshot, risk: memoryRescue.risk)
    }
    .menuBarExtraStyle(.window)

    Window(AppBrand.name, id: "dashboard") {
      BlitzDashboardView(
        monitor: monitor, memory: memoryRescue, cleanup: quickClean,
        storage: storageBreakdown, navigation: cleanNavigation, launchAtLogin: launchAtLogin,
        developerBrowser: developerBrowser, processes: devProcesses, workspaces: workspaces)
    }
    .defaultSize(width: 1080, height: 820)
    .opensOnlyOnRequest()

    Settings {
      BlitzSettingsView(memory: memoryRescue, launchAtLogin: launchAtLogin)
    }

    Window("BlitzClean · Developer tools", id: "workspace") {
      WorkspaceView(
        monitor: monitor, memory: memoryRescue, processes: devProcesses,
        workspaces: workspaces, storage: storageBreakdown, docker: dockerStorage,
        storageNavigation: storageNavigation, folders: folderExplorer,
        developerBrowser: developerBrowser
      )
      .blitzTheme()
    }
    .defaultSize(width: 1240, height: 820)
    .opensOnlyOnRequest()

    Window("Storage", id: "storage-breakdown") {
      StorageBreakdownView(
        model: storageBreakdown,
        monitor: monitor,
        dockerStorage: dockerStorage,
        navigation: storageNavigation,
        folderExplorer: folderExplorer
      ).blitzTheme()
    }
    .defaultSize(width: 960, height: 700)
    .opensOnlyOnRequest()

    Window("Memory Rescue", id: "memory-rescue") {
      MemoryRescueView(model: memoryRescue).blitzTheme()
    }
    .defaultSize(width: 820, height: 720)
    .opensOnlyOnRequest()

    Window("App Recovery", id: "app-recovery") {
      AppRecoveryView(memory: memoryRescue, model: appRecovery).blitzTheme()
    }
    .defaultSize(width: 860, height: 720)
    .opensOnlyOnRequest()

    Window("Processes", id: "processes") {
      DevProcessView(model: devProcesses).blitzTheme()
    }
    .defaultSize(width: 760, height: 620)
    .opensOnlyOnRequest()
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    NotificationCenter.default.post(name: .openWorkspace, object: nil)
    return true
  }

  func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {
    false
  }

  func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
    false
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
  }
}

extension Scene {
  fileprivate func opensOnlyOnRequest() -> some Scene {
    if #available(macOS 15.0, *) {
      return SceneBuilder.buildOptional(
        SceneBuilder.buildLimitedAvailability(
          defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)))
    } else {
      return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(self))
    }
  }
}

struct InitialWindowRequest {
  private var pending: String?

  init(_ arguments: [String]) {
    if arguments.contains("--workspace") {
      pending = "workspace"
    } else if arguments.contains("--storage") {
      pending = "storage-breakdown"
    } else if arguments.contains("--memory-rescue") {
      pending = "memory-rescue"
    } else if !arguments.contains("--background") {
      pending = "dashboard"
    }
  }

  mutating func consume() -> String? {
    defer { pending = nil }
    return pending
  }
}

@MainActor
enum AppLaunch {
  static var initialWindow = InitialWindowRequest(CommandLine.arguments)
}
