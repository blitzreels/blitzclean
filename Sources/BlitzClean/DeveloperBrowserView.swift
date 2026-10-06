import AppKit
import SwiftUI

/// Merged Git worktrees, shown as one Storage → Cleanup section.
struct WorktreeCleanupView: View {
  @ObservedObject var model: DeveloperBrowserModel
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var workspaces: WorkspaceController
  @Binding var pending: DeveloperArtifact?

  @State private var showsBlocked = false

  /// Each worktree's blocker, evaluated once per render.
  private struct Listing {
    let removable: [DeveloperArtifact]
    let blocked: [(artifact: DeveloperArtifact, reason: String)]

    var count: Int { removable.count + blocked.count }
  }

  private var listing: Listing {
    var removable: [DeveloperArtifact] = []
    var blocked: [(artifact: DeveloperArtifact, reason: String)] = []
    for artifact in model.artifacts where artifact.kind == .worktree {
      if let reason = blocker(artifact) {
        blocked.append((artifact, reason))
      } else {
        removable.append(artifact)
      }
    }
    return Listing(removable: removable, blocked: blocked)
  }

  private func detail(_ listing: Listing) -> String {
    if model.isScanning && listing.count == 0 { return "Looking for linked worktrees…" }
    if listing.count == 0 { return "No linked worktrees" }
    let removable = listing.removable.isEmpty ? "none" : "\(listing.removable.count)"
    return "\(listing.count) linked · \(removable) removable"
  }

  var body: some View {
    let listing = listing
    let removableBytes = listing.removable.compactMap(\.bytes).reduce(0, +)
    BlitzStorageSection(
      title: "Worktrees", symbol: "arrow.triangle.branch", detail: detail(listing),
      trailing: listing.removable.isEmpty ? nil : ByteText.full(removableBytes),
      showsContent: listing.count > 0 || model.isScanning
    ) {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Text(status).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText).lineLimit(2)
            .textSelection(.enabled)
          Spacer()
          if model.isScanning { ProgressView().controlSize(.small) }
        }.padding(.horizontal, 16).padding(.vertical, 12)
        ForEach(listing.removable) { artifact in
          BlitzRowDivider(leading: 16)
          row((artifact: artifact, blocker: nil))
        }
        if !listing.blocked.isEmpty {
          BlitzRowDivider(leading: 16)
          Button(
            showsBlocked
              ? "Hide worktrees that can't be removed"
              : "Show \(listing.blocked.count) that can't be removed"
          ) { showsBlocked.toggle() }
          .blitzButton(.quiet).controlSize(.small).padding(.vertical, 8)
          if showsBlocked {
            ForEach(listing.blocked, id: \.artifact.id) { entry in
              BlitzRowDivider(leading: 16)
              row((artifact: entry.artifact, blocker: entry.reason))
            }
          }
        }
      }
    }
    .task { model.loadIfNeeded() }
  }

  private var status: String {
    if let win = model.lastWin { return win }
    if model.isScanning { return model.progress }
    if model.limited { return model.progress }
    return "Only merged worktrees can be removed. Their local branches stay."
  }

  private func row(_ input: (artifact: DeveloperArtifact, blocker: String?)) -> some View {
    let artifact = input.artifact
    let reason = model.messages[artifact.id] ?? input.blocker
    return HStack(spacing: 12) {
      TechnologyIcon(technology: artifact.technology, size: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(branch(artifact)).font(BlitzType.rowTitle).lineLimit(1).truncationMode(.middle)
        Text(artifact.path).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.middle).help(artifact.path)
        Text(reason ?? merge(artifact)).font(BlitzType.caption)
          .foregroundStyle(reason == nil ? BlitzUI.tertiaryText : BlitzUI.warning).lineLimit(2)
      }.frame(maxWidth: .infinity, alignment: .leading)
      BlitzTrailingValue(value: artifact.bytes.map(ByteText.full) ?? "—", detail: nil)
        .frame(width: 96, alignment: .trailing)
      Group {
        if model.deleting.contains(artifact.id) {
          ProgressView().controlSize(.small)
        } else {
          Button("Remove…") { pending = artifact }.blitzButton(.secondary).controlSize(.small)
            .disabled(input.blocker != nil)
        }
      }.frame(width: 124, alignment: .trailing)
      BlitzActionMenu(label: "More actions for \(artifact.name)") {
        Button("Show in Finder") { Finder.reveal(artifact.path) }
        Button("Copy path") {
          Pasteboard.copy(artifact.path)
        }
      }
    }.padding(.horizontal, 16).padding(.vertical, 10)
  }

  private func branch(_ artifact: DeveloperArtifact) -> String {
    artifact.worktree?.record.branch?.replacingOccurrences(of: "refs/heads/", with: "")
      ?? artifact.name
  }

  private func merge(_ artifact: DeveloperArtifact) -> String {
    guard let git = artifact.worktree else { return "" }
    let base = git.base.map {
      " into "
        + $0.replacingOccurrences(of: "refs/remotes/", with: "")
        .replacingOccurrences(of: "refs/heads/", with: "")
    }
    return git.merge.rawValue + (base ?? "")
  }

  private func blocker(_ artifact: DeveloperArtifact) -> String? {
    if workspaces.preferences.contains(where: {
      $0.keepRunning
        && DeveloperPath.contains(.init(path: artifact.projectPath, root: $0.directory))
    }) {
      return "Project is set to keep running"
    }
    if processes.resources.contains(where: {
      $0.directory.map { DeveloperPath.contains(.init(path: $0, root: artifact.projectPath)) }
        ?? false
    }) {
      return "A process is running in this worktree"
    }
    return artifact.blocker
  }
}
