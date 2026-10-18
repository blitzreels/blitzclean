import Darwin
import Foundation

/// The only way the app signals another process. The target must still be the exact instance that
/// was shown (same PID, start time and executable), owned by this user, and not launchd or the app.
enum ProcessSignal {
  struct Request: Sendable {
    let expected: DevProcessIdentity
    let signal: Int32
  }

  enum Outcome: Equatable, Sendable {
    case sent(DevProcessIdentity)
    case changed
    case refused
    case failed(Int32)

    var wasSent: Bool {
      if case .sent = self { return true }
      return false
    }
  }

  static func send(_ request: Request) -> Outcome {
    let processID = request.expected.process.processID
    guard processID > 1, processID != getpid() else { return .refused }
    guard let current = DevProcessIdentity.read(processID), request.expected.matches(current)
    else { return .changed }
    guard current.process.owner == getuid() else { return .refused }
    guard kill(processID, request.signal) == 0 else { return .failed(errno) }
    if request.signal == SIGTERM, current.process.stopped,
      let latest = DevProcessIdentity.read(processID), request.expected.matches(latest)
    {
      kill(processID, SIGCONT)
    }
    return .sent(current)
  }
}
