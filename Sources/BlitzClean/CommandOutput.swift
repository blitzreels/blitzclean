import Foundation

/// A finished command as callers parse it: exit status, standard output, and why it failed.
struct CleanupCommandResult: Sendable {
  let status: Int32
  let output: String
  /// Why the command did not succeed, such as "ps did not answer in time"; nil when it exited 0.
  let failure: String?

  /// The parsed output, or why it could not be read. A parser returns nil for output it does not recognise,
  /// so "could not read" never turns into an empty list.
  func read<Value>(_ parse: (String) -> Value?) -> Result<Value, CommandReadError> {
    guard status == 0 else { return .failure(.init(reason: failure ?? "it failed")) }
    return parse(output).map { .success($0) } ?? .failure(.unrecognised)
  }

  /// Like `read`, but exit 1 with no output means nothing matched, which is how lsof reports an empty answer.
  func readMatches<Value>(_ parse: (String) -> Value?) -> Result<Value, CommandReadError> {
    guard status == 1, output.isEmpty else { return read(parse) }
    return parse("").map { .success($0) } ?? .failure(.unrecognised)
  }
}

/// Why a command's output could not be used; shown as "Couldn't read X: <reason>."
struct CommandReadError: LocalizedError, Equatable, Sendable {
  let reason: String

  var errorDescription: String? { reason }

  static let unrecognised = Self(reason: "its output was not in the expected format")
}

extension CommandRunner.Request {
  /// The tool's short name for messages, such as "lsof" or "xcrun simctl".
  var name: String {
    let tool = PathName.last(executable)
    guard tool == "xcrun", let subcommand = arguments.first else { return tool }
    return tool + " " + subcommand
  }
}

extension CommandRunner.Output {
  /// The output with a reason attached when the command named `command` did not exit 0.
  func result(_ command: String) -> CleanupCommandResult {
    .init(status: status, output: text, failure: failure(command))
  }

  func failure(_ command: String) -> String? {
    let firstError = errors.split(whereSeparator: \.isNewline).first.map {
      ": " + $0.trimmingCharacters(in: .whitespaces).prefix(160)
    }
    switch ending {
    case .exited(0): return nil
    case .exited(let status): return "\(command) exited with status \(status)\(firstError ?? "")"
    case .signaled: return "\(command) was stopped before it finished"
    case .timedOut: return "\(command) did not answer in time"
    case .outputLimit: return "\(command) printed more than expected, so its output was cut off"
    case .notStarted: return "\(command) could not start\(firstError ?? "")"
    }
  }
}

/// `ps -o` output with fixed columns, the last of which may contain spaces.
enum ProcessTable {
  struct Request {
    let output: String
    let columns: Int
  }

  /// Each row split into exactly `columns` fields; nil when there are no rows or any row is short.
  static func rows(_ request: Request) -> [[Substring]]? {
    var rows: [[Substring]] = []
    for line in request.output.split(whereSeparator: \.isNewline) {
      var fields = line.split(
        separator: " ", maxSplits: request.columns - 1, omittingEmptySubsequences: true)
      guard fields.count == request.columns else { return nil }
      let last = fields[fields.count - 1].trimmingCharacters(in: .whitespaces)
      guard !last.isEmpty else { return nil }
      fields[fields.count - 1] = Substring(last)
      rows.append(fields)
    }
    return rows.isEmpty ? nil : rows
  }
}

/// `lsof -F` output: one field per line, each starting with its letter.
enum LsofFields {
  /// Whether every line is a process ID, command, descriptor or name field, as `-Fpcn` and its subsets print.
  static func isWellFormed(_ output: String) -> Bool {
    output.split(whereSeparator: \.isNewline).allSatisfy { line in
      switch line.first {
      case "p": Int32(line.dropFirst()) != nil
      case "c", "f", "n": true
      default: false
      }
    }
  }
}
