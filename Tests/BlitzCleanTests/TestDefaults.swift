import Darwin
import Foundation

/// A throwaway defaults suite. cfprefsd writes an empty plist even after its domain is removed, so
/// each test run deletes the suites earlier runs left in ~/Library/Preferences before adding its own.
struct TestDefaults {
  let suite: String
  let defaults: UserDefaults

  init(_ prefix: String) {
    suite = "BlitzCleanTests-\(prefix)-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
    TestDefaultsRegistry.shared.add(suite)
  }
}

private final class TestDefaultsRegistry: @unchecked Sendable {
  static let shared = TestDefaultsRegistry()
  private let lock = NSLock()
  private var suites: [String] = []

  private init() {
    removeEarlierRuns()
    atexit { TestDefaultsRegistry.shared.removeAll() }
  }

  private var preferences: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
  }

  private func removeEarlierRuns() {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
    for name in names where name.hasPrefix("BlitzCleanTests-") && name.hasSuffix(".plist") {
      try? FileManager.default.removeItem(at: preferences.appendingPathComponent(name))
    }
  }

  func add(_ suite: String) { lock.withLock { suites.append(suite) } }

  func removeAll() {
    for suite in lock.withLock({ suites }) {
      let defaults = UserDefaults(suiteName: suite)
      defaults?.removePersistentDomain(forName: suite)
      defaults?.synchronize()
      try? FileManager.default.removeItem(
        at: preferences.appendingPathComponent(suite + ".plist"))
    }
  }
}
