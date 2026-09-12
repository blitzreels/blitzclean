import SwiftUI

enum BlitzUI {
  static let mint = Color(red: 0.09, green: 1.0, blue: 0.65)
  static let canvasBackground = Color(red: 0.035, green: 0.035, blue: 0.043)
  static let sidebarBackground = Color(red: 0.055, green: 0.055, blue: 0.063)
  static let panelStroke = Color.white.opacity(0.10)
  static let cardFill = Color.white.opacity(0.035)
  static let controlFill = Color.white.opacity(0.055)
  static let hoverFill = Color.white.opacity(0.075)
  static let primaryText = Color.white.opacity(0.92)
  static let secondaryText = Color.white.opacity(0.56)
  static let recordRed = Color(red: 1.0, green: 0.27, blue: 0.27)
}

enum BlitzButtonEmphasis {
  case accent, secondary
}

struct BlitzButtonStyle: ButtonStyle {
  let emphasis: BlitzButtonEmphasis
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.controlSize) private var controlSize
  @State private var isHovered = false

  init(_ emphasis: BlitzButtonEmphasis) {
    self.emphasis = emphasis
  }

  func makeBody(configuration: Configuration) -> some View {
    let prominent = emphasis == .accent
    let destructive = configuration.role == .destructive
    configuration.label
      .font(.system(size: controlSize == .large ? 13 : 12, weight: .medium))
      .symbolRenderingMode(.monochrome)
      .padding(.horizontal, controlSize == .large ? 16 : 10)
      .padding(.vertical, 4)
      .frame(minHeight: controlSize == .large ? 40 : 30)
      .foregroundStyle(
        destructive
          ? BlitzUI.recordRed : prominent ? Color.black.opacity(0.88) : BlitzUI.primaryText
      )
      .background(
        destructive
          ? BlitzUI.recordRed.opacity(0.10)
          : prominent
            ? BlitzUI.mint.opacity(isHovered ? 0.9 : 1)
            : isHovered ? BlitzUI.hoverFill : BlitzUI.controlFill,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(prominent && !destructive ? .clear : BlitzUI.panelStroke, lineWidth: 1)
      }
      .opacity(isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.4)
      .onHover { isHovered = $0 }
  }
}

extension View {
  func blitzTheme() -> some View {
    self
      .background(BlitzUI.canvasBackground.ignoresSafeArea())
      .foregroundStyle(BlitzUI.primaryText)
      .tint(BlitzUI.mint)
      .buttonStyle(BlitzButtonStyle(.secondary))
      .preferredColorScheme(.dark)
  }
}
