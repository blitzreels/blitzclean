import AppKit
import Carbon

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
    app.hide(nil)
  }
}
