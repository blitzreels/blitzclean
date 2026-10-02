import SwiftUI

struct BlitzStorageView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var cleanup: QuickCleanModel
  @ObservedObject var storage: StorageBreakdownModel
  @ObservedObject var navigation: CleanNavigation
  @ObservedObject var docker: DockerStorageModel
  @ObservedObject var folders: FolderExplorerModel
  let worktrees: WorktreeSources
  @State private var showsLargestFiles = false
  @State private var drives: [StorageDrive] = []

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        BlitzSegmentedPicker(
          title: "Storage", options: CleanStoragePage.allCases,
          selection: $navigation.storagePage, label: { $0.rawValue }
        ).frame(maxWidth: 340)
        Spacer()
        Text("\(ByteText.compact(monitor.snapshot.diskAvailable)) free")
          .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
      }.padding(.horizontal, 24).padding(.vertical, 16)
      Divider()
      switch navigation.storagePage {
      case .mac:
        MacStorageInventoryView(
          model: storage,
          onBrowse: { path in
            folders.open(path)
            showsLargestFiles = false
            navigation.storagePage = .browse
          })
      case .browse:
        HStack {
          if showsLargestFiles {
            Button("Back to folders", systemImage: "chevron.left") { showsLargestFiles = false }
              .blitzButton(.quiet)
          } else {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 4) {
                ForEach(drives) { drive in
                  Button {
                    folders.open(drive.path)
                  } label: {
                    Label(
                      drive.name,
                      systemImage: drive.internalDisk ? "internaldrive" : "externaldrive")
                  }.blitzButton(folders.path == drive.path ? .secondary : .quiet)
                    .accessibilityLabel("Browse \(drive.name)")
                }
                Button("Home", systemImage: "house") { folders.open(folders.homePath) }
                  .blitzButton(folders.path == folders.homePath ? .secondary : .quiet)
                  .accessibilityLabel("Browse home folder")
              }
            }
          }
          Spacer()
          if !showsLargestFiles {
            Button("Largest files", systemImage: "arrow.down.to.line") {
              folders.cancelScan()
              let roots = StorageDrives.roots
              if Set(storage.overview.reviewRoots) != Set(roots) {
                storage.overview.cancelScan()
                storage.overview.configureReview(
                  .init(
                    roots: roots, minimumBytes: 100 * 1_024 * 1_024,
                    maxEntries: 80_000, entireHierarchy: true))
              }
              showsLargestFiles = true
            }.blitzButton(.secondary).fixedSize()
              .help("Find the largest files across every connected drive")
          }
        }.padding(.horizontal, 24).padding(.top, 12)
        if showsLargestFiles {
          LargeFileReviewView(model: storage.overview, monitor: monitor)
        } else {
          FolderExplorerView(model: folders)
        }
      case .cleanup:
        StorageCleanupView(
          storage: storage, caches: cleanup, docker: docker, worktrees: worktrees)
      }
    }
    .task { drives = StorageDrives.mounted() }
  }
}

struct WorktreeSources {
  let model: DeveloperBrowserModel
  let processes: DevProcessModel
  let workspaces: WorkspaceController
}

struct StorageCleanupView: View {
  @ObservedObject var storage: StorageBreakdownModel
  @ObservedObject var caches: QuickCleanModel
  @ObservedObject var docker: DockerStorageModel
  let worktrees: WorktreeSources
  @State private var repeatPending: [RemovedEntry] = []
  @State private var worktreePending: DeveloperArtifact?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        RemovedBeforeView(model: storage.repeats, pending: $repeatPending)
        HStack {
          if storage.isScanning {
            ProgressView().controlSize(.small)
            Text("Checking project activity and build data…")
          } else if let date = storage.scannedAt {
            Text("Scanned \(date.formatted(date: .abbreviated, time: .shortened))")
          }
          Spacer()
          Button("Scan again") { storage.scan() }
            .disabled(storage.isScanning || storage.isCleaning)
        }.font(.system(size: 12)).foregroundStyle(.secondary)
        BlitzStorageSection(
          title: "Caches", symbol: "archivebox",
          detail: caches.scannedAt == nil
            ? "Unused app and package caches"
            : "\(ByteText.full(caches.totalBytes)) · \(caches.candidates.count) unused caches"
        ) {
          QuickCleanView(model: caches, history: storage.overview)
        }
        DeveloperCleanupView(model: storage)
        BlitzStorageSection(
          title: "Docker", symbol: "shippingbox",
          detail: docker.snapshot.map { "\(ByteText.full($0.rebuildableBytes)) reclaimable" }
            ?? "Unused images and build cache"
        ) {
          DockerStorageView(model: docker)
        }
        WorktreeCleanupView(
          model: worktrees.model, processes: worktrees.processes,
          workspaces: worktrees.workspaces, pending: $worktreePending)
        RemovalLogView(history: storage.overview)
      }.padding(BlitzUI.pagePadding)
    }
    .task { storage.scanIfNeeded() }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let artifact = worktreePending {
        BlitzConfirmation(
          title: "Remove this worktree?",
          message: artifact.path
            + "\n\nGit checks again that it is merged, then removes the folder. The local branch stays.",
          confirmTitle: "Remove worktree",
          onConfirm: {
            worktrees.model.remove(.init(artifact: artifact, history: storage.overview))
            worktreePending = nil
          }, onCancel: { worktreePending = nil })
      } else if repeatPending.isEmpty {
        DeveloperCleanupActions(model: storage)
      } else {
        let review = repeatPending.confirmation(storage.repeats)
        BlitzConfirmation(
          title: review.title, message: review.message,
          confirmTitle: repeatPending.count == 1 ? "Remove again" : "Remove \(repeatPending.count)",
          onConfirm: {
            storage.repeats.remove(repeatPending)
            repeatPending = []
          }, onCancel: { repeatPending = [] })
      }
    }
  }
}

struct BlitzStorageSection<Content: View>: View {
  let title: String
  let symbol: String
  let detail: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: symbol).frame(width: 24).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.system(size: 14, weight: .medium))
          Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
        }
        Spacer()
      }.padding(16).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
      Divider()
      content
    }.blitzTable()
  }
}
