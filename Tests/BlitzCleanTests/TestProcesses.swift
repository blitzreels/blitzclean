import Darwin
import Foundation

@testable import BlitzClean

/// A command a test runs as a real child process. Output goes to /dev/null.
struct TestCommand {
  let executable: String
  let arguments: [String]
  /// Working directory; the child inherits the test's own when absent.
  var directory: URL? = nil
}

/// Every process a test starts goes through here. `stop()` in the test's `defer` kills it, an exit
/// handler kills anything a test left running, and a watchdog kills it within a second when the
/// test process dies first (an interrupted run), so no `yes` or `sleep` outlives the suite.
enum TestProcesses {
  static func start(_ command: TestCommand) throws -> TestChild {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.executable)
    process.arguments = command.arguments
    process.currentDirectoryURL = command.directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return TestChild(process: process, processID: process.processIdentifier)
  }

  /// Takes ownership of a process the test started indirectly, such as an orphaned background job.
  static func adopt(_ processID: Int32) -> TestChild {
    TestChild(process: nil, processID: processID)
  }

  /// The same command started through `/bin/sh`, which arms the watchdog and then `exec`s it, for
  /// commands that app code launches itself. The process ID and executable stay the command's own.
  static func guarded(_ command: TestCommand) -> TestCommand {
    TestCommand(
      executable: "/bin/sh",
      arguments: ["-c", guardLine + "\nexec \"$@\"", "guard"]
        + [command.executable] + command.arguments, directory: command.directory)
  }

  /// A shell line that arms the watchdog for the shell running it (`$$`), for test scripts.
  static var guardLine: String {
    "/bin/sh -c '\(watchdog)' watchdog \(getpid()) $$ </dev/null >/dev/null 2>&1 &"
  }

  /// Exits once the target exits. If the test process goes away first, kills the target and its
  /// direct children, after checking the start time so a reused process ID is never signalled.
  /// It contains no single quotes so it can be quoted into `guardLine`.
  fileprivate static let watchdog = """
    runner=$1 target=$2
    started() { ps -o lstart= -p "$1" 2>/dev/null; }
    target_start=$(started "$target")
    [ -n "$target_start" ] || exit 0
    while kill -0 "$target" 2>/dev/null && kill -0 "$runner" 2>/dev/null; do sleep 1; done
    kill -0 "$runner" 2>/dev/null && exit 0
    [ "$(started "$target")" = "$target_start" ] || exit 0
    pkill -KILL -P "$target"
    kill -KILL "$target"
    """
}

final class TestChild: @unchecked Sendable {
  /// Absent for adopted processes, which the test did not launch itself.
  let process: Process?
  let processID: Int32
  /// Identifies an adopted process at adoption, so `stop()` never signals a reused process ID.
  private let identity: DevProcessIdentity?
  private let watchdog: Process?

  fileprivate init(process: Process?, processID: Int32) {
    self.process = process
    self.processID = processID
    identity = DevProcessIdentity.read(processID)
    let watchdog = Process()
    watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
    watchdog.arguments = [
      "-c", TestProcesses.watchdog, "watchdog", String(getpid()), String(processID),
    ]
    watchdog.standardInput = FileHandle.nullDevice
    watchdog.standardOutput = FileHandle.nullDevice
    watchdog.standardError = FileHandle.nullDevice
    self.watchdog = (try? watchdog.run()) == nil ? nil : watchdog
    TestChildRegistry.shared.add(self)
  }

  /// A launched child keeps its process ID until it is reaped; an adopted one must still match.
  var isRunning: Bool {
    if let process { return process.isRunning }
    guard let identity, let current = DevProcessIdentity.read(processID) else { return false }
    return identity.matches(current)
  }

  /// Kills the child and its descendants, paused or not, then waits for a launched child to exit.
  func stop() {
    TestChildRegistry.shared.remove(self)
    if isRunning {
      for pid in LiveProcessTree.read().descendants([processID]) {
        _ = kill(pid, SIGCONT)
        _ = kill(pid, SIGKILL)
      }
      if let process { Self.awaitExit(process) }
    }
    if let watchdog, watchdog.isRunning {
      watchdog.terminate()
      Self.awaitExit(watchdog)
    }
  }

  /// `waitUntilExit()` waits for a termination notice delivered on the main thread, which never comes when
  /// a serial test run holds that thread, so this polls with a deadline instead.
  private static func awaitExit(_ process: Process) {
    let deadline = Date.now.addingTimeInterval(5)
    while process.isRunning, Date.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
  }
}

private final class TestChildRegistry: @unchecked Sendable {
  static let shared = TestChildRegistry()
  private let lock = NSLock()
  private var children: [ObjectIdentifier: TestChild] = [:]

  private init() { atexit { TestChildRegistry.shared.stopAll() } }

  func add(_ child: TestChild) { lock.withLock { children[ObjectIdentifier(child)] = child } }

  func remove(_ child: TestChild) {
    _ = lock.withLock { children.removeValue(forKey: ObjectIdentifier(child)) }
  }

  func stopAll() {
    for child in lock.withLock({ Array(children.values) }) { child.stop() }
  }
}
