import AppKit
import Carbon
import SwiftUI

@MainActor
enum EmergencyControlsLauncher {
  private static var helper: Process?
  static let notification = Notification.Name("com.blitzreels.BlitzClean.emergency.show")

  static func start() { start(showing: false) }

  /// `showing` makes the helper open its panel as soon as it is ready, instead of waiting for a
  /// notification it might not be listening for yet.
  private static func start(showing: Bool) {
    guard helper?.isRunning != true, let executable = Bundle.main.executableURL else { return }
    let bundledHelper = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/BlitzClean Emergency.app/Contents/MacOS/BlitzRescue")
    let process = Process()
    process.executableURL =
      FileManager.default.isExecutableFile(atPath: bundledHelper.path) ? bundledHelper : executable
    process.arguments =
      ["--emergency-controls", "--parent", String(getpid())] + (showing ? ["--show"] : [])
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      helper = process
    } catch {
      helper = nil
    }
  }

  static func open() {
    if helper?.isRunning != true {
      start(showing: true)
    } else {
      DistributedNotificationCenter.default().postNotificationName(notification, object: nil)
    }
  }
}

@MainActor
final class EmergencyControls: NSObject, NSApplicationDelegate, NSTableViewDataSource,
  NSTableViewDelegate
{
  static var active: EmergencyControls?
  private let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
  private let table = NSTableView()
  private let status = NSTextField(wrappingLabelWithString: "Reading local workloads…")
  private let stop = NSButton(title: "Stop selected", target: nil, action: nil)
  private let more = NSPopUpButton(frame: .zero, pullsDown: false)
  private var targets: [EmergencyTarget] = []
  private var busy = false
  private var scanning = false
  private var pending: (target: EmergencyTarget, signal: AIThreadSignal)?
  private var hotKey: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private var timer: Timer?
  private var parent: DevProcessIdentity?

  static func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.appearance = NSAppearance(named: .darkAqua)
    let controller = EmergencyControls()
    active = controller
    app.delegate = controller
    app.run()
    active = nil
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let index = CommandLine.arguments.firstIndex(of: "--parent"),
      CommandLine.arguments.indices.contains(index + 1),
      let pid = Int32(CommandLine.arguments[index + 1])
    {
      parent = DevProcessIdentity.read(pid)
    }
    buildPanel()
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(show),
      name: EmergencyControlsLauncher.notification, object: nil)
    var event = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, _ in
        Task { @MainActor in EmergencyControls.active?.show() }
        return noErr
      }, 1, &event, nil, &eventHandler)
    registerShortcut()
    timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let parent = self.parent,
          DevProcessIdentity.read(parent.process.processID).map(parent.matches) != true
        {
          NSApp.terminate(nil)
          return
        }
        self.registerShortcut()
        if self.panel.isVisible { self.refresh() }
      }
    }
    refresh()
    if CommandLine.arguments.contains("--show") || parent == nil { show() }
  }

  private func registerShortcut() {
    guard hotKey == nil else { return }
    let registered = RegisterEventHotKey(
      UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey | cmdKey),
      EventHotKeyID(signature: 0x4243_4C4E, id: 1), GetApplicationEventTarget(), 0, &hotKey)
    if registered != noErr {
      status.stringValue = "Shortcut unavailable. Open Emergency controls from BlitzClean."
    } else if status.stringValue.hasPrefix("Shortcut unavailable") {
      status.stringValue = "Select a workload. Shared app totals include their local worker groups."
    }
  }

  private func buildPanel() {
    panel.title = "BlitzClean · Emergency controls"
    panel.identifier = NSUserInterfaceItemIdentifier("blitzclean-emergency")
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.backgroundColor = NSColor(BlitzUI.canvasBackground)
    panel.minSize = NSSize(width: 600, height: 380)
    panel.center()
    let root = NSStackView()
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 16
    root.edgeInsets = NSEdgeInsets(top: 12, left: 28, bottom: 24, right: 28)
    let title = NSTextField(labelWithString: "Emergency controls")
    title.font = .systemFont(ofSize: 24, weight: .semibold)
    title.textColor = NSColor(BlitzUI.primaryText)
    let hint = NSTextField(
      wrappingLabelWithString:
        "Suspend holds memory. Stop ends local work to release it.\nRemote generation may continue. Open anytime with Control–Option–Command–R."
    )
    hint.font = .systemFont(ofSize: 11)
    hint.textColor = NSColor(BlitzUI.secondaryText)
    root.addArrangedSubview(title)
    root.addArrangedSubview(hint)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workload"))
    column.title = "Local workload"
    column.width = 510
    column.minWidth = 240
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    let memory = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("memory"))
    memory.title = "Footprint"
    memory.width = 110
    memory.minWidth = 110
    memory.maxWidth = 110
    memory.resizingMask = []
    table.addTableColumn(memory)
    table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    table.autoresizingMask = [.width]
    table.rowHeight = 56
    table.backgroundColor = NSColor(BlitzUI.panelBackground)
    table.gridColor = NSColor(BlitzUI.separator)
    table.gridStyleMask = .solidHorizontalGridLineMask
    table.headerView = nil
    table.allowsMultipleSelection = false
    table.delegate = self
    table.dataSource = self
    table.setAccessibilityIdentifier("emergency-workloads")
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.wantsLayer = true
    scroll.layer?.cornerRadius = BlitzUI.cardRadius
    scroll.layer?.borderWidth = 1
    scroll.layer?.borderColor = NSColor(BlitzUI.panelStroke).cgColor
    scroll.backgroundColor = NSColor(BlitzUI.panelBackground)
    scroll.documentView = table
    root.addArrangedSubview(scroll)
    root.addArrangedSubview(status)
    stop.target = self
    stop.action = #selector(stopSelected)
    stop.bezelStyle = .rounded
    stop.isBordered = false
    stop.wantsLayer = true
    stop.layer?.cornerRadius = BlitzUI.controlRadius
    stop.layer?.backgroundColor = NSColor(BlitzUI.mint).cgColor
    stop.contentTintColor = .black
    stop.font = .systemFont(ofSize: 12, weight: .medium)
    status.font = .systemFont(ofSize: 11)
    status.textColor = NSColor(BlitzUI.supportingText)
    stop.setAccessibilityIdentifier("emergency-stop")
    more.addItems(withTitles: [
      "More actions", "Suspend — keeps memory", "Resume", "Force Stop…", "Cancel",
    ])
    more.target = self
    more.action = #selector(otherAction)
    let actions = NSStackView(views: [stop, more])
    actions.spacing = 12
    root.addArrangedSubview(actions)
    panel.contentView = root
    scroll.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56),
      scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
      status.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56),
      hint.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56),
      stop.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
      stop.heightAnchor.constraint(equalToConstant: 34),
    ])
    updateActions()
  }

  @objc func show() {
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    refresh()
  }

  private func refresh() {
    guard !scanning, !busy, pending == nil else { return }
    scanning = true
    Task {
      let result = await Task.detached(priority: .userInitiated) { EmergencyInventory.read() }.value
      let selected = selectedTarget?.id
      targets = result
      table.reloadData()
      if let selected, let index = targets.firstIndex(where: { $0.id == selected }) {
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      } else {
        table.deselectAll(nil)
      }
      scanning = false
      if status.stringValue == "Reading local workloads…" {
        status.stringValue =
          "Select a workload. Shared app totals include their local worker groups."
      }
      updateActions()
    }
  }

  private var selectedTarget: EmergencyTarget? {
    targets.indices.contains(table.selectedRow) ? targets[table.selectedRow] : nil
  }

  private func updateActions() {
    stop.isEnabled = !busy && (selectedTarget != nil || pending != nil)
    stop.alphaValue = stop.isEnabled ? 1 : 0.4
    more.isEnabled = !busy && selectedTarget != nil
    stop.title =
      pending?.signal == .pause
      ? "Confirm suspend" : pending == nil ? "Stop selected" : "Confirm stop"
  }

  @objc private func stopSelected() {
    if let pending {
      self.pending = nil
      execute(.init(target: pending.target, signal: pending.signal))
    } else if let target = selectedTarget {
      if target.isSharedApp {
        confirm(.init(target: target, signal: .quit))
      } else {
        execute(.init(target: target, signal: .quit))
      }
    }
  }

  private struct Action {
    let target: EmergencyTarget
    let signal: AIThreadSignal
  }

  @objc private func otherAction() {
    let index = more.indexOfSelectedItem
    more.selectItem(at: 0)
    guard let target = selectedTarget else { return }
    switch index {
    case 1:
      if target.isSharedApp {
        confirm(.init(target: target, signal: .pause))
      } else {
        execute(.init(target: target, signal: .pause))
      }
    case 2: execute(.init(target: target, signal: .resume))
    case 3: confirm(.init(target: target, signal: .forceQuit))
    case 4:
      pending = nil
      status.stringValue = "Cancelled."
      updateActions()
    default: break
    }
  }

  private func confirm(_ action: Action) {
    pending = (action.target, action.signal)
    status.stringValue =
      action.signal == .pause
      ? "Suspend the entire Codex app and all chats? Memory will remain allocated."
      : "Stop \(action.target.name)? In-progress work will end. Force Stop can lose unsaved changes."
    updateActions()
  }

  private func execute(_ action: Action) {
    busy = true
    status.stringValue = "Applying action to \(action.target.name)…"
    updateActions()
    Task {
      let result = await Task.detached(priority: .userInitiated) {
        await WorkloadControl.execute(
          .init(identities: action.target.identities, signal: action.signal))
      }.value
      if result.affected == 0 {
        status.stringValue =
          "The selected processes exited or changed. Select their current replacement."
      } else if result.remaining > 0 {
        status.stringValue =
          "\(result.remaining) processes still need attention. Force Stop is available in More actions."
      } else {
        let verb =
          action.signal == .pause ? "Suspended" : action.signal == .resume ? "Resumed" : "Stopped"
        status.stringValue =
          "\(verb) \(result.affected) processes. Retained footprint: \(ByteText.full(result.retainedBytes))."
      }
      busy = false
      updateActions()
      refresh()
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { targets.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard targets.indices.contains(row) else { return nil }
    let target = targets[row]
    let isMemory = tableColumn?.identifier.rawValue == "memory"
    let text = NSTextField(
      wrappingLabelWithString: isMemory
        ? ByteText.full(target.bytes)
        : "\(target.name)\(target.suspended ? " · Suspended" : "")\n\(target.detail)")
    text.font =
      isMemory ? .monospacedDigitSystemFont(ofSize: 12, weight: .medium) : .systemFont(ofSize: 12)
    text.textColor = NSColor(BlitzUI.primaryText)
    text.alignment = isMemory ? .right : .left
    text.maximumNumberOfLines = 2
    if isMemory { return text }
    let source: ApplicationIconSource =
      target.appName.map { .name($0) }
      ?? .process(target.identities.first?.process.processID ?? 0)
    let icon = NSImageView()
    icon.image =
      ApplicationIconResolver.image(source)
      ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 24),
      icon.heightAnchor.constraint(equalToConstant: 24),
    ])
    let row = NSStackView(views: [icon, text])
    row.spacing = 10
    return row
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    show()
    return true
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    pending = nil
    updateActions()
  }
}
