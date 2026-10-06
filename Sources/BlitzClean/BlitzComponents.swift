import AppKit
import SwiftUI

/// Section title with an optional item count and up to two trailing actions.
struct BlitzSectionHeader<Trailing: View>: View {
  let title: String
  let count: Int?
  @ViewBuilder let trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 6) {
      Text(title).font(BlitzType.section)
      if let count {
        Text("\(count)").font(BlitzType.caption).monospacedDigit()
          .foregroundStyle(BlitzUI.tertiaryText)
      }
      Spacer(minLength: 8)
      trailing()
    }.accessibilityElement(children: .contain).accessibilityAddTraits(.isHeader)
  }
}

/// One-line empty or loading state.
struct BlitzEmptyRow: View {
  let text: String
  let isLoading: Bool

  var body: some View {
    HStack(spacing: 8) {
      if isLoading { ProgressView().controlSize(.small) }
      Text(text).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
    }.frame(maxWidth: .infinity, minHeight: 56)
  }
}

/// Expands a capped list.
struct BlitzShowAllButton: View {
  let total: Int
  let noun: String
  @Binding var isExpanded: Bool

  var body: some View {
    Button(isExpanded ? "Show fewer" : "Show all \(total.formatted()) \(noun)") {
      isExpanded.toggle()
    }.blitzButton(.quiet).controlSize(.small)
  }
}

/// Result or error text shown beside the action that produced it.
struct BlitzStatusLine: View {
  let text: String
  let tone: BlitzStatusTone

  var body: some View {
    Text(text).font(BlitzType.body)
      .foregroundStyle(tone == .warning || tone == .critical ? tone.color : BlitzUI.supportingText)
      .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Monospaced trailing value column, with an optional second line such as a date.
struct BlitzTrailingValue: View {
  let value: String
  let detail: String?

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(value).font(BlitzType.numeric).foregroundStyle(BlitzUI.supportingText)
      if let detail {
        Text(detail).font(BlitzType.caption).foregroundStyle(BlitzUI.tertiaryText)
      }
    }.monospacedDigit().lineLimit(1)
  }
}

enum Pasteboard {
  @MainActor static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

enum Finder {
  @MainActor static func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  @MainActor static func chooseFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url?.path : nil
  }
}

/// App icon, name, one detail line and an optional warning, shared by Memory and Revive rows.
struct AppRowIdentity: View {
  let app: MemoryApp
  let detail: String?
  let warning: String?

  var body: some View {
    HStack(spacing: 12) {
      AppMemoryIcon(app: app)
      VStack(alignment: .leading, spacing: 2) {
        Text(app.name).font(BlitzType.rowTitle).lineLimit(1)
        if let detail {
          Text(detail).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
            .lineLimit(1).help(detail)
        }
        if let warning {
          Text(warning).font(BlitzType.caption).foregroundStyle(BlitzUI.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// Search pinned above a scrolling page.
struct PageSearchBar: View {
  let title: String
  @Binding var text: String

  var body: some View {
    BlitzSearchField(title: title, text: $text)
      .padding(.horizontal, BlitzUI.pagePadding).padding(.vertical, 12)
      .background(BlitzUI.canvasBackground)
  }
}

/// Menu row with a trailing checkmark for an on/off choice; menus use buttons, not toggles.
struct MenuCheckLabel: View {
  let title: String
  let isOn: Bool

  var body: some View {
    HStack {
      Text(title)
      Spacer()
      Image(systemName: "checkmark").opacity(isOn ? 1 : 0)
    }.accessibilityValue(isOn ? "On" : "Off")
  }
}

/// Count of items that need the user, on navigation items and buttons.
struct BlitzCountBadge: View {
  let count: Int
  let label: String

  var body: some View {
    Text("\(count)").font(BlitzType.captionEmphasis).monospacedDigit()
      .foregroundStyle(.black.opacity(0.88))
      .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
      .background(BlitzUI.warning, in: .capsule)
      .accessibilityLabel(label)
  }
}

/// Bottom bar for a selection or reclaimable total and its one cleanup action.
struct StorageActionBar: View {
  let summary: String
  /// Shown with a spinner while the action runs.
  let progress: String?
  /// Result of the last action.
  let message: String?
  let actionTitle: String
  /// Accent only for the page's main bulk action; inline section bars stay secondary.
  let emphasis: BlitzButtonEmphasis
  let isDisabled: Bool
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let progress {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(progress).font(BlitzType.caption).monospacedDigit()
            .foregroundStyle(BlitzUI.secondaryText)
        }
      } else if let message {
        BlitzStatusLine(text: message, tone: .working)
      }
      HStack {
        Text(summary).font(BlitzType.label).monospacedDigit()
        Spacer()
        Button(actionTitle, action: action).blitzButton(emphasis).disabled(isDisabled)
      }
    }
    .padding(.vertical, 12)
    .overlay(alignment: .top) { BlitzRowDivider(leading: 0) }
  }
}
