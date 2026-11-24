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
  @ObservedObject private var inventory = ConnectedDrivesModel.shared
  @State private var inspected: StorageDrive?
  private var drives: [StorageDrive] { inventory.drives }

  var body: some View {
    VStack(spacing: 0) {
      StoragePageHeader(selection: $navigation.storagePage) {
        if navigation.storagePage != .drive {
          if navigation.storagePage == .browse && selectedDrive == nil {
            Text(
              !inventory.loaded
                ? "Reading drives…"
                : showsLargestFiles && storage.overview.reviewRoots.count > 1
                  ? "Multiple drives" : "Drive unavailable"
            ).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          } else {
            StorageCapacityMeter(snapshot: monitor.snapshot, drive: selectedDrive).frame(width: 160)
          }
        }
      }
      Rectangle().fill(BlitzUI.separator).frame(height: 1)
      switch navigation.storagePage {
      case .drive:
        if let inspected {
          if let mounted = drives.first(where: {
            $0.path == inspected.path && $0.volumeID == inspected.volumeID
          }) {
            DriveContentsView(
              drive: mounted, history: storage.overview,
              back: { self.inspected = nil },
              browse: { path in
                folders.open(path)
                showsLargestFiles = false
                navigation.storagePage = .browse
              }
            ).id(mounted.volumeID ?? mounted.path)
          } else {
            VStack {
              Text(inventory.loaded ? "Drive disconnected" : "Reading drives…")
              Button("All drives") { self.inspected = nil }.blitzButton(.secondary)
            }.padding()
          }
        } else {
          DriveBreakdownView(
            model: storage.drive, worktrees: worktrees.model, history: storage.overview,
            startupName: drives.first(where: { $0.path == "/" })?.name ?? "Startup disk",
            onDrive: openDrive,
            onBrowse: { path in
              folders.open(path)
              showsLargestFiles = false
              navigation.storagePage = .browse
            }, onCleanup: openCleanup)
        }
      case .browse:
        if !showsLargestFiles {
          HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 2) {
                ForEach(drives) { drive in
                  BlitzChip(
                    title: drive.name,
                    symbol: drive.internalDisk ? "internaldrive" : "externaldrive",
                    isSelected: selectedDrive?.id == drive.id && folders.path != folders.homePath,
                    action: { folders.open(drive.path) })
                }
                BlitzChip(
                  title: "Home", symbol: "house", isSelected: folders.path == folders.homePath,
                  action: { folders.open(folders.homePath) })
              }.blitzChipGroup()
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Largest files", systemImage: "list.number") {
              reviewFiles(selectedDrive?.scanRoots ?? [folders.path])
            }.blitzButton(.secondary).fixedSize()
              .help("Rank files by size on this drive.")
          }.padding(.horizontal, BlitzUI.pagePadding).padding(.top, 16)
        }
        if showsLargestFiles {
          LargeFileReviewView(
            model: storage.overview, monitor: monitor,
            onCleanup: openCleanup,
            onBrowseFolders: {
              storage.overview.cancelScan()
              if storage.overview.reviewRoots.count == 1,
                let root = storage.overview.reviewRoots.first
              {
                folders.open(root)
              } else if let drive = selectedDrive {
                folders.open(drive.path)
              }
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
            reviewFiles(drives.flatMap(\.scanRoots))
          })
      }
    }
    .task { inventory.refresh() }
    .onChange(of: navigation.driveDestination, initial: true) {
      if let destination = navigation.driveDestination {
        navigation.driveDestination = nil
        openDrive(destination)
      }
    }
  }

  private var selectedDrive: StorageDrive? {
    guard navigation.storagePage == .browse else { return nil }
    if showsLargestFiles {
      let roots = storage.overview.reviewRoots
      if let match = drives.first(where: { Set($0.scanRoots) == Set(roots) }) { return match }
      guard roots.count == 1, let path = roots.first else { return nil }
      return StorageDrives.containing((path, drives))
    }
    return StorageDrives.containing((folders.path, drives))
  }

  private func openDrive(_ destination: DriveDestination) {
    inspected = nil
    switch destination.action {
    case .breakdown:
      if folders.isScanning { folders.cancelScan() }
      if storage.overview.isScanning { storage.overview.cancelScan() }
      inspected = destination.drive
      navigation.storagePage = .drive
    case .browse:
      if storage.overview.isScanning { storage.overview.cancelScan() }
      folders.open(destination.drive.path)
      showsLargestFiles = false
      navigation.storagePage = .browse
    case .largestFiles:
      reviewFiles(destination.drive.scanRoots)
    }
  }

  private func reviewFiles(_ roots: [String]) {
    guard !roots.isEmpty else { return }
    storage.overview.selectReviewRoots(roots)
    guard Set(storage.overview.reviewRoots) == Set(roots) else { return }
    folders.cancelScan()
    showsLargestFiles = true
    navigation.storagePage = .browse
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
  @State private var expandedSections: Set<String> = []

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          CleanupScanBar(
            storage: storage, caches: caches, docker: docker, simulators: simulators,
            repeats: storage.repeats, oldFiles: storage.oldFiles, largeFiles: storage.largeFiles,
            worktrees: worktrees.model)
          BlitzStorageSection(
            title: "Caches and diagnostic reports", symbol: "archivebox",
            detail: "Caches unchanged for 7 days and reports older than 30 days",
            trailing: nil, showsContent: true
          ) {
            QuickCleanView(model: caches, history: storage.overview)
          }.id(StorageCleanupFocus.caches)
          RemovedBeforeView(model: storage.repeats, pending: $repeatPending)
            .id(StorageCleanupFocus.regrown)
          OldFilesView(model: storage.oldFiles, history: storage.overview)
            .id(StorageCleanupFocus.oldFiles)
          LargeFilesView(
            model: storage.largeFiles, history: storage.overview, onSearchDrives: onSearchDrives
          ).id(StorageCleanupFocus.largeFiles)
          SimulatorDevicesView(model: simulators, history: storage.overview)
            .id(StorageCleanupFocus.simulators)
          DeveloperCleanupView(model: storage)
            .task { storage.scanCleanupIfNeeded() }
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
        expandedSections.formUnion(focus.sectionTitles)
        await Task.yield()
        proxy.scrollTo(focus, anchor: .top)
        storage.cleanupFocus = nil
      }
    }
    .environment(\.cleanupExpandedSections, $expandedSections)
    .task {
      storage.scanCleanupIfNeeded()
      if caches.scannedAt == nil { caches.scan() }
    }
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

  private var activeScans: [String] {
    [
      (caches.isScanning, "caches"), (oldFiles.isScanning, "old files"),
      (largeFiles.isScanning, "large files"), (storage.isScanning, "project folders"),
      (simulators.isRefreshing, "simulators"), (repeats.isChecking, "regrown folders"),
      (docker.isRefreshing, "Docker"), (worktrees.isScanning, "worktrees"),
    ].compactMap { $0.0 ? $0.1 : nil }
  }

  private var isBusy: Bool {
    storage.isCleaning || caches.isCleaning || docker.isCleaning || simulators.busyID != nil
      || !repeats.removing.isEmpty || !worktrees.deleting.isEmpty || oldFiles.isTrashing
      || !largeFiles.moving.isEmpty
  }

  var body: some View {
    let active = activeScans
    HStack(spacing: 8) {
      if !active.isEmpty {
        ProgressView().controlSize(.small)
        Text("Checking " + active.formatted(.list(type: .and)) + "…")
      } else if storage.incompleteMeasurements > 0 {
        Text("Some project folders still need measuring")
      } else if let date = storage.scannedAt {
        Text("Project folders checked \(date.formatted(.relative(presentation: .named)))")
      }
      Spacer()
      if worktrees.isScanning {
        Button("Stop worktree scan") { worktrees.cancel() }.blitzButton(.quiet)
          .controlSize(.small)
      }
      Button("Rescan all") { scanAll() }.blitzButton(.secondary).controlSize(.small)
        .disabled(!active.isEmpty || isBusy)
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

private struct CleanupExpandedSectionsKey: EnvironmentKey {
  static let defaultValue: Binding<Set<String>>? = nil
}

extension EnvironmentValues {
  var cleanupExpandedSections: Binding<Set<String>>? {
    get { self[CleanupExpandedSectionsKey.self] }
    set { self[CleanupExpandedSectionsKey.self] = newValue }
  }
}

extension StorageCleanupFocus {
  var sectionTitles: Set<String> {
    switch self {
    case .oldFiles: ["Old downloads and screenshots"]
    case .largeFiles: ["Large personal files"]
    case .caches: ["Caches and diagnostic reports"]
    case .simulators: ["Simulated devices"]
    case .regrown: ["Folders that grew back"]
    case .projects: ["Dependencies", "Build caches", "Simulator cache"]
    case .docker: ["Docker"]
    }
  }
}

struct BlitzStorageSection<Content: View>: View {
  let title: String
  let symbol: String
  let detail: String
  let trailing: String?
  let showsContent: Bool
  @ViewBuilder let content: Content
  @Environment(\.cleanupExpandedSections) private var expandedSections

  private var isExpanded: Bool {
    expandedSections?.wrappedValue.contains(title) ?? true
  }

  var body: some View {
    VStack(spacing: 0) {
      if let sections = expandedSections, showsContent {
        Button {
          if sections.wrappedValue.contains(title) {
            sections.wrappedValue.remove(title)
          } else {
            sections.wrappedValue.insert(title)
          }
        } label: {
          header
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + ", " + detail)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
      } else {
        header.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
      }
      if showsContent && isExpanded {
        BlitzRowDivider(leading: 0)
        content
      }
    }.blitzTable()
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).frame(width: 22).foregroundStyle(BlitzUI.secondaryText)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(BlitzType.headline)
        Text(detail).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer()
      if let trailing {
        Text(trailing).font(BlitzType.rowTitle).monospacedDigit()
          .foregroundStyle(BlitzUI.primaryText)
      }
      if expandedSections != nil && showsContent {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          .font(BlitzType.captionEmphasis).foregroundStyle(BlitzUI.secondaryText)
          .accessibilityHidden(true)
      }
    }.padding(.horizontal, 12).padding(.vertical, 10)
      .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
      .contentShape(Rectangle())
  }
}

struct StoragePageHeader<Capacity: View>: View {
  @Binding var selection: CleanStoragePage
  @ViewBuilder let capacity: () -> Capacity

  var body: some View {
    HStack(spacing: 16) {
      Text("Storage").font(BlitzType.largeTitle).tracking(-0.4)
        .foregroundStyle(BlitzUI.primaryText)
      BlitzSegmentedPicker(
        title: "Storage", options: CleanStoragePage.allCases,
        selection: $selection, label: { $0.rawValue }
      ).frame(width: 280)
      Spacer(minLength: 8)
      capacity()
    }
    .padding(.horizontal, BlitzUI.pagePadding)
    .padding(.top, 20).padding(.bottom, 18)
  }
}
