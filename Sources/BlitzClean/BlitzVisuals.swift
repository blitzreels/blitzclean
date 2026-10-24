import SwiftUI

/// Chart colors. Data is drawn in one neutral ink; only warning and critical readings take a color,
/// so color always means something needs attention (October 24 request: fewer colors).
enum BlitzPalette {
  static let data = Color.white.opacity(0.82)
  static let good = BlitzUI.mint

  /// The ink for a reading: neutral while it is fine, the tone's color when it needs attention.
  static func ink(_ tone: BlitzStatusTone) -> Color {
    tone == .warning || tone == .critical ? tone.color : data
  }
}

enum BlitzNumberFont {
  /// Large figures use the rounded face, as Activity and Battery settings do.
  static func value(_ size: CGFloat) -> Font {
    .system(size: size, weight: .semibold, design: .rounded)
  }
}

/// A quiet icon square, as Linear draws its icons: neutral fill and glyph, tinted only when its tone
/// needs attention (warning, critical) or reports a finished fix (good).
struct BlitzIconTile: View {
  let symbol: String
  let tone: BlitzStatusTone
  let size: CGFloat

  private var tinted: Bool { tone == .warning || tone == .critical }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
    shape
      .fill(tinted ? tone.color.opacity(0.14) : Color.white.opacity(0.06))
      .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
      .overlay(
        Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium))
          .foregroundStyle(tinted || tone == .good ? tone.color : BlitzUI.supportingText)
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
  /// The one surface for cards, tables and panels: panel fill, hairline border, 12-point corners.
  func blitzSurface() -> some View {
    let shape = RoundedRectangle(cornerRadius: BlitzUI.cardRadius, style: .continuous)
    return background(BlitzUI.panelBackground, in: shape)
      .clipShape(shape)
      .overlay {
        shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 1).allowsHitTesting(false)
      }
  }

  /// A padded card on the shared surface.
  func blitzCard(padding: CGFloat) -> some View {
    self.padding(padding).frame(maxWidth: .infinity, alignment: .leading).blitzSurface()
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
