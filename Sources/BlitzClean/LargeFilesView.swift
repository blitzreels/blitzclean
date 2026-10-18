import SwiftUI

/// Large videos, images, archives and folders in the user's own folders, each one click from the Trash.
struct LargeFilesView: View {
  @ObservedObject var model: LargeFilesModel
  @ObservedObject var history: CleanupOverviewModel
  let onSearchDrives: () -> Void
  @State private var showsAll = false
  private static let limit = 8

  var body: some View {
    let items = model.visibleItems
    BlitzStorageSection(
      title: "Large personal files", symbol: "film.stack", detail: detail,
      trailing: model.items.isEmpty ? nil : ByteText.full(model.totalBytes), showsContent: true
    ) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          BlitzSegmentedPicker(
            title: "File type",
            options: LargeFileKind.allCases.filter { $0 == .all || model.count($0) > 0 },
            selection: $model.filter, label: { "\($0.rawValue) \(model.count($0))" }
          ).frame(maxWidth: 520)
          Spacer(minLength: 8)
          if model.isScanning { ProgressView().controlSize(.small) }
          Button("Search every drive", action: onSearchDrives).blitzButton(.quiet)
            .controlSize(.small).fixedSize()
            .help("Rank the largest files across all drives in Storage → Browse")
        }
        if let message = model.message {
          HStack(spacing: 8) {
            BlitzStatusLine(text: message, tone: .working)
            if model.canUndo {
              Button("Undo") { model.undo() }.blitzButton(.secondary).controlSize(.small)
            }
          }
        }
        Text(
          "Files over 50 MB and folders over 300 MB in Downloads, Desktop, Documents, Movies, Pictures and Music. Git projects and apps are left out."
        ).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
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
    }
    .task { model.scanIfNeeded() }
  }

  private var detail: String {
    if model.scannedAt == nil { return "Measuring your folders…" }
    let partial = model.limited ? " · some folders not fully read" : ""
    if model.items.isEmpty { return "Nothing large in your folders\(partial)" }
    return "\(model.items.count) videos, images, archives and folders\(partial)"
  }

  private func row(_ item: LargeFileItem) -> some View {
    HStack(spacing: 12) {
      ApplicationIcon(
        source: .file(item.path), size: 28, fallback: item.kind == .folders ? "folder" : "doc")
      VStack(alignment: .leading, spacing: 2) {
        Text(item.name).font(BlitzType.rowTitle).lineLimit(1).truncationMode(.middle)
        Text(caption(item)).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 12)
      BlitzTrailingValue(value: ByteText.full(item.bytes), detail: nil)
      Group {
        if model.moving.contains(item.path) {
          ProgressView().controlSize(.small)
        } else {
          Button("Move to Trash") { model.trash(item, history: history) }
            .blitzButton(.secondary).controlSize(.small)
            .help("Checks the item is unchanged and not open, then moves it to the Trash")
        }
      }.frame(width: 112, alignment: .trailing)
      BlitzActionMenu(label: "More actions for \(item.name)") {
        Button("Show in Finder") { Finder.reveal(item.path) }
        Button("Copy path") { Pasteboard.copy(item.path) }
      }
    }.blitzRow()
  }

  private func caption(_ item: LargeFileItem) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let parent = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
    let location = parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    let kind =
      item.kind == .folders
      ? "Folder"
      : item.kind == .other
        ? "File"
        : String(
          item.kind.rawValue.dropLast())
    let date =
      item.modifiedAt == .distantPast
      ? "" : " · changed \(item.modifiedAt.formatted(.dateTime.month(.abbreviated).day().year()))"
    return "\(kind) · \(location)\(date)"
  }
}
