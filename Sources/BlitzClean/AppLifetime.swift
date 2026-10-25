import AppKit
import Carbon
import SwiftUI

enum AppQuitPolicy {
  struct Request {
    let explicitStop: Bool
    let event: NSAppleEventDescriptor?
  }

  static func keepsMonitoring(_ request: Request) -> Bool {
    guard !request.explicitStop else { return false }
    let reason =
      request.event?.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
      ?? request.event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
    let systemReasons: Set<OSType> = [
      OSType(kAEQuitAll), OSType(kAEShutDown), OSType(kAERestart), OSType(kAEReallyLogOut),
      OSType(kAELogOut),
    ]
    return reason.map { !systemReasons.contains($0) } ?? true
  }
}

@MainActor
enum AppLifetime {
  private(set) static var explicitStop = false

  static func stopMonitoringAndQuit() {
    explicitStop = true
    NSApp.terminate(nil)
  }

  /// Sparkle quits the app to install an update and relaunches it afterwards.
  static func allowRelaunchForUpdate() {
    explicitStop = true
  }

  static func closeDashboard(_ app: NSApplication) {
    for window in app.windows where window.styleMask.contains(.titled) {
      window.close()
    }
    app.setActivationPolicy(.accessory)
  }
}

/// Shows the dashboard only while its window is open. SwiftUI keeps a closed window's views alive and
/// recomputed every page on each reading, which cost about a third of BlitzClean's idle CPU.
struct DashboardWindowContent<Content: View>: View {
  /// Starts closed: SwiftUI can build this view for a window that is never shown.
  @State private var open = false
  @ViewBuilder let content: () -> Content

  var body: some View {
    Group {
      if open { content() } else { Color.clear }
    }.background(DashboardWindowLifecycle(onChange: { open = $0 }))
  }
}

struct DashboardWindowLifecycle: NSViewRepresentable {
  /// Called with whether the window is open whenever that may have changed.
  let onChange: (Bool) -> Void

  func makeNSView(context: Context) -> DashboardLifecycleView {
    let view = DashboardLifecycleView()
    view.onChange = onChange
    return view
  }

  func updateNSView(_ nsView: DashboardLifecycleView, context: Context) {
    nsView.onChange = onChange
  }
}

final class DashboardLifecycleView: NSView {
  var onChange: ((Bool) -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self)
    guard let window else { return }
    NotificationCenter.default.addObserver(
      self, selector: #selector(dashboardWillClose), name: NSWindow.willCloseNotification,
      object: window)
    for name in [
      NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
      NSWindow.didBecomeMainNotification,
    ] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(visibilityChanged), name: name, object: window)
    }
    visibilityChanged(Notification(name: NSWindow.didChangeOcclusionStateNotification))
  }

  @objc private func visibilityChanged(_ notification: Notification) {
    guard let window else { return }
    let visible = window.isVisible
    DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
  }

  @objc private func dashboardWillClose(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    DispatchQueue.main.async { [weak self] in self?.onChange?(false) }
  }
}
