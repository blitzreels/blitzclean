import AppKit
import SwiftUI

struct StorageBreakdownView: View {
  @ObservedObject var model: StorageBreakdownModel
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var dockerStorage: DockerStorageModel
  @ObservedObject var navigation: StorageNavigationModel
  @ObservedObject var folderExplorer: FolderExplorerModel
  @State private var selectedCategoryID: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      if navigation.page == .folders {
        FolderExplorerView(model: folderExplorer)
      } else if navigation.page == .breakdown && model.categories.isEmpty && model.isScanning {
        scanningView
      } else {
        switch navigation.page {
        case .cleanup:
          DeveloperCleanupView(
            model: model,
            snapshot: monitor.snapshot,
            onOpenDiskUsage: {
              navigation.page = .breakdown
            }
          )
        case .breakdown:
          StorageExplorerView(
            model: model,
            snapshot: monitor.snapshot,
            selectedCategoryID: $selectedCategoryID
          )
        case .docker:
          DockerStorageView(model: dockerStorage)
        case .folders:
          EmptyView()
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .frame(minWidth: 820, minHeight: 620)
    .task {
      model.scanIfNeeded()
    }
    .onChange(of: model.categories) { _, categories in
      if selectedCategoryID == nil {
        selectedCategoryID = categories.first?.id
      }
    }
  }

  private var header: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(pageTitle)
          .font(.title2.weight(.semibold))
        Text(pageStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Picker("View", selection: $navigation.page) {
        ForEach(StoragePage.allCases) { page in
          Text(page.rawValue).tag(page)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 440)

      if navigation.page != .folders {
        if navigation.page == .docker ? dockerStorage.isRefreshing : model.isScanning {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          if navigation.page == .docker {
            dockerStorage.refresh()
          } else {
            model.scan()
          }
        } label: {
          Label("Scan Again", systemImage: "arrow.clockwise")
        }
        .disabled(isRefreshDisabled)
      }
    }
    .padding(16)
  }

  private var scanningView: some View {
    ContentUnavailableView {
      Label("Scanning Developer Storage", systemImage: "externaldrive.badge.magnifyingglass")
    } description: {
      Text("Checking dependencies, active projects, simulators, caches, and large files.")
    } actions: {
      ProgressView()
        .controlSize(.small)
    }
  }

  private var pageTitle: String {
    switch navigation.page {
    case .docker:
      "Docker Storage"
    case .folders:
      "What takes space"
    case .cleanup, .breakdown:
      "Storage"
    }
  }

  private var pageStatus: String {
    if navigation.page == .folders {
      return
        "Double-click a folder to drill down. Sizes are allocated disk blocks, measured with du."
    }

    if navigation.page == .docker {
      if dockerStorage.isRefreshing {
        return dockerStorage.snapshot == nil
          ? "Reading Docker disk usage…" : "Showing saved results · refreshing…"
      }

      if let updatedAt = dockerStorage.snapshot?.updatedAt {
        return "Updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))"
      }

      return dockerStorage.errorMessage ?? "Docker has not been checked yet"
    }

    return scanStatus
  }

  private var isRefreshDisabled: Bool {
    if navigation.page == .docker {
      return dockerStorage.isRefreshing || dockerStorage.isCleaning
    }

    return model.isScanning || model.isCleaning
  }

  private var scanStatus: String {
    if model.isScanning {
      if !model.categories.isEmpty {
        return "Showing saved results · refreshing sections…"
      }

      return "Checking project activity and simulator state…"
    }

    guard let scannedAt = model.scannedAt else {
      return "Not scanned yet"
    }

    return "Scanned \(scannedAt.formatted(date: .abbreviated, time: .shortened))"
  }
}

enum StoragePage: String, CaseIterable, Identifiable {
  case cleanup = "Clean Up"
  case folders = "Folders"
  case breakdown = "Categories"
  case docker = "Docker"

  var id: Self {
    self
  }
}

@MainActor
final class StorageNavigationModel: ObservableObject {
  @Published var page = StoragePage.cleanup
}

private struct DeveloperCleanupView: View {
  @ObservedObject var model: StorageBreakdownModel
  let snapshot: SystemSnapshot
  let onOpenDiskUsage: () -> Void
  @State private var ageThreshold = 0
  @State private var showsConfirmation = false
  @State private var showsStopConfirmation = false
  @State private var pendingProcessItem: StorageItem?
  @State private var dependencySort = DependencySort.largest
  @State private var dependencyVisibility = DependencyVisibility.canDelete
  @State private var dependencySearch = ""
  @State private var showsDeveloperDetails = false

  private var allNodeItems: [StorageItem] {
    model.categories.first { category in
      category.id == "node-modules"
    }?.items.filter { item in
      item.cleanupKind == .nodeModules
    } ?? []
  }

  private var nodeItems: [StorageItem] {
    let cutoff =
      Calendar.current.date(
        byAdding: .day,
        value: -ageThreshold,
        to: .now
      ) ?? .now
    let visibleItems = allNodeItems.filter { item in
      let matchesVisibility: Bool

      switch dependencyVisibility {
      case .canDelete:
        matchesVisibility = item.cleanupAvailability?.isReady == true
      case .inUse:
        matchesVisibility = item.activeProcesses?.isEmpty == false
      case .all:
        matchesVisibility = true
      }

      let matchesAge =
        ageThreshold == 0
        || (item.lastActivityAt ?? .distantFuture) < cutoff
      let matchesSearch =
        dependencySearch.isEmpty
        || item.name.localizedCaseInsensitiveContains(dependencySearch)
        || item.path.localizedCaseInsensitiveContains(dependencySearch)
      return matchesVisibility && matchesAge && matchesSearch
    }

    switch dependencySort {
    case .largest:
      return visibleItems.sorted { left, right in
        left.bytes > right.bytes
      }
    case .oldest:
      return visibleItems.sorted { left, right in
        (left.lastActivityAt ?? .distantFuture) < (right.lastActivityAt ?? .distantFuture)
      }
    }
  }

  private var generatedItems: [StorageItem] {
    model.categories.first { category in
      category.id == "node-modules"
    }?.items.filter { item in
      item.cleanupKind == .generatedBuildCache
    }.sorted { left, right in
      left.bytes > right.bytes
    } ?? []
  }

  private var simulatorCache: StorageItem? {
    model.categories.flatMap(\.items).first { item in
      item.cleanupKind == .simulatorCache
    }
  }

  private var safeBytes: UInt64 {
    model.recommendedBytes
  }

  private var allSafeBytes: UInt64 {
    model.readyItems.reduce(0) { result, item in
      result + item.bytes
    }
  }

  private var deletableNodeItems: [StorageItem] {
    allNodeItems.filter { item in
      item.cleanupAvailability?.isReady == true
    }
  }

  private var deletableNodeBytes: UInt64 {
    deletableNodeItems.reduce(0) { result, item in
      result + item.bytes
    }
  }

  private var inUseNodeCount: Int {
    allNodeItems.filter { item in
      item.activeProcesses?.isEmpty == false
    }.count
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        CleanupWinsView(
          overview: model.overview, available: snapshot.diskAvailable, total: snapshot.diskTotal)
        CleanupOpportunitiesView(model: model, overview: model.overview)
        DisclosureGroup(
          "All developer storage · dependencies, builds & simulators",
          isExpanded: $showsDeveloperDetails
        ) {
          reclaimCard

          CleanupSection(
            title: "Project Dependencies",
            detail: "Reinstallable node_modules grouped by their real workspace",
            systemImage: "shippingbox.fill"
          ) {
            nodeControls

            if dependencyVisibility != .canDelete {
              DependencyLegend()
            }

            if nodeItems.isEmpty && model.isScanning {
              SectionLoadingRow(text: "Scanning dependency folders…")
            } else if nodeItems.isEmpty {
              EmptySectionRow(text: "No dependency folders found in configured project roots.")
            } else {
              ForEach(nodeItems) { item in
                CleanupItemRow(
                  item: item,
                  isSelected: model.selectedPaths.contains(item.path),
                  onSelectionChange: { selection in
                    model.setSelected(selection)
                  },
                  onStopAndSelect: { processItem in
                    pendingProcessItem = processItem
                    showsStopConfirmation = true
                  },
                  isStoppingProcesses: model.stoppingProcessPath == item.path
                )
              }
            }
          }

          if !generatedItems.isEmpty {
            CleanupSection(
              title: "Generated Build Caches",
              detail: "Collapsed npm, Vercel, and Trigger outputs",
              systemImage: "hammer.fill"
            ) {
              ForEach(generatedItems) { item in
                CleanupItemRow(
                  item: item,
                  isSelected: model.selectedPaths.contains(item.path),
                  onSelectionChange: { selection in
                    model.setSelected(selection)
                  },
                  onStopAndSelect: { _ in },
                  isStoppingProcesses: false
                )
              }
            }
          }

          CleanupSection(
            title: "Apple Simulators",
            detail: "Running devices are protected; simulator caches are rebuildable",
            systemImage: "iphone.gen3"
          ) {
            simulatorSummary

            if model.simulatorDevices.isEmpty && model.isScanning {
              SectionLoadingRow(text: "Reading simulator devices…")
            } else {
              ForEach(model.simulatorDevices) { device in
                SimulatorDeviceRow(device: device)
              }
            }

            if let simulatorCache {
              CleanupItemRow(
                item: simulatorCache,
                isSelected: model.selectedPaths.contains(simulatorCache.path),
                onSelectionChange: { selection in
                  model.setSelected(selection)
                },
                onStopAndSelect: { _ in },
                isStoppingProcesses: false
              )
            }
          }
        }
        StorageCapacityStrip(
          snapshot: snapshot,
          categories: model.categories,
          onOpenDiskUsage: onOpenDiskUsage
        )
      }
      .padding(18)
    }
    .safeAreaInset(edge: .bottom) {
      if !model.selectedItems.isEmpty || model.isCleaning || model.cleanupMessage != nil {
        cleanupBar
      }
    }
    .alert("Delete selected items permanently?", isPresented: $showsConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete Permanently", role: .destructive) {
        model.cleanSelected()
      }
    } message: {
      Text(
        "\(model.selectedItems.count) item(s), \(ByteText.full(model.selectedBytes)). "
          + "This cannot be undone. Current rebuild and activity checks run before deletion; changed or busy items are skipped."
      )
    }
    .alert(
      "Stop running processes?",
      isPresented: $showsStopConfirmation,
      presenting: pendingProcessItem
    ) { item in
      Button("Cancel", role: .cancel) {}
      Button("Stop & Select", role: .destructive) {
        model.stopProcessesAndSelect(item)
      }
    } message: { item in
      Text(stopConfirmationMessage(item))
    }
  }

  private var reclaimCard: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Rebuildable at last scan · estimated size")
          .font(.headline)
        Text(ByteText.full(allSafeBytes))
          .font(.system(size: 32, weight: .semibold, design: .rounded))
          .monospacedDigit()
        Text(
          "\(deletableNodeItems.count) dependency folders · "
            + "\(ByteText.full(deletableNodeBytes))"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 6) {
        HStack(spacing: 8) {
          Button("Select Suggested · \(ByteText.compact(safeBytes))") {
            model.selectRecommended()
          }
          .disabled(model.isScanning || safeBytes == 0)

          Button("Select All Safe") {
            for item in model.readyItems {
              model.setSelected(
                StorageSelection(path: item.path, isSelected: true)
              )
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isScanning || model.readyItems.isEmpty)
        }

        Label("Deletes permanently", systemImage: "trash.fill")
          .font(.callout.weight(.medium))
          .foregroundStyle(.orange)
        Text("Rebuildable items only · no simulator device deletion")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(18)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
  }

  private func stopConfirmationMessage(_ item: StorageItem) -> String {
    let processNames =
      item.activeProcesses?.map { process in
        "\(process.name) (PID \(process.processID))"
      }.joined(separator: ", ") ?? "the running processes"

    return "Stop \(processNames)? Unsaved process work can be lost. "
      + "Project source stays untouched; dependencies are selected only after a rescan."
  }

  private var nodeControls: some View {
    VStack(spacing: 9) {
      HStack(spacing: 10) {
        Picker("Projects", selection: $dependencyVisibility) {
          Text("Can Delete \(deletableNodeItems.count)")
            .tag(DependencyVisibility.canDelete)
          Text("In Use \(inUseNodeCount)")
            .tag(DependencyVisibility.inUse)
          Text("All \(allNodeItems.count)")
            .tag(DependencyVisibility.all)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 330)

        TextField("Find a project or path", text: $dependencySearch)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 180)

        Picker("Age", selection: $ageThreshold) {
          Text("Any age").tag(0)
          Text("7+ days").tag(7)
          Text("30+ days").tag(30)
          Text("90+ days").tag(90)
        }
        .labelsHidden()
        .frame(width: 120)

        Picker("Sort", selection: $dependencySort) {
          ForEach(DependencySort.allCases) { sort in
            Text(sort.rawValue).tag(sort)
          }
        }
        .labelsHidden()
        .frame(width: 105)
      }

      HStack {
        Text(
          "\(nodeItems.count) shown · "
            + "\(ByteText.full(nodeItems.reduce(0) { $0 + $1.bytes }))"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Spacer()

        Button("Select Shown") {
          for item in nodeItems where item.cleanupAvailability?.isReady == true {
            model.setSelected(
              StorageSelection(path: item.path, isSelected: true)
            )
          }
        }
        .disabled(
          !nodeItems.contains { item in
            item.cleanupAvailability?.isReady == true
          }
        )

        Button("Clear Selection") {
          model.clearSelection()
        }
        .disabled(model.selectedPaths.isEmpty)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.quaternary.opacity(0.35))
  }

  private var simulatorSummary: some View {
    HStack(spacing: 10) {
      Label(
        "\(model.bootedSimulatorCount) booted",
        systemImage: model.bootedSimulatorCount == 0 ? "checkmark.circle" : "play.circle.fill"
      )
      .foregroundStyle(model.bootedSimulatorCount == 0 ? Color.secondary : Color.green)

      Text("·")
        .foregroundStyle(.tertiary)

      Text("\(model.simulatorDeviceCount) devices")
        .foregroundStyle(.secondary)

      Spacer()

      Button("Open Xcode") {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Xcode.app"))
      }
    }
    .font(.caption)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.quaternary.opacity(0.35))
  }

  private var cleanupBar: some View {
    VStack(spacing: 8) {
      if model.isCleaning {
        ProgressView(value: model.cleanupProgress) {
          Text("Deleting \(model.cleanupCompletedCount) of \(model.cleanupTotalCount)")
        }
      } else if let cleanupMessage = model.cleanupMessage {
        Text(cleanupMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Text("\(model.selectedItems.count) selected")
          .foregroundStyle(.secondary)
        Text("·")
          .foregroundStyle(.tertiary)
        Text(ByteText.full(model.selectedBytes))
          .fontWeight(.semibold)
          .monospacedDigit()

        Spacer()

        Button("Delete Permanently") {
          showsConfirmation = true
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.selectedItems.isEmpty || model.isCleaning)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .background(.bar)
    .overlay(alignment: .top) {
      Divider()
    }
  }
}

private struct StorageCapacityStrip: View {
  let snapshot: SystemSnapshot
  let categories: [StorageCategory]
  let onOpenDiskUsage: () -> Void

  private var largestCategories: [StorageCategory] {
    Array(
      categories
        .filter { category in
          category.bytes > 0 && !category.id.hasPrefix("computer-")
        }
        .sorted { left, right in
          left.bytes > right.bytes
        }
        .prefix(3)
    )
  }

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        CapacityMiniCard(
          title: "Mac",
          available: snapshot.diskAvailable,
          total: snapshot.diskTotal,
          systemImage: "internaldrive",
          tint: MenuBarTones.disk(snapshot).color
        )

        if let developerVolume = snapshot.developerVolume {
          CapacityMiniCard(
            title: "Dev drive",
            available: developerVolume.available,
            total: developerVolume.total,
            systemImage: "externaldrive",
            tint: MetricTone.forDisk(
              DiskCapacityInput(
                available: developerVolume.available, total: developerVolume.total)
            ).color
          )
        }

        CapacityMiniCard(
          title: "Memory",
          available: snapshot.ramAvailable,
          total: snapshot.ramTotal,
          systemImage: "memorychip",
          tint: snapshot.ramUsedRatio >= 0.9 ? .red : .accentColor
        )
      }

      HStack(spacing: 10) {
        Text("Largest developer data")
          .font(.caption.weight(.semibold))

        ForEach(largestCategories) { category in
          Label(
            "\(category.name) \(ByteText.compact(category.bytes))",
            systemImage: category.systemImage
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Spacer()

        Button("See All Disk Usage", action: onOpenDiskUsage)
          .buttonStyle(.link)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
    }
  }
}

private struct CapacityMiniCard: View {
  let title: String
  let available: UInt64
  let total: UInt64
  let systemImage: String
  let tint: Color

  private var used: UInt64 {
    total > available ? total - available : 0
  }

  private var usedRatio: Double {
    guard total > 0 else {
      return 0
    }

    return Double(used) / Double(total)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .foregroundStyle(.secondary)
        Text(title)
          .font(.caption.weight(.semibold))
        Spacer()
        Text("\(ByteText.full(available)) free")
          .font(.headline)
          .monospacedDigit()
      }

      ProgressView(value: usedRatio)
        .tint(tint)

      Text("\(ByteText.full(used)) used of \(ByteText.full(total))")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(12)
    .frame(maxWidth: .infinity)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct CleanupSection<Content: View>: View {
  let title: String
  let detail: String
  let systemImage: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(14)

      Divider()
      content
    }
    .background(.background, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.separator, lineWidth: 1)
    }
  }
}

private struct CleanupItemRow: View {
  let item: StorageItem
  let isSelected: Bool
  let onSelectionChange: (StorageSelection) -> Void
  let onStopAndSelect: (StorageItem) -> Void
  let isStoppingProcesses: Bool
  @State private var showsProcesses = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Toggle(
          "",
          isOn: Binding(
            get: { isSelected },
            set: { value in
              onSelectionChange(StorageSelection(path: item.path, isSelected: value))
            }
          )
        )
        .labelsHidden()
        .disabled(!isReady)

        VStack(alignment: .leading, spacing: 3) {
          Text(projectName)
            .fontWeight(.medium)
            .lineLimit(1)
          Text(item.path)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 2) {
          Text("Project changed")
            .font(.caption2)
            .foregroundStyle(.tertiary)
          if let lastActivityAt = item.lastActivityAt {
            Text(lastActivityAt, style: .relative)
              .font(.callout.weight(.medium))
              .help(lastActivityAt.formatted(date: .abbreviated, time: .shortened))
          } else {
            Text("Unknown")
              .font(.callout.weight(.medium))
              .foregroundStyle(.secondary)
          }
        }
        .frame(width: 105, alignment: .trailing)

        if let processes = item.activeProcesses, !processes.isEmpty {
          RunningProcessDisclosure(
            processes: processes,
            isExpanded: $showsProcesses
          )
        } else {
          if case .blocked = item.cleanupAvailability {
            StorageAvailabilityLabel(availability: item.cleanupAvailability)
          }
        }

        VStack(alignment: .trailing, spacing: 2) {
          Text("\(ByteText.full(item.bytes)) on disk")
            .fontWeight(.semibold)
            .monospacedDigit()

          if let contentBytes = item.contentBytes, contentBytes < item.bytes {
            Text("\(ByteText.full(contentBytes)) file data")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .frame(width: 118, alignment: .trailing)
        .help(diskUsageHelp)

        Button {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        } label: {
          Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help("Reveal in Finder")
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)

      if showsProcesses, let processes = item.activeProcesses, !processes.isEmpty {
        RunningProcessesDetail(
          item: item,
          processes: processes,
          isStopping: isStoppingProcesses,
          onStopAndSelect: onStopAndSelect
        )
      }
    }
    .overlay(alignment: .bottom) {
      Divider()
        .padding(.leading, 42)
    }
  }

  private var isReady: Bool {
    item.cleanupAvailability?.isReady == true
  }

  private var projectName: String {
    return item.name
  }

  private var diskUsageHelp: String {
    guard let contentBytes = item.contentBytes, contentBytes < item.bytes else {
      return "Space this folder consumes on the drive."
    }

    return "The drive reserves whole storage blocks for every file. "
      + "Thousands of tiny dependency files can therefore consume more disk space than their file data."
  }
}

private struct RunningProcessDisclosure: View {
  let processes: [ProjectProcessInfo]
  @Binding var isExpanded: Bool

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack(spacing: 4) {
        Text(label)
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
      }
      .font(.caption2.weight(.medium))
      .foregroundStyle(.orange)
    }
    .buttonStyle(.plain)
    .help("Show process names, PIDs, listening ports, and stop controls")
  }

  private var label: String {
    let ports = Array(Set(processes.flatMap(\.listeningPorts))).sorted()
    guard let firstPort = ports.first else {
      return "\(processes.count) running"
    }

    if ports.count == 1 {
      return "\(processes.count) running · :\(firstPort)"
    }

    return "\(processes.count) running · :\(firstPort) +\(ports.count - 1)"
  }
}

private struct RunningProcessesDetail: View {
  let item: StorageItem
  let processes: [ProjectProcessInfo]
  let isStopping: Bool
  let onStopAndSelect: (StorageItem) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label("Processes using this project", systemImage: "terminal.fill")
          .font(.caption.weight(.semibold))
        Spacer()

        if isStopping {
          ProgressView()
            .controlSize(.small)
          Text("Stopping…")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Button("Stop & Select") {
            onStopAndSelect(item)
          }
          .buttonStyle(.bordered)
        }
      }

      ForEach(processes) { process in
        HStack(spacing: 8) {
          Text(process.name)
            .font(.callout.weight(.medium))
          Text("PID \(process.processID)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

          Spacer()

          if process.listeningPorts.isEmpty {
            Text("No listening ports")
              .foregroundStyle(.secondary)
          } else {
            Text(portList(process))
              .foregroundStyle(.blue)
          }
        }
        .font(.caption)
      }

      Text(
        "Stopping can discard unsaved process work. Project source files are never deleted here."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding(.leading, 50)
    .padding(.trailing, 14)
    .padding(.vertical, 10)
    .background(.orange.opacity(0.055))
    .overlay(alignment: .top) {
      Divider().padding(.leading, 42)
    }
  }

  private func portList(_ process: ProjectProcessInfo) -> String {
    "Ports "
      + process.listeningPorts.map { port in
        ":\(port)"
      }.joined(separator: ", ")
  }
}

private struct DependencyLegend: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label {
        Text(
          "In use · protected: a dev server, Terminal, Codex, or another app is using the project.")
      } icon: {
        Image(systemName: "lock.fill")
          .foregroundStyle(.orange)
      }

      Label {
        Text(
          "On disk is the space consumed. Tiny dependency files can use more space than their file data."
        )
      } icon: {
        Image(systemName: "externaldrive.fill")
          .foregroundStyle(.secondary)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }
}

private enum DependencySort: String, CaseIterable, Identifiable {
  case largest = "Largest"
  case oldest = "Oldest"

  var id: Self {
    self
  }
}

private enum DependencyVisibility: String, CaseIterable, Identifiable {
  case canDelete
  case inUse
  case all

  var id: Self {
    self
  }
}

private struct StorageAvailabilityLabel: View {
  let availability: StorageCleanupAvailability?

  var body: some View {
    Text(label)
      .font(.caption2.weight(.medium))
      .foregroundStyle(color)
      .help(helpText)
  }

  private var label: String {
    switch availability {
    case .ready:
      return "Selectable"
    case .blocked(let reason):
      return blockedLabel(reason)
    case nil:
      return "Review"
    }
  }

  private var helpText: String {
    switch availability {
    case .ready:
      return "This dependency folder can be selected and reinstalled from the project lockfile."
    case .blocked(let reason):
      return blockedHelp(reason)
    case nil:
      return "\(AppBrand.name) cannot verify that this item is safe to delete automatically."
    }
  }

  private func blockedLabel(_ reason: String) -> String {
    switch reason {
    case "Project is in use":
      return "In use · protected"
    case "No exact reinstall lock":
      return "Lockfile missing"
    case "Missing package.json":
      return "Not a project"
    default:
      return reason
    }
  }

  private func blockedHelp(_ reason: String) -> String {
    switch reason {
    case "Project is in use":
      return
        "A running process has this project open. Stop its dev server or task, then scan again."
    case "No exact reinstall lock":
      return
        "No npm, pnpm, Yarn, or Bun lockfile was found, so an exact reinstall is not guaranteed."
    case "Missing package.json":
      return "No package.json was found for this dependency folder."
    default:
      return reason
    }
  }

  private var color: Color {
    switch availability {
    case .ready:
      return .green
    case .blocked:
      return .orange
    case nil:
      return .secondary
    }
  }
}

private struct SimulatorDeviceRow: View {
  let device: SimulatorDeviceInfo

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: device.state == "Booted" ? "play.circle.fill" : "stop.circle")
        .foregroundStyle(device.state == "Booted" ? .green : .secondary)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text(device.name)
          .fontWeight(.medium)
        Text(device.runtime)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if let lastBootedAt = device.lastBootedAt {
        Text("Booted \(lastBootedAt, style: .relative)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(device.state)
        .font(.caption2.weight(.medium))
        .foregroundStyle(device.state == "Booted" ? .green : .secondary)

      Text(ByteText.full(device.bytes))
        .fontWeight(.semibold)
        .monospacedDigit()
        .frame(width: 82, alignment: .trailing)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .overlay(alignment: .bottom) {
      Divider()
        .padding(.leading, 42)
    }
  }
}

private struct EmptySectionRow: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
  }
}

private struct SectionLoadingRow: View {
  let text: String

  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
  }
}

private struct DockerStorageView: View {
  @ObservedObject var model: DockerStorageModel
  @State private var showsConfirmation = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        dockerSummary

        if let errorMessage = model.errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }

        if let snapshot = model.snapshot {
          DockerCategorySection(snapshot: snapshot)
          protectionCard
        } else if model.isRefreshing {
          SectionLoadingRow(text: "Reading images, containers, volumes, and build cache…")
        } else if !model.isInstalled {
          ContentUnavailableView(
            "Docker Not Installed",
            systemImage: "shippingbox",
            description: Text("Install Docker Desktop to see its native storage breakdown.")
          )
        }
      }
      .padding(18)
    }
    .safeAreaInset(edge: .bottom) {
      dockerCleanupBar
    }
    .alert("Clean rebuildable Docker data?", isPresented: $showsConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Clean Docker", role: .destructive) {
        model.cleanRebuildable()
      }
    } message: {
      Text(
        "Unused images and build cache will be deleted permanently. "
          + "Containers and volumes will not be deleted."
      )
    }
  }

  private var dockerSummary: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Rebuildable Docker data")
          .font(.headline)
        Text(ByteText.full(model.snapshot?.rebuildableBytes ?? 0))
          .font(.system(size: 32, weight: .semibold, design: .rounded))
          .monospacedDigit()
        Text("Unused images and build cache only")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 6) {
        Label("Volumes protected", systemImage: "lock.fill")
          .font(.callout.weight(.medium))
          .foregroundStyle(.green)
        Text("No Terminal window · no container deletion")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(18)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
  }

  private var protectionCard: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "lock.shield.fill")
        .foregroundStyle(.green)
        .font(.title2)
      VStack(alignment: .leading, spacing: 4) {
        Text("Data-bearing Docker resources stay untouched")
          .font(.headline)
        Text(
          "\(AppBrand.name) never prunes volumes or containers. Images used by a container are also retained."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
  }

  private var dockerCleanupBar: some View {
    VStack(spacing: 8) {
      if model.isCleaning {
        ProgressView()
          .controlSize(.small)
        Text("Cleaning unused Docker images and build cache…")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if let cleanupMessage = model.cleanupMessage {
        Text(cleanupMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Text("Reclaimable")
          .foregroundStyle(.secondary)
        Text(ByteText.full(model.snapshot?.rebuildableBytes ?? 0))
          .fontWeight(.semibold)
          .monospacedDigit()

        Spacer()

        Button("Clean Rebuildable") {
          showsConfirmation = true
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          model.snapshot?.rebuildableBytes == 0
            || model.isCleaning
            || model.isRefreshing
        )
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .background(.bar)
    .overlay(alignment: .top) {
      Divider()
    }
  }
}

private struct DockerCategorySection: View {
  let snapshot: DockerStorageSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Docker Breakdown")
            .font(.headline)
          Text("\(ByteText.full(snapshot.totalBytes)) allocated across Docker resources")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text("Updated \(snapshot.updatedAt, style: .relative)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(14)

      Divider()

      ForEach(snapshot.categories) { category in
        DockerCategoryRow(category: category)
      }
    }
    .background(.background, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.separator, lineWidth: 1)
    }
  }
}

private struct DockerCategoryRow: View {
  let category: DockerStorageCategory

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 26)

      VStack(alignment: .leading, spacing: 3) {
        Text(category.name)
          .fontWeight(.medium)
        Text("\(category.totalCount) total · \(category.activeCount) active")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 2) {
        Text(ByteText.full(category.sizeBytes))
          .fontWeight(.semibold)
          .monospacedDigit()
        Text("\(ByteText.full(category.reclaimableBytes)) reclaimable")
          .font(.caption)
          .foregroundStyle(category.reclaimableBytes > 0 ? Color.orange : Color.secondary)
      }
      .frame(width: 150, alignment: .trailing)

      if category.isProtected {
        Text("Protected").font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .overlay(alignment: .bottom) {
      Divider()
        .padding(.leading, 52)
    }
  }

  private var systemImage: String {
    switch category.id {
    case "images":
      return "square.stack.3d.up.fill"
    case "containers":
      return "shippingbox.fill"
    case "volumes":
      return "externaldrive.fill"
    case "build-cache":
      return "hammer.fill"
    default:
      return "circle.grid.2x2.fill"
    }
  }
}

private struct StorageExplorerView: View {
  @ObservedObject var model: StorageBreakdownModel
  let snapshot: SystemSnapshot
  @Binding var selectedCategoryID: String?
  @State private var selectedVolumeID = "mac"

  private var selectedCategory: StorageCategory? {
    breakdown.categories.first { category in
      category.id == selectedCategoryID
    }
  }

  private var volumes: [StorageVolumeContext] {
    var result = [
      StorageVolumeContext(
        id: "mac",
        name: "Mac",
        rootPath: "/",
        availableBytes: snapshot.diskAvailable,
        totalBytes: snapshot.diskTotal
      )
    ]

    if let developerVolume = snapshot.developerVolume {
      result.append(
        StorageVolumeContext(
          id: "developer",
          name: "Dev drive",
          rootPath: developerVolume.path,
          availableBytes: developerVolume.available,
          totalBytes: developerVolume.total
        )
      )
    }

    return result
  }

  private var selectedVolume: StorageVolumeContext {
    volumes.first { volume in
      volume.id == selectedVolumeID
    } ?? volumes[0]
  }

  private var breakdown: StorageVolumeBreakdownResult {
    StorageVolumeBreakdown.result(
      StorageVolumeBreakdownRequest(
        categories: model.categories,
        volume: selectedVolume
      )
    )
  }

  private var computerCategories: [StorageCategory] {
    breakdown.categories.filter { category in
      category.id.hasPrefix("computer-") || category.id == "other-storage"
    }
  }

  private var developerCategories: [StorageCategory] {
    breakdown.categories.filter { category in
      !category.id.hasPrefix("computer-") && category.id != "other-storage"
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        StorageVolumeCoverageView(
          volumes: volumes,
          selectedVolumeID: $selectedVolumeID,
          selectedVolume: selectedVolume,
          coverage: breakdown.coverage
        )

        Divider()

        List(selection: $selectedCategoryID) {
          Section("Computer") {
            ForEach(computerCategories) { category in
              StorageCategoryLabel(category: category)
                .tag(category.id)
            }
          }

          Section("Developer") {
            ForEach(developerCategories) { category in
              StorageCategoryLabel(category: category)
                .tag(category.id)
            }
          }
        }
        .listStyle(.sidebar)
      }
      .frame(minWidth: 280, idealWidth: 310, maxWidth: 340)
      .background(.regularMaterial)

      Divider()

      if let selectedCategory {
        StorageCategoryDetail(
          category: selectedCategory,
          volumeName: selectedVolume.name
        )
      } else {
        ContentUnavailableView("Select a category", systemImage: "internaldrive")
      }
    }
    .onChange(of: selectedVolumeID) { _, _ in
      selectedCategoryID = breakdown.categories.first?.id
    }
    .onChange(of: model.categories) { _, _ in
      if selectedCategory == nil {
        selectedCategoryID = breakdown.categories.first?.id
      }
    }
  }
}

private struct StorageVolumeCoverageView: View {
  let volumes: [StorageVolumeContext]
  @Binding var selectedVolumeID: String
  let selectedVolume: StorageVolumeContext
  let coverage: StorageVolumeCoverage

  private var usedRatio: Double {
    guard selectedVolume.totalBytes > 0 else {
      return 0
    }

    return Double(selectedVolume.usedBytes) / Double(selectedVolume.totalBytes)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("Disk", selection: $selectedVolumeID) {
        ForEach(volumes) { volume in
          Text(volume.name).tag(volume.id)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      HStack(alignment: .firstTextBaseline) {
        Text(ByteText.full(selectedVolume.totalBytes))
          .font(.title3.weight(.semibold))
          .monospacedDigit()
        Text("capacity")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }

      ProgressView(value: usedRatio)
        .tint(usedRatio >= 0.9 ? .red : .accentColor)

      HStack {
        Text("\(ByteText.full(selectedVolume.usedBytes)) used")
        Spacer()
        Text("\(ByteText.full(selectedVolume.availableBytes)) free")
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      Divider()

      CoverageValueRow(
        color: .blue,
        title: "Storage classified",
        value: coverage.identifiedBytes
      )
      CoverageValueRow(
        color: .secondary,
        title: "Other files & macOS",
        value: coverage.otherBytes
      )

      Text("Known developer categories plus the exact remaining used space")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
  }
}

private struct CoverageValueRow: View {
  let color: Color
  let title: String
  let value: UInt64

  var body: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(title)
        .font(.caption)
      Spacer()
      Text(ByteText.full(value))
        .font(.caption.weight(.semibold))
        .monospacedDigit()
    }
  }
}

private struct StorageCategoryLabel: View {
  let category: StorageCategory

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: category.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(category.name)
          .fontWeight(.medium)
        Text(category.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Text(ByteText.compact(category.bytes))
        .monospacedDigit()
    }
    .padding(.vertical, 4)
  }
}

private struct StorageCategoryDetail: View {
  let category: StorageCategory
  let volumeName: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(category.name)
            .font(.title2.weight(.semibold))
          Text(category.detail)
            .foregroundStyle(.secondary)
          Text("On \(volumeName)")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer()
        Text(ByteText.full(category.bytes))
          .font(.title2.weight(.semibold))
          .monospacedDigit()
      }
      .padding(18)

      Divider()

      if category.id == "other-storage" {
        ContentUnavailableView {
          Label("Everything outside the developer scan", systemImage: "internaldrive")
        } description: {
          Text(
            "This is the exact remainder after subtracting the developer categories "
              + "listed here. It includes macOS, applications, documents, media, "
              + "and data \(AppBrand.name) does not classify yet."
          )
        }
      } else {
        List(category.items) { item in
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
              Text(item.name)
                .lineLimit(1)
              Text(item.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer()
            Text(ByteText.full(item.bytes))
              .monospacedDigit()
            Button {
              NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: item.path)
              ])
            } label: {
              Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
          }
          .padding(.vertical, 5)
        }
        .listStyle(.inset)
      }
    }
  }
}
