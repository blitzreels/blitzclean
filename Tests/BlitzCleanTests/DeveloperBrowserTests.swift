import Foundation
import Testing

@testable import BlitzClean

@Suite(.serialized)
struct DeveloperBrowserTests {
  @Test @MainActor
  func queuesTwoRemovalsAndRemovesCompletedRowsWithReceipts() async throws {
    let fixture = try DeveloperFixture()
    defer { fixture.remove() }
    for name in ["one", "two"] {
      try fixture.write(.init(path: name + "/package.json", value: "{}"))
      try fixture.write(.init(path: name + "/package-lock.json", value: "{}"))
      try fixture.write(
        .init(path: name + "/node_modules/fixture", value: "temporary dependencies"))
    }
    let history = CleanupOverviewModel(
      .init(
        store: .init(url: URL(fileURLWithPath: fixture.root + "/history.json")),
        scanRequest: .init(roots: [], minimumBytes: 1, maxEntries: 1),
        synchronizesInBackground: false))
    let model = DeveloperBrowserModel()
    let deadline = Date.now.addingTimeInterval(25)
    let artifacts = ["one", "two"].map {
      DeveloperArtifactScanner.dependency(
        .init(
          path: fixture.root + "/\($0)/node_modules", activeDirectories: [],
          keptDirectories: []))
    }
    #expect(artifacts.allSatisfy { $0.blocker == nil })
    for artifact in artifacts { model.remove(.init(artifact: artifact, history: history)) }
    #expect(model.deleting.count == 2)
    while !model.deleting.isEmpty, Date.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.deleting.isEmpty)
    #expect(model.artifacts.isEmpty)
    #expect(history.ledger.wins.count == 2)
    #expect(FileManager.default.fileExists(atPath: fixture.root + "/one/package-lock.json"))
    #expect(FileManager.default.fileExists(atPath: fixture.root + "/two/package-lock.json"))
  }

  @Test
  func detectsFrameworksFromActualDependencies() throws {
    let fixture = try DeveloperFixture()
    defer { fixture.remove() }
    try fixture.write(
      .init(
        path: "package.json",
        value: #"{"devDependencies":{"@tanstack/react-start":"1"},"dependencies":{"react":"19"}}"#))
    #expect(
      ProjectTechnology.detect(.init(directory: fixture.root, processName: "vite")) == .tanstack)
    try fixture.write(
      .init(
        path: "package.json", value: #"{"dependencies":{"next":"16","@tanstack/react-query":"5"}}"#)
    )
    #expect(ProjectTechnology.detect(.init(directory: fixture.root, processName: "node")) == .next)
    try fixture.write(
      .init(
        path: "package.json", value: #"{"name":"not-next-a-tanstack-project","dependencies":{}}"#))
    #expect(ProjectTechnology.detect(.init(directory: fixture.root, processName: "node")) == .node)
  }

  @Test
  func discoveryPrunesDependenciesAndSymbolicLinks() throws {
    let fixture = try DeveloperFixture()
    defer { fixture.remove() }
    try fixture.write(.init(path: "app/.git", value: "gitdir: unused"))
    try fixture.write(
      .init(path: "app/node_modules/package/node_modules/ignored", value: "fixture"))
    try fixture.write(.init(path: "outside/node_modules/fixture", value: "fixture"))
    try FileManager.default.createSymbolicLink(
      atPath: fixture.root + "/app/linked", withDestinationPath: fixture.root + "/outside")
    let result = DeveloperArtifactScanner.discover(
      .init(roots: [fixture.root + "/app"], maximumEntries: 100, maximumDepth: 6))
    #expect(result.dependencies == [fixture.root + "/app/node_modules"])
    #expect(result.repositories == [fixture.root + "/app"])
    let limited = DeveloperArtifactScanner.discover(
      .init(roots: [fixture.root], maximumEntries: 1, maximumDepth: 6))
    #expect(limited.limited)
  }

  @Test
  func parsesNullDelimitedWorktreesWithSpacesAndNewlines() {
    let result = GitWorktrees.parse(
      "worktree /tmp/main\0HEAD abc\0branch refs/heads/main\0\0worktree /tmp/topic with\nnewline\0HEAD def\0detached\0locked user reason\0\0"
    )
    #expect(result.count == 2)
    #expect(result[0].primary)
    #expect(result[1].path == "/tmp/topic with\nnewline")
    #expect(result[1].locked && result[1].branch == nil)
  }

  @Test
  func onlyCleanMergedLinkedWorktreeCanBeRemovedAndBranchSurvives() throws {
    let fixture = try DeveloperFixture()
    defer { fixture.remove() }
    let assessment = try fixture.worktree()
    #expect(assessment.merge == .merged)
    #expect(assessment.blocker == nil)
    let outcome = DeveloperArtifactCleanup.remove(fixture.artifact(assessment))
    #expect(outcome.removed)
    #expect(!FileManager.default.fileExists(atPath: assessment.record.path))
    #expect(
      DeveloperCommand.git(
        .init(
          directory: fixture.root,
          arguments: ["show-ref", "--verify", "refs/heads/topic"])
      ).status == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.root + "/source.txt"))
  }

  @Test
  func dirtyAndIgnoredFilesBlockEvenMergedWorktrees() throws {
    let fixture = try DeveloperFixture()
    defer { fixture.remove() }
    var assessment = try fixture.worktree()
    try fixture.write(.init(path: "linked/.env", value: "fixture-only"))
    assessment = fixture.inspect(assessment.record)
    #expect(assessment.merge == .merged)
    #expect(assessment.blocker == "Has ignored files. Review them first.")
    try fixture.write(.init(path: "linked/source.txt", value: "unsaved edits"))
    #expect(fixture.inspect(assessment.record).blocker == "Uncommitted or untracked files")
    #expect(!DeveloperArtifactCleanup.remove(fixture.artifact(assessment)).removed)
    #expect(FileManager.default.fileExists(atPath: fixture.root + "/linked/.env"))
  }

  @Test
  func revalidatesCommitAndDirtyStateAfterReview() throws {
    let fixture = try DeveloperFixture()
    defer { fixture.remove() }
    let assessment = try fixture.worktree()
    try fixture.write(.init(path: "linked/new.txt", value: "new work"))
    #expect(
      GitWorktrees.validateRemoval(
        .init(expected: assessment, activeDirectories: [], keptDirectories: [])) != nil)
    try fixture.git(.init(directory: assessment.record.path, arguments: ["add", "new.txt"]))
    try fixture.git(
      .init(directory: assessment.record.path, arguments: ["commit", "-m", "unmerged"]))
    #expect(
      GitWorktrees.validateRemoval(
        .init(expected: assessment, activeDirectories: [], keptDirectories: [])) != nil)
    let current = try #require(GitWorktrees.list(fixture.root)?.first { !$0.primary })
    #expect(fixture.inspect(current).merge == .unverified)
  }

  @Test
  func protectsPrimaryLockedDetachedActiveAndPinnedWorktrees() throws {
    let fixture = try DeveloperFixture()
    defer { fixture.remove() }
    let assessment = try fixture.worktree()
    let primary = try #require(GitWorktrees.list(fixture.root)?.first)
    #expect(fixture.inspect(primary).blocker == "Primary checkout")
    #expect(
      GitWorktrees.inspect(
        .init(
          repository: fixture.root, record: assessment.record,
          base: assessment.base, activeDirectories: [assessment.record.path + "/src"],
          keptDirectories: [])
      ).blocker == "Project is in use")
    #expect(
      GitWorktrees.inspect(
        .init(
          repository: fixture.root, record: assessment.record,
          base: assessment.base, activeDirectories: [], keptDirectories: [assessment.record.path])
      ).blocker == "Keep running is enabled")
    #expect(
      GitWorktrees.inspect(
        .init(
          repository: fixture.root, record: assessment.record,
          base: assessment.base, activeDirectories: nil, keptDirectories: [])
      ).blocker != nil)
    try fixture.git(
      .init(directory: fixture.root, arguments: ["worktree", "lock", assessment.record.path]))
    let locked = try #require(GitWorktrees.list(fixture.root)?.first { !$0.primary })
    #expect(fixture.inspect(locked).blocker == "Worktree is locked")
    try fixture.git(
      .init(directory: fixture.root, arguments: ["worktree", "unlock", assessment.record.path]))
    try fixture.git(.init(directory: assessment.record.path, arguments: ["checkout", "--detach"]))
    let detached = try #require(GitWorktrees.list(fixture.root)?.first { !$0.primary })
    #expect(fixture.inspect(detached).blocker == "Detached HEAD. Save its commits first.")
  }

  @Test
  func dependencyDeletionPreservesSourceAndLockfile() throws {
    let fixture = try DeveloperFixture()
    defer { fixture.remove() }
    try fixture.dependencies()
    let artifact = DeveloperArtifactScanner.dependency(
      .init(
        path: fixture.root + "/node_modules",
        activeDirectories: [], keptDirectories: []))
    #expect(artifact.reinstallCommand == "npm ci")
    #expect(artifact.blocker == nil)
    let result = DeveloperArtifactCleanup.remove(artifact)
    #expect(result.removed)
    #expect(!FileManager.default.fileExists(atPath: artifact.path))
    #expect(FileManager.default.fileExists(atPath: fixture.root + "/package-lock.json"))
    #expect(FileManager.default.fileExists(atPath: fixture.root + "/source.txt"))
  }

  @Test
  func missingLockfileAndTrackedDependenciesCannotBeRemoved() throws {
    let fixture = try DeveloperFixture()
    defer { fixture.remove() }
    try fixture.dependencies()
    try fixture.git(.init(directory: fixture.root, arguments: ["init", "-b", "main"]))
    try fixture.git(.init(directory: fixture.root, arguments: ["add", "node_modules"]))
    let artifact = DeveloperArtifactScanner.dependency(
      .init(
        path: fixture.root + "/node_modules",
        activeDirectories: [], keptDirectories: []))
    #expect(
      DeveloperArtifactCleanup.dependencyBlocker(.init(artifact: artifact, active: [], kept: []))
        != nil)
    try FileManager.default.removeItem(atPath: fixture.root + "/package-lock.json")
    #expect(
      DeveloperArtifactScanner.dependency(
        .init(
          path: artifact.path,
          activeDirectories: [], keptDirectories: [])
      ).blocker == "No exact reinstall lock")
  }

  @Test
  func replacedDependencyDirectoryFailsIdentityValidation() throws {
    let fixture = try DeveloperFixture()
    defer { fixture.remove() }
    try fixture.dependencies()
    let artifact = DeveloperArtifactScanner.dependency(
      .init(
        path: fixture.root + "/node_modules",
        activeDirectories: [], keptDirectories: []))
    try FileManager.default.moveItem(atPath: artifact.path, toPath: fixture.root + "/original")
    try fixture.write(.init(path: "node_modules/new", value: "new instance"))
    #expect(!DeveloperArtifactCleanup.remove(artifact).removed)
    #expect(FileManager.default.fileExists(atPath: artifact.path + "/new"))
  }

  @Test
  func commandOutputIsBounded() {
    let result = DeveloperCommand.run(
      .init(executable: "/usr/bin/yes", arguments: [], timeout: 2, maximumBytes: 1_024))
    #expect(result.status == -1)
    #expect(result.output.utf8.count <= 1_024)
  }
}

private struct DeveloperFixture {
  let root: String

  init() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "blitzclean-browser-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    root = try #require(ReviewFile.canonicalPath(directory.path))
  }

  func remove() { try? FileManager.default.removeItem(atPath: root) }

  struct File {
    let path: String
    let value: String
  }

  func write(_ file: File) throws {
    let url = URL(fileURLWithPath: root).appendingPathComponent(file.path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(file.value.utf8).write(to: url)
  }

  func git(_ request: DeveloperCommand.GitRequest) throws {
    let result = DeveloperCommand.git(request)
    #expect(result.status == 0)
    guard result.status == 0 else { throw CocoaError(.fileReadUnknown) }
  }

  func worktree() throws -> WorktreeAssessment {
    try git(.init(directory: root, arguments: ["init", "-b", "main"]))
    try git(.init(directory: root, arguments: ["config", "user.email", "fixture@example.invalid"]))
    try git(.init(directory: root, arguments: ["config", "user.name", "BlitzClean fixture"]))
    try git(.init(directory: root, arguments: ["config", "commit.gpgsign", "false"]))
    try write(.init(path: "source.txt", value: "committed source"))
    try write(.init(path: ".gitignore", value: ".env\nlinked/\nnode_modules/\n"))
    try git(.init(directory: root, arguments: ["add", "source.txt", ".gitignore"]))
    try git(.init(directory: root, arguments: ["commit", "-m", "initial"]))
    try git(
      .init(directory: root, arguments: ["worktree", "add", "-b", "topic", root + "/linked"]))
    let record = try #require(GitWorktrees.list(root)?.first { !$0.primary })
    return inspect(record)
  }

  func inspect(_ record: GitWorktreeRecord) -> WorktreeAssessment {
    GitWorktrees.inspect(
      .init(
        repository: root, record: record, base: GitWorktrees.base(root),
        activeDirectories: [], keptDirectories: []))
  }

  func artifact(_ assessment: WorktreeAssessment) -> DeveloperArtifact {
    .init(
      kind: .worktree, path: assessment.record.path, projectPath: assessment.record.path,
      technology: .unknown, bytes: 1_024, modifiedAt: nil, blocker: assessment.blocker,
      identity: assessment.identity, worktree: assessment, reinstallCommand: nil,
      internalVolume: true)
  }

  func dependencies() throws {
    try write(.init(path: "package.json", value: "{}"))
    try write(.init(path: "package-lock.json", value: "{}"))
    try write(.init(path: "source.txt", value: "source survives"))
    try write(.init(path: "node_modules/fixture.txt", value: "rebuildable fixture"))
  }
}
