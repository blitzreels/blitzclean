import AppKit
import Darwin
import SwiftUI
import Testing

@testable import BlitzClean

/// Writes dashboard screenshots for design review when `BLITZCLEAN_DESIGN_DIR` is set.
@MainActor
struct DesignRenderTests {
  @Test func rendersDashboardPagesWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["BLITZCLEAN_DESIGN_DIR"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let monitor = SystemMonitor()
    let memory = MemoryRescueModel()
    memory.refresh()
    monitor.refresh()
    for _ in 0..<40 where memory.apps.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
    try await Task.sleep(for: .seconds(2))
    monitor.refresh()

    let apps = memory.apps.filter(\.isRecoveryEligible).sorted { $0.memoryBytes > $1.memoryBytes }
    let defaults = try #require(UserDefaults(suiteName: "design-render-\(UUID())"))
    let recovery = AppRecoveryModel(driver: RenderRecoveryDriver(apps: apps), defaults: defaults)
    await recovery.scan(apps)
    if apps.count > 3 { _ = await recovery.revive(apps[3]) }
    if apps.count > 4 { _ = await recovery.revive(apps[4]) }

    let navigation = CleanNavigation(try #require(UserDefaults(suiteName: "nav-\(UUID())")))
    let services = DashboardServices(
      recovery: recovery, permissions: PermissionsModel(), docker: DockerStorageModel(),
      folders: FolderExplorerModel(),
      launchAtLogin: LaunchAtLoginController())
    let processes = DevProcessModel()
    processes.refresh()
    for _ in 0..<40 where processes.threads.isEmpty {
      try await Task.sleep(for: .milliseconds(250))
    }
    for page in CleanPage.allCases {
      navigation.page = page
      let view = BlitzDashboardView(
        monitor: monitor, memory: memory, cleanup: QuickCleanModel(),
        storage: StorageBreakdownModel(), navigation: navigation,
        developerBrowser: DeveloperBrowserModel(), processes: processes,
        workspaces: WorkspaceController(), services: services
      )
      try await write(view, to: directory.appendingPathComponent("\(page.rawValue).png"))
    }
    try await write(
      BlitzTrayView(
        monitor: monitor, memory: memory, recovery: recovery, navigation: navigation),
      to: directory.appendingPathComponent("Tray.png"), size: .init(width: 340, height: 640))
    let storage = StorageBreakdownModel()
    try await write(
      StorageCleanupView(
        storage: storage, caches: QuickCleanModel(), docker: DockerStorageModel(),
        worktrees: .init(
          model: DeveloperBrowserModel(), processes: processes, workspaces: WorkspaceController())
      )
      .background(BlitzUI.canvasBackground).environment(\.colorScheme, .dark),
      to: directory.appendingPathComponent("Storage cleanup.png"), wait: .seconds(20),
      size: .init(width: 1080, height: 2600))
    try await write(
      MacStorageInventoryView(model: storage, onBrowse: { _ in })
        .background(BlitzUI.canvasBackground).environment(\.colorScheme, .dark),
      to: directory.appendingPathComponent("Storage inventory.png"),
      size: .init(width: 1080, height: 1400))
  }

  private func write(
    _ view: some View, to url: URL, wait: Duration = .seconds(2),
    size: CGSize = .init(width: 1080, height: 760)
  ) async throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.orderFrontRegardless()
    try await Task.sleep(for: wait)
    host.layoutSubtreeIfNeeded()
    let rep = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    window.orderOut(nil)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: url)
  }
}

private actor RenderRecoveryDriver: AppRecoveryDriver {
  let apps: [MemoryApp]
  private var resumed: Set<Int32> = []

  init(apps: [MemoryApp]) { self.apps = apps }

  private func index(_ app: MemoryApp) -> Int { apps.firstIndex(of: app) ?? 99 }

  private func process(_ app: MemoryApp, _ state: Int32) -> RecoveryProcess {
    RecoveryProcess(
      processID: app.processID, owner: geteuid(), startSeconds: 1, startMicroseconds: 1,
      state: UInt32(state))
  }

  func resolve(_ app: MemoryApp) throws -> RecoveryTarget {
    let stopped = index(app) == 0 || index(app) == 3 || index(app) == 4
    return RecoveryTarget(app: app, process: process(app, stopped ? SSTOP : SSLEEP))
  }

  func observe(_ target: RecoveryTarget) throws -> RecoveryObservation {
    let position = index(target.app)
    if position == 4, resumed.contains(target.app.processID) { throw RecoveryExit() }
    if resumed.contains(target.app.processID) {
      return RecoveryObservation(process: process(target.app, SRUN), response: .responding)
    }
    switch position {
    case 0, 3, 4:
      return RecoveryObservation(process: process(target.app, SSTOP), response: .noReply)
    case 1: return RecoveryObservation(process: process(target.app, SSLEEP), response: .noReply)
    default: return RecoveryObservation(process: process(target.app, SSLEEP), response: .responding)
    }
  }

  func resume(_ target: RecoveryTarget) { resumed.insert(target.app.processID) }

  func pause(_ duration: Duration) {}

  func crashReport(for app: MemoryApp, since: Date) -> URL? {
    URL(fileURLWithPath: "/tmp/\(app.name).ips")
  }
}
