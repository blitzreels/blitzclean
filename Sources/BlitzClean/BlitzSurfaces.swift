import SwiftUI

extension BlitzUI {
  static let heroRadius: CGFloat = 18
}

extension BlitzType {
  static let display = Font.system(size: 30, weight: .semibold, design: .rounded)
  static let displayNumber = Font.system(size: 40, weight: .semibold, design: .rounded)
    .monospacedDigit()
}

extension CleanPage {
  /// Ring color for the resource a page owns: the one accent, then two neutrals.
  /// Warning and critical tones override it.
  var hue: Color {
    switch self {
    case .memory: BlitzUI.mint
    case .cpu: Color.white.opacity(0.82)
    default: Color.white.opacity(0.46)
    }
  }
}

/// Featured surface: the card fill with a larger radius and a slightly brighter edge.
extension View {
  func blitzHeroCard() -> some View {
    let shape = RoundedRectangle(cornerRadius: BlitzUI.heroRadius, style: .continuous)
    return background(BlitzUI.cardFill, in: shape)
      .overlay { shape.strokeBorder(BlitzUI.panelStroke, lineWidth: 1).allowsHitTesting(false) }
  }
}

/// Rounded-square symbol that identifies a finding's category. Neutral unless the finding is a warning.
struct BlitzIconTile: View {
  let symbol: String
  let tone: BlitzStatusTone
  var size: CGFloat = 34

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
    let isAlert = tone == .warning || tone == .critical
    shape.fill(isAlert ? tone.color.opacity(0.14) : BlitzUI.controlFill)
      .overlay {
        Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium))
          .foregroundStyle(isAlert ? tone.color : BlitzUI.supportingText)
      }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

/// One-shot burst of particles; plays whenever `trigger` changes and honors Reduce Motion.
struct BlitzCelebration: View {
  let trigger: Date?
  @State private var start: Date?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private static let duration: TimeInterval = 1.9
  private static let colors = [BlitzUI.mint, .white]

  var body: some View {
    TimelineView(.animation(paused: start == nil)) { timeline in
      Canvas { context, size in
        guard let start else { return }
        let t = timeline.date.timeIntervalSince(start)
        guard t < Self.duration else { return }
        let origin = CGPoint(x: size.width / 2, y: size.height * 0.42)
        for index in 0..<64 {
          let seed = Double(index) * 12.9898
          let angle = (sin(seed) * 0.5 + 0.5) * .pi * 2
          let speed = 160 + (sin(seed * 1.7) * 0.5 + 0.5) * 260
          let x = origin.x + cos(angle) * speed * t
          let y = origin.y + sin(angle) * speed * t * 0.7 + 320 * t * t
          let fade = max(0, 1 - t / Self.duration)
          let side = 3 + (sin(seed * 3.1) * 0.5 + 0.5) * 4
          var particle = context
          particle.opacity = fade
          particle.translateBy(x: x, y: y)
          particle.rotate(by: .radians(t * 6 + seed))
          particle.fill(
            Path(
              roundedRect: CGRect(x: -side / 2, y: -side / 4, width: side, height: side / 2),
              cornerRadius: 1),
            with: .color(Self.colors[index % Self.colors.count]))
        }
      }
    }
    .allowsHitTesting(false).accessibilityHidden(true)
    .onAppear { play() }
    .onChange(of: trigger) { play() }
  }

  private func play() {
    guard trigger != nil, !reduceMotion else { return }
    let now = Date.now
    start = now
    Task {
      try? await Task.sleep(for: .seconds(Self.duration))
      if start == now { start = nil }
    }
  }
}

/// One resource row in the menu bar tray: its value, tone and page.
struct MacVital: Identifiable, Equatable {
  let page: CleanPage
  let title: String
  let value: String
  /// Value for narrow rows, such as the menu bar panel.
  let compactValue: String
  let caption: String
  /// Share in use, from 0 to 1; absent while the reading is unavailable.
  let load: Double?
  let tone: MetricTone

  var id: CleanPage { page }
  /// Ring and legend color; it identifies the resource and never changes with severity.
  var color: Color { page.hue }
  /// Warning or critical color for the value text; absent when the resource is fine.
  var alertColor: Color? { tone == .warning || tone == .critical ? tone.color : nil }

  static func all(_ input: MacVitalInput) -> [MacVital] {
    let snapshot = input.snapshot
    let hasRAM = snapshot.ramTotal > 0
    let hasDisk = snapshot.diskTotal > 0
    let memoryValue =
      switch input.memoryDisplay {
      case .available: "\(input.memoryDisplay.value(snapshot)) available"
      case .used, .percentage: "\(input.memoryDisplay.value(snapshot)) used"
      }
    return [
      .init(
        page: .memory, title: "Memory", value: hasRAM ? memoryValue : "—",
        compactValue: input.memoryDisplay.menuValue(snapshot),
        caption: hasRAM
          ? input.memoryDisplay == .available
            ? "\(ByteText.compact(snapshot.ramUsed)) used of \(ByteText.compact(snapshot.ramTotal))"
            : "\(ByteText.compact(snapshot.ramAvailable)) available"
          : "Reading memory…",
        load: hasRAM ? snapshot.ramUsedRatio : nil,
        tone: input.memoryTone),
      .init(
        page: .cpu, title: "CPU", value: snapshot.cpuUsage.map(PercentText.make) ?? "—",
        compactValue: snapshot.cpuUsage.map(PercentText.make) ?? "—",
        caption: snapshot.cpuUsage.map { "\(PercentText.make(1 - $0)) idle" } ?? "Reading CPU…",
        load: snapshot.cpuUsage, tone: snapshot.cpuUsage.map(MenuBarTones.cpu) ?? .neutral),
      .init(
        page: .storage, title: "Storage",
        value: hasDisk ? "\(ByteText.compact(snapshot.diskAvailable)) free" : "—",
        compactValue: hasDisk ? "\(ByteText.compact(snapshot.diskAvailable)) free" : "—",
        caption: hasDisk
          ? "\(PercentText.make(snapshot.diskUsedRatio)) of \(ByteText.compact(snapshot.diskTotal)) used"
          : "Reading storage…",
        load: hasDisk ? snapshot.diskUsedRatio : nil, tone: MenuBarTones.disk(snapshot)),
    ]
  }
}

struct MacVitalInput {
  let snapshot: SystemSnapshot
  let memoryDisplay: MenuBarMemoryDisplay
  let memoryTone: MetricTone
}
