import SwiftUI

/// Colors that identify each resource across Overview, the sidebar pages and their icons.
enum BlitzPalette {
  static let storage = Color(red: 0.25, green: 0.52, blue: 0.98)
  static let memory = Color(red: 0.58, green: 0.40, blue: 0.96)
  static let cpu = Color(red: 0.98, green: 0.55, blue: 0.20)
  static let apps = Color(red: 0.96, green: 0.32, blue: 0.42)
  static let good = Color(red: 0.20, green: 0.78, blue: 0.47)

  static func tone(_ tone: BlitzStatusTone) -> Color {
    tone == .good || tone == .muted || tone == .working ? good : tone.color
  }
}

enum BlitzNumberFont {
  /// Large figures use the rounded face, as Activity and Battery settings do.
  static func value(_ size: CGFloat) -> Font {
    .system(size: size, weight: .semibold, design: .rounded)
  }
}

/// A System Settings–style squircle: flat color, white glyph, a faint top highlight.
struct BlitzColorTile: View {
  let symbol: String
  let color: Color
  let size: CGFloat

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
    shape
      .fill(color.gradient)
      .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
      .overlay(
        Image(systemName: symbol).font(.system(size: size * 0.5, weight: .medium))
          .foregroundStyle(.white)
      )
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

/// A thin rounded bar split into colored parts; the rest of the track stays empty.
struct SegmentedBar: View {
  struct Segment: Identifiable {
    let id: String
    let color: Color
    let fraction: Double
  }

  let segments: [Segment]
  let height: CGFloat

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 1) {
        ForEach(segments) { segment in
          Rectangle().fill(segment.color)
            .frame(width: max(2, geometry.size.width * min(1, max(0, segment.fraction))))
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white.opacity(0.07))
      .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
    }.frame(height: height)
  }
}

/// Small uppercase group label, as in System Settings and Linear's sidebars.
struct BlitzGroupLabel: View {
  let title: String

  var body: some View {
    Text(title).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).tracking(0.6)
      .foregroundStyle(BlitzUI.tertiaryText)
      .accessibilityAddTraits(.isHeader)
  }
}

extension View {
  /// The one card surface: panel fill, hairline border, 12-point corners.
  func blitzCard(padding: CGFloat) -> some View {
    self.padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        BlitzUI.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
  }
}

/// A button label with the glyph that matches its verb, so every action reads at a glance.
struct BlitzActionLabel: View {
  let title: String

  var body: some View {
    if let symbol = Self.symbol(title) {
      Label(title, systemImage: symbol)
    } else {
      Text(title)
    }
  }

  static func symbol(_ title: String) -> String? {
    switch title.split(separator: " ").first.map(String.init) ?? "" {
    case "Delete", "Empty", "Remove": "trash"
    case "Stop": "stop.fill"
    case "Quit", "Close": "xmark"
    case "Pause": "pause.fill"
    case "Resume": "play.fill"
    case "Review", "See", "Open": "arrow.right"
    case "Revive": "waveform.path.ecg"
    case "Free": "sparkles"
    case "Run": "tortoise.fill"
    default: nil
    }
  }
}
