import Darwin
import Foundation

enum NodeStorageOrigin: String, Codable, Sendable {
  case project
  case npmCache
  case vercelBuild
  case triggerBuild

  var isGenerated: Bool {
    self != .project
  }
}

struct NodeModulesContext: Equatable, Sendable {
  let nodeModulesPath: String
  let cleanupTargetPath: String
  let projectRootPath: String?
  let displayName: String
  let origin: NodeStorageOrigin
  let manifestPath: String?
  let lockfilePath: String?
}

struct NodeModulesResolutionRequest {
  let nodeModulesPath: String
  let fileManager: FileManager
}

enum NodeModulesResolver {
  static let lockfiles = [
    "package-lock.json",
    "pnpm-lock.yaml",
    "yarn.lock",
    "bun.lock",
    "bun.lockb",
  ]

  static func resolve(_ request: NodeModulesResolutionRequest) -> NodeModulesContext {
    let path = URL(fileURLWithPath: request.nodeModulesPath).standardized.path
    let generated = generatedTarget(path)
    let immediateProject = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let projectSearchStart = generated?.projectSearchStart ?? immediateProject
    let project = findProject(
      ProjectSearchRequest(
        startPath: projectSearchStart,
        fileManager: request.fileManager
      )
    )
    let origin = generated?.origin ?? .project
    let target = generated?.targetPath ?? path

    return NodeModulesContext(
      nodeModulesPath: path,
      cleanupTargetPath: target,
      projectRootPath: project?.rootPath,
      displayName: displayName(
        DisplayNameRequest(
          immediateProjectPath: immediateProject,
          projectRootPath: project?.rootPath,
          origin: origin
        )
      ),
      origin: origin,
      manifestPath: project?.manifestPath,
      lockfilePath: project?.lockfilePath
    )
  }

  private static func generatedTarget(_ path: String) -> GeneratedTarget? {
    let rules = [
      GeneratedRule(marker: "/.npm/_npx/", origin: .npmCache, targetSuffix: "/.npm/_npx"),
      GeneratedRule(
        marker: "/.vercel/output/", origin: .vercelBuild, targetSuffix: "/.vercel/output"),
      GeneratedRule(marker: "/.trigger/tmp/", origin: .triggerBuild, targetSuffix: "/.trigger/tmp"),
    ]

    for rule in rules {
      guard let range = path.range(of: rule.marker) else {
        continue
      }

      let prefix = String(path[..<range.lowerBound])
      return GeneratedTarget(
        targetPath: prefix + rule.targetSuffix,
        projectSearchStart: prefix,
        origin: rule.origin
      )
    }

    return nil
  }

  private static func findProject(_ request: ProjectSearchRequest) -> ProjectMatch? {
    var current = URL(fileURLWithPath: request.startPath).standardized
    var nearestManifest: (path: String, root: String)?

    for _ in 0..<16 {
      let rootPath = current.path
      let manifestPath = current.appendingPathComponent("package.json").path
      if nearestManifest == nil, request.fileManager.fileExists(atPath: manifestPath) {
        nearestManifest = (manifestPath, rootPath)
      }

      if let lockfile = lockfiles.first(where: { filename in
        request.fileManager.fileExists(atPath: current.appendingPathComponent(filename).path)
      }) {
        let resolvedManifest =
          request.fileManager.fileExists(atPath: manifestPath)
          ? manifestPath
          : nearestManifest?.path
        return ProjectMatch(
          rootPath: rootPath,
          manifestPath: resolvedManifest,
          lockfilePath: current.appendingPathComponent(lockfile).path
        )
      }

      let parent = current.deletingLastPathComponent()
      guard parent.path != current.path else {
        break
      }
      current = parent
    }

    guard let nearestManifest else {
      return nil
    }

    return ProjectMatch(
      rootPath: nearestManifest.root,
      manifestPath: nearestManifest.path,
      lockfilePath: nil
    )
  }

  private static func displayName(_ request: DisplayNameRequest) -> String {
    switch request.origin {
    case .npmCache:
      return "npx cache"
    case .vercelBuild:
      return "Vercel builds · \(rootName(request.projectRootPath))"
    case .triggerBuild:
      return "Trigger builds · \(rootName(request.projectRootPath))"
    case .project:
      guard let projectRootPath = request.projectRootPath else {
        return URL(fileURLWithPath: request.immediateProjectPath).lastPathComponent
      }

      let root = rootName(projectRootPath)
      guard request.immediateProjectPath != projectRootPath else {
        return root
      }

      let prefix = projectRootPath.hasSuffix("/") ? projectRootPath : projectRootPath + "/"
      guard request.immediateProjectPath.hasPrefix(prefix) else {
        return root
      }

      let scope = String(request.immediateProjectPath.dropFirst(prefix.count))
      return scope.isEmpty ? root : "\(root) · \(scope)"
    }
  }

  private static func rootName(_ path: String?) -> String {
    guard let path else {
      return "cache"
    }

    return URL(fileURLWithPath: path).lastPathComponent
  }
}

struct ProjectActivityRequest {
  let rootPath: String
  let fileManager: FileManager
}

enum ProjectActivityResolver {
  struct ScanRequest {
    let rootPath: String
    let maximumEntries: Int
    let deadline: Date
  }

  static func latestChange(_ request: ProjectActivityRequest) -> Date? {
    scan(
      .init(
        rootPath: request.rootPath, maximumEntries: 20_000, deadline: .now.addingTimeInterval(0.15))
    )
  }

  static func scan(_ request: ScanRequest) -> Date? {
    guard request.maximumEntries > 0, Date.now < request.deadline else { return nil }
    let paths = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 2)
    paths.initialize(to: strdup(request.rootPath))
    paths.advanced(by: 1).initialize(to: nil)
    defer {
      free(paths.pointee)
      paths.deinitialize(count: 2)
      paths.deallocate()
    }
    guard let tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
    defer { fts_close(tree) }
    var newest: Date?
    var count = 0
    errno = 0
    while let entry = fts_read(tree) {
      count += 1
      guard count <= request.maximumEntries, Date.now < request.deadline else { return nil }
      let info = entry.pointee
      let name = withUnsafePointer(to: &entry.pointee.fts_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(info.fts_namelen) + 1) {
          String(cString: $0)
        }
      }
      if info.fts_info == FTS_D, info.fts_level > 0, excludedDirectoryNames.contains(name) {
        fts_set(tree, entry, FTS_SKIP)
      } else if info.fts_info == FTS_F, !name.hasPrefix("._"), name != ".DS_Store",
        let metadata = info.fts_statp?.pointee
      {
        let date = Date(
          timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec)
            + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000)
        newest = max(newest ?? .distantPast, date)
      } else if info.fts_info == FTS_ERR || info.fts_info == FTS_DNR || info.fts_info == FTS_NS {
        return nil
      }
      errno = 0
    }
    return errno == 0 ? newest : nil
  }

  private static let excludedDirectoryNames: Set<String> = [
    ".git", ".next", ".trigger", ".turbo", ".vercel", "build", "coverage", "dist", "node_modules",
    ".build", ".swiftpm", ".venv", "venv", "__pycache__", ".cache", "Pods", ".gradle",
  ]
}

private struct GeneratedRule {
  let marker: String
  let origin: NodeStorageOrigin
  let targetSuffix: String
}

private struct GeneratedTarget {
  let targetPath: String
  let projectSearchStart: String
  let origin: NodeStorageOrigin
}

private struct ProjectSearchRequest {
  let startPath: String
  let fileManager: FileManager
}

private struct ProjectMatch {
  let rootPath: String
  let manifestPath: String?
  let lockfilePath: String?
}

private struct DisplayNameRequest {
  let immediateProjectPath: String
  let projectRootPath: String?
  let origin: NodeStorageOrigin
}
