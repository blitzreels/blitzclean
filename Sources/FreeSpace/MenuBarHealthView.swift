import AppKit
import SwiftUI

enum MenuBarPreferenceKey {
  static let showHealth = "menuBar.showHealth"
  static let showCPU = "menuBar.showCPU"
  static let showMemory = "menuBar.showMemory"
  static let showDisk = "menuBar.showDisk"
}

struct MenuBarStatusTextInput {
  let snapshot: SystemSnapshot
  let showDisk: Bool
  let showCPU: Bool
  let showMemory: Bool
}

enum MenuBarStatusText {
  static func make(_ input: MenuBarStatusTextInput) -> String {
    var segments: [String] = []

    if input.showDisk {
      segments.append("\(ByteText.compact(input.snapshot.diskAvailable)) free")
    }

    if input.showCPU {
      segments.append("CPU \(percentage(input.snapshot.cpuUsage))")
    }

    if input.showMemory {
      segments.append("RAM \(percentage(input.snapshot.ramUsedRatio))")
    }

    return segments.joined(separator: "  ")
  }

  static func percentage(_ ratio: Double?) -> String {
    guard let ratio else {
      return "--"
    }

    return "\((ratio * 100).formatted(.number.precision(.fractionLength(0))))%"
  }
}

struct MenuBarHealthLabel: View {
  @Environment(\.openWindow) private var openWindow
  let snapshot: SystemSnapshot
  let risk: MemoryRisk

  @AppStorage(MenuBarPreferenceKey.showHealth) private var showHealth = true
  @AppStorage(MenuBarPreferenceKey.showCPU) private var showCPU = true
  @AppStorage(MenuBarPreferenceKey.showMemory) private var showMemory = true
  @AppStorage(MenuBarPreferenceKey.showDisk) private var showDisk = true

  private var statusText: String {
    MenuBarStatusText.make(
      MenuBarStatusTextInput(
        snapshot: snapshot,
        showDisk: showDisk,
        showCPU: showCPU,
        showMemory: showMemory
      )
    )
  }

  var body: some View {
    Image(nsImage: MenuBarLabelRenderer.image(content: metrics, colored: showHealth))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
      .help(accessibilityLabel)
      .task {
        if let window = AppLaunch.initialWindow.consume() {
          openWindow(id: window)
          NSApp.activate(ignoringOtherApps: true)
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .openMemoryRescue)) { _ in
        openWindow(id: "memory-rescue")
        NSApp.activate(ignoringOtherApps: true)
      }
      .onReceive(NotificationCenter.default.publisher(for: .openWorkspace)) { _ in
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
      }
      .onReceive(NotificationCenter.default.publisher(for: .openStorageReview)) { _ in
        openWindow(id: "storage-breakdown")
        NSApp.activate(ignoringOtherApps: true)
      }
  }

  var metrics: some View {
    HStack(spacing: 8) {
      Image(systemName: risk > .normal ? "exclamationmark.triangle.fill" : "bolt.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(showHealth && risk > .normal ? risk.tone.color : .primary)
      if showCPU {
        MenuBarMetric(
          title: "CPU", value: snapshot.cpuUsage.map(PercentText.make) ?? "—",
          tone: snapshot.cpuUsage.map(MenuBarTones.cpu) ?? .neutral, colored: showHealth)
      }
      if showMemory {
        MenuBarMetric(
          title: "RAM",
          value: snapshot.ramTotal > 0 ? PercentText.make(snapshot.ramUsedRatio) : "—",
          tone: risk > .normal ? risk.tone : snapshot.memoryPressure.tone, colored: showHealth)
      }
      if showDisk {
        MenuBarMetric(
          title: "FREE",
          value: snapshot.diskTotal > 0 ? ByteText.compact(snapshot.diskAvailable) : "—",
          tone: MenuBarTones.disk(snapshot), colored: showHealth)
      }
    }.frame(height: 22)
  }

  private var accessibilityLabel: String {
    let cpu =
      snapshot.cpuUsage.map { usage in
        MenuBarStatusText.percentage(usage)
      } ?? "sampling"
    let memory = MenuBarStatusText.percentage(snapshot.ramUsedRatio)
    let disk = ByteText.full(snapshot.diskAvailable)
    return
      "Mac \(snapshot.healthStatus.title), CPU \(cpu), memory \(memory), \(disk) disk free. \(statusText)"
  }
}

enum MenuBarTones {
  static func cpu(_ usage: Double) -> MetricTone {
    if usage >= 0.95 {
      return .critical
    }

    if usage >= 0.75 {
      return .warning
    }

    return .good
  }

  static func disk(_ snapshot: SystemSnapshot) -> MetricTone {
    MetricTone.forDisk(
      DiskCapacityInput(available: snapshot.diskAvailable, total: snapshot.diskTotal))
  }
}

private struct MenuBarMetric: View {
  let title: String
  let value: String
  let tone: MetricTone
  let colored: Bool

  var body: some View {
    VStack(spacing: 0) {
      Text(title).font(.system(size: 8, weight: .medium)).opacity(0.8)
      Text(value).font(.system(size: 10, weight: .semibold)).monospacedDigit()
        .foregroundStyle(colored && (tone == .warning || tone == .critical) ? tone.color : .primary)
    }.fixedSize()
  }
}

@MainActor
enum MenuBarLabelRenderer {
  static func image(content: some View, colored: Bool) -> NSImage {
    let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let renderer = ImageRenderer(
      content:
        content
        .foregroundStyle(colored ? (isDark ? Color.white : Color.black) : Color.black)
        .environment(\.colorScheme, isDark ? .dark : .light)
        .padding(.horizontal, 1)
    )
    renderer.scale = 2

    guard let cgImage = renderer.cgImage else {
      return NSImage()
    }

    let image = NSImage(
      cgImage: cgImage,
      size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2))
    image.isTemplate = !colored
    return image
  }
}

struct MenuBarDisplayMenuItems: View {
  var body: some View {
    Section("Show in menu bar") { MenuBarDisplayControls() }
  }
}

struct MenuBarDisplayControls: View {
  @AppStorage(MenuBarPreferenceKey.showHealth) private var showHealth = true
  @AppStorage(MenuBarPreferenceKey.showCPU) private var showCPU = true
  @AppStorage(MenuBarPreferenceKey.showMemory) private var showMemory = true
  @AppStorage(MenuBarPreferenceKey.showDisk) private var showDisk = true

  var body: some View {
    Group {
      Toggle("CPU", isOn: $showCPU)
      Toggle("Memory", isOn: $showMemory)
      Toggle("Disk free", isOn: $showDisk)
      Toggle("Status colors", isOn: $showHealth)
    }
  }
}
