import Foundation

enum DeveloperArtifactKind: String, Sendable {
  case worktree = "Worktrees"
  case dependencies = "Dependencies"
}

struct DeveloperArtifact: Identifiable, Sendable {
  let kind: DeveloperArtifactKind
  let path: String
  let projectPath: String
  let technology: ProjectTechnology
  let bytes: UInt64?
  let modifiedAt: Date?
  let blocker: String?
  let identity: DirectoryIdentity?
  let worktree: WorktreeAssessment?
  let reinstallCommand: String?
  let internalVolume: Bool
  var id: String { path }
  var name: String { URL(fileURLWithPath: projectPath).lastPathComponent }

  func withBlocker(_ reason: String?) -> Self {
    .init(
      kind: kind, path: path, projectPath: projectPath, technology: technology, bytes: bytes,
      modifiedAt: modifiedAt, blocker: reason, identity: identity, worktree: worktree,
      reinstallCommand: reinstallCommand, internalVolume: internalVolume)
  }
}

struct DeveloperDiscovery: Sendable {
  let repositories: [String]
  let dependencies: [String]
  let limited: Bool
}

enum DeveloperArtifactScanner {
  static var roots: [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
      "\(home)/dev", "\(home)/Developer", "\(home)/Projects", "\(home)/.codex/worktrees",
      "\(home)/.claude/worktrees",
    ]
      + DeveloperLocations.additionalProjectRoots + WorkspacePreferences.load().map(\.directory)
  }

  struct DiscoveryRequest: Sendable {
    let roots: [String]
    let maximumEntries: Int
    let maximumDepth: Int
  }

  static func discover(_ request: DiscoveryRequest) -> DeveloperDiscovery {
    var repositories: Set<String> = []
    var dependencies: Set<String> = []
    var visited: Set<String> = []
    var remaining = request.maximumEntries
    var limited = false
    let ignored: Set<String> = [
      ".git", ".next", ".build", ".pnpm", ".venv", "Pods", "build", "dist", "Library", ".Trash",
    ]
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
    for root in Set(request.roots).sorted() {
      guard let path = ReviewFile.canonicalPath(root) else { continue }
      let url = URL(fileURLWithPath: path)
      if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
        repositories.insert(path)
      }
      guard
        let enumerator = FileManager.default.enumerator(
          at: url, includingPropertiesForKeys: Array(keys),
          options: [],
          errorHandler: { _, _ in
            limited = true
            return true
          })
      else { continue }
      for case let child as URL in enumerator {
        if remaining <= 0 || Task.isCancelled {
          limited = true
          break
        }
        remaining -= 1
        guard let values = try? child.resourceValues(forKeys: keys) else {
          limited = true
          continue
        }
        let name = child.lastPathComponent
        if values.isSymbolicLink == true {
          enumerator.skipDescendants()
          continue
        }
        if name == ".git" {
          repositories.insert(child.deletingLastPathComponent().path)
          enumerator.skipDescendants()
        } else if values.isDirectory == true {
          if name == "node_modules" {
            dependencies.insert(child.path)
            enumerator.skipDescendants()
          } else if ignored.contains(name) || values.isPackage == true
            || !visited.insert(child.path).inserted
          {
            enumerator.skipDescendants()
          } else if enumerator.level >= request.maximumDepth {
            limited = true
            enumerator.skipDescendants()
          }
        }
      }
      if remaining <= 0 || Task.isCancelled { break }
    }
    return .init(
      repositories: Array(repositories.sorted().prefix(150)),
      dependencies: Array(dependencies.sorted().prefix(300)),
      limited: limited || repositories.count > 150 || dependencies.count > 300)
  }

  struct DependencyRequest: Sendable {
    let path: String
    let activeDirectories: Set<String>?
    let keptDirectories: [String]
  }

  static func dependency(_ input: DependencyRequest) -> DeveloperArtifact {
    let path = input.path
    let context = NodeModulesResolver.resolve(.init(nodeModulesPath: path, fileManager: .default))
    let root =
      context.projectRootPath ?? URL(fileURLWithPath: path).deletingLastPathComponent().path
    let identity = DirectoryIdentity.read(path)
    var blocker: String?
    if identity == nil {
      blocker = "Folder missing or replaced by a link"
    } else if context.origin != .project || context.cleanupTargetPath != path {
      blocker = "Managed cache — use Storage"
    } else if input.keptDirectories.contains(where: {
      DeveloperPath.contains(.init(path: root, root: $0))
    }) {
      blocker = "Keep running is enabled"
    } else if let active = input.activeDirectories {
      if case .blocked(let reason) = NodeModulesSafety.evaluate(
        .init(
          context: context,
          activeWorkingDirectories: active, fileManager: .default))
      {
        blocker = reason
      }
    } else {
      blocker = "Could not verify running processes"
    }
    let internalVolume = CleanupVolume.read(path)?.isInternal == true
    if blocker == nil, !internalVolume { blocker = "External drive — review in Finder" }
    let artifact = DeveloperArtifact(
      kind: .dependencies, path: path, projectPath: root,
      technology: ProjectTechnology.detect(.init(directory: root, processName: "node")),
      bytes: DeveloperCommand.bytes(path),
      modifiedAt: try? URL(fileURLWithPath: path).resourceValues(forKeys: [
        .contentModificationDateKey
      ]).contentModificationDate,
      blocker: blocker, identity: identity, worktree: nil,
      reinstallCommand: reinstall(context.lockfilePath), internalVolume: internalVolume)
    return artifact.withBlocker(
      blocker
        ?? DeveloperArtifactCleanup.dependencyBlocker(
          .init(artifact: artifact, active: input.activeDirectories, kept: input.keptDirectories)))
  }

  static func reinstall(_ lockfile: String?) -> String? {
    switch lockfile.map({ URL(fileURLWithPath: $0).lastPathComponent }) {
    case "package-lock.json": "npm ci"
    case "pnpm-lock.yaml": "pnpm install --frozen-lockfile"
    case "yarn.lock": "yarn install --frozen-lockfile"
    case "bun.lock", "bun.lockb": "bun install --frozen-lockfile"
    default: nil
    }
  }
}
