import AppKit
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
  case accent, secondary, quiet
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
    let height: CGFloat =
      controlSize == .large ? 40 : controlSize == .small ? 28 : controlSize == .mini ? 24 : 34
    let fontSize: CGFloat =
      controlSize == .large ? 13 : controlSize == .small || controlSize == .mini ? 11 : 12
    let destructive = configuration.role == .destructive
    configuration.label
      .font(.system(size: fontSize, weight: .medium))
      .symbolRenderingMode(.monochrome)
      .padding(.horizontal, controlSize == .large ? 16 : 10)
      .padding(.vertical, 4)
      .frame(minHeight: height)
      .foregroundStyle(
        destructive
          ? BlitzUI.recordRed
          : prominent
            ? Color.black.opacity(0.88)
            : emphasis == .quiet && !isHovered ? BlitzUI.secondaryText : BlitzUI.primaryText
      )
      .background(
        destructive
          ? BlitzUI.recordRed.opacity(0.10)
          : prominent
            ? BlitzUI.mint.opacity(isHovered ? 0.9 : 1)
            : isHovered ? BlitzUI.hoverFill : emphasis == .quiet ? .clear : BlitzUI.controlFill,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(emphasis == .secondary ? BlitzUI.panelStroke : .clear, lineWidth: 1)
          .allowsHitTesting(false)
      }
      .opacity(isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.4)
      .contentShape(RoundedRectangle(cornerRadius: 8))
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

struct BlitzSelectionButtonStyle: ButtonStyle {
  let isSelected: Bool
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isSelected ? BlitzUI.primaryText : BlitzUI.secondaryText)
      .background(
        isSelected ? Color.white.opacity(0.10) : isHovered ? BlitzUI.controlFill : .clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .opacity(isEnabled ? configuration.isPressed ? 0.76 : 1 : 0.4)
      .onHover { isHovered = $0 }
  }
}

struct BlitzSegmentedPicker<Value: Hashable>: View {
  let title: String
  let options: [Value]
  @Binding var selection: Value
  let label: (Value) -> String
  @Environment(\.controlSize) private var controlSize

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options, id: \.self) { value in
        Button {
          selection = value
        } label: {
          Text(label(value)).font(.system(size: 12, weight: .medium))
            .lineLimit(1).frame(maxWidth: .infinity)
            .frame(height: controlSize == .small ? 26 : 32)
        }
        .buttonStyle(BlitzSelectionButtonStyle(isSelected: selection == value))
        .accessibilityAddTraits(selection == value ? [.isSelected] : [])
        .accessibilityValue(selection == value ? "Selected" : "")
      }
    }.padding(3).background(BlitzUI.controlFill, in: RoundedRectangle(cornerRadius: 10))
      .accessibilityElement(children: .contain).accessibilityLabel(title)
  }
}

struct BlitzSearchField: View {
  let title: String
  @Binding var text: String
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField(title, text: $text).textFieldStyle(.plain).focused($focused)
        .font(.system(size: 12))
    }.padding(.horizontal, 10).frame(height: 34)
      .background(BlitzUI.controlFill, in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(focused ? BlitzUI.mint.opacity(0.6) : BlitzUI.panelStroke, lineWidth: 1)
          .allowsHitTesting(false)
      }
  }
}

struct BlitzSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack {
      configuration.label.accessibilityHidden(true)
      Spacer()
      Toggle(isOn: configuration.$isOn) { configuration.label }
        .labelsHidden().toggleStyle(.switch)
    }
  }
}
