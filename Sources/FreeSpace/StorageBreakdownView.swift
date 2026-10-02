import AppKit
import SwiftUI

struct DeveloperCleanupView: View {
  @ObservedObject var model: StorageBreakdownModel
  @State private var ageThreshold = 0
  @State private var dependencyLimit = 20
  @State private var dependencySort = DependencySort.largest
  @State private var dependencyVisibility = DependencyVisibility.canDelete
  @State private var dependencySearch = ""
  @State private var showsAllSimulators = false

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

  private var displayedNodeItems: [StorageItem] { Array(nodeItems.prefix(dependencyLimit)) }

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

  private var deletableNodeItems: [StorageItem] {
    allNodeItems.filter { item in
      item.cleanupAvailability?.isReady == true
    }
  }

  private var inUseNodeCount: Int {
    allNodeItems.filter { item in
      item.activeProcesses?.isEmpty == false
    }.count
  }

  var body: some View {
    VStack(spacing: 12) {
      CleanupSection(
        title: "Dependencies",
        detail:
          "\(ByteText.full(allNodeItems.reduce(0) { $0 + $1.bytes })) · \(allNodeItems.count) project folders",
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
          ForEach(displayedNodeItems) { item in
            CleanupItemRow(
              item: item,
              isSelected: model.selectedPaths.contains(item.path),
              onSelectionChange: { selection in
                model.setSelected(selection)
              },
              onStopAndSelect: { model.stopProcessesAndSelect($0) },
              isStoppingProcesses: model.stoppingProcessPath == item.path
            )
          }
        }
        if nodeItems.count > dependencyLimit {
          Button("Show next \(min(20, nodeItems.count - dependencyLimit)) folders") {
            dependencyLimit += 20
          }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
      }
      .onChange(of: dependencySearch) { _, _ in dependencyLimit = 20 }
      .onChange(of: dependencySort) { _, _ in dependencyLimit = 20 }
      .onChange(of: dependencyVisibility) { _, _ in dependencyLimit = 20 }
      .onChange(of: ageThreshold) { _, _ in dependencyLimit = 20 }

      if !generatedItems.isEmpty {
        CleanupSection(
          title: "Build caches",
          detail:
            "\(ByteText.full(generatedItems.reduce(0) { $0 + $1.bytes })) · npm, Vercel, and Trigger outputs",
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
        title: "Simulators",
        detail: "\(model.simulatorDeviceCount) devices · \(model.bootedSimulatorCount) running",
        systemImage: "iphone.gen3"
      ) {
        if model.simulatorDevices.isEmpty && model.isScanning {
          SectionLoadingRow(text: "Reading simulator devices…")
        } else {
          ForEach(displayedSimulators) { device in
            SimulatorDeviceRow(device: device)
          }
          if model.simulatorDevices.count > 5 {
            Button(
              showsAllSimulators
                ? "Show fewer" : "Show all \(model.simulatorDevices.count) devices"
            ) { showsAllSimulators.toggle() }
            .blitzButton(.quiet).controlSize(.small)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
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
  }

  private var nodeControls: some View {
    VStack(spacing: 9) {
      HStack(spacing: 10) {
        BlitzSegmentedPicker(
          title: "Status", options: [DependencyVisibility.canDelete, .inUse, .all],
          selection: $dependencyVisibility,
          label: { value in
            switch value {
            case .canDelete: "Can delete \(deletableNodeItems.count)"
            case .inUse: "In use \(inUseNodeCount)"
            case .all: "All \(allNodeItems.count)"
            }
          }
        ).frame(width: 330)

        BlitzSearchField(title: "Find a project or path", text: $dependencySearch)
          .frame(minWidth: 180)

      }
      HStack(alignment: .top, spacing: 12) {
        BlitzSegmentedPicker(
          title: "Age", options: [0, 7, 30, 90], selection: $ageThreshold,
          label: { $0 == 0 ? "Any age" : "\($0)+ days" })
        BlitzSegmentedPicker(
          title: "Sort", options: DependencySort.allCases, selection: $dependencySort,
          label: { $0.rawValue }
        ).frame(width: 200)
      }

      HStack {
        Text(
          "\(displayedNodeItems.count) of \(nodeItems.count) matches · "
            + "\(ByteText.full(nodeItems.reduce(0) { $0 + $1.bytes }))"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Spacer()

        Button("Select visible") {
          for item in displayedNodeItems where item.cleanupAvailability?.isReady == true {
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

  private var displayedSimulators: [SimulatorDeviceInfo] {
    let sorted = model.simulatorDevices.sorted { left, right in
      let leftBooted = left.state == "Booted"
      let rightBooted = right.state == "Booted"
      return leftBooted != rightBooted ? leftBooted : left.bytes > right.bytes
    }
    return showsAllSimulators ? sorted : Array(sorted.prefix(5))
  }
}
struct DeveloperCleanupActions: View {
  @ObservedObject var model: StorageBreakdownModel
  @State private var showsConfirmation = false

  var body: some View {
    VStack(spacing: 0) {
      if !model.selectedItems.isEmpty || model.isCleaning || model.cleanupMessage != nil {
        cleanupBar
      }
      if showsConfirmation {
        BlitzConfirmation(
          title: "Delete selected items permanently?",
          message:
            "\(model.selectedItems.count) items, \(ByteText.full(model.selectedBytes)). This cannot be undone. Rebuild and activity checks run before deletion; changed or busy items are skipped.\n\n"
            + model.selectedItems.map(\.path).joined(separator: "\n"),
          confirmTitle: "Delete permanently",
          onConfirm: {
            showsConfirmation = false
            model.cleanSelected()
          }, onCancel: { showsConfirmation = false })
      }
    }
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

        Button("Review selected…") {
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

private struct CleanupSection<Content: View>: View {
  let title: String
  let detail: String
  let systemImage: String
  @ViewBuilder let content: Content

  var body: some View {
    BlitzStorageSection(title: title, symbol: systemImage, detail: detail) {
      content
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
        .toggleStyle(BlitzCheckboxStyle(showsLabel: false))
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
          Text("\(processes.count) running")
            .font(.system(size: 11)).foregroundStyle(.orange)
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

        BlitzActionMenu(label: "Actions for \(item.name)") {
          Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
          }
          if let processes = item.activeProcesses, !processes.isEmpty {
            Button(showsProcesses ? "Hide running processes" : "Show running processes") {
              showsProcesses.toggle()
            }
          }
        }
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

private struct RunningProcessesDetail: View {
  let item: StorageItem
  let processes: [ProjectProcessInfo]
  let isStopping: Bool
  let onStopAndSelect: (StorageItem) -> Void
  @State private var reviewingStop = false

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
          Button("Stop and select…") {
            reviewingStop = true
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

      if reviewingStop {
        BlitzConfirmation(
          title: "Stop running processes?",
          message:
            "Stopping these listed processes can discard unsaved work. Dependencies are selected only after a rescan.",
          confirmTitle: "Stop and select",
          onConfirm: {
            reviewingStop = false
            onStopAndSelect(item)
          }, onCancel: { reviewingStop = false })
      }
    }
    .padding(.leading, 50)
    .padding(.trailing, 14)
    .padding(.vertical, 10)
    .background(.orange.opacity(0.055))
    .overlay(alignment: .top) {
      BlitzRowDivider(leading: 42)
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

      if device.state == "Booted" {
        Text("Running")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.green)
      }

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

struct DockerStorageView: View {
  @ObservedObject var model: DockerStorageModel
  @State private var showsConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Containers and volumes are protected")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        Button("Refresh Docker") { model.refresh() }
          .disabled(model.isRefreshing || model.isCleaning)
      }
      if let errorMessage = model.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
          .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
      }

      if let snapshot = model.snapshot {
        DockerCategorySection(snapshot: snapshot)
      } else if model.isRefreshing {
        SectionLoadingRow(text: "Reading images, containers, volumes, and build cache…")
      } else if !model.isInstalled {
        ContentUnavailableView(
          "Docker Not Installed",
          systemImage: "shippingbox",
          description: Text("Install Docker Desktop to see its native storage breakdown.")
        )
      }
      dockerCleanupBar
      if showsConfirmation {
        BlitzConfirmation(
          title: "Clean rebuildable Docker data?",
          message:
            "Unused images and build cache will be deleted permanently. Containers and volumes will not be deleted.",
          confirmTitle: "Clean Docker",
          onConfirm: {
            showsConfirmation = false
            model.cleanRebuildable()
          }, onCancel: { showsConfirmation = false })
      }
    }.padding(16)
      .task { model.refreshIfNeeded() }
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

        Button("Review Docker cleanup…") {
          showsConfirmation = true
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          (model.snapshot?.rebuildableBytes ?? 0) == 0
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
          Text("Allocated storage")
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
