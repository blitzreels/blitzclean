import AppKit
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
  @Published private(set) var enabled = SMAppService.mainApp.status == .enabled

  func setEnabled(_ requestedState: Bool) {
    do {
      if requestedState {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      showError(error.localizedDescription)
    }

    enabled = SMAppService.mainApp.status == .enabled
  }

  private func showError(_ message: String) {
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = "Launch at Login could not be changed"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
