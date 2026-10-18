import Foundation

enum StorageOwner: String, CaseIterable, Sendable {
  case codex = "Codex"
  case claude = "Claude"
  case docker = "Docker"
  case chrome = "Google Chrome"
  case cursor = "Cursor"
  case xcode = "Xcode"

  var bundleIDs: [String] {
    switch self {
    case .codex: ["com.openai.codex", "com.openai.chat"]
    case .claude: ["com.anthropic.claudefordesktop"]
    case .docker: ["com.docker.docker"]
    case .chrome: ["com.google.Chrome"]
    case .cursor: ["com.todesktop.230313mzl4w4u92"]
    case .xcode: ["com.apple.dt.Xcode"]
    }
  }

  static func named(_ name: String) -> Self? {
    allCases.first {
      $0.rawValue.localizedCaseInsensitiveCompare(name) == .orderedSame
        || $0.bundleIDs.contains(name)
        || ($0 == .codex && ["ChatGPT", "Codex CLI", "Codex workers"].contains(name))
        || ($0 == .claude && name == "Claude Code")
    }
  }

  static func forPath(_ path: String) -> Self? {
    let lower = StorageGuidance.visiblePath(path).lowercased()
    let parts = lower.split(separator: "/").map(String.init)
    if parts.contains(".codex") || parts.contains("com.openai.codex") { return .codex }
    if parts.contains(".claude") || lower.contains("/library/application support/claude/")
      || lower.hasSuffix("/library/application support/claude")
      || parts.contains("com.anthropic.claudefordesktop")
    {
      return .claude
    }
    if parts.contains(".docker") || parts.contains("com.docker.docker")
      || parts.contains("group.com.docker") || parts.contains("docker.raw")
    {
      return .docker
    }
    if parts.contains("com.google.chrome")
      || lower.contains("/library/application support/google/chrome")
    {
      return .chrome
    }
    if parts.contains(".cursor") || lower.contains("/library/application support/cursor") {
      return .cursor
    }
    if parts.contains("xcode") || parts.contains("coresimulator")
      || parts.contains("com_apple_mobileasset_iossimulatorruntime")
    {
      return .xcode
    }
    return nil
  }
}

struct StorageGuidance: Equatable, Sendable {
  enum Kind: Sendable {
    case rebuildable, managed, protected, review
  }

  let kind: Kind
  let reason: String
  let cleanup: StorageCleanupFocus?

  static func visiblePath(_ path: String) -> String {
    let prefix = "/System/Volumes/Data"
    let path = path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count)) : path
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }

  static func read(_ path: String) -> Self {
    let path = visiblePath(path)
    let parts = path.split(separator: "/").map(String.init)
    let name = parts.last ?? ""
    let lower = path.lowercased()
    if parts.contains(".git") {
      return .init(kind: .protected, reason: "Git history · keep with the project", cleanup: nil)
    }
    if parts.contains("Backups.backupdb") || parts.contains(".timemachine")
      || parts.contains(where: {
        [".Trashes", ".Trash", ".Spotlight-V100", ".fseventsd"].contains($0)
      })
    {
      return .init(kind: .protected, reason: "Managed by macOS · do not remove here", cleanup: nil)
    }
    if lower.contains("/coresimulator/")
      || lower.contains("com_apple_mobileasset_iossimulatorruntime")
    {
      return .init(
        kind: .managed, reason: "Simulator data · use device cleanup", cleanup: .simulators)
    }
    if parts.contains(where: { $0.hasSuffix(".app") }) {
      return .init(
        kind: .protected, reason: "Application bundle · uninstall from Inventory", cleanup: nil)
    }
    if StorageOwner.forPath(path) == .docker {
      return .init(
        kind: .managed, reason: "Docker data · clean through Docker, keep databases",
        cleanup: .docker)
    }
    if parts.contains(".codex") || lower.contains("/com.openai.codex/") {
      return .init(kind: .managed, reason: "Codex history and app data · keep", cleanup: nil)
    }
    if StorageOwner.forPath(path) == .claude {
      return .init(kind: .managed, reason: "Claude app or VM data · manage in Claude", cleanup: nil)
    }
    if parts.contains("node_modules") || parts.contains(".next") || parts.contains(".trigger") {
      return .init(
        kind: .rebuildable, reason: "Project cache · check rebuild and running processes",
        cleanup: .projects)
    }
    if lower.contains("/library/caches/") || lower.hasSuffix("/library/caches")
      || parts.contains("_cacache") || lower.contains("/library/pnpm/store")
      || lower.contains("/xcode/deriveddata") || parts.contains(".cache")
    {
      return .init(
        kind: .rebuildable, reason: "Cache · check age and activity before cleaning",
        cleanup: .caches)
    }
    if parts.contains(".ssh") || parts.contains(".gnupg") || name == ".env"
      || name.hasPrefix(".env.")
    {
      return .init(
        kind: .protected, reason: "Credentials or project configuration · keep", cleanup: nil)
    }
    if [
      "/library", "/library/application support", "/library/containers",
      "/library/group containers",
    ]
    .contains(where: { lower.hasSuffix($0) })
      || lower.contains("/library/application support/") || lower.contains("/library/containers/")
      || lower.contains("/library/group containers/")
      || lower.contains("/library/mobile documents/")
    {
      return .init(kind: .managed, reason: "App data · review in its owning app", cleanup: nil)
    }
    if path.hasPrefix("/System/") || path.hasPrefix("/Library/") || path.hasPrefix("/private/") {
      return .init(kind: .protected, reason: "System data · keep", cleanup: nil)
    }
    if ["dmg", "pkg", "iso"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
      return .init(
        kind: .review, reason: "Installer · Trash if installation is finished", cleanup: nil)
    }
    return .init(
      kind: .review, reason: "Review first · may contain originals or project files", cleanup: nil)
  }

  static func read(_ item: StorageItem) -> Self {
    if let kind = item.cleanupKind {
      let focus: StorageCleanupFocus = kind == .simulatorCache ? .simulators : .projects
      switch item.cleanupAvailability {
      case .ready:
        return .init(
          kind: .rebuildable, reason: "Rebuildable · checks passed; checked again before deletion",
          cleanup: focus)
      case .blocked(let reason):
        return .init(kind: .rebuildable, reason: "Kept · " + reason, cleanup: focus)
      case nil: break
      }
    }
    return read(item.path)
  }

  func caption(_ path: String) -> String {
    guard let owner = StorageOwner.forPath(path)?.rawValue,
      !reason.lowercased().hasPrefix(owner.lowercased())
    else { return reason }
    return owner + " · " + reason
  }

  var allowsDirectTrash: Bool { kind == .review || kind == .rebuildable }
}

struct StorageCleanupRoute {
  let focus: StorageCleanupFocus
  let path: String?

  var projectRoot: String? {
    guard focus == .projects, let path else { return nil }
    let parts = StorageGuidance.visiblePath(path).split(separator: "/").map(String.init)
    guard
      let index = parts.firstIndex(where: { ["node_modules", ".next", ".trigger"].contains($0) })
    else { return nil }
    return "/" + parts.prefix(index).joined(separator: "/")
  }
}
