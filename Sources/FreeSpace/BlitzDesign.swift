import AppKit
import SwiftUI

enum BlitzType {
  static let largeTitle = Font.system(size: 24, weight: .semibold)
  static let title = Font.system(size: 17, weight: .semibold)
  static let headline = Font.system(size: 15, weight: .semibold)
  static let section = Font.system(size: 13, weight: .semibold)
  static let callout = Font.system(size: 13)
  static let rowTitle = Font.system(size: 13, weight: .medium)
  static let body = Font.system(size: 12)
  static let label = Font.system(size: 12, weight: .medium)
  static let caption = Font.system(size: 11)
  static let captionEmphasis = Font.system(size: 11, weight: .medium)
  static let numeric = Font.system(size: 12).monospacedDigit()
}

enum BlitzUI {
  static let mint = Color(red: 0.09, green: 1.0, blue: 0.65)
  static let lavender = mint
  static let warning = Color(red: 1.0, green: 0.72, blue: 0.22)
  static let recordRed = Color(red: 1.0, green: 0.27, blue: 0.27)
  static let canvasBackground = Color(red: 0.035, green: 0.035, blue: 0.043)
  static let panelBackground = Color(white: 0.105)
  static let sidebarBackground = panelBackground
  static let menuFill = Color(white: 0.13)
  static let panelStroke = Color.white.opacity(0.10)
  static let separator = Color.white.opacity(0.08)
  static let cardFill = Color.white.opacity(0.035)
  static let quietFill = Color.white.opacity(0.045)
  static let controlFill = Color.white.opacity(0.055)
  static let hoverFill = Color.white.opacity(0.075)
  static let selectedFill = Color.white.opacity(0.10)
  static let strongFill = Color.white.opacity(0.16)
  static let strongStroke = Color.white.opacity(0.22)
  static let primaryText = Color.white.opacity(0.92)
  static let supportingText = Color.white.opacity(0.72)
  static let secondaryText = Color.white.opacity(0.56)
  static let tertiaryText = Color.white.opacity(0.38)
  static let controlRadius: CGFloat = 8
  static let cardRadius: CGFloat = 12
  static let pagePadding: CGFloat = 28
  static let toolbarHeight: CGFloat = 52
  static let titleFont = BlitzType.largeTitle
  static let valueFont = Font.system(size: 32, weight: .medium)

  static func sectionLabel(_ title: String) -> some View {
    Text(title).font(BlitzType.captionEmphasis).foregroundStyle(secondaryText).lineLimit(1)
  }
}

enum BlitzButtonEmphasis {
  case accent, emphasized, secondary, quiet
}

enum BlitzControlMetrics {
  static func height(_ size: ControlSize) -> CGFloat {
    switch size {
    case .mini: 24
    case .small: 28
    case .large, .extraLarge: 40
    default: 34
    }
  }

  static func fontSize(_ size: ControlSize) -> CGFloat {
    switch size {
    case .mini, .small: 11
    case .large, .extraLarge: 13
    default: 12
    }
  }

  static func horizontalPadding(_ size: ControlSize) -> CGFloat {
    switch size {
    case .mini, .small: 8
    case .large, .extraLarge: 16
    default: 10
    }
  }
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
    configuration.label
      .font(.system(size: BlitzControlMetrics.fontSize(controlSize), weight: .medium))
      .lineLimit(1)
      .symbolRenderingMode(.monochrome)
      .padding(.horizontal, BlitzControlMetrics.horizontalPadding(controlSize))
      .padding(.vertical, 4)
      .frame(minHeight: BlitzControlMetrics.height(controlSize))
      .foregroundStyle(foreground(configuration.role))
      .background(fill, in: RoundedRectangle(cornerRadius: BlitzUI.controlRadius))
      .overlay {
        RoundedRectangle(cornerRadius: BlitzUI.controlRadius)
          .strokeBorder(emphasis == .secondary ? BlitzUI.panelStroke : .clear, lineWidth: 1)
          .allowsHitTesting(false)
      }
      .opacity(isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.4)
      .contentShape(RoundedRectangle(cornerRadius: BlitzUI.controlRadius))
      .onHover { isHovered = $0 }
      .blitzPointingHand()
  }

  private func foreground(_ role: ButtonRole?) -> Color {
    if role == .destructive, emphasis != .accent { return BlitzUI.recordRed }
    switch emphasis {
    case .accent, .emphasized: return .black.opacity(0.88)
    case .secondary: return BlitzUI.primaryText
    case .quiet: return isHovered && isEnabled ? BlitzUI.primaryText : BlitzUI.secondaryText
    }
  }

  private var fill: Color {
    let hovered = isHovered && isEnabled
    switch emphasis {
    case .accent: return hovered ? BlitzUI.mint.opacity(0.9) : BlitzUI.mint
    case .emphasized: return hovered ? .white : BlitzUI.primaryText
    case .secondary: return hovered ? BlitzUI.hoverFill : BlitzUI.controlFill
    case .quiet: return hovered ? BlitzUI.quietFill : .clear
    }
  }
}

extension View {
  func blitzButton(_ emphasis: BlitzButtonEmphasis) -> some View {
    buttonStyle(BlitzButtonStyle(emphasis))
  }

  @ViewBuilder func blitzPointingHand() -> some View {
    if #available(macOS 15.0, *) {
      pointerStyle(.link).allowsWindowActivationEvents(true)
    } else {
      self
    }
  }

  func blitzInput() -> some View {
    textFieldStyle(.plain).font(BlitzType.callout)
      .padding(.horizontal, 12).frame(height: 38)
      .background(BlitzUI.controlFill, in: RoundedRectangle(cornerRadius: BlitzUI.controlRadius))
      .overlay {
        RoundedRectangle(cornerRadius: BlitzUI.controlRadius).strokeBorder(BlitzUI.panelStroke)
      }
  }

  func blitzTheme() -> some View {
    self
      .background(BlitzUI.canvasBackground.ignoresSafeArea())
      .foregroundStyle(BlitzUI.primaryText)
      .tint(BlitzUI.mint)
      .buttonStyle(BlitzButtonStyle(.secondary))
      .toggleStyle(BlitzCheckboxStyle())
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
        isSelected ? BlitzUI.selectedFill : isHovered ? BlitzUI.quietFill : .clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .contentShape(RoundedRectangle(cornerRadius: 6))
      .opacity(isEnabled ? configuration.isPressed ? 0.76 : 1 : 0.4)
      .onHover { isHovered = $0 }
      .blitzPointingHand()
  }
}

struct BlitzSegmentedPicker<Value: Hashable>: View {
  let title: String
  let options: [Value]
  @Binding var selection: Value
  let label: (Value) -> String
  var body: some View {
    HStack(spacing: 2) {
      ForEach(options, id: \.self) { value in
        Button {
          selection = value
        } label: {
          Text(label(value)).font(BlitzType.label).lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 30).padding(.horizontal, 10)
            .contentShape(Rectangle())
        }.buttonStyle(BlitzSelectionButtonStyle(isSelected: value == selection))
          .accessibilityAddTraits(selection == value ? .isSelected : [])
      }
    }.padding(2)
      .background(BlitzUI.controlFill, in: RoundedRectangle(cornerRadius: BlitzUI.controlRadius))
      .accessibilityElement(children: .contain).accessibilityLabel(title)
  }
}

struct BlitzProcessButton: View {
  let title: String
  let label: String
  let isBusy: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if isBusy { ProgressView().controlSize(.mini) }
        Text(title)
      }.frame(minWidth: 42)
    }.blitzButton(.secondary).controlSize(.regular)
      .disabled(isBusy).accessibilityLabel(label)
  }
}

struct BlitzSearchField: View {
  let title: String
  @Binding var text: String
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
        .foregroundStyle(BlitzUI.tertiaryText)
      TextField(title, text: $text).textFieldStyle(.plain).focused($focused)
        .font(BlitzType.body)
        .accessibilityLabel(title)
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(BlitzUI.tertiaryText)
        }.buttonStyle(.plain).accessibilityLabel("Clear search").help("Clear search")
      }
    }.padding(.horizontal, 10).frame(height: 34)
      .background(BlitzUI.controlFill, in: RoundedRectangle(cornerRadius: BlitzUI.controlRadius))
      .overlay {
        RoundedRectangle(cornerRadius: BlitzUI.controlRadius)
          .strokeBorder(focused ? BlitzUI.mint.opacity(0.6) : BlitzUI.panelStroke, lineWidth: 1)
          .allowsHitTesting(false)
      }
  }
}

struct BlitzPageHeader<Actions: View>: View {
  let title: String
  var detail: String? = nil
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(BlitzType.largeTitle).tracking(-0.4)
          .foregroundStyle(BlitzUI.primaryText)
        if let detail {
          Text(detail).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 16)
      actions()
    }
    .padding(.horizontal, BlitzUI.pagePadding)
    .padding(.top, 20)
    .padding(.bottom, 18)
    .background {
      Color.clear.contentShape(Rectangle()).blitzWindowDrag()
    }
  }
}

enum BlitzStatusTone: Equatable {
  case good, working, warning, critical, muted

  var color: Color {
    switch self {
    case .good: BlitzUI.mint
    case .working: BlitzUI.supportingText
    case .warning: BlitzUI.warning
    case .critical: BlitzUI.recordRed
    case .muted: BlitzUI.tertiaryText
    }
  }
}

struct BlitzStatusDot: View {
  let tone: BlitzStatusTone
  var diameter: CGFloat = 6

  var body: some View {
    Circle().fill(tone.color).frame(width: diameter, height: diameter)
      .accessibilityHidden(true)
  }
}

struct BlitzStatusBadge: View {
  let title: String
  let tone: BlitzStatusTone

  var body: some View {
    HStack(spacing: 6) {
      BlitzStatusDot(tone: tone, diameter: 5)
      Text(title).font(BlitzType.captionEmphasis).lineLimit(1)
    }
    .foregroundStyle(tone == .muted || tone == .working ? BlitzUI.secondaryText : tone.color)
    .padding(.horizontal, 9)
    .frame(height: 24)
    .background(
      (tone == .muted || tone == .working ? Color.white : tone.color).opacity(0.08), in: .capsule)
  }
}

struct BlitzActionMenu<Content: View>: View {
  let label: String
  var title: String? = nil
  var symbol = "ellipsis"
  @ViewBuilder let content: () -> Content
  @State private var expanded = false
  @State private var menuHeight: CGFloat = 160
  @State private var hovered = false
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button {
      expanded.toggle()
    } label: {
      HStack(spacing: 8) {
        if let title { Text(title).font(BlitzType.label) }
        Image(systemName: title == nil ? symbol : expanded ? "chevron.up" : "chevron.down")
          .font(.system(size: 12, weight: .semibold))
      }
      .foregroundStyle(hovered || expanded ? BlitzUI.primaryText : BlitzUI.secondaryText)
      .padding(.horizontal, 10).frame(minWidth: 34, minHeight: 34).contentShape(Rectangle())
      .background(
        expanded ? BlitzUI.selectedFill : hovered ? BlitzUI.quietFill : .clear,
        in: RoundedRectangle(cornerRadius: BlitzUI.controlRadius))
    }.buttonStyle(.plain).accessibilityLabel(label).help(label)
      .opacity(isEnabled ? 1 : 0.4)
      .onHover { hovered = $0 }
      .blitzPointingHand()
      .anchorPreference(key: BlitzDropdownPreference.self, value: .bounds) { anchor in
        expanded
          ? BlitzDropdownPresentation(
            anchor: anchor, width: 264, alignsLeading: title != nil, height: menuHeight,
            content: AnyView(
              VStack(alignment: .leading, spacing: 2) {
                content().buttonStyle(BlitzMenuActionStyle()).toggleStyle(BlitzMenuToggleStyle())
              }.padding(6)
                .environment(\.blitzDismissMenu, { expanded = false })
                .disabled(!isEnabled)
                .background {
                  GeometryReader { proxy in
                    Color.clear.onAppear { menuHeight = proxy.size.height }
                      .onChange(of: proxy.size.height) { _, height in menuHeight = height }
                  }
                }
            ), dismiss: { expanded = false }) : nil
      }
      .onExitCommand { expanded = false }
      .onChange(of: isEnabled) { _, enabled in if !enabled { expanded = false } }
      .onDisappear { expanded = false }
  }
}

private struct BlitzMenuToggleStyle: ToggleStyle {
  @Environment(\.blitzDismissMenu) private var dismiss

  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
      dismiss()
    } label: {
      HStack {
        configuration.label
        Spacer()
        Image(systemName: "checkmark").opacity(configuration.isOn ? 1 : 0)
      }
    }.buttonStyle(BlitzMenuItemStyle()).accessibilityValue(configuration.isOn ? "On" : "Off")
  }
}

private struct BlitzMenuDismissKey: EnvironmentKey {
  static let defaultValue: @MainActor @Sendable () -> Void = {}
}

extension EnvironmentValues {
  fileprivate var blitzDismissMenu: @MainActor @Sendable () -> Void {
    get { self[BlitzMenuDismissKey.self] }
    set { self[BlitzMenuDismissKey.self] = newValue }
  }
}

private struct BlitzMenuActionStyle: PrimitiveButtonStyle {
  @Environment(\.blitzDismissMenu) private var dismiss

  func makeBody(configuration: Configuration) -> some View {
    Button(role: configuration.role) {
      configuration.trigger()
      dismiss()
    } label: {
      configuration.label
    }.buttonStyle(BlitzMenuItemStyle())
  }
}

private struct BlitzMenuItemStyle: ButtonStyle {
  @State private var hovered = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(BlitzType.callout)
      .foregroundStyle(
        configuration.role == .destructive ? BlitzUI.recordRed : BlitzUI.primaryText
      )
      .lineLimit(2).multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
      .padding(.horizontal, 10)
      .background(
        configuration.isPressed
          ? BlitzUI.selectedFill : hovered && isEnabled ? BlitzUI.hoverFill : .clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .contentShape(Rectangle()).opacity(isEnabled ? 1 : 0.4)
      .onHover { hovered = $0 }
      .blitzPointingHand()
  }
}

private struct BlitzRowModifier: ViewModifier {
  @State private var hovered = false

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 16).padding(.vertical, 10)
      .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
      .background(hovered ? BlitzUI.quietFill : .clear)
      .contentShape(Rectangle())
      .onHover { hovered = $0 }
  }
}

struct BlitzRowDivider: View {
  var leading: CGFloat = 56

  var body: some View {
    Rectangle().fill(BlitzUI.separator).frame(height: 1).padding(.leading, leading)
  }
}

private struct BlitzWindowDragModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.gesture(WindowDragGesture()).allowsWindowActivationEvents(true)
    } else {
      content
    }
  }
}

extension View {
  func blitzRow() -> some View { modifier(BlitzRowModifier()) }

  func blitzWindowDrag() -> some View { modifier(BlitzWindowDragModifier()) }

  func blitzTable() -> some View {
    background(BlitzUI.cardFill)
      .clipShape(RoundedRectangle(cornerRadius: BlitzUI.cardRadius))
      .overlay {
        RoundedRectangle(cornerRadius: BlitzUI.cardRadius)
          .strokeBorder(BlitzUI.separator, lineWidth: 1).allowsHitTesting(false)
      }
  }
}

struct BlitzSwitchStyle: ToggleStyle {
  var showsLabel = true

  func makeBody(configuration: Configuration) -> some View {
    BlitzToggleBody(configuration: configuration, kind: .switch, showsLabel: showsLabel)
  }
}

struct BlitzCheckboxStyle: ToggleStyle {
  var showsLabel = true

  func makeBody(configuration: Configuration) -> some View {
    BlitzToggleBody(configuration: configuration, kind: .checkbox, showsLabel: showsLabel)
  }
}

private struct BlitzToggleBody: View {
  enum Kind { case `switch`, checkbox }

  let configuration: ToggleStyleConfiguration
  let kind: Kind
  let showsLabel: Bool
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovered = false

  var body: some View {
    Button {
      withAnimation(.easeOut(duration: 0.14)) { configuration.isOn.toggle() }
    } label: {
      HStack(spacing: 10) {
        if kind == .checkbox { indicator }
        if showsLabel {
          configuration.label.frame(
            maxWidth: kind == .switch ? .infinity : nil, alignment: .leading)
        }
        if kind == .switch { indicator }
      }.frame(minWidth: 34, minHeight: 34).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.4)
    .onHover { hovered = $0 }
    .blitzPointingHand()
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }
    }
  }

  @ViewBuilder private var indicator: some View {
    let on = configuration.isOn
    switch kind {
    case .switch:
      Capsule().fill(on ? BlitzUI.mint : hovered ? BlitzUI.strongFill : BlitzUI.selectedFill)
        .overlay(alignment: on ? .trailing : .leading) {
          Circle().fill(on ? Color.black.opacity(0.85) : BlitzUI.primaryText)
            .frame(width: 16, height: 16).padding(3)
        }
        .frame(width: 38, height: 22)
    case .checkbox:
      RoundedRectangle(cornerRadius: 5)
        .fill(on ? BlitzUI.mint : hovered ? BlitzUI.hoverFill : BlitzUI.controlFill)
        .overlay {
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(on ? .clear : BlitzUI.strongStroke, lineWidth: 1)
        }
        .overlay {
          Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
            .foregroundStyle(.black.opacity(0.85)).opacity(on ? 1 : 0)
        }
        .frame(width: 18, height: 18)
    }
  }
}
