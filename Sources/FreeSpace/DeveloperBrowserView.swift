import AppKit
import SwiftUI

struct DeveloperBrowserView: View {
  let kind: DeveloperArtifactKind
  @ObservedObject var model: DeveloperBrowserModel
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var workspaces: WorkspaceController
  @ObservedObject var history: CleanupOverviewModel
  @State private var search = ""
  @State private var removableOnly = false
  @State private var confirmation: DeveloperArtifact?

  private var items: [DeveloperArtifact] {
    model.artifacts.filter {
      $0.kind == kind
        && (search.isEmpty
          || ($0.path + " " + $0.technology.rawValue + " " + ($0.worktree?.record.branch ?? ""))
            .localizedStandardContains(search))
        && (!removableOnly || blocker($0) == nil)
    }
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        header
        HStack(spacing: 14) {
          BlitzSearchField(title: "Search folders", text: $search)
          Toggle("Ready to review", isOn: $removableOnly).toggleStyle(.checkbox)
          Button("Choose folder…") { chooseFolder() }
            .disabled(model.isScanning || !model.deleting.isEmpty)
          Button("Scan") { model.scan() }
            .disabled(model.isScanning || !model.deleting.isEmpty)
        }
        if let folder = model.selectedFolder {
          HStack {
            Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(
              .middle)
            Button("All projects") { model.chooseFolder(nil) }
              .disabled(model.isScanning || !model.deleting.isEmpty)
          }
        }
        if model.isScanning {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(model.progress).font(.callout).lineLimit(1)
            Spacer()
            Button("Stop scan") { model.cancel() }
          }
        } else if model.limited {
          Label(model.progress, systemImage: "info.circle").font(.caption).foregroundStyle(
            .secondary)
        }
        if let win = model.lastWin {
          Label(win, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
        }
        HStack {
          Text("\(items.count) folders · largest first").font(.callout.weight(.medium))
          Spacer()
          if let date = model.scannedAt {
            Text("Scanned \(date, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
          }
        }
        ForEach(items) { artifact in
          row(artifact)
        }
        if items.isEmpty, !model.isScanning {
          ContentUnavailableView(
            search.isEmpty ? "No matching \(kind.rawValue.lowercased())" : "No matches",
            systemImage: kind == .worktree ? "arrow.triangle.branch" : "shippingbox",
            description: Text("Scan folders or add another project root in Settings."))
        }
        Text(
          kind == .worktree
            ? "Merge status uses local Git refs. Squash merges can remain unverified. Ignored files need review; local branches are kept after removal."
            : "Dependency folders stay on disk until you remove them. A lockfile supplies the restore command; active projects remain protected."
        )
        .font(.caption).foregroundStyle(.secondary)
      }.padding(24)
    }
    .task { model.loadIfNeeded() }
    .alert(
      kind == .worktree
        ? "Remove this worktree permanently?" : "Remove these dependencies permanently?",
      isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    ) {
      Button("Remove permanently", role: .destructive) {
        if let artifact = confirmation { model.remove(.init(artifact: artifact, history: history)) }
        confirmation = nil
      }
      Button("Cancel", role: .cancel) { confirmation = nil }
    } message: {
      Text(
        (confirmation?.path ?? "") + "\n\n"
          + (kind == .worktree
            ? "Git will recheck this merged worktree and remove its folder. The local branch stays available."
            : "The project will need its dependencies installed again. Source files and lockfiles stay in place.")
          + "\n\nYou can keep browsing while removal runs.")
    }
  }

  private var header: some View {
    HStack {
      Text(
        "\(ByteText.full(items.filter { blocker($0) == nil }.compactMap(\.bytes).reduce(0, +))) available to remove"
      )
      .font(.system(size: 15, weight: .semibold)).monospacedDigit()
      Spacer()
      if model.sessionGain > 0 {
        Text("\(ByteText.full(model.sessionGain)) reclaimed")
          .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
      }
    }
  }

  private func row(_ artifact: DeveloperArtifact) -> some View {
    let reason = blocker(artifact)
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        TechnologyIcon(technology: artifact.technology, size: 28)
        VStack(alignment: .leading, spacing: 5) {
          Text(artifact.name).font(.system(size: 13, weight: .medium))
          Text(artifact.path).font(.system(size: 11)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(artifact.path)
          if let message = model.messages[artifact.id] ?? reason {
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(
              .enabled)
          }
        }
        Spacer(minLength: 16)
        Text(artifact.bytes.map(ByteText.full) ?? "—")
          .font(.system(size: 13, weight: .medium)).monospacedDigit()
        Menu {
          Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact.path)])
          }
          if let command = artifact.reinstallCommand {
            Button("Copy restore command") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(command, forType: .string)
            }
          }
        } label: {
          Image(systemName: "ellipsis")
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .accessibilityLabel("Actions for \(artifact.name)").help("More actions")
        if model.deleting.contains(artifact.id) {
          ProgressView().controlSize(.small)
        } else {
          Button("Remove…", role: .destructive) { confirmation = artifact }
            .controlSize(.small).disabled(reason != nil)
        }
      }
      if let git = artifact.worktree {
        HStack(spacing: 8) {
          Text(
            git.record.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "Detached HEAD"
          )
          .lineLimit(1).truncationMode(.middle)
          Spacer()
          Text(git.merge.rawValue)
          if let base = git.base {
            Text(
              "into "
                + base.replacingOccurrences(of: "refs/remotes/", with: "").replacingOccurrences(
                  of: "refs/heads/", with: ""))
          }
        }.font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }.padding(.vertical, 14)
      .overlay(alignment: .bottom) { Divider() }
  }

  private func blocker(_ artifact: DeveloperArtifact) -> String? {
    if workspaces.preferences.contains(where: {
      $0.keepRunning
        && DeveloperPath.contains(.init(path: artifact.projectPath, root: $0.directory))
    }) {
      return "Keep running is enabled"
    }
    if processes.resources.contains(where: {
      $0.directory.map { DeveloperPath.contains(.init(path: $0, root: artifact.projectPath)) }
        ?? false
    }) {
      return "Project is in use"
    }
    return artifact.blocker
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.chooseFolder(url)
  }
}
