import AppKit
import SwiftUI

struct DeveloperBrowserView: View {
  let kind: DeveloperArtifactKind
  @ObservedObject var model: DeveloperBrowserModel
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var workspaces: WorkspaceController
  @ObservedObject var history: CleanupOverviewModel
  @Environment(\.openWindow) private var openWindow
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
          TextField("Search project, path or framework", text: $search)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Search developer folders")
          Toggle("Ready to review", isOn: $removableOnly).toggleStyle(.checkbox)
          Button("Choose folder…") { chooseFolder() }
            .disabled(model.isScanning || !model.deleting.isEmpty)
          Button("Refresh folders", systemImage: "arrow.clockwise") { model.scan() }
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
      }.padding(28)
    }
    .navigationTitle(kind.rawValue)
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
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 14) {
        Image(systemName: kind == .worktree ? "arrow.triangle.branch" : "shippingbox.fill")
          .font(.system(size: 30)).foregroundStyle(AppBrand.accent)
        VStack(alignment: .leading, spacing: 6) {
          Text(
            kind == .worktree
              ? "Finished branches. Reclaimed space." : "Your dependencies, by size."
          )
          .font(.title.bold())
          Text(
            kind == .worktree
              ? "Browse linked checkouts and see what prevents removal."
              : "An npkill-style browser with project protection and cleanup receipts."
          )
          .foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 24) {
        VStack(alignment: .leading, spacing: 5) {
          Text("SPACE TO REVIEW").font(.caption2).foregroundStyle(.secondary)
          Text(ByteText.full(items.filter { blocker($0) == nil }.compactMap(\.bytes).reduce(0, +)))
            .font(.title2.weight(.semibold)).monospacedDigit()
        }
        Divider().frame(height: 40)
        VStack(alignment: .leading, spacing: 5) {
          Text("RECLAIMED THIS SESSION").font(.caption2).foregroundStyle(.secondary)
          Text(ByteText.full(model.sessionGain)).font(.title2.weight(.semibold)).monospacedDigit()
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 5) {
          Text("Need RAM back?").font(.callout.weight(.medium))
          Button("Manage running processes") { openWindow(id: "processes") }
          Text("Disk cleanup does not directly release RAM.").font(.caption).foregroundStyle(
            .secondary)
        }
      }.panelCard(padding: 18)
    }
  }

  private func row(_ artifact: DeveloperArtifact) -> some View {
    let running = processes.resources.filter {
      $0.directory.map { DeveloperPath.contains(.init(path: $0, root: artifact.projectPath)) }
        ?? false
    }
    let reason = blocker(artifact)
    return VStack(alignment: .leading, spacing: 13) {
      HStack(alignment: .top, spacing: 14) {
        TechnologyIcon(technology: artifact.technology, size: 42)
        VStack(alignment: .leading, spacing: 5) {
          Text(artifact.name).font(.headline)
          Text(
            artifact.technology.rawValue
              + (artifact.internalVolume ? " · Mac storage" : " · External storage")
          )
          .font(.caption).foregroundStyle(.secondary)
          Text(artifact.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .truncationMode(.middle).textSelection(.enabled).help(artifact.path)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 5) {
          Text(artifact.bytes.map(ByteText.full) ?? "Size unavailable")
            .font(.title3.weight(.semibold)).monospacedDigit()
          if !running.isEmpty {
            Text(
              "\(running.count) processes · \(ByteText.compact(running.compactMap(\.memoryBytes).reduce(0, +))) RAM"
            )
            .font(.caption).foregroundStyle(.secondary)
          } else {
            Text("No running process observed").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      if let git = artifact.worktree {
        HStack(spacing: 10) {
          Label(
            git.record.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "Detached HEAD",
            systemImage: "arrow.triangle.branch"
          )
          .lineLimit(1).truncationMode(.middle)
          Spacer()
          Label(
            git.merge.rawValue,
            systemImage: git.merge == .merged ? "checkmark.circle" : "questionmark.circle"
          )
          .foregroundStyle(git.merge == .merged ? Color.green : .secondary)
          if let base = git.base {
            Text(
              "into "
                + base.replacingOccurrences(of: "refs/remotes/", with: "")
                .replacingOccurrences(of: "refs/heads/", with: "")
            )
            .foregroundStyle(.secondary)
          }
        }.font(.caption)
      }
      HStack(spacing: 12) {
        if let message = model.messages[artifact.id] {
          Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        } else if let reason {
          Label(reason, systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
        } else {
          Label("Ready to review", systemImage: "checkmark.circle").font(.caption).foregroundStyle(
            .green)
        }
        Spacer()
        if let command = artifact.reinstallCommand {
          Button("Copy restore command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
          }.help("Run \(command) in \(artifact.projectPath)")
        }
        Button("Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact.path)])
        }
        if model.deleting.contains(artifact.id) {
          ProgressView().controlSize(.small)
          Text("Removing…").font(.caption).foregroundStyle(.secondary)
        } else {
          Button("Remove…", role: .destructive) { confirmation = artifact }
            .disabled(reason != nil)
        }
      }
    }.panelCard(padding: 18)
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
