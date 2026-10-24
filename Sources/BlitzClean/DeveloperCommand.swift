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
  /// chose here. A repository's own config can name commands git runs during `status` (fsmonitor) or
  /// other operations (hooks), so every call turns those off.
  static let gitSafety = [
    "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c",
    "core.untrackedCache=false",
  ]

  static func git(_ request: GitRequest) -> CleanupCommandResult {
    run(
      .init(
        executable: "/usr/bin/git",
        arguments: gitSafety + ["--no-optional-locks", "-C", request.directory] + request.arguments,
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
