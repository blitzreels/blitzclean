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

/// A removal review split into what goes (one line per item, with its size) and the note about what stays.
/// Callers write "name · size" lines, a blank line, then the note; a single block is all note.
struct ConfirmationContent: Equatable {
  struct Item: Equatable {
    let name: String
    let value: String?
  }

  let items: [Item]
  let note: String

  static func parse(_ message: String) -> Self {
    let blocks = message.components(separatedBy: "\n\n")
    let lines = blocks[0].split(separator: "\n").map(String.init)
    guard lines.count > 1
    else { return .init(items: [], note: message) }
    let items = lines.map { line -> Item in
      guard let range = line.range(of: " · ", options: .backwards) else {
        return .init(name: line, value: nil)
      }
      return .init(
        name: String(line[..<range.lowerBound]), value: String(line[range.upperBound...]))
    }
    return .init(items: items, note: blocks.dropFirst().joined(separator: "\n\n"))
  }
}

/// The review shown before a permanent or bulk action: a floating card above the page with what goes, what
/// stays, Cancel and a red confirm button. Escape cancels.
struct BlitzConfirmation: View {
  let title: String
  let message: String
  let confirmTitle: String
  let onConfirm: () -> Void
  let onCancel: () -> Void

  var body: some View {
    let content = ConfirmationContent.parse(message)
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 12) {
        BlitzIconTile(
          symbol: BlitzActionLabel.symbol(confirmTitle) ?? "exclamationmark", tone: .critical,
          size: 32)
        Text(title).font(.system(size: 15, weight: .semibold))
        Spacer(minLength: 0)
      }
      if !content.items.isEmpty { itemList(content.items) }
      if !content.note.isEmpty {
        Text(content.note).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      HStack(spacing: 8) {
        Spacer()
        Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
          .blitzButton(.secondary).controlSize(.large)
        Button(role: .destructive, action: onConfirm) { BlitzActionLabel(title: confirmTitle) }
          .blitzButton(.destructive).controlSize(.large)
      }
    }
    .padding(20)
    .frame(maxWidth: 560, alignment: .leading)
    .background(BlitzUI.menuFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1).allowsHitTesting(false)
    }
    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
    .padding(16)
    .frame(maxWidth: .infinity)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  private func itemList(_ items: [ConfirmationContent.Item]) -> some View {
    let rows = VStack(spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        HStack(spacing: 12) {
          Text(item.name).font(BlitzType.callout).foregroundStyle(BlitzUI.supportingText)
            .lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 8)
          if let value = item.value {
            Text(value).font(BlitzType.numeric).foregroundStyle(BlitzUI.secondaryText)
          }
        }.padding(.horizontal, 12).frame(height: 30)
        if index < items.count - 1 { BlitzRowDivider(leading: 12) }
      }
    }
    return Group {
      if items.count > 6 {
        ScrollView { rows }.frame(height: 6 * 30)
      } else {
        rows
      }
    }
    .background(
      Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(BlitzUI.separator, lineWidth: 1).allowsHitTesting(false)
    }
  }
}
