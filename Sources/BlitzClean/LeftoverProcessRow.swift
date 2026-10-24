import SwiftUI

struct LeftoverProcessRow: View {
  let process: LeftoverProcess
  let isBusy: Bool
  let onQuit: () -> Void
  let onForceQuit: () -> Void
  let onHide: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      ProjectIcon(
        directory: process.workingDirectory, processName: process.executableName, size: 28,
        fallbackSymbol: "terminal.fill")
      VStack(alignment: .leading, spacing: 2) {
        Text(process.title).font(BlitzType.rowTitle).lineLimit(1)
        Text(detail).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.middle)
      }.frame(maxWidth: .infinity, alignment: .leading)
        .help("Still running after the app or terminal that started it closed.")
      BlitzTrailingValue(
        value: process.memoryBytes.map(ByteText.full) ?? "—",
        detail: "\(process.cpuPercent.formatted(.number.precision(.fractionLength(0))))% CPU"
      ).frame(width: 80, alignment: .trailing)
      BlitzProcessButton(
        title: "Quit", label: "Quit \(process.title)", isBusy: isBusy, action: onQuit
      )
      .frame(width: 96, alignment: .trailing)
      .help("Ask \(process.title) to quit.")
      BlitzActionMenu(label: "More actions for \(process.title)") {
        Button("Force Quit…", role: .destructive, action: onForceQuit)
        if let directory = process.workingDirectory {
          Button("Show folder in Finder") { Finder.reveal(directory) }
        }
        Button("Copy process ID") { Pasteboard.copy(String(process.processID)) }
        Divider()
        Button("Hide \(process.executableName)", action: onHide)
      }.disabled(isBusy)
    }.blitzRow()
  }

  private var detail: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let directory = process.workingDirectory.map { path in
      path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    return [
      directory, "PID \(process.processID)",
      "up \(MemoryControlView.uptime(since: process.startedAt))",
    ].compactMap { $0 }.joined(separator: " · ")
  }
}

enum LeftoverAction {
  case quit([LeftoverProcess])
  case forceQuit(LeftoverProcess)

  var processes: [LeftoverProcess] {
    switch self {
    case .quit(let processes): processes
    case .forceQuit(let process): [process]
    }
  }

  var force: Bool {
    if case .forceQuit = self { return true }
    return false
  }

  var title: String {
    switch self {
    case .quit(let processes): "Quit \(processes.count) leftover processes?"
    case .forceQuit(let process): "Force quit \(process.title)?"
    }
  }

  var message: String {
    let memory = ByteText.full(processes.compactMap(\.memoryBytes).reduce(0, +))
    return switch self {
    case .quit(let processes):
      "The app or terminal that started them already closed. Each one is asked to quit and can still save its work. \(processes.map(\.title).joined(separator: ", ")) · \(memory)."
    case .forceQuit:
      "It ends immediately and cannot save its work. \(memory)."
    }
  }

  var confirmTitle: String {
    force ? "Force Quit" : "Quit all"
  }
}
