import AppKit
import SwiftUI

/// Merged Git worktrees, shown as one Storage → Cleanup section.
struct WorktreeCleanupView: View {
  @ObservedObject var model: DeveloperBrowserModel
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var workspaces: WorkspaceController
  @Binding var pending: DeveloperArtifact?

  private var items: [DeveloperArtifact] { model.artifacts.filter { $0.kind == .worktree } }

  private var removableBytes: UInt64 {
    items.filter { blocker($0) == nil }.compactMap(\.bytes).reduce(0, +)
  }

  private var detail: String {
    if model.isScanning && items.isEmpty { return "Looking for linked worktrees…" }
    if items.isEmpty { return "No linked worktrees" }
    return "\(items.count) linked · \(ByteText.full(removableBytes)) removable"
  }

  var body: some View {
    BlitzStorageSection(title: "Worktrees", symbol: "arrow.triangle.branch", detail: detail) {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Text(status).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText).lineLimit(2)
            .textSelection(.enabled)
          Spacer()
          if model.isScanning {
            ProgressView().controlSize(.small)
            Button("Stop") { model.cancel() }.blitzButton(.quiet).controlSize(.small)
          } else {
            Button("Scan again") { model.scan() }.blitzButton(.quiet).controlSize(.small)
              .disabled(!model.deleting.isEmpty)
          }
        }.padding(.horizontal, 16).padding(.vertical, 12)
        ForEach(items) { artifact in
          BlitzRowDivider(leading: 16)
          row(artifact)
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

  private func row(_ artifact: DeveloperArtifact) -> some View {
    let reason = model.messages[artifact.id] ?? blocker(artifact)
    return HStack(spacing: 12) {
      TechnologyIcon(technology: artifact.technology, size: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(branch(artifact)).font(BlitzType.rowTitle).lineLimit(1).truncationMode(.middle)
        Text(artifact.path).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1).truncationMode(.middle).help(artifact.path)
        Text(reason ?? merge(artifact)).font(BlitzType.caption)
          .foregroundStyle(reason == nil ? BlitzUI.tertiaryText : BlitzUI.warning).lineLimit(2)
      }.frame(maxWidth: .infinity, alignment: .leading)
      Text(artifact.bytes.map(ByteText.full) ?? "—").font(BlitzType.numeric)
        .foregroundStyle(BlitzUI.primaryText).frame(width: 96, alignment: .trailing)
      Group {
        if model.deleting.contains(artifact.id) {
          ProgressView().controlSize(.small)
        } else {
          Button("Remove…") { pending = artifact }.blitzButton(.secondary).controlSize(.small)
            .disabled(blocker(artifact) != nil)
        }
      }.frame(width: 124, alignment: .trailing)
      BlitzActionMenu(label: "More actions for \(artifact.name)") {
        Button("Show in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact.path)])
        }
        Button("Copy path") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(artifact.path, forType: .string)
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
