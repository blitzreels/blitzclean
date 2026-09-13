import SwiftUI

struct BlitzStorageView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var cleanup: QuickCleanModel
  @ObservedObject var storage: StorageBreakdownModel
  @ObservedObject var navigation: CleanNavigation
  @ObservedObject var developerBrowser: DeveloperBrowserModel
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var workspaces: WorkspaceController

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        BlitzSegmentedPicker(
          title: "Storage tools", options: CleanStoragePage.allCases,
          selection: $navigation.storagePage, label: { $0.rawValue }
        ).frame(width: 340)
        Spacer()
        Text("\(ByteText.full(monitor.snapshot.diskAvailable)) free")
          .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
      }.padding(.horizontal, 24).padding(.vertical, 16)
      Divider()
      Group {
        switch navigation.storagePage {
        case .caches: QuickCleanView(model: cleanup, history: storage.overview)
        case .files: LargeFileReviewView(model: storage.overview, monitor: monitor)
        case .dependencies:
          DeveloperBrowserView(
            kind: .dependencies, model: developerBrowser, processes: processes,
            workspaces: workspaces, history: storage.overview)
        }
      }
    }
  }
}
