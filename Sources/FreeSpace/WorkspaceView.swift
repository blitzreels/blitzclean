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
        PressureBanner(assessment: processes.pressure, review: nil)
        if let action = processes.projectAction {
          BlitzStatusLine(text: action, tone: .working)
        }
        if let status = controller.status ?? processes.statusMessage {
          BlitzStatusLine(text: status, tone: .working)
        }
        let projects = processes.projects(controller.preferences).filter { project in
          query.isEmpty || project.preference.name.localizedCaseInsensitiveContains(query)
            || project.directory.localizedCaseInsensitiveContains(query)
            || project.servers.flatMap(\.listeningPorts).contains { String($0).contains(query) }
        }
        let running = projects.filter(\.isRunning)
        let stopped = projects.filter { !$0.isRunning }
        if !running.isEmpty { section("Active projects", running) }
        if !stopped.isEmpty { section("Saved projects", stopped) }
        if projects.isEmpty {
          Text(
            query.isEmpty
              ? "No projects yet. Running projects appear here; use Add project to save one."
              : "No projects match this search"
          ).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
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
        Text(project.directory).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.middle)
        if !project.servers.isEmpty {
          Text(
            project.servers.map {
              "\($0.name) \($0.listeningPorts.map { ":\($0)" }.joined(separator: ", "))"
            }.joined(separator: " · ")
          ).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText).lineLimit(1)
        }
        if let message = processes.projectMessages[project.directory] {
          Text(message).font(BlitzType.caption).foregroundStyle(BlitzUI.supportingText)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 16)
      BlitzTrailingValue(
        value: ByteText.full(project.memoryBytes),
        detail: "\(project.resources.count) processes · \(Int(project.cpuPercent))% CPU"
      ).fixedSize()
      ZStack(alignment: .trailing) {
        Color.clear
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
        if let target = processes.projectTargets[project.directory] {
          Button(target.isPaused ? "Resume" : "Pause") { processes.pauseProject(target) }
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
        Button("Configure project…") { editing = project.preference }
        Button {
          controller.keep(
            .init(preference: project.preference, keep: !project.preference.keepRunning))
        } label: {
          MenuCheckLabel(title: "Keep running", isOn: project.preference.keepRunning)
        }
      }.disabled(busy)
    }.blitzRow()
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
