import AppKit
import Foundation

@MainActor
final class CleanupLauncher {
  static let shared = CleanupLauncher()

  private let molePath = ExecutableLocator.firstAvailable([
    "/opt/homebrew/bin/mo",
    "/usr/local/bin/mo",
  ])
  var hasMole: Bool {
    molePath != nil
  }

  func previewMole() {
    guard let molePath else {
      return
    }

    launchInTerminal("\(shellQuote(molePath)) clean --dry-run")
  }

  func runMole() {
    guard let molePath else {
      return
    }

    let confirmed = confirm(
      Confirmation(
        title: "Run Mole cleanup?",
        message: "Mole will open in Terminal and ask you what to remove.",
        actionTitle: "Open Mole"
      )
    )

    guard confirmed else {
      return
    }

    launchInTerminal("\(shellQuote(molePath)) clean")
  }

  func openStorageSettings() {
    guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")
    else {
      return
    }

    NSWorkspace.shared.open(settingsURL)
  }

  private func confirm(_ confirmation: Confirmation) -> Bool {
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = confirmation.title
    alert.informativeText = confirmation.message
    alert.alertStyle = .warning
    alert.addButton(withTitle: confirmation.actionTitle)
    alert.addButton(withTitle: "Cancel")

    return alert.runModal() == .alertFirstButtonReturn
  }

  private func launchInTerminal(_ command: String) {
    let escapedCommand =
      command
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
      tell application "Terminal"
          activate
          do script "\(escapedCommand)"
      end tell
      """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]

    try? process.run()
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

private struct Confirmation {
  let title: String
  let message: String
  let actionTitle: String
}

private enum ExecutableLocator {
  static func firstAvailable(_ candidates: [String]) -> String? {
    candidates.first { candidate in
      FileManager.default.isExecutableFile(atPath: candidate)
    }
  }
}
