import Darwin
import Foundation

struct DirectoryIdentity: Equatable, Sendable {
  let device: Int32
  let inode: UInt64

  static func read(_ path: String) -> Self? {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      ReviewFile.canonicalPath(path) == path
    else { return nil }
    return .init(device: info.st_dev, inode: info.st_ino)
  }
}

struct GitWorktreeRecord: Equatable, Sendable {
  let path: String
  let head: String
  let branch: String?
  let locked: Bool
  let bare: Bool
  let prunable: Bool
  let primary: Bool
}

enum WorktreeMerge: String, Sendable {
  case merged = "Merged"
  case unverified = "Merge unverified"
  case unknown = "Git unavailable"
}

struct WorktreeAssessment: Sendable {
  let repository: String
  let record: GitWorktreeRecord
  let identity: DirectoryIdentity?
  let base: String?
  let merge: WorktreeMerge
  let blocker: String?
}

enum GitWorktrees {
  static func parse(_ output: String) -> [GitWorktreeRecord] {
    var fields: [String] = []
    var result: [GitWorktreeRecord] = []
    func flush() {
      guard let path = fields.first(where: { $0.hasPrefix("worktree ") }) else {
        fields.removeAll()
        return
      }
      result.append(
        .init(
          path: String(path.dropFirst(9)),
          head: fields.first(where: { $0.hasPrefix("HEAD ") }).map { String($0.dropFirst(5)) }
            ?? "",
          branch: fields.first(where: { $0.hasPrefix("branch ") }).map { String($0.dropFirst(7)) },
          locked: fields.contains { $0 == "locked" || $0.hasPrefix("locked ") },
          bare: fields.contains("bare"),
          prunable: fields.contains { $0 == "prunable" || $0.hasPrefix("prunable ") },
          primary: result.isEmpty))
      fields.removeAll()
    }
    for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
      if field.isEmpty { flush() } else { fields.append(String(field)) }
    }
    flush()
    return result
  }

  static func list(_ directory: String) -> [GitWorktreeRecord]? {
    let result = DeveloperCommand.git(
      .init(directory: directory, arguments: ["worktree", "list", "--porcelain", "-z"]))
    return result.status == 0 ? parse(result.output) : nil
  }

  static func base(_ directory: String) -> String? {
    let symbolic = DeveloperCommand.git(
      .init(
        directory: directory,
        arguments: ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]))
    let remote =
      symbolic.status == 0 ? symbolic.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    for candidate in [
      remote, "refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main",
      "refs/heads/master",
    ].compactMap({ $0 }) {
      if DeveloperCommand.git(
        .init(
          directory: directory,
          arguments: ["rev-parse", "--verify", candidate + "^{commit}"])
      ).status == 0 {
        return candidate
      }
    }
    return nil
  }

  struct Inspection: Sendable {
    let repository: String
    let record: GitWorktreeRecord
    let base: String?
    let activeDirectories: Set<String>?
    let keptDirectories: [String]
  }

  static func inspect(_ input: Inspection) -> WorktreeAssessment {
    let record = input.record
    let identity = DirectoryIdentity.read(record.path)
    let merge: WorktreeMerge
    if let base = input.base, !record.head.isEmpty {
      let result = DeveloperCommand.git(
        .init(
          directory: input.repository,
          arguments: ["merge-base", "--is-ancestor", record.head, base]))
      merge = result.status == 0 ? .merged : result.status == 1 ? .unverified : .unknown
    } else {
      merge = .unknown
    }
    var blocker: String?
    if record.primary || record.bare {
      blocker = "Primary checkout"
    } else if record.locked {
      blocker = "Worktree is locked"
    } else if record.prunable || identity == nil {
      blocker = "Missing folder or symbolic link"
    } else if record.branch == nil {
      blocker = "Detached HEAD — preserve its commits"
    } else if input.keptDirectories.contains(where: {
      DeveloperPath.contains(.init(path: record.path, root: $0))
    }) {
      blocker = "Keep running is enabled"
    } else if let active = input.activeDirectories {
      if active.contains(where: { DeveloperPath.contains(.init(path: $0, root: record.path)) }) {
        blocker = "Project is in use"
      }
    } else {
      blocker = "Could not verify running processes"
    }
    if blocker == nil {
      let status = DeveloperCommand.git(
        .init(
          directory: record.path,
          arguments: [
            "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching",
            "--ignore-submodules=none",
          ]))
      if status.status != 0 {
        blocker = "Could not verify every local file"
      } else if !status.output.isEmpty {
        let entries = status.output.split(separator: "\0")
        blocker =
          entries.allSatisfy { $0.hasPrefix("!! ") }
          ? "Ignored files remain — review them first"
          : "Uncommitted or untracked files"
      }
    }
    if blocker == nil, merge != .merged { blocker = "No verified merge into the base branch" }
    return .init(
      repository: input.repository, record: record, identity: identity,
      base: input.base, merge: merge, blocker: blocker)
  }

  struct Removal: Sendable {
    let expected: WorktreeAssessment
    let activeDirectories: Set<String>?
    let keptDirectories: [String]
  }

  static func validateRemoval(_ input: Removal) -> String? {
    let expected = input.expected
    guard let identity = expected.identity,
      DirectoryIdentity.read(expected.record.path) == identity,
      let current = list(expected.repository)?.first(where: { $0.path == expected.record.path }),
      current == expected.record
    else { return "Worktree changed. Refresh and review it again." }
    let assessment = inspect(
      .init(
        repository: expected.repository, record: current,
        base: base(expected.repository), activeDirectories: input.activeDirectories,
        keptDirectories: input.keptDirectories))
    return assessment.blocker
  }
}

enum DeveloperPath {
  struct Membership {
    let path: String
    let root: String
  }

  static func contains(_ input: Membership) -> Bool {
    input.path == input.root || input.path.hasPrefix(input.root + "/")
  }
}
