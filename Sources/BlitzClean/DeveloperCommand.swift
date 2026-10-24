import Foundation

enum DeveloperCommand {
  struct Request: Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval
    let maximumBytes: Int
  }

  static func run(_ request: Request) -> CleanupCommandResult {
    let command = CommandRunner.Request(
      executable: request.executable, arguments: request.arguments, timeout: request.timeout,
      maximumBytes: request.maximumBytes, input: nil, environment: .noninteractive)
    return CommandRunner.run(command).result(command.name)
  }

  struct GitRequest: Sendable {
    let directory: String
    let arguments: [String]
  }

  /// Git runs in folders BlitzClean finds on its own, including repositories the user cloned but never
  /// chose here. A repository's own config can name commands git runs during `status` (fsmonitor, clean
  /// filters) or other operations (hooks), so every call turns those off.
  static let gitSafety = [
    "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c",
    "core.untrackedCache=false", "-c", "core.pager=cat",
  ]

  /// `gitSafety` plus a blank override for every filter defined by the config of each directory git will
  /// read: the repository, and for `worktree remove` the worktree too, whose own config git reads when it
  /// checks that worktree. Filters from the user's global config, such as Git LFS, keep working. Listing
  /// config runs nothing. Nil when any listing fails or a name can't be overridden, so no git runs at all.
  /// Status calls also pass `--ignore-submodules=all`, since a submodule's config is never listed here.
  static func gitArguments(_ directories: [String]) -> [String]? {
    var names: Set<String> = []
    for directory in directories {
      let listed = run(
        .init(
          executable: "/usr/bin/git",
          arguments: gitSafety + [
            "-C", directory, "config", "--includes", "--show-scope", "--get-regexp", "^filter\\.",
          ], timeout: 12, maximumBytes: 262_144))
      guard let found = GitFilters.repositoryNames(listed) else { return nil }
      names.formUnion(found)
    }
    return gitSafety
      + names.sorted().flatMap { name in
        ["clean", "smudge", "process"].flatMap { ["-c", "filter.\(name).\($0)="] }
          + ["-c", "filter.\(name).required=false"]
      }
  }

  static func git(_ request: GitRequest) -> CleanupCommandResult {
    guard let safety = gitArguments([request.directory]) else {
      let reason = "This repository defines a filter BlitzClean can't turn off safely."
      return .init(status: -1, output: "", failure: reason)
    }
    return run(
      .init(
        executable: "/usr/bin/git",
        arguments: safety + ["--no-optional-locks", "-C", request.directory] + request.arguments,
        timeout: 12, maximumBytes: 262_144))
  }

  static func bytes(_ path: String) -> UInt64? {
    DiskUsage.allocatedBytes(.init(path: path, timeout: 20))
  }
}

/// Allocated size of a folder on its own volume. Unreadable entries are skipped, so the total can be
/// a lower bound; a timeout or an unopenable folder gives nil.
enum DiskUsage {
  struct Request: Sendable {
    let path: String
    let timeout: TimeInterval
  }

  static func allocatedBytes(_ request: Request) -> UInt64? {
    FolderFootprint.measure(
      .init(path: request.path, deadline: .now.addingTimeInterval(request.timeout))
    )?.allocated
  }
}

/// Filter names a repository's own config defines, read from `git config --show-scope --get-regexp`.
enum GitFilters {
  static func repositoryNames(_ listed: CleanupCommandResult) -> Set<String>? {
    // Exit 1 with no output means the repository defines no filters.
    if listed.status == 1, listed.output.isEmpty { return [] }
    guard listed.status == 0 else { return nil }
    var names: Set<String> = []
    for line in listed.output.split(separator: "\n") {
      let fields = line.split(separator: "\t", maxSplits: 1)
      guard fields.count == 2 else { return nil }
      if fields[0] == "global" || fields[0] == "system" { continue }
      let key = fields[1].split(separator: " ", maxSplits: 1)[0]
      guard key.hasPrefix("filter."), let dot = key.lastIndex(of: "."),
        dot > key.index(key.startIndex, offsetBy: 7)
      else { return nil }
      let name = String(key[key.index(key.startIndex, offsetBy: 7)..<dot])
      // `-c key=value` splits at the first "=", so such a name can't be overridden.
      guard !name.contains("=") else { return nil }
      names.insert(name)
    }
    return names
  }
}
