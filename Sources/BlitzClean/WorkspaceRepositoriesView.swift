import SwiftUI

/// Projects → Repositories: one card per Git repository and one row per worktree with work in it.
extension WorkspaceProjectsView {
  /// Git state for every running folder and every folder an agent works in.
  func readRepositories() {
    let folders =
      processes.projects(controller.preferences).filter(\.isRunning).map(\.directory)
      + processes.threads.compactMap { $0.directory.flatMap(WorkspaceCatalog.root) }
    repos.update(folders)
  }

  func repoSection(_ groups: [RepoGroup]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      BlitzSectionHeader(title: "Repositories", count: groups.count) {}
      ForEach(groups) { group in
        VStack(spacing: 0) {
          repoHeader(group)
          ForEach(group.active) { worktree in
            BlitzRowDivider(leading: 16)
            worktreeRow(worktree, in: group)
          }
          if !group.idle.isEmpty {
            BlitzRowDivider(leading: 16)
            idleWorktrees(group)
          }
        }.blitzTable()
      }
    }
  }

  func repoHeader(_ group: RepoGroup) -> some View {
    HStack(spacing: 12) {
      ProjectIcon(
        directory: group.primaryPath, processName: "", size: 28, fallbackSymbol: "folder.fill")
      VStack(alignment: .leading, spacing: 2) {
        Text(group.name).font(BlitzType.headline).lineLimit(1)
        Text(Self.tilde(group.primaryPath)).font(BlitzType.caption)
          .foregroundStyle(BlitzUI.tertiaryText).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 12)
      let worktrees = group.active.count + group.idle.count
      let agents: String? =
        switch group.agentCount {
        case 0: nil
        case 1: "1 agent"
        default: "\(group.agentCount) agents"
        }
      Text(
        [
          agents,
          worktrees == 1 ? "1 worktree" : "\(worktrees) worktrees",
          ByteText.compact(group.memoryBytes),
        ].compactMap { $0 }.joined(separator: " · ")
      ).font(BlitzType.caption).monospacedDigit().foregroundStyle(BlitzUI.secondaryText)
    }.padding(.horizontal, 16).padding(.vertical, 12)
  }

  func worktreeRow(_ worktree: RepoWorktree, in group: RepoGroup) -> some View {
    let project = worktree.project
    let busy =
      project.map { project in
        processes.actingProjects.contains(project.directory)
          || docker.acting.contains(project.directory)
          || project.servers.contains { processes.stoppingIDs.contains($0.id) }
      } ?? false
      || worktree.agents.contains { processes.stoppingThreads.contains($0.id) }
    return HStack(alignment: .center, spacing: 12) {
      Image(systemName: "arrow.triangle.branch").font(.system(size: 12, weight: .medium))
        .foregroundStyle(BlitzUI.tertiaryText).frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(worktree.checkout?.branch ?? "detached HEAD")
            .font(.system(size: 13, weight: .medium, design: .monospaced)).lineLimit(1)
          if !worktree.isPrimary {
            Text(PathName.last(worktree.path)).font(BlitzType.caption)
              .foregroundStyle(BlitzUI.tertiaryText).lineLimit(1).truncationMode(.middle)
          }
          if let checkout = worktree.checkout { gitState(checkout) }
          if let project, processes.projectTargets[project.directory]?.isPaused == true {
            BlitzStatusBadge(title: "Paused", tone: .warning)
          }
        }
        Text(Self.workSummary(worktree)).font(BlitzType.caption)
          .foregroundStyle(BlitzUI.secondaryText).lineLimit(1)
        if let project, !project.servers.isEmpty { portLinks(project) }
        if let project, let message = processes.projectMessages[project.directory] {
          Text(message).font(BlitzType.caption).foregroundStyle(BlitzUI.supportingText)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 12)
      Text(ByteText.compact(worktree.memoryBytes)).font(BlitzType.numeric)
        .foregroundStyle(BlitzUI.supportingText).frame(minWidth: 56, alignment: .trailing)
        .help(project.flatMap(stopImpact) ?? "Memory used by the agents in this worktree")
      ZStack(alignment: .trailing) {
        Color.clear
        if let project, project.preference.keepRunning == false,
          processes.projectTargets[project.directory] != nil || !project.servers.isEmpty
            || project.containers.contains(where: \.running)
        {
          BlitzProcessButton(
            title: "Stop", label: "Stop \(worktree.checkout?.branch ?? group.name)", isBusy: busy
          ) { stopWorkspace(project) }
          .help(stopImpact(project) ?? "Stop this worktree's dev processes.")
        }
      }.frame(width: 84, height: 34)
      BlitzActionMenu(label: "Options for \(worktree.checkout?.branch ?? group.name)") {
        if !worktree.agents.isEmpty {
          let paused = worktree.agents.allSatisfy(\.isPaused)
          Button(paused ? "Resume agents" : "Pause agents — keeps memory") {
            for agent in worktree.agents {
              if paused { processes.resumeThread(agent) } else { processes.pauseThread(agent) }
            }
          }
          Button(worktree.agents.count == 1 ? "Quit agent" : "Quit \(worktree.agents.count) agents")
          {
            for agent in worktree.agents { processes.stopThread(agent, force: false) }
          }
          Divider()
        }
        Button("Show in Finder") { Finder.reveal(worktree.path) }
        Button("Copy path") { Pasteboard.copy(worktree.path) }
        if let project {
          Divider()
          projectMenu(project)
        }
      }.disabled(busy)
    }.padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 56)
  }

  @ViewBuilder func gitState(_ checkout: GitCheckout) -> some View {
    let parts = [
      checkout.changes > 0 ? "\(checkout.changes) changed" : nil,
      checkout.ahead > 0 ? "↑\(checkout.ahead)" : nil,
      checkout.behind > 0 ? "↓\(checkout.behind)" : nil,
    ].compactMap { $0 }
    if !parts.isEmpty {
      Text(parts.joined(separator: " ")).font(BlitzType.caption).monospacedDigit()
        .foregroundStyle(BlitzUI.secondaryText)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(BlitzUI.quietFill, in: .capsule)
        .help("Uncommitted files, and commits ahead of or behind its upstream branch")
    }
  }

  func idleWorktrees(_ group: RepoGroup) -> some View {
    let expanded = expandedIdle.contains(group.id)
    let names = group.idle.map { $0.branch.map(Self.branchName) ?? Self.tilde($0.path) }
    return VStack(alignment: .leading, spacing: 6) {
      Button {
        if expanded { expandedIdle.remove(group.id) } else { expandedIdle.insert(group.id) }
      } label: {
        HStack(spacing: 6) {
          Text(
            group.idle.count == 1 ? "1 idle worktree" : "\(group.idle.count) idle worktrees"
          ).font(BlitzType.captionEmphasis).foregroundStyle(BlitzUI.secondaryText)
          if !expanded {
            Text(names.prefix(4).joined(separator: ", ") + (names.count > 4 ? "…" : ""))
              .font(BlitzType.caption).foregroundStyle(BlitzUI.tertiaryText).lineLimit(1)
          }
          Spacer(minLength: 0)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).blitzPointingHand()
      if expanded {
        ForEach(group.idle, id: \.path) { record in
          HStack(spacing: 8) {
            Text(record.branch.map(Self.branchName) ?? "detached")
              .font(.system(size: 12, design: .monospaced)).foregroundStyle(BlitzUI.supportingText)
            Text(Self.tilde(record.path)).font(BlitzType.caption)
              .foregroundStyle(BlitzUI.tertiaryText).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Show in Finder") { Finder.reveal(record.path) }
              .blitzButton(.quiet).controlSize(.mini)
          }
        }
      }
    }.padding(.horizontal, 16).padding(.vertical, 10)
  }

  /// What runs in a worktree: agents first, then programs grouped by name, such as `node ×4`.
  static func workSummary(_ worktree: RepoWorktree) -> String {
    var parts: [String] = []
    let tools = Dictionary(grouping: worktree.agents, by: \.tool.title)
    for (title, agents) in tools.sorted(by: { $0.value.count > $1.value.count }) {
      let paused = agents.filter(\.isPaused).count
      parts.append(
        (agents.count == 1 ? title : "\(title) ×\(agents.count)")
          + (paused > 0 ? " (\(paused) paused)" : ""))
    }
    let agentIDs = Set(worktree.agents.flatMap(\.processIDs))
    let programs = Dictionary(
      grouping: (worktree.project?.resources ?? []).filter { !agentIDs.contains($0.processID) },
      by: \.name)
    for (name, group) in programs.sorted(by: { $0.value.count > $1.value.count }).prefix(3) {
      parts.append(group.count == 1 ? name : "\(name) ×\(group.count)")
    }
    let others = programs.count - min(3, programs.count)
    if others > 0 { parts.append("\(others) more") }
    return parts.isEmpty ? "Nothing running" : parts.joined(separator: " · ")
  }

  static func branchName(_ reference: String) -> String {
    reference.hasPrefix("refs/heads/") ? String(reference.dropFirst(11)) : reference
  }

  static func tilde(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }
}
