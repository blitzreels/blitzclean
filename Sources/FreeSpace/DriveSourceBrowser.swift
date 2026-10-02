import AppKit
import SwiftUI

struct DriveSourceBrowser: View {
  @ObservedObject var model: CleanupOverviewModel
  let blocked: Bool
  @State private var drives: [StorageDrive] = []
  @State private var entries: [FolderEntry] = []
  @State private var listingError: String?
  @State private var listing = false
  @State private var visibleCount = 12

  private var folder: String? { model.reviewRoots.count == 1 ? model.reviewRoots.first : nil }
  private var scopeID: String { model.reviewRoots.joined(separator: "\n") }
  private var title: String {
    guard let folder else { return "All drives" }
    return drives.first { $0.path == folder }?.name
      ?? URL(fileURLWithPath: folder).lastPathComponent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(title)
          .font(BlitzType.section).lineLimit(1).truncationMode(.middle)
        Spacer()
        Button("Choose folder…", systemImage: "folder") { chooseFolder() }
          .blitzButton(.quiet).disabled(blocked)
        Button(model.isScanning ? "Stop scan" : "Scan again") {
          if model.isScanning {
            model.cancelScan()
          } else {
            drives = StorageDrives.mounted()
            model.refresh()
          }
        }.blitzButton(.secondary).disabled(blocked)
      }
      if folder == nil {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
          ForEach(drives) { drive in
            Button {
              open([drive.path])
            } label: {
              HStack(spacing: 10) {
                Image(systemName: drive.internalDisk ? "internaldrive" : "externaldrive")
                  .font(.system(size: 20)).foregroundStyle(BlitzUI.secondaryText)
                VStack(alignment: .leading, spacing: 3) {
                  Text(drive.name).font(BlitzType.rowTitle).lineLimit(1)
                  Text(
                    "\(ByteText.compact(drive.available)) free of \(ByteText.compact(drive.total))"
                  )
                  .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10))
              }.padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain).blitzTable().disabled(blocked)
          }
        }
      } else if let folder {
        HStack(spacing: 8) {
          Button("All drives", systemImage: "externaldrive") { open(drives.flatMap(\.scanRoots)) }
            .blitzButton(.quiet)
          if folder != "/" && !drives.contains(where: { $0.path == folder }) {
            Button("Up", systemImage: "arrow.up") {
              open([URL(fileURLWithPath: folder).deletingLastPathComponent().path])
            }.blitzButton(.quiet)
          }
          Text(folder).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }.disabled(blocked)
        if let listingError {
          Text(listingError).font(BlitzType.body).foregroundStyle(BlitzUI.warning)
        } else if listing {
          Text("Reading folder…").font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
        } else {
          LazyVStack(spacing: 0) {
            ForEach(entries.prefix(visibleCount)) { entry in
              Button {
                if entry.isDirectory {
                  open([entry.path])
                } else {
                  NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                }
              } label: {
                HStack(spacing: 10) {
                  Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .foregroundStyle(BlitzUI.secondaryText).frame(width: 20)
                  Text(entry.name).font(BlitzType.body).lineLimit(1).truncationMode(.middle)
                  Spacer(minLength: 8)
                  Text(entry.bytes.map(ByteText.compact) ?? "Folder")
                    .font(BlitzType.caption).monospacedDigit().foregroundStyle(
                      BlitzUI.secondaryText)
                  Image(systemName: entry.isDirectory ? "chevron.right" : "arrow.up.forward")
                    .font(.system(size: 10)).foregroundStyle(BlitzUI.tertiaryText)
                }.blitzRow().contentShape(Rectangle())
              }.buttonStyle(.plain).disabled(blocked)
              BlitzRowDivider(leading: 46)
            }
          }.blitzTable()
          if entries.count > visibleCount {
            Button("Show more · \(entries.count) items") { visibleCount += 100 }
              .blitzButton(.quiet)
          }
        }
      }
    }
    .task { drives = StorageDrives.mounted() }
    .task(id: scopeID) {
      visibleCount = 12
      entries = []
      listingError = nil
      guard let folder else { return }
      listing = true
      let result = await Task.detached(priority: .utility) {
        let readable = FileManager.default.isReadableFile(atPath: folder)
        return (FolderSizeScanner().listing(of: folder), readable)
      }.value
      guard !Task.isCancelled else { return }
      entries = result.0.sorted {
        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      listingError =
        result.1 ? nil : "Access denied. Grant access to this location in macOS Settings."
      listing = false
    }
  }

  private func open(_ roots: [String]) {
    model.cancelScan()
    model.mediaFilter = MediaReviewFilter()
    model.configureReview(
      .init(
        roots: roots, minimumBytes: model.reviewMinimumBytes,
        maxEntries: 80_000, entireHierarchy: true))
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    open([url.path])
  }
}
