import Foundation

@MainActor
final class DeveloperBrowserModel: ObservableObject {
  @Published private(set) var artifacts: [DeveloperArtifact] = []
  @Published private(set) var isScanning = false
  @Published private(set) var scannedAt: Date?
  @Published private(set) var progress = ""
  @Published private(set) var limited = false
  @Published private(set) var deleting: Set<String> = []
  @Published private(set) var messages: [String: String] = [:]
  @Published private(set) var lastWin: String?
  @Published private(set) var sessionGain: UInt64 = 0
  @Published private(set) var selectedFolder: String?
  private var scanTask: Task<Void, Never>?
  private var pending: [DeveloperArtifact] = []
  private var forced: Set<String> = []
  private var deleteTask: Task<Void, Never>?

  func loadIfNeeded() {
    if scannedAt == nil, !isScanning { scan() }
  }

  func cancel() { scanTask?.cancel() }

  func chooseFolder(_ folder: URL?) {
    guard !isScanning, deleting.isEmpty else { return }
    selectedFolder = folder?.path
    scan()
  }

  func scan() {
    guard !isScanning, deleting.isEmpty else { return }
    isScanning = true
    progress = "Finding linked worktrees…"
    limited = false
    let roots = selectedFolder.map { [$0] } ?? DeveloperArtifactScanner.roots
    let kept = WorkspacePreferences.load().filter(\.keepRunning).map(\.directory)
    scanTask = Task.detached(priority: .utility) { [weak self] in
      let discovery = DeveloperArtifactScanner.discover(
        .init(roots: roots, maximumEntries: 30_000, maximumDepth: 7))
      let active = CleanupActivity.workingDirectories()
      var repositories: Set<String> = []
      var allArtifacts: [DeveloperArtifact] = []
      var unreadable: [String] = []
      for repository in discovery.repositories {
        if Task.isCancelled { break }
        let listed = GitWorktrees.list(repository)
        if case .failure(let error) = listed {
          unreadable.append(
            "Couldn't read worktrees in \(PathName.last(repository)): \(error.reason)."
          )
        }
        guard let records = try? listed.get(), records.count > 1,
          let primary = records.first?.path,
          repositories.insert(primary).inserted
        else { continue }
        let repository = DirectoryIdentity.read(primary) == nil ? repository : primary
        let base = GitWorktrees.base(repository)
        for record in records.dropFirst().prefix(40) {
          if Task.isCancelled || allArtifacts.count >= 150 { break }
          await self?.setProgress(
            "Checking \(PathName.last(record.path))…")
          let assessment = GitWorktrees.inspect(
            .init(
              repository: repository, record: record, base: base,
              activeDirectories: active, keptDirectories: kept))
          let internalVolume = CleanupVolume.read(record.path)?.isInternal == true
          allArtifacts.append(
            .init(
              kind: .worktree, path: record.path, projectPath: record.path,
              technology: ProjectTechnology.detect(.init(directory: record.path, processName: "")),
              bytes: assessment.identity == nil ? nil : DeveloperCommand.bytes(record.path),
              modifiedAt: nil,
              blocker: assessment.blocker
                ?? (internalVolume ? nil : "On an external drive. Review it in Finder."),
              identity: assessment.identity, worktree: assessment, reinstallCommand: nil,
              internalVolume: internalVolume))
          await self?.publishProgress(allArtifacts)
        }
      }
      await self?.finish(
        .init(
          artifacts: allArtifacts,
          limited: discovery.limited || allArtifacts.count >= 150 || Task.isCancelled,
          unreadable: unreadable))
    }
  }

  private func setProgress(_ value: String) { progress = value }

  /// Partial results replace the list only on the first scan; a rescan keeps the old list until it finishes.
  private func publishProgress(_ values: [DeveloperArtifact]) {
    if scannedAt == nil { publish(values) }
  }

  private func publish(_ values: [DeveloperArtifact]) {
    artifacts = values.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
  }

  private struct Completion: Sendable {
    let artifacts: [DeveloperArtifact]
    let limited: Bool
    /// "Couldn't read worktrees in X: reason." for each repository Git could not list.
    let unreadable: [String]
  }

  private func finish(_ result: Completion) {
    publish(result.artifacts)
    isScanning = false
    scannedAt = .now
    limited = result.limited
    progress =
      result.unreadable.first.map {
        result.unreadable.count == 1
          ? $0 : "\($0) \(result.unreadable.count - 1) more repositories too."
      }
      ?? (result.limited
        ? "Partial scan. Some locations were unreadable or reached the scan limit. Choose a folder to narrow the scan."
        : "Scan complete")
    scanTask = nil
  }

  struct Removal {
    let artifact: DeveloperArtifact
    let history: CleanupOverviewModel
    /// Removes a worktree despite local-only blockers such as uncommitted or ignored files.
    let force: Bool
  }

  func remove(_ request: Removal) {
    let artifact = request.artifact
    let allowed =
      artifact.blocker == nil || (request.force && DeveloperArtifactCleanup.canForce(artifact))
    guard allowed, !deleting.contains(artifact.id) else { return }
    if isScanning { scanTask?.cancel() }
    deleting.insert(artifact.id)
    messages.removeValue(forKey: artifact.id)
    pending.append(artifact)
    if request.force { forced.insert(artifact.id) }
    guard deleteTask == nil else { return }
    deleteTask = Task { [weak self] in
      guard let self else { return }
      while !pending.isEmpty {
        while isScanning { try? await Task.sleep(for: .milliseconds(100)) }
        let next = pending.removeFirst()
        messages[next.id] = "Verifying and removing…"
        let force = forced.remove(next.id) != nil
        let outcome = await Task.detached(priority: .utility) {
          force
            ? DeveloperArtifactCleanup.forceRemoveWorktree(next)
            : DeveloperArtifactCleanup.remove(next)
        }.value
        deleting.remove(next.id)
        if outcome.removed {
          artifacts.removeAll { $0.path == next.path || $0.path.hasPrefix(next.path + "/") }
          lastWin = outcome.message
          if let win = outcome.win {
            sessionGain += win.measuredGain ?? 0
            request.history.record(win)
          }
        } else {
          messages[next.id] = outcome.message
        }
      }
      deleteTask = nil
    }
  }
}
