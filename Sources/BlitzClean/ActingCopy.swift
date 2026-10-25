import AppKit

/// Which running copy of BlitzClean pauses builds and sends memory alerts. The released app and the dev
/// build both monitor; only one acts, so a build is never paused twice and an alert never arrives twice.
/// A copy steps aside for one with a newer protection level, and the dev build steps aside for a released
/// app at the same level. A copy without the key predates this rule and never acts on builds.
enum ActingCopy {
  static let key = "BlitzCleanProtection"

  struct Copy: Equatable, Sendable {
    let level: Int
    let isDevelopment: Bool
  }

  struct Input {
    let own: Copy
    let others: [Copy]
  }

  static func acts(_ input: Input) -> Bool {
    !input.others.contains { other in
      other.level > input.own.level
        || (other.level == input.own.level && input.own.isDevelopment && !other.isDevelopment)
    }
  }

  static func level(_ bundle: Bundle?) -> Int {
    bundle?.object(forInfoDictionaryKey: key) as? Int ?? 0
  }

  nonisolated(unsafe) private static var cached: (date: Date, acts: Bool)?
  private static let lock = NSLock()

  /// Rechecked every 30 seconds, since a copy can start or quit at any time.
  static var current: Bool {
    lock.lock()
    defer { lock.unlock() }
    if let cached, Date.now.timeIntervalSince(cached.date) < 30 { return cached.acts }
    let identifiers = [AppBrand.bundleIdentifier, AppBrand.developmentBundleIdentifier]
    let others = NSWorkspace.shared.runningApplications.compactMap { app -> Copy? in
      guard let identifier = app.bundleIdentifier, identifiers.contains(identifier),
        app.processIdentifier != getpid()
      else { return nil }
      return Copy(
        level: level(app.bundleURL.flatMap(Bundle.init(url:))),
        isDevelopment: identifier == AppBrand.developmentBundleIdentifier)
    }
    let value = acts(
      .init(
        own: .init(level: level(.main), isDevelopment: AppBrand.isDevelopmentBuild),
        others: others))
    cached = (.now, value)
    return value
  }
}
