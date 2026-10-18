import Foundation

struct DeveloperCleanupOutcome: Sendable {
  let path: String
  let removed: Bool
  let message: String
  let win: CleanupWin?
}

enum DeveloperArtifactCleanup {
  static func remove(_ artifact: DeveloperArtifact) -> DeveloperCleanupOutcome {
    func failed(_ reason: String) -> DeveloperCleanupOutcome {
      .init(path: artifact.path, removed: false, message: reason, win: nil)
    }
    guard artifact.blocker == nil, artifact.internalVolume,
      CleanupVolume.read(artifact.path)?.isInternal == true
    else { return failed(artifact.blocker ?? "This folder is protected") }
    guard let identity = artifact.identity, DirectoryIdentity.read(artifact.path) == identity else {
      return failed("Folder changed. Refresh and review it again.")
    }
    let kept = WorkspacePreferences.load().filter(\.keepRunning).map(\.directory)
    let active = CleanupActivity.workingDirectories()
    switch artifact.kind {
    case .worktree:
      guard let expected = artifact.worktree else { return failed("Worktree evidence is missing") }
      if let reason = GitWorktrees.validateRemoval(
        .init(
          expected: expected,
          activeDirectories: active, keptDirectories: kept))
      {
        return failed(reason)
      }
    case .dependencies:
      if let reason = dependencyBlocker(.init(artifact: artifact, active: active, kept: kept)) {
        return failed(reason)
      }
    }
    let handles = CleanupActivity.command(["-nP", "-Fpcn", "+D", artifact.path])
    guard handles.status == 1, handles.output.isEmpty else {
      return failed(
        "Files are open, or open-file verification could not finish. Close the project and try again."
      )
    }
    guard DirectoryIdentity.read(artifact.path) == identity else {
      return failed("Folder changed during verification")
    }
    let latestActive = CleanupActivity.workingDirectories()
    let latestKept = WorkspacePreferences.load().filter(\.keepRunning).map(\.directory)
    let before = CleanupVolume.read(artifact.path)
    let removed: Bool
    switch artifact.kind {
    case .worktree:
      guard let expected = artifact.worktree else { return failed("Worktree evidence is missing") }
      if let reason = GitWorktrees.validateRemoval(
        .init(
          expected: expected,
          activeDirectories: latestActive, keptDirectories: latestKept))
      {
        return failed(reason)
      }
      let result = DeveloperCommand.run(
        .init(
          executable: "/usr/bin/git",
          arguments: ["-C", expected.repository, "worktree", "remove", "--", artifact.path],
          timeout: 120, maximumBytes: 65_536))
      removed = result.status == 0 && !FileManager.default.fileExists(atPath: artifact.path)
    case .dependencies:
      if let reason = dependencyBlocker(
        .init(artifact: artifact, active: latestActive, kept: latestKept))
      {
        return failed(reason)
      }
      do {
        try RemovalGate.remove(.init(path: artifact.path, expected: nil, method: .permanent))
        removed = true
      } catch { return failed("Could not remove this folder: \(error.localizedDescription)") }
    }
    guard removed else {
      return failed("Git refused removal or could not finish. Refresh to check this worktree.")
    }
    let win = CleanupWin(
      id: UUID().uuidString, date: .now,
      title: artifact.kind == .worktree
        ? "Removed worktree · \(artifact.name)" : "Removed dependencies · \(artifact.name)",
      paths: [artifact.path], before: before, after: before.flatMap { CleanupVolume.read($0.path) })
    return .init(
      path: artifact.path, removed: true,
      message: win.title + " · "
        + (win.measuredGain.map { ByteText.full($0) + " measured gain" }
          ?? "space measurement unavailable"),
      win: win)
  }

  /// Blockers that only protect files inside the folder; a forced removal keeps the branch and its commits.
  static let forceableWorktreeBlockers: Set<String> = [
    "Has ignored files. Review them first.", "Uncommitted or untracked files",
    "No verified merge into the base branch",
  ]

  static func canForce(_ artifact: DeveloperArtifact) -> Bool {
    artifact.kind == .worktree && artifact.internalVolume
      && artifact.blocker.map(forceableWorktreeBlockers.contains) == true
  }

  /// Removes a worktree whose only blockers are local files, after re-checking identity, use and open files.
  static func forceRemoveWorktree(_ artifact: DeveloperArtifact) -> DeveloperCleanupOutcome {
    func failed(_ reason: String) -> DeveloperCleanupOutcome {
      .init(path: artifact.path, removed: false, message: reason, win: nil)
    }
    guard canForce(artifact), let expected = artifact.worktree,
      CleanupVolume.read(artifact.path)?.isInternal == true
    else { return failed(artifact.blocker ?? "This worktree is protected") }
    guard let identity = artifact.identity, DirectoryIdentity.read(artifact.path) == identity,
      let current = GitWorktrees.list(expected.repository)?.first(where: {
        $0.path == expected.record.path
      }), current == expected.record
    else { return failed("Worktree changed. Refresh and review it again.") }
    let assessment = GitWorktrees.inspect(
      .init(
        repository: expected.repository, record: current,
        base: GitWorktrees.base(expected.repository),
        activeDirectories: CleanupActivity.workingDirectories(),
        keptDirectories: WorkspacePreferences.load().filter(\.keepRunning).map(\.directory)))
    if let reason = assessment.blocker, !forceableWorktreeBlockers.contains(reason) {
      return failed(reason)
    }
    let handles = CleanupActivity.command(["-nP", "-Fpcn", "+D", artifact.path])
    guard handles.status == 1, handles.output.isEmpty else {
      return failed("Files are open in an app. Close the project and try again.")
    }
    let before = CleanupVolume.read(artifact.path)
    let result = DeveloperCommand.run(
      .init(
        executable: "/usr/bin/git",
        arguments: [
          "-C", expected.repository, "worktree", "remove", "--force", "--", artifact.path,
        ],
        timeout: 180, maximumBytes: 65_536))
    guard result.status == 0, !FileManager.default.fileExists(atPath: artifact.path) else {
      return failed("Git could not remove this worktree. Refresh to check it.")
    }
    let win = CleanupWin(
      id: UUID().uuidString, date: .now, title: "Removed worktree · \(artifact.name)",
      paths: [artifact.path], before: before, after: before.flatMap { CleanupVolume.read($0.path) })
    return .init(
      path: artifact.path, removed: true,
      message: win.title + " · branch kept"
        + (win.measuredGain.map { " · " + ByteText.full($0) + " freed" } ?? ""),
      win: win)
  }

  struct DependencyValidation {
    let artifact: DeveloperArtifact
    let active: Set<String>?
    let kept: [String]
  }

  static func dependencyBlocker(_ input: DependencyValidation) -> String? {
    let artifact = input.artifact
    guard artifact.path.hasSuffix("/node_modules"), let identity = artifact.identity,
      DirectoryIdentity.read(artifact.path) == identity
    else { return "Dependency folder changed" }
    let context = NodeModulesResolver.resolve(
      .init(nodeModulesPath: artifact.path, fileManager: .default))
    guard context.origin == .project, context.cleanupTargetPath == artifact.path,
      context.projectRootPath == artifact.projectPath
    else { return "Project identity changed" }
    guard
      !input.kept.contains(where: {
        DeveloperPath.contains(.init(path: artifact.projectPath, root: $0))
      })
    else {
      return "Keep running is enabled"
    }
    guard let active = input.active else { return "Could not verify current activity" }
    if case .blocked(let reason) = NodeModulesSafety.evaluate(
      .init(
        context: context,
        activeWorkingDirectories: active, fileManager: .default))
    {
      return reason
    }
    if DeveloperCommand.git(
      .init(
        directory: artifact.projectPath,
        arguments: ["rev-parse", "--is-inside-work-tree"])
    ).status == 0 {
      let tracked = DeveloperCommand.git(
        .init(
          directory: artifact.projectPath,
          arguments: ["ls-files", "-z", "--", artifact.path]))
      guard tracked.status == 0, tracked.output.isEmpty else {
        return "Dependencies contain tracked files or Git could not verify them"
      }
    }
    return nil
  }
}
