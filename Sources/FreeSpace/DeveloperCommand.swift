import Darwin
import Foundation

enum DeveloperCommand {
  struct Request: Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval
    let maximumBytes: Int
  }

  static func run(_ request: Request) -> CleanupCommandResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: request.executable)
    process.arguments = request.arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = environment
    do { try process.run() } catch { return .init(status: -1, output: "") }
    let deadline = DispatchWorkItem {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + request.timeout, execute: deadline)
    var data = Data()
    var limited = false
    while let chunk = try? pipe.fileHandleForReading.read(upToCount: 32_768), !chunk.isEmpty {
      if data.count + chunk.count <= request.maximumBytes, !limited {
        data.append(chunk)
      } else {
        limited = true
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      }
    }
    process.waitUntilExit()
    deadline.cancel()
    return .init(
      status: limited || process.terminationReason != .exit ? -1 : process.terminationStatus,
      output: String(decoding: data, as: UTF8.self))
  }

  struct GitRequest: Sendable {
    let directory: String
    let arguments: [String]
  }

  static func git(_ request: GitRequest) -> CleanupCommandResult {
    run(
      .init(
        executable: "/usr/bin/git",
        arguments: ["--no-optional-locks", "-C", request.directory] + request.arguments,
        timeout: 12, maximumBytes: 262_144))
  }

  static func bytes(_ path: String) -> UInt64? {
    let result = run(
      .init(
        executable: "/usr/bin/du", arguments: ["-xsk", path],
        timeout: 20, maximumBytes: 4_096))
    guard result.status == 0,
      let value = result.output.split(whereSeparator: \.isWhitespace).first.flatMap({ UInt64($0) })
    else { return nil }
    return value * 1_024
  }
}
