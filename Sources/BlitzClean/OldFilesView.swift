import AppKit
import SwiftUI

/// Old downloads and screenshots: one action moves them all to the Trash, with Undo.
struct OldFilesView: View {
  @ObservedObject var model: OldFilesModel
  @ObservedObject var history: CleanupOverviewModel
  @State private var showsAll = false
  private static let limit = 8

  var body: some View {
    let items = model.visibleItems
    BlitzStorageSection(
      title: "Old downloads and screenshots", symbol: "clock.arrow.circlepath",
      detail: detail(items), trailing: items.isEmpty ? nil : ByteText.full(model.totalBytes),
      showsContent: true
    ) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          Text("Not opened or changed in").font(BlitzType.body)
            .foregroundStyle(BlitzUI.secondaryText)
          BlitzSegmentedPicker(
            title: "Age", options: OldFileAge.allCases, selection: $model.age,
            label: { $0.title }
          ).frame(width: 260).disabled(model.isTrashing)
          Spacer(minLength: 8)
          if model.isScanning || model.isTrashing { ProgressView().controlSize(.small) }
          Button(actionTitle(items)) { model.trashAll(history: history) }
            .blitzButton(.accent)
            .disabled(items.isEmpty || model.isScanning || model.isTrashing)
            .help("Recheck each item, then move it to the Trash. You can undo right after.")
        }
        status
        Text(
          "Folders count only when nothing inside changed. Apps and items in use are skipped. Space is freed when you empty the Trash."
        ).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      }.padding(16)
      if !items.isEmpty {
        BlitzRowDivider(leading: 0)
        let visible = showsAll ? items : Array(items.prefix(Self.limit))
        LazyVStack(spacing: 0) {
          ForEach(visible) { item in
            row(item)
            if item.id != visible.last?.id { BlitzRowDivider(leading: 56) }
          }
        }
        if items.count > Self.limit {
          BlitzShowAllButton(total: items.count, noun: "items", isExpanded: $showsAll)
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
      }
      if model.keptCount > 0 {
        BlitzRowDivider(leading: 0)
        HStack {
          Text("\(model.keptCount) kept \(model.keptCount == 1 ? "item is" : "items are") hidden")
          Spacer()
          Button("Show again") { model.showKeptAgain() }.blitzButton(.quiet).controlSize(.small)
        }.font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .padding(.horizontal, 16).padding(.vertical, 8)
      }
    }
    .task { model.scanIfNeeded() }
  }

  @ViewBuilder private var status: some View {
    if model.isTrashing {
      Text("Moving \(model.completed) of \(model.total) to the Trash…")
        .font(BlitzType.caption).monospacedDigit().foregroundStyle(BlitzUI.secondaryText)
    } else if let result = model.result {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          BlitzStatusLine(text: summary(result), tone: result.movedCount > 0 ? .working : .warning)
          if model.canUndo {
            Button("Undo") { model.undo() }.blitzButton(.secondary).controlSize(.small)
          }
          if result.movedCount > 0 {
            Button("Open Trash") { openTrash() }.blitzButton(.quiet).controlSize(.small)
          }
        }
        ForEach(result.failures.prefix(3), id: \.self) { failure in
          Text(failure).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
            .lineLimit(1).truncationMode(.middle)
        }
      }
    } else if let message = model.restoreMessage {
      BlitzStatusLine(text: message, tone: .working)
    }
  }

  private func detail(_ items: [OldFileItem]) -> String {
    if model.scannedAt == nil { return "Checking Downloads and screenshots…" }
    let unmeasured =
      model.unmeasured > 0 ? " · \(model.unmeasured) large folders not checked" : ""
    if items.isEmpty { return "Nothing older than \(model.age.title)\(unmeasured)" }
    return
      "\(items.count.formatted()) \(items.count == 1 ? "item" : "items") unused for \(model.age.title)\(unmeasured)"
  }

  private func actionTitle(_ items: [OldFileItem]) -> String {
    items.isEmpty ? "Move to Trash" : "Move \(items.count.formatted()) to Trash"
  }

  private func summary(_ result: OldFilesResult) -> String {
    let skipped = result.failures.isEmpty ? "" : " Skipped \(result.failures.count)."
    guard result.movedCount > 0 else { return "Nothing was moved.\(skipped)" }
    return
      "Moved \(result.movedCount) \(result.movedCount == 1 ? "item" : "items") · \(ByteText.full(result.movedBytes)) to the Trash.\(skipped)"
  }

  private func row(_ item: OldFileItem) -> some View {
    HStack(spacing: 12) {
      ApplicationIcon(
        source: .file(item.path), size: 28, fallback: item.isFolder ? "folder" : "doc")
      VStack(alignment: .leading, spacing: 2) {
        Text(item.name).font(BlitzType.rowTitle).lineLimit(1).truncationMode(.middle)
        Text(
          "\(item.source.rawValue) · last used \(item.lastUsedAt.formatted(.dateTime.month(.abbreviated).day().year()))"
        ).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText).lineLimit(1)
      }
      Spacer(minLength: 12)
      BlitzTrailingValue(value: ByteText.full(item.bytes), detail: nil)
      Button("Keep") { model.keep(item) }.blitzButton(.quiet).controlSize(.small)
        .disabled(model.isTrashing)
        .help("Leave this item out of the cleanup")
      BlitzActionMenu(label: "More actions for \(item.name)") {
        Button("Show in Finder") { Finder.reveal(item.path) }
        Button("Copy path") { Pasteboard.copy(item.path) }
      }
    }.blitzRow()
  }

  private func openTrash() {
    NSWorkspace.shared.open(
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
  }
}
