import Darwin
import Foundation

/// Runs a short-lived command with a deadline, bounded output, and no inherited terminal.
/// On timeout or overflow the command and every process it started are stopped.
enum CommandRunner {
  struct Environment: Sendable {
    let set: [String: String]
    let removed: [String]

    static let inherited = Self(set: [:], removed: [])
    static let noninteractive = Self(
      set: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"], removed: [])
  }

  struct Request: Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval
    let maximumBytes: Int
    let input: Data?
    let environment: Environment
  }

  enum Ending: Equatable, Sendable {
    case exited(Int32)
    case signaled
    case timedOut
    case outputLimit
    case notStarted
  }

  struct Output: Sendable {
    let ending: Ending
    let data: Data
    let errors: String

    var status: Int32 {
      if case .exited(let status) = ending { return status }
      return -1
    }
    var text: String { String(decoding: data, as: UTF8.self) }
  }

  static func run(_ request: Request) -> Output {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    let input = request.input == nil ? nil : Pipe()
    process.executableURL = URL(fileURLWithPath: request.executable)
    process.arguments = request.arguments
    process.standardInput = input ?? FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    var environment = ProcessInfo.processInfo.environment
    environment.merge(request.environment.set) { $1 }
    for key in request.environment.removed { environment.removeValue(forKey: key) }
    process.environment = environment
    do { try process.run() } catch {
      return .init(ending: .notStarted, data: Data(), errors: error.localizedDescription)
    }
    let processID = process.processIdentifier
    let stop = CommandStop()
    let finished = DispatchSemaphore(value: 0)
    BlockingThread.start {
      guard finished.wait(timeout: .now() + request.timeout) == .timedOut,
        process.isRunning, stop.mark(.timedOut)
      else { return }
      stopTree(.init(root: processID, signal: SIGTERM))
      if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
        stopTree(.init(root: processID, signal: SIGKILL))
      }
    }

    let workers = DispatchGroup()
    if let input, let data = request.input {
      let handle = input.fileHandleForWriting
      _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
      workers.enter()
      BlockingThread.start {
        try? handle.write(contentsOf: data)
        try? handle.close()
        workers.leave()
      }
    }
    let diagnostics = CommandBuffer(limit: 65_536)
    workers.enter()
    BlockingThread.start {
      diagnostics.drain(errors.fileHandleForReading)
      workers.leave()
    }
    var data = Data()
    while let chunk = try? output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
      guard data.count + chunk.count <= request.maximumBytes else {
        if stop.mark(.outputLimit) { stopTree(.init(root: processID, signal: SIGKILL)) }
        continue
      }
      if stop.reason == nil { data.append(chunk) }
    }
    process.waitUntilExit()
    workers.wait()
    finished.signal()
    let ending: Ending =
      stop.reason
      ?? (process.terminationReason == .exit ? .exited(process.terminationStatus) : .signaled)
    return .init(ending: ending, data: data, errors: diagnostics.text)
  }

  private struct TreeStop {
    let root: Int32
    let signal: Int32
  }

  private static func stopTree(_ request: TreeStop) {
    let tree = LiveProcessTree.read()
    for processID in tree.descendants([request.root]).reversed() where processID > 1 {
      kill(processID, request.signal)
    }
    kill(request.root, request.signal)
  }
}

private final class CommandStop: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: CommandRunner.Ending?

  var reason: CommandRunner.Ending? { lock.withLock { stored } }

  func mark(_ reason: CommandRunner.Ending) -> Bool {
    lock.withLock {
      guard stored == nil else { return false }
      stored = reason
      return true
    }
  }
}

private final class CommandBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var data = Data()

  init(limit: Int) { self.limit = limit }

  func drain(_ handle: FileHandle) {
    while let chunk = try? handle.read(upToCount: 16_384), !chunk.isEmpty {
      lock.withLock {
        if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
      }
    }
  }

  var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// Runs blocking pipe I/O and deadlines on a thread of their own. Queued on global dispatch queues
/// instead, they never started once concurrent callers had blocked every pool thread waiting on
/// their own commands, and those callers then waited forever.
enum BlockingThread {
  static func start(_ work: @escaping @Sendable () -> Void) {
    Thread(block: work).start()
  }
}
