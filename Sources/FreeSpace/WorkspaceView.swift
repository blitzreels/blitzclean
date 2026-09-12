import AppKit
import SwiftUI

enum WorkspaceSection: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case projects = "Projects"
  case workers = "AI workers"
  case worktrees = "Worktrees"
  case dependencies = "Dependencies"
  case storage = "Storage"
  case incidents = "Incidents"
  case settings = "Settings"
  var id: Self { self }
  var symbol: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .projects: "folder"
    case .workers: "point.3.connected.trianglepath.dotted"
    case .worktrees: "arrow.triangle.branch"
    case .dependencies: "shippingbox"
    case .storage: "internaldrive"
    case .incidents: "waveform.path.ecg"
    case .settings: "gearshape"
    }
  }
}

struct WorkspaceView: View {
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var memory: MemoryRescueModel
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var workspaces: WorkspaceController
  @ObservedObject var storage: StorageBreakdownModel
  @ObservedObject var docker: DockerStorageModel
  @ObservedObject var storageNavigation: StorageNavigationModel
  @ObservedObject var folders: FolderExplorerModel
  @ObservedObject var developerBrowser: DeveloperBrowserModel
  @Environment(\.openWindow) private var openWindow
  @State var section: WorkspaceSection? = .overview

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(spacing: 10) {
          BrandMark()
          VStack(alignment: .leading, spacing: 2) {
            Text(AppBrand.name).font(.title3.bold())
            Text("Developer tools").font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 16).padding(.top, 20)
        List(WorkspaceSection.allCases, selection: $section) { page in
          Label(page.rawValue, systemImage: page.symbol).tag(page)
            .padding(.vertical, 5)
        }
        .listStyle(.sidebar)
        VStack(alignment: .leading, spacing: 8) {
          Label(memory.risk.title, systemImage: "circle.fill")
            .foregroundStyle(memory.risk.tone.color)
          Text("Local tools. Your control.").foregroundStyle(.secondary)
          Text("v1.0 · Open source").foregroundStyle(.tertiary)
        }
        .font(.caption).padding(16)
      }
      .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
    } detail: {
      Group {
        switch section ?? .overview {
        case .overview: overview
        case .projects: WorkspaceProjectsView(processes: processes, controller: workspaces)
        case .workers: WorkerOwnershipView(model: processes)
        case .worktrees:
          DeveloperBrowserView(
            kind: .worktree, model: developerBrowser, processes: processes,
            workspaces: workspaces, history: storage.overview)
        case .dependencies:
          DeveloperBrowserView(
            kind: .dependencies, model: developerBrowser, processes: processes,
            workspaces: workspaces, history: storage.overview)
        case .storage:
          StorageBreakdownView(
            model: storage, monitor: monitor, dockerStorage: docker,
            navigation: storageNavigation, folderExplorer: folders)
        case .incidents: IncidentTimelineView(model: memory)
        case .settings: WorkspaceSettingsView(memory: memory, storage: storage)
        }
      }
      .toolbar {
        ToolbarItemGroup {
          Button("Review apps", systemImage: "memorychip") { openWindow(id: "memory-rescue") }
          Button("Refresh", systemImage: "arrow.clockwise") {
            monitor.refresh()
            memory.refresh()
            processes.refresh()
          }
          .disabled(processes.isRefreshing)
        }
      }
    }
    .tint(AppBrand.accent)
    .frame(minWidth: 1100, minHeight: 720)
  }

  private var overview: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Make room for your next build.").font(.system(size: 30, weight: .semibold))
          Text("Clear the leftovers. Know what’s running. Keep the work that matters.")
            .font(.title3).foregroundStyle(.secondary)
        }
        HStack(spacing: 14) {
          OverviewMetric(
            title: "AVAILABLE STORAGE", value: ByteText.full(monitor.snapshot.diskAvailable),
            detail: "\(DiskSpacePolicy.reserveLabel) healthy reserve", symbol: "internaldrive",
            color: .primary)
          OverviewMetric(
            title: "MEMORY PRESSURE", value: memory.pressure.title,
            detail: "Swap \(memory.sample?.swapUsed.map(ByteText.full) ?? "unavailable")",
            symbol: "memorychip", color: memory.risk.tone.color)
          OverviewMetric(
            title: "BACKGROUND TOOLS", value: "\(processes.resources.filter(\.isTool).count)",
            detail: ByteText.full(
              processes.resources.filter(\.isTool).compactMap(\.memoryBytes).reduce(0, +))
              + " observed footprint",
            symbol: "terminal", color: .primary)
        }
        HStack(alignment: .top, spacing: 18) {
          VStack(alignment: .leading, spacing: 16) {
            HStack {
              Text("Your projects").font(.headline)
              Spacer()
              Button("Manage") { section = .projects }.buttonStyle(.link)
            }
            let projects = WorkspaceCatalog.projects(
              .init(
                resources: processes.resources, processes: processes.processes,
                preferences: workspaces.preferences))
            ForEach(projects.prefix(5)) { project in
              HStack(spacing: 12) {
                ProjectIcon(
                  directory: project.directory, processName: "", size: 28,
                  fallbackSymbol: "folder.fill")
                VStack(alignment: .leading, spacing: 4) {
                  Text(project.preference.name).font(.callout.weight(.medium))
                  Text("\(project.resources.count) processes · \(project.servers.count) servers")
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(ByteText.compact(project.memoryBytes)).monospacedDigit()
              }
              Divider()
            }
            if projects.isEmpty {
              Text("Running project folders appear here.").foregroundStyle(.secondary)
            }
            Text(
              "Pin projects you want to keep running. Saved projects remain available after their servers stop."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .topLeading).panelCard(padding: 20)
          VStack(alignment: .leading, spacing: 16) {
            Text("Understand the footprint").font(.headline)
            Text("An AI app’s total includes the tools, builds and browsers it launches.")
              .font(.callout).foregroundStyle(.secondary)
            ForEach(Array(ResourceOwnership.groups(processes.resources.filter(\.isTool)).prefix(4)))
            { group in
              HStack {
                VStack(alignment: .leading, spacing: 3) {
                  Text(group.name).font(.callout)
                  Text("\(group.processCount) processes · \(group.owner)")
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(ByteText.compact(group.memoryBytes)).monospacedDigit()
              }
            }
            Button("Inspect AI workers") { section = .workers }.buttonStyle(.borderedProminent)
            Text(
              "Repeated processes are worth reviewing; their count alone does not prove they are abandoned."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .topLeading).panelCard(padding: 20)
        }
        HStack(spacing: 16) {
          Image(systemName: "externaldrive.badge.minus").font(.largeTitle).foregroundStyle(
            AppBrand.accent)
          VStack(alignment: .leading, spacing: 5) {
            Text("Storage that comes back to you").font(.headline)
            Text(
              "Review rebuildable caches and large files, then see the space actually recovered."
            )
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Review storage") { section = .storage }.buttonStyle(.borderedProminent)
        }
        .panelCard(padding: 20)
        if let incident = memory.incidents.first(where: {
          $0.kind == "pressure" && $0.sample?.pressure == .critical
        }) {
          HStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg").foregroundStyle(.orange).font(.title2)
            VStack(alignment: .leading, spacing: 5) {
              Text("Last critical memory incident").font(.headline)
              Text(incident.date, format: .dateTime.month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("See what happened") { section = .incidents }
          }.panelCard(padding: 20)
        }
      }.padding(28)
    }
    .navigationTitle("Overview")
  }
}

private struct OverviewMetric: View {
  let title: String
  let value: String
  let detail: String
  let symbol: String
  let color: Color
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: symbol).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 27, weight: .semibold)).foregroundStyle(color)
        .monospacedDigit()
      Text(detail).font(.caption).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading).panelCard(padding: 20)
  }
}

struct WorkspaceProjectsView: View {
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var controller: WorkspaceController
  @State private var editing: WorkspacePreference?
  @State private var stopping: WorkspaceProject?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        HStack {
          VStack(alignment: .leading, spacing: 6) {
            Text("Keep the right projects running.").font(.title.bold())
            Text("Your choice persists. Servers stop only when you ask.").foregroundStyle(
              .secondary)
          }
          Spacer()
          Button("Add project", systemImage: "plus") { chooseProject() }
        }
        if let status = controller.status ?? processes.statusMessage {
          Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
        let projects = WorkspaceCatalog.projects(
          .init(
            resources: processes.resources, processes: processes.processes,
            preferences: controller.preferences))
        ForEach(projects) { project in
          VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 14) {
              ProjectIcon(
                directory: project.directory, processName: "", size: 40,
                fallbackSymbol: "folder.fill")
              VStack(alignment: .leading, spacing: 5) {
                Text(project.preference.name).font(.headline)
                Text(project.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  .truncationMode(.middle)
              }
              Spacer()
              VStack(alignment: .trailing, spacing: 4) {
                Text(ByteText.full(project.memoryBytes)).font(.title3.weight(.semibold))
                  .monospacedDigit()
                Text("\(project.resources.count) processes · \(project.servers.count) servers")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
            HStack {
              Toggle(
                "Keep running",
                isOn: Binding(
                  get: { project.preference.keepRunning },
                  set: { controller.keep(.init(preference: project.preference, keep: $0)) })
              )
              .toggleStyle(.switch).controlSize(.small)
              Spacer()
              Button("Configure") { editing = project.preference }
              if !project.servers.isEmpty {
                Button("Stop servers") { stopping = project }
                  .disabled(
                    project.preference.keepRunning
                      || project.servers.contains { processes.stoppingIDs.contains($0.id) })
              } else if project.preference.startCommand != nil {
                Button(controller.starting.contains(project.id) ? "Starting…" : "Start") {
                  controller.start(
                    .init(preference: project.preference, existingServers: project.servers))
                  processes.refresh()
                }
                .buttonStyle(.borderedProminent).disabled(controller.starting.contains(project.id))
              } else {
                Button("Set up Start") { editing = project.preference }
              }
            }
            if !project.servers.isEmpty {
              Text(
                project.servers.map {
                  "\($0.name) \($0.listeningPorts.map { ":\($0)" }.joined(separator: ", "))"
                }.joined(separator: " · ")
              )
              .font(.caption).foregroundStyle(.secondary)
            }
          }.panelCard(padding: 20)
        }
        if projects.isEmpty {
          ContentUnavailableView(
            "Add your first project", systemImage: "folder.badge.plus",
            description: Text(
              "Choose a project folder and save its start command. Running projects are also discovered automatically."
            ))
        }
      }.padding(28)
    }
    .navigationTitle("Projects")
    .sheet(item: $editing) { preference in
      WorkspaceEditor(preference: preference, controller: controller)
    }
    .alert(
      "Stop this project's servers?",
      isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } })
    ) {
      Button("Stop servers", role: .destructive) {
        if let project = stopping {
          processes.stopProject(project.servers.map { processes.stopRequest($0) })
        }
        stopping = nil
      }
      Button("Cancel", role: .cancel) { stopping = nil }
    } message: {
      Text(
        (stopping?.servers.map { "\($0.name) · PID \($0.processID)" }.joined(separator: "\n") ?? "")
          + "\n\nLocal pages using these servers will stop responding. AI apps and their tool sessions stay running."
      )
    }
  }

  private func chooseProject() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    editing = WorkspacePreference(
      directory: WorkspacePreferences.canonical(url.path),
      name: url.lastPathComponent, keepRunning: false, startCommand: nil)
  }
}

private struct WorkspaceEditor: View {
  @State var preference: WorkspacePreference
  @ObservedObject var controller: WorkspaceController
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Project setup").font(.title2.bold())
      Text(preference.directory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      TextField("Project name", text: $preference.name)
      VStack(alignment: .leading, spacing: 8) {
        Text("Start command").font(.headline)
        TextField(
          "For example: pnpm dev",
          text: Binding(
            get: { preference.startCommand ?? "" },
            set: { preference.startCommand = $0.isEmpty ? nil : $0 })
        )
        .font(.system(.body, design: .monospaced))
        Text(
          "Runs in this folder, using your zsh environment, only when you click Start. Use a foreground server command."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Toggle("Keep this project running", isOn: $preference.keepRunning)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") {
          controller.save(preference)
          dismiss()
        }.keyboardShortcut(.defaultAction)
          .disabled(preference.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(26).frame(width: 490)
  }
}

struct WorkerOwnershipView: View {
  @ObservedObject var model: DevProcessModel
  @Environment(\.openWindow) private var openWindow
  @State private var stopping: [DevStopRequest] = []
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          VStack(alignment: .leading, spacing: 6) {
            Text("See what your AI tools launch.").font(.title.bold())
            Text("Grouped by tool, parent app and project folder.").foregroundStyle(.secondary)
          }
          Spacer()
          Button("Detailed processes") { openWindow(id: "processes") }
        }
        Text(
          "An app can own many tool processes. A shared project folder does not establish which conversation owns them."
        )
        .font(.callout).foregroundStyle(.secondary)
        if let status = model.statusMessage {
          Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(4)
        }
        ForEach(ResourceOwnership.groups(model.resources.filter(\.isTool))) { group in
          let requests = model.toolStopRequests(group.id)
          let protectedByProject = requests.contains {
            WorkspacePreferences.isKeptRunning($0.process.workingDirectory)
          }
          VStack(alignment: .leading, spacing: 14) {
            ResourceGroupRow(group: group)
            HStack {
              Toggle(
                "Keep running",
                isOn: Binding(
                  get: { model.keptTools.contains(group.id) },
                  set: { model.keepTools(.init(groupID: group.id, keep: $0)) })
              )
              .toggleStyle(.switch).controlSize(.small)
              Spacer()
              Button("Stop tools…") { stopping = model.toolStopRequests(group.id) }
                .disabled(
                  model.keptTools.contains(group.id) || protectedByProject
                    || requests.contains { model.stoppingIDs.contains($0.process.id) })
            }
            if protectedByProject {
              Text(
                "Protected by the project's Keep running setting. Change it in Projects to stop these tools."
              )
              .font(.caption).foregroundStyle(.secondary)
            }
          }.panelCard(padding: 18)
        }
        if !model.resources.contains(where: \.isTool) {
          ContentUnavailableView(
            "No tool workers identified", systemImage: "terminal",
            description: Text("Tool workers appear as your AI apps launch them."))
        }
      }.padding(28)
    }.navigationTitle("AI workers")
      .alert(
        "Stop \(stopping.count) tool processes?",
        isPresented: Binding(get: { !stopping.isEmpty }, set: { if !$0 { stopping = [] } })
      ) {
        Button("Stop these tools", role: .destructive) {
          model.stopTools(stopping)
          stopping = []
        }
        Button("Cancel", role: .cancel) { stopping = [] }
      } message: {
        Text(
          "This disconnects the selected tools and can interrupt their running requests. Check their work first. Your AI app stays open; reconnect tools in that app if needed.\n\nPIDs: "
            + stopping.map { String($0.process.id) }.joined(separator: ", "))
      }
  }
}

struct ResourceGroupRow: View {
  let group: ResourceGroup
  var body: some View {
    HStack(spacing: 14) {
      ProjectIcon(directory: nil, processName: group.name, size: 32, fallbackSymbol: "terminal")
      VStack(alignment: .leading, spacing: 5) {
        Text(group.name).font(.headline)
        Text(([group.owner] + (group.project.map { [$0] } ?? [])).joined(separator: " · "))
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 5) {
        Text(ByteText.full(group.memoryBytes)).font(.callout.weight(.semibold)).monospacedDigit()
        Text(
          "\(group.processCount) processes"
            + (group.unknownMemoryCount > 0 ? " · partial memory reading" : "")
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

struct IncidentTimelineView: View {
  @ObservedObject var model: MemoryRescueModel
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("What happened to my Mac?").font(.title.bold())
          Text(
            "Local memory history from the last 24 hours. Exits alone do not confirm a crash or an OOM."
          )
          .foregroundStyle(.secondary)
        }
        ForEach(
          model.incidents.filter {
            $0.kind == "pressure" || $0.kind == "app-recovery" || $0.kind == "quit"
          }.prefix(50)
        ) { incident in
          VStack(alignment: .leading, spacing: 14) {
            HStack {
              Text(incident.detail).font(.headline)
              Spacer()
              Text(incident.date, format: .dateTime.month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
            }
            if let sample = incident.sample {
              Text(
                "Pressure \(sample.pressure.title.lowercased()) · Swap \(sample.swapUsed.map(ByteText.full) ?? "unknown") · Compressed \(ByteText.full(sample.compressed))"
              )
              .font(.callout).foregroundStyle(.secondary)
            }
            if let groups = incident.resources, !groups.isEmpty {
              ForEach(Array(groups.prefix(5))) { group in ResourceGroupRow(group: group) }
              Text(
                "Largest observed worker groups near this event. Footprint is not guaranteed recoverable RAM."
              )
              .font(.caption).foregroundStyle(.secondary)
            } else {
              ForEach(Array(incident.apps.prefix(3).enumerated()), id: \.offset) { _, app in
                HStack {
                  Text(app.name)
                  Spacer()
                  Text(ByteText.full(app.bytes)).monospacedDigit()
                }
                .font(.callout)
              }
              Text(
                "Only app totals were captured for this event; individual worker attribution is unavailable."
              )
              .font(.caption).foregroundStyle(.secondary)
            }
          }.panelCard(padding: 20)
        }
        if model.incidents.isEmpty {
          ContentUnavailableView(
            "No incidents recorded", systemImage: "checkmark.shield",
            description: Text("Monitoring continues while the menu-bar app is running."))
        }
      }.padding(28)
    }.navigationTitle("Incidents")
  }
}
