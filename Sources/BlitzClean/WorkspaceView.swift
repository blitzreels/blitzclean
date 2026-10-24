import AppKit
import SwiftUI

struct WorkspaceProjectsView: View {
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var controller: WorkspaceController
  @ObservedObject var monitor: SystemMonitor
  @StateObject var repos = RepoWorkspaceModel()
  @State var expandedIdle: Set<String> = []
  @State private var query = ""
  @State private var editing: WorkspacePreference?
  @State private var pending: LeftoverAction?
  @State private var showsAllLeftovers = false
  @StateObject var docker = DockerProjectsModel()

  private static let leftoverLimit = 8

  var body: some View {
    Group {
      if let editing {
        WorkspaceEditor(
          preference: editing, controller: controller, onClose: { self.editing = nil })
      } else {
        projectList
      }
    }
  }

  private var projectList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        if let action = processes.projectAction {
          BlitzStatusLine(text: action, tone: .working)
        }
        if let status = controller.status ?? processes.statusMessage ?? repos.message {
          BlitzStatusLine(text: status, tone: .working)
        }
        if let message = docker.message { BlitzStatusLine(text: message, tone: .working) }
        sections
      }.padding(BlitzUI.pagePadding)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let action = pending {
        BlitzConfirmation(
          title: action.title, message: action.message, confirmTitle: action.confirmTitle,
          onConfirm: {
            pending = nil
            processes.quitLeftovers(.init(targets: action.processes, force: action.force))
          }, onCancel: { pending = nil })
      }
    }
    .navigationTitle("Projects")
    .task {
      while !Task.isCancelled {
        docker.refresh()
        try? await Task.sleep(for: .seconds(RefreshCadence.interval(.docker)))
      }
    }
    .onChange(of: controller.preferences) { processes.updateProjectTargets() }
    .onChange(of: processes.scannedAt, initial: true) { readRepositories() }
    .safeAreaInset(edge: .top, spacing: 0) {
      HStack(spacing: 8) {
        BlitzSearchField(title: "Search projects, paths or ports", text: $query)
        Button("Add project", systemImage: "plus") { chooseProject() }.blitzButton(.secondary)
      }.padding(.horizontal, BlitzUI.pagePadding).padding(.vertical, 12)
        .background(BlitzUI.canvasBackground)
    }
  }

  private var filteredProjects: [WorkspaceProject] {
    WorkspaceCatalog.includingDocker(
      .init(
        projects: processes.projects(controller.preferences),
        containers: docker.snapshot?.containers ?? [])
    ).filter { project in
      query.isEmpty || project.preference.name.localizedCaseInsensitiveContains(query)
        || project.directory.localizedCaseInsensitiveContains(query)
        || project.servers.flatMap(\.listeningPorts).contains { String($0).contains(query) }
    }
  }

  @ViewBuilder private var sections: some View {
    let projects = filteredProjects
    let grouped = RepoGrouping.group(
      .init(
        projects: projects,
        agents: processes.threads.filter { query.isEmpty || $0.matches(query) },
        checkouts: repos.checkouts, worktrees: repos.worktrees))
    let leftovers: [LeftoverProcess] = processes.visibleLeftovers.filter {
      query.isEmpty || $0.matches(query)
    }
    let stopped = projects.filter { !$0.isRunning }
    if query.isEmpty, !processes.threads.isEmpty {
      AgentBudgetCard(
        budget: AgentBudget.make(
          .init(
            agents: processes.threads, availableBytes: monitor.snapshot.ramAvailable,
            pressure: processes.pressure.risk)),
        pressure: processes.pressure.risk)
    }
    if !grouped.repos.isEmpty { repoSection(grouped.repos) }
    if !grouped.others.isEmpty { section("Other running folders", grouped.others) }
    if let message = processes.leftoverMessage {
      BlitzStatusLine(text: message, tone: .working)
    }
    if !leftovers.isEmpty { leftoverSection(leftovers) }
    if !processes.hiddenLeftoverNames.isEmpty, query.isEmpty { hiddenLeftoversLine }
    if !stopped.isEmpty { section("Saved projects", stopped) }
    if projects.isEmpty && leftovers.isEmpty {
      Text(
        query.isEmpty
          ? "No projects yet. Running projects appear here; use Add project to save one."
          : "No projects match this search"
      ).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
    }
  }

  private func section(_ title: String, _ projects: [WorkspaceProject]) -> some View {
    let lastID = projects.last?.id
    return VStack(alignment: .leading, spacing: 10) {
      BlitzSectionHeader(title: title, count: projects.count) {}
      LazyVStack(spacing: 0) {
        ForEach(projects) { project in
          projectRow(project)
          if project.id != lastID { BlitzRowDivider(leading: 62) }
        }
      }.blitzTable()
    }
  }

  private func projectRow(_ project: WorkspaceProject) -> some View {
    let busy =
      processes.actingProjects.contains(project.directory)
      || docker.acting.contains(project.directory)
      || project.servers.contains { processes.stoppingIDs.contains($0.id) }
    return HStack(spacing: 14) {
      ProjectIcon(
        directory: project.directory, processName: "", size: 32,
        fallbackSymbol: "folder.fill")
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(project.preference.name).font(BlitzType.rowTitle).lineLimit(1)
          if processes.projectTargets[project.directory]?.isPaused == true {
            BlitzStatusBadge(title: "Paused", tone: .warning)
          }
          if project.preference.keepRunning {
            Image(systemName: "lock").font(.system(size: 10))
              .foregroundStyle(BlitzUI.secondaryText).help("This project is kept running")
          }
        }
        Text(
          project.directory.hasPrefix("docker:")
            ? "Docker · project not assigned"
            : project.directory.replacingOccurrences(
              of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        )
        .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        .lineLimit(1).truncationMode(.middle)
        portLinks(project)
        if project.isRunning, let impact = stopImpact(project) {
          Text(impact).font(BlitzType.caption).foregroundStyle(BlitzUI.tertiaryText)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        if let message = processes.projectMessages[project.directory] {
          Text(message).font(BlitzType.caption).foregroundStyle(BlitzUI.supportingText)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 16)
      BlitzTrailingValue(
        value: project.resources.isEmpty && !project.containers.isEmpty
          ? "—" : ByteText.full(project.memoryBytes),
        detail: project.resources.isEmpty && !project.containers.isEmpty
          ? "Container RAM unavailable"
          : "\(project.resources.count) processes in this folder · \(Int(project.cpuPercent))% CPU"
      ).fixedSize()
        .help(
          "Memory measures local host processes. Container memory belongs to Docker's virtual machine."
        )
      ZStack(alignment: .trailing) {
        Color.clear
        if processes.projectTargets[project.directory] != nil
          || project.containers.contains(where: \.running)
        {
          BlitzProcessButton(
            title: "Stop", label: "Stop \(project.preference.name)", isBusy: busy
          ) { stopWorkspace(project) }
          .disabled(project.preference.keepRunning)
          .help(
            "Stop development workers and associated containers. Database volumes are preserved.")
        } else if !project.servers.isEmpty {
          BlitzProcessButton(
            title: "Stop", label: "Stop \(project.preference.name)", isBusy: busy
          ) { processes.stopProject(project.servers.map { processes.stopRequest($0) }) }
          .disabled(project.preference.keepRunning)
          .help("Stop this project's local servers.")
        } else if !project.containers.isEmpty {
          BlitzProcessButton(
            title: "Start", label: "Start \(project.preference.name)", isBusy: busy
          ) {
            Task {
              _ = await docker.apply(
                .init(directory: project.directory, containers: project.containers, start: true))
            }
          }
        } else if project.preference.startCommand != nil {
          BlitzProcessButton(
            title: "Start", label: "Start \(project.preference.name)",
            isBusy: controller.starting.contains(project.id)
          ) {
            controller.start(
              .init(preference: project.preference, existingServers: project.servers))
            processes.refresh()
          }
        }
      }.frame(width: 96, height: 34)
      BlitzActionMenu(label: "Options for \(project.preference.name)") {
        projectMenu(project)
      }.disabled(busy)
    }.blitzRow()
  }

  @ViewBuilder func portLinks(_ project: WorkspaceProject) -> some View {
    let ports = project.servers.flatMap { server in
      server.listeningPorts.map { (name: server.name, port: $0) }
    }
    if !ports.isEmpty {
      HStack(spacing: 6) {
        ForEach(ports.prefix(4), id: \.port) { item in
          Button {
            if let url = URL(string: "http://localhost:\(item.port)") {
              NSWorkspace.shared.open(url)
            }
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "globe").font(.system(size: 9, weight: .semibold))
              Text("localhost:\(String(item.port))").monospacedDigit()
            }
            .font(BlitzType.caption).foregroundStyle(BlitzUI.supportingText)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.white.opacity(0.06), in: .capsule)
          }.buttonStyle(.plain).blitzPointingHand()
            .help("Open \(item.name) at http://localhost:\(String(item.port))")
        }
      }
    }
  }

  @ViewBuilder func projectMenu(_ project: WorkspaceProject) -> some View {
    if let target = processes.projectTargets[project.directory] {
      Button(target.isPaused ? "Resume workers" : "Suspend workers — keeps memory") {
        processes.pauseProject(target)
      }
      .disabled(project.preference.keepRunning && !target.isPaused)
      Divider()
    }
    let autoPause = processes.autoPauseDirectories.contains(project.directory)
    Button {
      processes.setAutoPause(.init(directory: project.directory, enabled: !autoPause))
    } label: {
      MenuCheckLabel(title: "Pause automatically under pressure", isOn: autoPause)
    }
    .disabled(
      project.preference.keepRunning || processes.projectTargets[project.directory] == nil)
    if !project.containers.isEmpty {
      Button("Assign containers to project…") {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
          docker.assign(.init(containers: project.containers, directory: url.path))
        }
      }
    }
    if !project.directory.hasPrefix("docker:") {
      Button("Configure project…") { editing = project.preference }
      Button {
        controller.keep(
          .init(preference: project.preference, keep: !project.preference.keepRunning))
      } label: {
        MenuCheckLabel(title: "Keep running", isOn: project.preference.keepRunning)
      }
    }
  }

  /// Plain account of what Stop ends and what it leaves alone.
  func stopImpact(_ project: WorkspaceProject) -> String? {
    let processCount =
      processes.projectTargets[project.directory]?.identities.count ?? project.servers.count
    let containers = project.containers.filter(\.running).count
    guard processCount > 0 || containers > 0 else { return nil }
    var ends: [String] = []
    if processCount > 0 {
      ends.append(processCount == 1 ? "1 dev process" : "\(processCount) dev processes")
    }
    if containers > 0 {
      ends.append(containers == 1 ? "1 Docker container" : "\(containers) Docker containers")
    }
    let stopped = min(
      project.memoryBytes,
      processes.projectTargets[project.directory]?.memoryBytes
        ?? project.servers.reduce(0) { $0 + $1.memoryBytes })
    let frees = stopped > 0 ? " and frees about \(ByteText.compact(stopped))" : ""
    return
      "Stop ends \(ends.joined(separator: " and "))\(frees). Code, files and database volumes stay."
  }

  func stopWorkspace(_ project: WorkspaceProject) {
    if let target = processes.projectTargets[project.directory] {
      processes.stopProjectWorkers(target)
    } else if !project.servers.isEmpty {
      processes.stopProject(project.servers.map { processes.stopRequest($0) })
    }
    if !project.containers.isEmpty {
      Task {
        _ = await docker.apply(
          .init(directory: project.directory, containers: project.containers, start: false))
      }
    }
  }

  private func leftoverSection(_ leftovers: [LeftoverProcess]) -> some View {
    let visible =
      showsAllLeftovers || !query.isEmpty ? leftovers : Array(leftovers.prefix(Self.leftoverLimit))
    let stopping = !processes.stoppingLeftovers.isEmpty
    return VStack(alignment: .leading, spacing: 10) {
      BlitzSectionHeader(title: "Leftover processes", count: leftovers.count) {
        if leftovers.count > 1 {
          Button("Quit \(leftovers.count)…") { pending = .quit(leftovers) }
            .blitzButton(.secondary).controlSize(.small).disabled(stopping || pending != nil)
            .help("Ask every listed process to quit")
        }
      }
      LazyVStack(spacing: 0) {
        ForEach(visible) { process in
          leftoverRow(process)
          if process.id != visible.last?.id { BlitzRowDivider(leading: 56) }
        }
      }.blitzTable()
      if leftovers.count > Self.leftoverLimit, query.isEmpty {
        BlitzShowAllButton(
          total: leftovers.count, noun: "processes", isExpanded: $showsAllLeftovers)
      }
    }
  }

  private func leftoverRow(_ process: LeftoverProcess) -> some View {
    LeftoverProcessRow(
      process: process, isBusy: processes.stoppingLeftovers.contains(process.processID),
      onQuit: { processes.quitLeftovers(.init(targets: [process], force: false)) },
      onForceQuit: { pending = .forceQuit(process) },
      onHide: { processes.setLeftoverName(.init(name: process.executableName, hidden: true)) })
  }

  private var hiddenLeftoversLine: some View {
    HStack(spacing: 8) {
      Text("Hidden leftovers: \(processes.hiddenLeftoverNames.joined(separator: ", "))")
        .font(BlitzType.caption).foregroundStyle(BlitzUI.tertiaryText).lineLimit(1)
        .truncationMode(.tail)
      Button("Show again") { processes.showHiddenLeftovers() }
        .blitzButton(.quiet).controlSize(.small)
    }
  }

  private func chooseProject() {
    guard let path = Finder.chooseFolder() else { return }
    editing = WorkspacePreference(
      directory: WorkspacePreferences.canonical(path),
      name: URL(fileURLWithPath: path).lastPathComponent, keepRunning: false, startCommand: nil)
  }
}

private struct WorkspaceEditor: View {
  @State var preference: WorkspacePreference
  @ObservedObject var controller: WorkspaceController
  let onClose: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Project setup").font(BlitzType.title)
      Text(preference.directory).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        .textSelection(.enabled)
      VStack(alignment: .leading, spacing: 8) {
        Text("Project name").font(BlitzType.rowTitle)
        TextField("Project name", text: $preference.name).blitzInput()
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("Start command").font(BlitzType.rowTitle)
        TextField(
          "For example: pnpm dev",
          text: Binding(
            get: { preference.startCommand ?? "" },
            set: { preference.startCommand = $0.isEmpty ? nil : $0 })
        )
        .blitzInput().font(.system(.body, design: .monospaced))
        Text(
          "Runs in this folder, using your zsh environment, only when you click Start. Use a foreground server command."
        )
        .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      }
      Toggle("Keep this project running", isOn: $preference.keepRunning)
        .toggleStyle(BlitzSwitchStyle()).font(BlitzType.callout)
      HStack {
        Spacer()
        Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction).blitzButton(.secondary)
        Button("Save") {
          controller.save(preference)
          onClose()
        }.keyboardShortcut(.defaultAction).blitzButton(.accent)
          .disabled(preference.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(BlitzUI.pagePadding).frame(
      maxWidth: 680, maxHeight: .infinity, alignment: .topLeading
    )
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension MemoryIncident {
  /// Recovery entries show "App · Result"; older entries stored signal and hedging text.
  var displayTitle: String {
    if kind == "pressure" {
      let legacy = [
        "Memory stable": MemoryRisk.normal.title, "Memory demand rising": MemoryRisk.growing.title,
        "Memory needs attention": MemoryRisk.warning.title,
        "Memory pressure critical": MemoryRisk.critical.title,
      ]
      return legacy[detail] ?? detail
    }
    guard kind == "app-recovery", let split = detail.range(of: ": ") else { return detail }
    let name = detail[..<split.lowerBound]
    let rest = detail[split.upperBound...]
    let stored = rest.prefix { $0 != "." }.trimmingCharacters(in: .whitespaces)
    let legacy = [
      "Resume sent · check the app": "Revived",
      "Process resumed · check the window": "Revived",
      "Responding after resume": "Revived",
      "App is responding": "Running",
      "No window response": "Not responding",
      "Response not verified": "Checked",
      "Recovery unavailable": "Couldn't revive",
    ]
    return "\(name) · \(legacy[stored] ?? stored)"
  }
}
