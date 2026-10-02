import AppKit
import SwiftUI

struct WorkspaceProjectsView: View {
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var controller: WorkspaceController
  @State private var query = ""
  @State private var editing: WorkspacePreference?

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
        PressureBanner(
          assessment: processes.pressure, actionTitle: "Refresh", onReview: { processes.refresh() })
        if let action = processes.projectAction {
          Text(action).font(BlitzType.body).foregroundStyle(BlitzUI.supportingText)
        }
        if let status = controller.status ?? processes.statusMessage {
          Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
        let projects = WorkspaceCatalog.resolvedProjects(
          .init(
            input: .init(
              resources: processes.resources, processes: processes.processes,
              preferences: controller.preferences), roots: processes.workspaceRoots)
        ).filter { project in
          query.isEmpty || project.preference.name.localizedCaseInsensitiveContains(query)
            || project.directory.localizedCaseInsensitiveContains(query)
            || project.servers.flatMap(\.listeningPorts).contains { String($0).contains(query) }
        }
        let running = projects.filter(\.isRunning)
        let stopped = projects.filter { !$0.isRunning }
        if !running.isEmpty { section("Active projects", running) }
        if !stopped.isEmpty { section("Saved projects", stopped) }
        if projects.isEmpty && !query.isEmpty {
          Text("No projects match this search").foregroundStyle(.secondary)
        } else if projects.isEmpty {
          ContentUnavailableView(
            "Add your first project", systemImage: "folder.badge.plus",
            description: Text(
              "Choose a project folder and save its start command. Running projects are also discovered automatically."
            ))
        }
      }.padding(BlitzUI.pagePadding)
    }
    .navigationTitle("Projects")
    .onChange(of: controller.preferences) { processes.updateProjectTargets() }
    .safeAreaInset(edge: .top, spacing: 0) {
      HStack(spacing: 8) {
        BlitzSearchField(title: "Search projects, paths or ports", text: $query)
        Button("Add project", systemImage: "plus") { chooseProject() }.blitzButton(.secondary)
      }.padding(.horizontal, BlitzUI.pagePadding).padding(.vertical, 12)
        .background(BlitzUI.canvasBackground)
    }
  }

  private func section(_ title: String, _ projects: [WorkspaceProject]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Text(title).font(BlitzType.section)
        Text("\(projects.count)").font(BlitzType.caption).monospacedDigit()
          .foregroundStyle(BlitzUI.tertiaryText)
      }
      LazyVStack(spacing: 0) {
        ForEach(projects) { project in
          projectRow(project)
          if project.id != projects.last?.id { BlitzRowDivider(leading: 62) }
        }
      }.blitzTable()
    }
  }

  private func projectRow(_ project: WorkspaceProject) -> some View {
    let busy =
      processes.actingProjects.contains(project.directory)
      || project.servers.contains { processes.stoppingIDs.contains($0.id) }
    return HStack(spacing: 14) {
      ProjectIcon(
        directory: project.directory, processName: "", size: 32,
        fallbackSymbol: "folder.fill")
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(project.preference.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
          if processes.projectTargets[project.directory]?.isPaused == true {
            BlitzStatusBadge(title: "Paused", tone: .warning)
          }
          if project.preference.keepRunning {
            Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.secondary)
              .help("This project is kept running")
          }
        }
        Text(project.directory).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          .truncationMode(.middle)
        if !project.servers.isEmpty {
          Text(
            project.servers.map {
              "\($0.name) \($0.listeningPorts.map { ":\($0)" }.joined(separator: ", "))"
            }.joined(separator: " · ")
          ).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        if let message = processes.projectMessages[project.directory] {
          Text(message).font(BlitzType.caption).foregroundStyle(BlitzUI.supportingText)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 16)
      VStack(alignment: .trailing, spacing: 4) {
        Text(ByteText.full(project.memoryBytes)).font(.system(size: 13, weight: .medium))
          .monospacedDigit()
        Text("\(project.resources.count) processes · \(Int(project.cpuPercent))% CPU")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }.fixedSize()
      Group {
        if let target = processes.projectTargets[project.directory] {
          BlitzProcessButton(
            title: "Stop", label: "Stop \(project.preference.name)", isBusy: busy
          ) { processes.stopProjectWorkers(target) }
          .disabled(project.preference.keepRunning)
          .help("Stop \(target.identities.count) development processes. AI sessions stay open.")
        } else if !project.servers.isEmpty {
          BlitzProcessButton(
            title: "Stop", label: "Stop \(project.preference.name)", isBusy: busy
          ) { processes.stopProject(project.servers.map { processes.stopRequest($0) }) }
          .disabled(project.preference.keepRunning)
          .help("Stop this project's local servers.")
        } else if project.preference.startCommand != nil {
          Button("Start") {
            controller.start(
              .init(preference: project.preference, existingServers: project.servers))
            processes.refresh()
          }.disabled(controller.starting.contains(project.id))
        }
      }.frame(width: 96, alignment: .trailing)
      BlitzActionMenu(label: "Options for \(project.preference.name)") {
        if let target = processes.projectTargets[project.directory] {
          Button(target.isPaused ? "Resume" : "Pause") { processes.pauseProject(target) }
            .disabled(project.preference.keepRunning && !target.isPaused)
          Divider()
        }
        Toggle(
          "Pause automatically under pressure",
          isOn: Binding(
            get: { processes.autoPauseDirectories.contains(project.directory) },
            set: { processes.setAutoPause(.init(directory: project.directory, enabled: $0)) })
        )
        .disabled(
          project.preference.keepRunning || processes.projectTargets[project.directory] == nil)
        Button("Configure project…") { editing = project.preference }
        Toggle(
          "Keep running",
          isOn: Binding(
            get: { project.preference.keepRunning },
            set: { controller.keep(.init(preference: project.preference, keep: $0)) }
          ))
      }.disabled(busy)
    }.blitzRow()
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
  let onClose: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Project setup").font(.title2.bold())
      Text(preference.directory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      VStack(alignment: .leading, spacing: 8) {
        Text("Project name").font(.system(size: 13, weight: .medium))
        TextField("Project name", text: $preference.name).blitzInput()
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("Start command").font(.headline)
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
        .font(.caption).foregroundStyle(.secondary)
      }
      Toggle("Keep this project running", isOn: $preference.keepRunning)
      HStack {
        Spacer()
        Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
        Button("Save") {
          controller.save(preference)
          onClose()
        }.keyboardShortcut(.defaultAction)
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
