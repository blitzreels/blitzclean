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

/// One resource in the concentric load rings.
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

/// Concentric load rings, outermost first.
struct BlitzVitalRings<Center: View>: View {
  let vitals: [MacVital]
  let lineWidth: CGFloat
  @ViewBuilder let center: () -> Center
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var gap: CGFloat { lineWidth * 0.7 }

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      ZStack {
        ForEach(Array(vitals.enumerated()), id: \.element.id) { index, vital in
          ring(vital, diameter: side - CGFloat(index) * 2 * (lineWidth + gap))
        }
        center()
          .frame(width: max(0, side - CGFloat(vitals.count) * 2 * (lineWidth + gap) - 8))
      }.frame(width: side, height: side)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(vitals.map { "\($0.title) \($0.value)" }.joined(separator: ", "))
  }

  private func ring(_ vital: MacVital, diameter: CGFloat) -> some View {
    let load = max(0.004, min(1, vital.load ?? 0))
    return ZStack {
      Circle().stroke(Color.white.opacity(0.06), lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: vital.load != nil ? load : 0)
        .stroke(vital.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .frame(width: max(0, diameter - lineWidth), height: max(0, diameter - lineWidth))
    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: load)
  }
}

/// Legend entry for one ring: hue dot, title, value and caption.
struct MacVitalLabel: View {
  let vital: MacVital

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Circle().fill(vital.color).frame(width: 7, height: 7)
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
      VStack(alignment: .leading, spacing: 2) {
        Text(vital.title).font(BlitzType.captionEmphasis).foregroundStyle(BlitzUI.secondaryText)
        Text(vital.value).font(BlitzType.rowTitle).monospacedDigit().lineLimit(1)
          .minimumScaleFactor(0.85).contentTransition(.numericText())
          .foregroundStyle(vital.alertColor ?? BlitzUI.primaryText)
        Text(vital.caption).font(BlitzType.caption).monospacedDigit()
          .foregroundStyle(BlitzUI.tertiaryText).lineLimit(1)
      }
    }
  }
}

/// The busiest resource, for the center of the rings: its load and name.
struct MacVitalPeak: View {
  let vitals: [MacVital]
  let size: CGFloat

  var body: some View {
    if let peak = vitals.filter({ $0.load != nil }).max(by: { ($0.load ?? 0) < ($1.load ?? 0) }) {
      VStack(spacing: 0) {
        Text(PercentText.make(peak.load ?? 0))
          .font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
          .foregroundStyle(peak.alertColor ?? BlitzUI.primaryText)
          .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.6)
        Text(peak.title.lowercased()).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Busiest: \(peak.title), \(PercentText.make(peak.load ?? 0)) used")
    }
  }
}
