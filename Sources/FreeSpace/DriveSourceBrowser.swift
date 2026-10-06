import AppKit
import SwiftUI

struct DriveSourceBrowser: View {
  @ObservedObject var model: CleanupOverviewModel
  let blocked: Bool
  let onBrowseFolders: () -> Void
  @State private var drives: [StorageDrive] = []

  private var roots: Set<String> { Set(model.reviewRoots) }
  private var allDrives: Bool { roots == Set(drives.flatMap(\.scanRoots)) }
  private var customFolder: String? {
    guard model.reviewRoots.count == 1, !allDrives,
      !drives.contains(where: { Set($0.scanRoots) == roots })
    else { return nil }
    return model.reviewRoots.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 2) {
            BlitzChip(
              title: "All drives", symbol: "square.stack.3d.up", isSelected: allDrives,
              action: { open(drives.flatMap(\.scanRoots)) })
            ForEach(drives) { drive in
              BlitzChip(
                title: drive.name,
                symbol: drive.internalDisk ? "internaldrive" : "externaldrive",
                isSelected: roots == Set(drive.scanRoots), action: { open(drive.scanRoots) })
            }
            BlitzChip(
              title: customFolder.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "Folder…",
              symbol: "folder", isSelected: customFolder != nil, action: chooseFolder)
          }.blitzChipGroup()
        }.fixedSize(horizontal: false, vertical: true).disabled(blocked)
        Spacer(minLength: 8)
        Button(model.isScanning ? "Stop scan" : "Scan again") {
          if model.isScanning { model.cancelScan() } else { model.refresh() }
        }.blitzButton(.quiet).disabled(blocked).fixedSize()
        Button("Browse folders", systemImage: "folder", action: onBrowseFolders)
          .blitzButton(.secondary).fixedSize()
      }
      if let customFolder {
        Text(customFolder).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
      }
    }
    .task { drives = StorageDrives.mounted() }
  }

  private func open(_ roots: [String]) {
    guard !roots.isEmpty, Set(roots) != Set(model.reviewRoots) else { return }
    model.cancelScan()
    model.configureReview(
      .init(
        roots: roots, minimumBytes: model.reviewMinimumBytes,
        maxEntries: 80_000, entireHierarchy: true))
  }

  private func chooseFolder() {
    guard let path = Finder.chooseFolder() else { return }
    open([path])
  }

}
