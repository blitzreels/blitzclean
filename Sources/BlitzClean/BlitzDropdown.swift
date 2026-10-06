import SwiftUI

struct BlitzDropdownPresentation {
  let anchor: Anchor<CGRect>
  let width: CGFloat
  let alignsLeading: Bool
  let height: CGFloat
  let content: AnyView
  let dismiss: () -> Void
}

struct BlitzDropdownPreference: PreferenceKey {
  static var defaultValue: BlitzDropdownPresentation? { nil }
  static func reduce(
    value: inout BlitzDropdownPresentation?, nextValue: () -> BlitzDropdownPresentation?
  ) {
    value = nextValue() ?? value
  }
}

extension View {
  func blitzDropdownHost() -> some View {
    overlayPreferenceValue(BlitzDropdownPreference.self) { presentation in
      GeometryReader { geometry in
        if let presentation {
          let anchor = geometry[presentation.anchor]
          let width = min(max(presentation.width, anchor.width), geometry.size.width - 24)
          let height = min(presentation.height, geometry.size.height - 24)
          let preferredX = presentation.alignsLeading ? anchor.minX : anchor.maxX - width
          let x = min(max(12, preferredX), geometry.size.width - width - 12)
          let y =
            anchor.maxY + height + 4 <= geometry.size.height - 12
            ? anchor.maxY + 4 : max(12, anchor.minY - height - 4)
          ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { presentation.dismiss() }
            presentation.content.frame(width: width)
              .background(BlitzUI.menuFill)
              .clipShape(RoundedRectangle(cornerRadius: BlitzUI.cardRadius))
              .overlay {
                RoundedRectangle(cornerRadius: BlitzUI.cardRadius)
                  .strokeBorder(BlitzUI.panelStroke)
              }
              .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
              .offset(x: x, y: y)
          }.onExitCommand { presentation.dismiss() }
        }
      }.allowsHitTesting(presentation != nil)
    }
  }
}

struct BlitzConfirmation: View {
  let title: String
  let message: String
  let confirmTitle: String
  let onConfirm: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.system(size: 14, weight: .semibold))
      if message.count > 320 || message.split(separator: "\n").count > 4 {
        ScrollView { detail }.frame(height: 100)
      } else {
        detail.fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        Button(confirmTitle, role: .destructive, action: onConfirm)
      }
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      .background(BlitzUI.panelBackground)
      .overlay(alignment: .top) { Rectangle().fill(BlitzUI.separator).frame(height: 1) }
  }

  private var detail: some View {
    Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
  }
}
