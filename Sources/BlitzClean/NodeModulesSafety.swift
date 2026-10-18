import Foundation

enum NodeModulesSafety {
  static func evaluate(_ request: NodeModulesSafetyRequest) -> StorageCleanupAvailability {
    let context = request.context
    let root = context.projectRootPath ?? context.cleanupTargetPath
    let activityRoot = ReviewFile.canonicalPath(root) ?? root
    let projectPrefix = activityRoot.hasSuffix("/") ? activityRoot : activityRoot + "/"
    let isActive = request.activeWorkingDirectories.contains { path in
      if path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
        return true
      }
      let physicalPath = ReviewFile.canonicalPath(path) ?? path
      return physicalPath == activityRoot || physicalPath.hasPrefix(projectPrefix)
    }
    guard !isActive else {
      return .blocked("Project is in use")
    }

    if context.origin.isGenerated {
      return .ready
    }

    guard context.manifestPath != nil else {
      return .blocked("Missing package.json")
    }

    guard context.lockfilePath != nil else {
      return .blocked("No exact reinstall lock")
    }

    return .ready
  }
}

struct NodeModulesSafetyRequest {
  let context: NodeModulesContext
  let activeWorkingDirectories: Set<String>
  let fileManager: FileManager
}
