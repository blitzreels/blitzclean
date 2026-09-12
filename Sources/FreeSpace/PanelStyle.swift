import SwiftUI

enum MetricTone: Equatable {
  case neutral
  case good
  case warning
  case critical

  var color: Color {
    switch self {
    case .neutral:
      .secondary
    case .good:
      BlitzUI.mint
    case .warning:
      .orange
    case .critical:
      .red
    }
  }

  static func forUsedRatio(_ ratio: Double) -> MetricTone {
    if ratio >= 0.95 {
      return .critical
    }

    if ratio >= 0.85 {
      return .warning
    }

    return .good
  }

  static func forAvailableRatio(_ ratio: Double) -> MetricTone {
    if ratio <= 0.1 {
      return .critical
    }

    if ratio <= 0.2 {
      return .warning
    }

    return .good
  }

  static func forDisk(_ input: DiskCapacityInput) -> MetricTone {
    switch DiskSpacePolicy.status(input) {
    case .healthy: .good
    case .warning: .warning
    case .critical: .critical
    case .unknown: .neutral
    }
  }
}

enum PanelMetrics {
  static let cardRadius: CGFloat = 12
  static let cardPadding: CGFloat = 12
  static let innerRadius: CGFloat = 6
}

private struct PanelCardModifier: ViewModifier {
  let padding: CGFloat

  func body(content: Content) -> some View {
    content
      .padding(padding)
      .background(
        BlitzUI.cardFill,
        in: RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)
          .strokeBorder(BlitzUI.panelStroke, lineWidth: 1)
      }
  }
}

extension View {
  func panelCard(padding: CGFloat = PanelMetrics.cardPadding) -> some View {
    modifier(PanelCardModifier(padding: padding))
  }
}

struct PanelSectionHeader<Trailing: View>: View {
  let title: String
  @ViewBuilder let trailing: () -> Trailing

  init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
    self.title = title
    self.trailing = trailing
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .tracking(0.6)
        .foregroundStyle(.secondary)
      Spacer()
      trailing()
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }
}

struct CapacityBar: View {
  let usedRatio: Double
  let tone: MetricTone

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.fill.secondary)
        Capsule()
          .fill(tone.color)
          .frame(width: max(6, geometry.size.width * min(1, max(0, usedRatio))))
      }
    }
    .frame(height: 6)
    .animation(.easeOut(duration: 0.25), value: usedRatio)
  }
}

enum PercentText {
  static func make(_ ratio: Double) -> String {
    (ratio * 100).formatted(.number.precision(.fractionLength(0))) + "%"
  }
}
