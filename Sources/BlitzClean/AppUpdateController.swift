import AppKit
import Sparkle

@MainActor
protocol AppUpdateDriving: AnyObject {
  var canCheckForUpdates: Bool { get }
  var automaticallyChecksForUpdates: Bool { get set }
  var onReadinessChange: (() -> Void)? { get set }
  func start() throws
  func checkForUpdates()
}

/// Sparkle-backed updates for signed release builds. Development builds carry no feed key and stay unavailable.
@MainActor
final class AppUpdateController: NSObject, ObservableObject {
  enum Status: Equatable {
    case idle
    case checking
    case upToDate
    case available(String)
    case downloading(String)
    case readyToInstall(String)
    case failed(String)
    case unavailable
  }

  struct FeedConfiguration {
    /// Absent in builds packaged without a feed.
    let feedURL: String?
    /// Absent in builds packaged without the signing key.
    let publicKey: String?

    static var bundle: Self {
      .init(
        feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
        publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
    }

    var isValid: Bool {
      guard let feedURL, URL(string: feedURL)?.scheme == "https", let publicKey else {
        return false
      }
      return !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  static let releasesURL = URL(string: "https://github.com/blitzreels/blitzclean/releases/latest")!

  @Published private(set) var status: Status = .idle
  @Published private(set) var automaticChecks = false
  @Published private(set) var isWaitingForUpdater = false
  /// Absent until `start()` runs, and in builds without a valid feed.
  private var driver: (any AppUpdateDriving)?
  private let makeDriver: @MainActor (AppUpdateController) -> (any AppUpdateDriving)?
  private var hasStarted = false
  private var installHandler: (() -> Void)?

  override convenience init() {
    self.init { controller in
      FeedConfiguration.bundle.isValid ? SparkleUpdateDriver(delegate: controller) : nil
    }
  }

  init(makeDriver: @escaping @MainActor (AppUpdateController) -> (any AppUpdateDriving)?) {
    self.makeDriver = makeDriver
    super.init()
  }

  var version: String? {
    switch status {
    case .available(let version), .downloading(let version), .readyToInstall(let version): version
    default: nil
    }
  }

  var isAvailable: Bool { driver != nil }

  var actionTitle: String {
    if case .readyToInstall(let version) = status, installHandler != nil {
      return "Restart to update to \(version)"
    }
    switch status {
    case .checking: return "Checking…"
    case .available(let version), .readyToInstall(let version): return "Update to \(version)"
    case .downloading: return "Show download"
    case .unavailable: return "View releases"
    default: return "Check for updates"
    }
  }

  var detail: String {
    switch status {
    case .idle:
      return automaticChecks ? "Checks once a day." : "Automatic checks are off."
    case .checking: return "Looking for a newer version…"
    case .upToDate: return "BlitzClean \(AppBrand.version) is the latest version."
    case .available(let version): return "BlitzClean \(version) is available."
    case .downloading(let version): return "Downloading BlitzClean \(version)…"
    case .readyToInstall(let version):
      return installHandler == nil
        ? "BlitzClean \(version) is ready to install."
        : "BlitzClean \(version) is downloaded. Restarting takes a few seconds."
    case .failed(let message): return message
    case .unavailable: return "This build has no update feed. Download releases from GitHub."
    }
  }

  var canCheck: Bool { !isWaitingForUpdater && status != .checking }

  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    guard let driver = makeDriver(self) else {
      status = .unavailable
      return
    }
    driver.onReadinessChange = { [weak self] in self?.resumeWaitingCheck() }
    do {
      try driver.start()
      self.driver = driver
      automaticChecks = driver.automaticallyChecksForUpdates
    } catch {
      status = .failed(error.localizedDescription)
    }
  }

  func check() {
    if let installHandler {
      AppLifetime.allowRelaunchForUpdate()
      installHandler()
      return
    }
    start()
    guard driver != nil else {
      NSWorkspace.shared.open(Self.releasesURL)
      return
    }
    isWaitingForUpdater = true
    resumeWaitingCheck()
  }

  func setAutomaticChecks(_ enabled: Bool) {
    guard let driver else { return }
    driver.automaticallyChecksForUpdates = enabled
    automaticChecks = driver.automaticallyChecksForUpdates
  }

  struct Installation {
    let version: String
    let install: () -> Void
  }

  func prepareInstallation(_ installation: Installation) {
    installHandler = installation.install
    isWaitingForUpdater = false
    status = .readyToInstall(installation.version)
  }

  func finishCycle(error: (any Error)?) {
    if let error {
      installHandler = nil
      status = .failed(error.localizedDescription)
    } else if status == .checking {
      status = .idle
    }
    resumeWaitingCheck()
  }

  private func resumeWaitingCheck() {
    guard isWaitingForUpdater, let driver, driver.canCheckForUpdates else { return }
    isWaitingForUpdater = false
    if version == nil { status = .checking }
    driver.checkForUpdates()
  }
}

@MainActor
private final class SparkleUpdateDriver: AppUpdateDriving {
  private let controller: SPUStandardUpdaterController
  private var observation: NSKeyValueObservation?
  var onReadinessChange: (() -> Void)?

  init(delegate: AppUpdateController) {
    controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: delegate)
    observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) {
      [weak self] _, _ in
      Task { @MainActor in self?.onReadinessChange?() }
    }
  }

  var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
  var automaticallyChecksForUpdates: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }

  func start() throws { try controller.updater.start() }
  func checkForUpdates() { controller.checkForUpdates(nil) }
}

extension AppUpdateController: SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
  /// The app lives in the menu bar, so scheduled updates surface in the tray and Settings
  /// instead of a window that steals focus.
  var supportsGentleScheduledUpdateReminders: Bool { true }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    status = .available(item.displayVersionString)
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
    status = .upToDate
  }

  func updater(
    _ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest
  ) {
    status = .downloading(item.displayVersionString)
  }

  func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
    status = .readyToInstall(item.displayVersionString)
  }

  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    prepareInstallation(.init(version: item.displayVersionString, install: immediateInstallHandler))
    return true
  }

  func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
    AppLifetime.allowRelaunchForUpdate()
  }

  func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
    error: (any Error)?
  ) {
    if let error = error as NSError?, error.domain == SUSparkleErrorDomain,
      error.code == Int(SUError.noUpdateError.rawValue)
    {
      status = .upToDate
      finishCycle(error: nil)
      return
    }
    finishCycle(error: error)
  }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    immediateFocus
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    status =
      state.stage == .notDownloaded
      ? .available(update.displayVersionString) : .readyToInstall(update.displayVersionString)
  }

  func standardUserDriverWillFinishUpdateSession() {
    if status == .checking { status = .idle }
  }
}
