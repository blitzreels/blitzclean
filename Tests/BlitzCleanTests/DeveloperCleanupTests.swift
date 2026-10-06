import Foundation
import Testing

@testable import BlitzClean

struct DeveloperCleanupTests {
  @Test
  func nodeModulesReadyWithManifestAndLockfile() throws {
    let fixture = try ProjectFixture(lockfile: "pnpm-lock.yaml")
    defer { fixture.remove() }

    let result = NodeModulesSafety.evaluate(
      NodeModulesSafetyRequest(
        context: context(fixture.nodeModulesPath),
        activeWorkingDirectories: [],
        fileManager: .default
      )
    )

    #expect(result == .ready)
  }

  @Test
  func nodeModulesBlockedWithoutLockfile() throws {
    let fixture = try ProjectFixture(lockfile: nil)
    defer { fixture.remove() }

    let result = NodeModulesSafety.evaluate(
      NodeModulesSafetyRequest(
        context: context(fixture.nodeModulesPath),
        activeWorkingDirectories: [],
        fileManager: .default
      )
    )

    #expect(result == .blocked("No exact reinstall lock"))
  }

  @Test
  func nodeModulesBlockedWhenProjectIsActive() throws {
    let fixture = try ProjectFixture(lockfile: "yarn.lock")
    defer { fixture.remove() }

    let result = NodeModulesSafety.evaluate(
      NodeModulesSafetyRequest(
        context: context(fixture.nodeModulesPath),
        activeWorkingDirectories: [fixture.projectPath + "/apps/web"],
        fileManager: .default
      )
    )

    #expect(result == .blocked("Project is in use"))
  }

  @Test
  func monorepoPackageUsesWorkspaceLockfile() throws {
    let fixture = try MonorepoFixture()
    defer { fixture.remove() }

    let context = context(fixture.nodeModulesPath)

    #expect(context.projectRootPath == fixture.projectPath)
    #expect(context.lockfilePath == fixture.projectPath + "/pnpm-lock.yaml")
    #expect(
      context.displayName
        == "\(fixture.projectURL.lastPathComponent) · packages/config"
    )
  }

  @Test
  func generatedVercelDependenciesCollapseToOutput() throws {
    let fixture = try MonorepoFixture()
    defer { fixture.remove() }
    let generatedPath =
      fixture.projectPath
      + "/apps/web/.vercel/output/functions/server.func/node_modules"
    try FileManager.default.createDirectory(
      atPath: generatedPath,
      withIntermediateDirectories: true
    )

    let context = context(generatedPath)

    #expect(context.origin == .vercelBuild)
    #expect(context.cleanupTargetPath == fixture.projectPath + "/apps/web/.vercel/output")
    #expect(
      context.displayName
        == "Vercel builds · \(fixture.projectURL.lastPathComponent)"
    )
  }

  @Test
  func projectActivityUsesNewestRealFile() throws {
    let fixture = try ProjectFixture(lockfile: "package-lock.json")
    defer { fixture.remove() }
    let sourceURL = fixture.projectURL.appendingPathComponent("public/assets/slide.png")
    try FileManager.default.createDirectory(
      at: sourceURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data().write(to: sourceURL)
    let expected = Date(timeIntervalSince1970: 1_900_000_000)
    try FileManager.default.setAttributes(
      [.modificationDate: expected],
      ofItemAtPath: sourceURL.path
    )
    let ignoredURL = fixture.projectURL.appendingPathComponent("node_modules/newer.js")
    try Data().write(to: ignoredURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
      ofItemAtPath: ignoredURL.path
    )

    let result = ProjectActivityResolver.latestChange(
      ProjectActivityRequest(rootPath: fixture.projectPath, fileManager: .default)
    )

    #expect(result == expected)
  }

  @Test
  func cleanupCountsOnlySuccessfulDeletes() {
    let service = DeveloperCleanupService { url in
      if url.lastPathComponent == "failed" {
        throw CleanupTestError.failed
      }
    }
    let result = service.clean(
      CleanupRequest(
        items: [
          cleanupItem(path: "/tmp/cleaned", bytes: 2_000),
          cleanupItem(path: "/tmp/failed", bytes: 9_000),
        ]
      )
    )

    #expect(result.cleanedPaths == ["/tmp/cleaned"])
    #expect(result.recoveredBytes == 2_000)
    #expect(result.failureCount == 1)
  }

  private func cleanupItem(_ input: CleanupItemInput) -> StorageItem {
    StorageItem(
      name: URL(fileURLWithPath: input.path).lastPathComponent,
      path: input.path,
      bytes: input.bytes,
      cleanupKind: .nodeModules,
      cleanupAvailability: .ready,
      lastActivityAt: nil,
      contentBytes: nil,
      nodeOrigin: .project,
      projectRootPath: nil,
      dependencyInstalledAt: nil,
      activeProcesses: nil
    )
  }

  private func context(_ path: String) -> NodeModulesContext {
    NodeModulesResolver.resolve(
      NodeModulesResolutionRequest(
        nodeModulesPath: path,
        fileManager: .default
      )
    )
  }

  private func cleanupItem(path: String, bytes: UInt64) -> StorageItem {
    cleanupItem(CleanupItemInput(path: path, bytes: bytes))
  }
}

private struct CleanupItemInput {
  let path: String
  let bytes: UInt64
}

private enum CleanupTestError: Error {
  case failed
}

private struct ProjectFixture {
  let projectURL: URL

  init(lockfile: String?) throws {
    projectURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: projectURL.appendingPathComponent("node_modules"),
      withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: projectURL.appendingPathComponent("package.json"))

    if let lockfile {
      try Data().write(to: projectURL.appendingPathComponent(lockfile))
    }
  }

  var projectPath: String {
    projectURL.path
  }

  var nodeModulesPath: String {
    projectURL.appendingPathComponent("node_modules").path
  }

  func remove() {
    try? FileManager.default.removeItem(at: projectURL)
  }
}

private struct MonorepoFixture {
  let projectURL: URL

  init() throws {
    projectURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: projectURL.appendingPathComponent("packages/config/node_modules"),
      withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: projectURL.appendingPathComponent("package.json"))
    try Data().write(to: projectURL.appendingPathComponent("pnpm-lock.yaml"))
    try Data("{}".utf8).write(
      to: projectURL.appendingPathComponent("packages/config/package.json")
    )
  }

  var projectPath: String {
    projectURL.path
  }

  var nodeModulesPath: String {
    projectURL.appendingPathComponent("packages/config/node_modules").path
  }

  func remove() {
    try? FileManager.default.removeItem(at: projectURL)
  }
}
