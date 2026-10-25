import SwiftUI

/// Git worktrees across project folders and Codex or Claude sessions, largest first, with a safe Remove.
struct DriveWorktreesSection: View {
  @ObservedObject var model: DeveloperBrowserModel
  let history: CleanupOverviewModel
  let onConfirm: (PendingProcessAction) -> Void
  @State private var showsAll = false

  private static let limit = 6

  private var worktrees: [DeveloperArtifact] {
    model.artifacts.filter { $0.kind == .worktree }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
  }

  var body: some View {
    let worktrees = worktrees
    let removable = worktrees.filter { $0.blocker == nil }
    let total = worktrees.reduce(0) { $0 + ($1.bytes ?? 0) }
    let shown = showsAll ? worktrees : Array(worktrees.prefix(Self.limit))
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        BlitzIconTile(symbol: "arrow.triangle.branch", tone: .muted, size: 28)
        VStack(alignment: .leading, spacing: 3) {
          Text("Git worktrees").font(.system(size: 14, weight: .semibold))
          Text(summary(count: worktrees.count, removable: removable.count))
            .font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText).lineLimit(1)
        }
        Spacer()
        ProgressView().controlSize(.small).opacity(model.isScanning ? 1 : 0)
        if total > 0 {
          Text(ByteText.full(total)).font(BlitzType.rowTitle).monospacedDigit()
        }
        if removable.count > 1 {
          Button("Remove \(removable.count) merged") {
            confirm(.init(worktrees: removable, force: false))
          }
          .blitzButton(.secondary).controlSize(.small)
          .disabled(!model.deleting.isEmpty)
        }
      }.padding(16).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
      if !shown.isEmpty {
        BlitzRowDivider(leading: 0)
        ForEach(shown) { worktree in
          row(worktree)
          if worktree.id != shown.last?.id { BlitzRowDivider(leading: 54) }
        }
        if worktrees.count > Self.limit {
          BlitzRowDivider(leading: 0)
          BlitzShowAllButton(total: worktrees.count, noun: "worktrees", isExpanded: $showsAll)
            .padding(.vertical, 8)
        }
      }
    }
    .blitzTable()
    .task { model.loadIfNeeded() }
  }

  private func summary(count: Int, removable: Int) -> String {
    if model.isScanning, count == 0 { return "Looking for worktrees in your projects…" }
    if count == 0 { return "No linked worktrees found" }
    let merged = removable == 0 ? "none fully merged" : "\(removable) merged and safe to remove"
    return "\(count) project copies · \(merged) · also counted in the groups below"
  }

  private func row(_ worktree: DeveloperArtifact) -> some View {
    let busy = model.deleting.contains(worktree.id)
    let branch = worktree.worktree?.record.branch.map {
      $0.replacingOccurrences(of: "refs/heads/", with: "")
    }
    let repository = worktree.worktree.map {
      PathName.last($0.repository)
    }
    return HStack(spacing: 12) {
      Image(systemName: "arrow.triangle.branch").font(.system(size: 13, weight: .medium))
        .foregroundStyle(BlitzUI.secondaryText).frame(width: 26)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(worktree.name).font(BlitzType.rowTitle).lineLimit(1)
          if worktree.blocker == nil {
            BlitzStatusBadge(title: "Merged", tone: .good)
          } else if worktree.blocker == "Project is in use" {
            BlitzStatusBadge(title: "In use", tone: .warning)
          }
        }
        Text(
          [branch, repository.map { "from \($0)" }, worktree.blocker].compactMap { $0 }
            .joined(separator: " · ")
        )
        .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText).lineLimit(1)
        .truncationMode(.middle)
        if let message = model.messages[worktree.id] {
          Text(message).font(BlitzType.caption).foregroundStyle(BlitzUI.warning).lineLimit(1)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
        .help(worktree.path)
      Text(worktree.bytes.map(ByteText.full) ?? "—").font(BlitzType.numeric)
        .foregroundStyle(BlitzUI.supportingText).frame(minWidth: 84, alignment: .trailing)
      Group {
        if worktree.blocker == nil {
          BlitzProcessButton(title: "Remove", label: "Remove \(worktree.name)", isBusy: busy) {
            confirm(.init(worktrees: [worktree], force: false))
          }
        } else if DeveloperArtifactCleanup.canForce(worktree) {
          BlitzProcessButton(
            title: "Remove…", label: "Remove \(worktree.name) anyway", isBusy: busy
          ) {
            confirm(.init(worktrees: [worktree], force: true))
          }.help(
            "Removes the folder even though: \(worktree.blocker ?? ""). The branch and its commits stay."
          )
        } else {
          Button("Show") { Finder.reveal(worktree.path) }.blitzButton(.quiet).controlSize(.small)
        }
      }.frame(width: 112, alignment: .trailing)
    }.blitzRow()
  }

  private struct Request {
    let worktrees: [DeveloperArtifact]
    let force: Bool
  }

  private func confirm(_ request: Request) {
    let worktrees = request.worktrees
    let bytes = worktrees.reduce(0) { $0 + ($1.bytes ?? 0) }
    let model = model
    let history = history
    let reason: String =
      switch worktrees.first?.blocker {
      case "Has ignored files. Review them first.":
        "It holds files Git ignores, such as node_modules or build output."
      case "Uncommitted or untracked files":
        "It has uncommitted or untracked files; they are deleted for good."
      default:
        "Its branch is not merged into the base branch yet."
      }
    let warning =
      request.force
      ? "\n\n\(reason) The branch and its commits stay, so committed work can be checked out again."
      : "\n\nGit checks again that each is merged and has no local changes, then removes the "
        + "folder. Branches stay."
    onConfirm(
      .init(
        title: worktrees.count == 1
          ? "Remove worktree \(worktrees[0].name)?" : "Remove \(worktrees.count) merged worktrees?",
        message: worktrees.map(\.path).joined(separator: "\n") + warning
          + " Frees up to \(ByteText.full(bytes)).",
        confirmTitle: request.force ? "Remove anyway" : "Remove \(ByteText.compact(bytes))",
        perform: {
          for worktree in worktrees {
            model.remove(.init(artifact: worktree, history: history, force: request.force))
          }
        }))
  }
}
