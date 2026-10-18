import Foundation
import Testing

@testable import BlitzClean

struct StorageGuidanceTests {
  @Test func managedPayloadsInTheScreenshotAreNotRawTrashCandidates() {
    let paths = [
      "/Users/me/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
      "/Users/me/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img",
      "/Users/me/.codex/thread_history_1.sqlite",
      "/Users/me/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel/v1/weights.bin",
      "/Users/me/dev/app/.git/objects/pack/data.pack",
      "/Users/me/dev/app/.env.local",
      "/Users/me/Library",
      "/Users/me/Library/Application Support",
      "/Volumes/harddrive/.Trashes/501/original.mov",
    ]
    for path in paths {
      #expect(!ReviewFileDeletion.canTrashPath(path))
      #expect(!ReviewFileDeletion.canTrashPath("/System/Volumes/Data" + path))
    }
  }

  @Test func identifiesOwnersWithoutNeedingRunningApps() {
    #expect(StorageOwner.forPath("/System/Volumes/Data/Users/me/.codex/history.sqlite") == .codex)
    #expect(
      StorageOwner.forPath("/Users/me/Library/Application Support/Claude/vm/rootfs.img") == .claude)
    #expect(StorageOwner.forPath("/Users/me/Library/Containers/com.docker.docker/data") == .docker)
    #expect(StorageOwner.named("Codex")?.bundleIDs.first == "com.openai.codex")
    #expect(StorageOwner.named("Claude Code")?.bundleIDs.first == "com.anthropic.claudefordesktop")
    #expect(StorageOwner.forPath("/Volumes/harddrive/projects/claude/notes.txt") == nil)
    #expect(StorageOwner.forPath("/Users/me/.codex-backup/notes.txt") == nil)
  }

  @Test func sizeAndLocationDoNotMakePersonalDataSafe() {
    for path in ["/Volumes/harddrive/recordings/original.mov", "/Users/me/Documents/contract.pdf"] {
      #expect(StorageGuidance.read(path).kind == .review)
      #expect(StorageGuidance.read(path).cleanup == nil)
      #expect(ReviewFileDeletion.canTrashPath(path))
    }
    #expect(
      StorageGuidance.read("/Volumes/harddrive/Downloads/installer.dmg").reason.contains(
        "if installation is finished"))
  }

  @Test func routesCacheActionsToTheirProjectAndDockerToDocker() {
    let path = "/Volumes/harddrive/work/project/node_modules/dependency/file.js"
    #expect(StorageGuidance.read(path).cleanup == .projects)
    #expect(ReviewFileDeletion.canTrashPath(path))
    #expect(
      StorageCleanupRoute(focus: .projects, path: path).projectRoot
        == "/Volumes/harddrive/work/project")
    #expect(
      StorageGuidance.read("/Users/me/Library/Containers/com.docker.docker/Data/Docker.raw").cleanup
        == .docker)
  }

  @Test func inventoryUsesVerifiedEligibilityAndPreservesBlockedReasons() {
    func item(_ availability: StorageCleanupAvailability) -> StorageItem {
      .init(
        name: "app", path: "/Volumes/harddrive/app/node_modules", bytes: 100,
        cleanupKind: .nodeModules, cleanupAvailability: availability, lastActivityAt: nil,
        contentBytes: nil, nodeOrigin: nil, projectRootPath: nil, dependencyInstalledAt: nil,
        activeProcesses: nil)
    }
    #expect(StorageGuidance.read(item(.ready)).reason.contains("checks passed"))
    #expect(
      StorageGuidance.read(item(.blocked("Project is in use"))).reason == "Kept · Project is in use"
    )
    #expect(
      !StorageGuidance.read("/Volumes/harddrive/app/node_modules").reason.contains("checks passed"))
  }

  @Test func selectedLocationScanFindsRebuildableDataWithoutScanningHome() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(
      at: project.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
    try Data("{}".utf8).write(to: project.appendingPathComponent("package-lock.json"))
    let path = try #require(ReviewFile.canonicalPath(root.path))
    let scanner = StorageBreakdownScanner(measure: { _ in .init(allocated: 4096, content: 10) })
    let result = scanner.scan(.init(scope: .inventory, inventoryRoot: path, onUpdate: { _ in }))
    #expect(
      result.categories.allSatisfy {
        $0.items.allSatisfy { ReviewFile.canonicalPath($0.path)?.hasPrefix(path + "/") == true }
      })
    let dependency = try #require(
      result.categories.flatMap(\.items).first { $0.cleanupKind == .nodeModules })
    #expect(dependency.path.hasSuffix("/project/node_modules"))
    #expect(dependency.cleanupAvailability == .ready)
    #expect(!result.categories.contains { $0.id == "computer-applications" })
  }

  @Test func generatedCleanupCannotExpandOutsideTheSelectedFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let selected = root.appendingPathComponent(".trigger/tmp/one")
    try FileManager.default.createDirectory(
      at: selected.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))
    try Data("{}".utf8).write(to: root.appendingPathComponent("package-lock.json"))
    let scanner = StorageBreakdownScanner(measure: { _ in .init(allocated: 4096, content: 10) })
    let result = scanner.scan(
      .init(scope: .cleanup, inventoryRoot: selected.path, onUpdate: { _ in }))
    #expect(result.categories.flatMap(\.items).isEmpty)
  }

  @Test func boundedDiscoveryReportsLimitsAndDoesNotFollowLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside/node_modules")
    let selected = root.appendingPathComponent("selected")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: selected.appendingPathComponent("linked"),
      withDestinationURL: outside.deletingLastPathComponent())
    let result = DependencyFileScan.discoverWithin(
      .init(root: selected.path, deadline: .now.addingTimeInterval(1), maximumEntries: 100))
    #expect(result.paths.isEmpty)
    #expect(result.complete)
    let expired = DependencyFileScan.discoverWithin(
      .init(root: root.path, deadline: .distantPast, maximumEntries: 100))
    #expect(!expired.complete)
    #expect(expired.paths.isEmpty)
  }
}

struct ChosenDeletionTests {
  @Test func browseCanDeleteAppDataTheUserPicksButNotProtectedFolders() {
    let home = NSHomeDirectory()
    #expect(ReviewFileDeletion.canDeleteWhenChosen(home + "/.codex/worktrees/old"))
    #expect(ReviewFileDeletion.canDeleteWhenChosen(home + "/Library/Application Support/Google"))
    #expect(!ReviewFileDeletion.canDeleteWhenChosen(home + "/Library/Application Support"))
    #expect(!ReviewFileDeletion.canDeleteWhenChosen(home + "/dev/app/.git"))
    #expect(!ReviewFileDeletion.canDeleteWhenChosen("/System/Library/Fonts"))
  }
}
