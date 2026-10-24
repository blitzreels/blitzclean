import SwiftUI

struct BlitzStorageView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var cleanup: QuickCleanModel
  @ObservedObject var storage: StorageBreakdownModel
  @ObservedObject var navigation: CleanNavigation
  @ObservedObject var docker: DockerStorageModel
  @ObservedObject var folders: FolderExplorerModel
  let worktrees: WorktreeSources
  @AppStorage("storage.showsLargestFiles") private var showsLargestFiles = false
  @State private var drives: [StorageDrive] = []

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        BlitzSegmentedPicker(
          title: "Storage", options: CleanStoragePage.allCases,
          selection: $navigation.storagePage, label: { $0.rawValue }
        ).frame(maxWidth: 320)
        Spacer()
        if navigation.storagePage != .drive {
          StorageCapacityMeter(snapshot: monitor.snapshot, drive: selectedDrive).frame(width: 200)
        }
      }.padding(.horizontal, BlitzUI.pagePadding).padding(.vertical, 12)
      Rectangle().fill(BlitzUI.separator).frame(height: 1)
      switch navigation.storagePage {
      case .drive:
        DriveBreakdownView(
          model: storage.drive, worktrees: worktrees.model, history: storage.overview,
          onBrowse: { path in
            folders.open(path)
            showsLargestFiles = false
            navigation.storagePage = .browse
          }, onCleanup: openCleanup)
      case .browse:
        if !showsLargestFiles {
          HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 2) {
                ForEach(drives) { drive in
                  BlitzChip(
                    title: drive.name,
                    symbol: drive.internalDisk ? "internaldrive" : "externaldrive",
                    isSelected: folders.path == drive.path, action: { folders.open(drive.path) })
                }
                BlitzChip(
                  title: "Home", symbol: "house", isSelected: folders.path == folders.homePath,
                  action: { folders.open(folders.homePath) })
              }.blitzChipGroup()
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Largest files", systemImage: "list.number") {
              folders.cancelScan()
              showsLargestFiles = true
            }.blitzButton(.secondary).fixedSize()
              .help("Rank individual files by size across drives. Your choice is remembered.")
          }.padding(.horizontal, BlitzUI.pagePadding).padding(.top, 16)
        }
        if showsLargestFiles {
          LargeFileReviewView(
            model: storage.overview, monitor: monitor,
            onCleanup: openCleanup,
            onBrowseFolders: {
              storage.overview.cancelScan()
              showsLargestFiles = false
            })
        } else {
          FolderExplorerView(
            model: folders,
            onManageSimulators: { openCleanup(.init(focus: .simulators, path: nil)) },
            onCleanup: openCleanup)
        }
      case .cleanup:
        StorageCleanupView(
          storage: storage, caches: cleanup, docker: docker, worktrees: worktrees,
          onSearchDrives: {
            showsLargestFiles = true
            navigation.storagePage = .browse
          })
      }
    }
    .task { drives = StorageDrives.mounted() }
    .onChange(of: storage.scannedAt) { drives = StorageDrives.mounted() }
  }

  private var selectedDrive: StorageDrive? {
    let path =
      navigation.storagePage == .browse
      ? showsLargestFiles ? storage.overview.reviewRoots.first : folders.path
      : nil
    guard let path else { return nil }
    return drives.filter { !$0.internalDisk }.first {
      path == $0.path || path.hasPrefix($0.path + "/")
    }
  }

  private func openCleanup(_ route: StorageCleanupRoute) {
    if let root = route.projectRoot, root != storage.projectRoot {
      storage.selectProjectRoot(root)
    }
    storage.cleanupFocus = route.focus
    navigation.storagePage = .cleanup
  }
}

private struct StorageCapacityMeter: View {
  let snapshot: SystemSnapshot
  let drive: StorageDrive?

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(ByteText.compact(drive?.available ?? snapshot.diskAvailable)).font(BlitzType.label)
        Text("free of \(ByteText.compact(drive?.total ?? snapshot.diskTotal))").font(
          BlitzType.caption
        )
        .foregroundStyle(BlitzUI.secondaryText)
      }.monospacedDigit().lineLimit(1)
      CapacityBar(
        usedRatio: drive.map { $0.total == 0 ? 0 : 1 - Double($0.available) / Double($0.total) }
          ?? snapshot.diskUsedRatio,
        tone: BlitzStatusTone.forDisk(
          .init(
            available: drive?.available ?? snapshot.diskAvailable,
            total: drive?.total ?? snapshot.diskTotal)))
    }.accessibilityElement(children: .combine)
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
  let onSearchDrives: () -> Void
  @StateObject private var simulators = SimulatorDevicesModel()
  @State private var repeatPending: [RemovedEntry] = []
  @State private var worktreePending: DeveloperArtifact?

  private var cacheDetail: String {
    if caches.scannedAt == nil { return "Known caches and old diagnostic reports" }
    if caches.candidates.isEmpty { return "No eligible files in the checked locations" }
    return "\(caches.candidates.count) eligible items · review before removing"
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          CleanupScanBar(
            storage: storage, caches: caches, docker: docker, simulators: simulators,
            repeats: storage.repeats, oldFiles: storage.oldFiles, largeFiles: storage.largeFiles,
            worktrees: worktrees.model)
          OldFilesView(model: storage.oldFiles, history: storage.overview)
            .id(StorageCleanupFocus.oldFiles)
          LargeFilesView(
            model: storage.largeFiles, history: storage.overview, onSearchDrives: onSearchDrives
          ).id(StorageCleanupFocus.largeFiles)
          BlitzStorageSection(
            title: "System Data cleanup", symbol: "archivebox",
            detail: cacheDetail,
            trailing: caches.scannedAt == nil || caches.candidates.isEmpty
              ? nil : ByteText.full(caches.totalBytes),
            showsContent: true
          ) {
            VStack(alignment: .leading, spacing: 5) {
              Text(
                "Rebuildable caches unchanged for 7 days and diagnostic reports older than 30 days."
              )
              Text("macOS, swap, backups, app databases, and personal files stay protected.")
              Text(
                "This is the eligible cleanup size, not the full System Data total shown by macOS.")
            }.font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
              .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            BlitzRowDivider(leading: 0)
            QuickCleanView(model: caches, history: storage.overview)
          }
          .id(StorageCleanupFocus.caches)
          SimulatorDevicesView(model: simulators, history: storage.overview)
            .id(StorageCleanupFocus.simulators)
          RemovedBeforeView(model: storage.repeats, pending: $repeatPending)
            .id(StorageCleanupFocus.regrown)
          DeveloperCleanupView(model: storage)
            .id(StorageCleanupFocus.projects)
          BlitzStorageSection(
            title: "Docker", symbol: "shippingbox",
            detail: docker.snapshot == nil
              ? "Unused images and build cache" : "Reclaimable · containers and volumes protected",
            trailing: docker.snapshot.map { ByteText.full($0.rebuildableBytes) },
            showsContent: true
          ) {
            DockerStorageView(model: docker)
          }.id(StorageCleanupFocus.docker)
          WorktreeCleanupView(
            model: worktrees.model, processes: worktrees.processes,
            workspaces: worktrees.workspaces, pending: $worktreePending)
          RemovalLogView(history: storage.overview)
        }.padding(BlitzUI.pagePadding)
      }
      .task(id: storage.cleanupFocus) {
        guard let focus = storage.cleanupFocus else { return }
        await Task.yield()
        proxy.scrollTo(focus, anchor: .top)
        storage.cleanupFocus = nil
      }
    }
    .task { storage.scanCleanupIfNeeded() }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let artifact = worktreePending {
        BlitzConfirmation(
          title: "Remove this worktree?",
          message: artifact.path
            + "\n\nGit checks again that it is merged, then removes the folder. The local branch stays.",
          confirmTitle: "Remove worktree",
          onConfirm: {
            worktrees.model.remove(
              .init(artifact: artifact, history: storage.overview, force: false))
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

/// The Cleanup page's single refresh: every section rescans together.
private struct CleanupScanBar: View {
  @ObservedObject var storage: StorageBreakdownModel
  @ObservedObject var caches: QuickCleanModel
  @ObservedObject var docker: DockerStorageModel
  @ObservedObject var simulators: SimulatorDevicesModel
  @ObservedObject var repeats: RepeatCleanupModel
  @ObservedObject var oldFiles: OldFilesModel
  @ObservedObject var largeFiles: LargeFilesModel
  @ObservedObject var worktrees: DeveloperBrowserModel

  private var isScanning: Bool {
    storage.isScanning || caches.isScanning || docker.isRefreshing || simulators.isRefreshing
      || repeats.isChecking || worktrees.isScanning || oldFiles.isScanning
      || largeFiles.isScanning
  }

  private var isBusy: Bool {
    storage.isCleaning || caches.isCleaning || docker.isCleaning || simulators.busyID != nil
      || !repeats.removing.isEmpty || !worktrees.deleting.isEmpty || oldFiles.isTrashing
      || !largeFiles.moving.isEmpty
  }

  var body: some View {
    HStack(spacing: 8) {
      if isScanning {
        ProgressView().controlSize(.small)
        Text("Scanning personal files, devices, caches, projects, Docker, and worktrees…")
      } else if storage.incompleteMeasurements > 0 {
        Text("Some project folders are unmeasured · Scan again to finish")
      } else if let date = storage.scannedAt {
        Text("Scanned \(date.formatted(date: .abbreviated, time: .shortened))")
      }
      Spacer()
      if worktrees.isScanning {
        Button("Stop worktree scan") { worktrees.cancel() }.blitzButton(.quiet)
          .controlSize(.small)
      }
      Button("Scan again") { scanAll() }.blitzButton(.secondary).controlSize(.small)
        .disabled(isScanning || isBusy)
    }.font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
  }

  private func scanAll() {
    storage.scanCleanup()
    caches.scan()
    docker.refresh()
    repeats.check(force: true)
    oldFiles.scan()
    largeFiles.scan()
    worktrees.scan()
    Task { await simulators.refresh() }
  }
}

struct BlitzStorageSection<Content: View>: View {
  let title: String
  let symbol: String
  let detail: String
  /// Total for the section, absent until it has been measured.
  let trailing: String?
  /// False when the section has nothing to act on; the header alone states that.
  let showsContent: Bool
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: symbol).frame(width: 24).foregroundStyle(BlitzUI.secondaryText)
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(BlitzType.headline)
          Text(detail).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
            .lineLimit(1).truncationMode(.middle)
        }
        Spacer()
        if let trailing {
          Text(trailing).font(BlitzType.rowTitle).monospacedDigit()
            .foregroundStyle(BlitzUI.primaryText)
        }
      }.padding(16).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
      if showsContent {
        BlitzRowDivider(leading: 0)
        content
      }
    }.blitzTable()
  }
}
