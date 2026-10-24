import Foundation

/// How long a test waits for asynchronous work. Generous on purpose: a passing test returns as soon
/// as its condition holds, and only a failing one waits this long, while a Mac that is swapping can
/// take seconds to schedule a background task.
/// Long enough for background readers, which back off up to 3× under memory pressure (`RefreshCadence`).
let testTimeout: Duration = .seconds(90)

/// Polls until `condition` holds, every 5 ms at first and backing off to 100 ms. Returns false when
/// `testTimeout` passes first, so callers assert on the result or on the state it waited for.
@discardableResult
func eventually(
  isolation: isolated (any Actor)? = #isolation, _ condition: () async throws -> Bool
) async rethrows -> Bool {
  let deadline = ContinuousClock.now + testTimeout
  var interval = Duration.milliseconds(5)
  while try await !condition() {
    guard ContinuousClock.now < deadline else { return false }
    try? await Task.sleep(for: interval)
    interval = min(interval * 2, .milliseconds(100))
  }
  return true
}

/// `eventually` for synchronous tests, which block their thread between polls.
@discardableResult
func eventuallyBlocking(_ condition: () throws -> Bool) rethrows -> Bool {
  let deadline = ContinuousClock.now + testTimeout
  var interval = Duration.milliseconds(5)
  while try !condition() {
    guard ContinuousClock.now < deadline else { return false }
    Thread.sleep(forTimeInterval: Double(interval.components.attoseconds) / 1e18)
    interval = min(interval * 2, .milliseconds(100))
  }
  return true
}
