import Foundation
import Testing

@testable import BlitzClean

@MainActor
struct AppUpdateControllerTests {
  @Test func acceptsOnlySignedHTTPSFeeds() {
    typealias Feed = AppUpdateController.FeedConfiguration
    let url = "https://github.com/blitzreels/blitzclean/releases/latest/download/appcast.xml"
    #expect(Feed(feedURL: url, publicKey: "key").isValid)
    #expect(
      !Feed(feedURL: url.replacingOccurrences(of: "https", with: "http"), publicKey: "key").isValid)
    #expect(!Feed(feedURL: url, publicKey: "  ").isValid)
    #expect(!Feed(feedURL: nil, publicKey: "key").isValid)
    #expect(!Feed(feedURL: url, publicKey: nil).isValid)
  }

  @Test func buildWithoutFeedIsUnavailableAndStartsOnce() {
    var made = 0
    let controller = AppUpdateController { _ in
      made += 1
      return nil
    }
    controller.start()
    controller.start()
    #expect(made == 1)
    #expect(controller.status == .unavailable)
    #expect(!controller.isAvailable)
    #expect(controller.actionTitle == "View releases")
  }

  @Test func manualCheckWaitsForUpdaterReadinessWithoutASecondClick() {
    let driver = UpdateDriverStub()
    driver.canCheckForUpdates = false
    let controller = AppUpdateController { _ in driver }
    controller.start()
    controller.check()
    #expect(controller.isWaitingForUpdater)
    #expect(!controller.canCheck)
    #expect(driver.manualChecks == 0)
    driver.canCheckForUpdates = true
    #expect(driver.manualChecks == 1)
    #expect(controller.status == .checking)
    driver.onReadinessChange?()
    #expect(driver.manualChecks == 1)
  }

  @Test func automaticChecksFollowTheUpdater() {
    let driver = UpdateDriverStub()
    let controller = AppUpdateController { _ in driver }
    controller.start()
    #expect(controller.automaticChecks)
    controller.setAutomaticChecks(false)
    #expect(!driver.automaticallyChecksForUpdates)
    #expect(!controller.automaticChecks)
  }

  @Test func downloadedUpdateRestartsInsteadOfCheckingAgain() {
    let driver = UpdateDriverStub()
    let controller = AppUpdateController { _ in driver }
    controller.start()
    var installs = 0
    controller.prepareInstallation(.init(version: "1.3.0", install: { installs += 1 }))
    #expect(controller.actionTitle == "Restart to update to 1.3.0")
    controller.check()
    #expect(installs == 1)
    #expect(driver.manualChecks == 0)
  }

  @Test func failedCycleReportsErrorAndDropsPendingInstall() {
    let driver = UpdateDriverStub()
    let controller = AppUpdateController { _ in driver }
    controller.start()
    controller.prepareInstallation(.init(version: "1.3.0", install: {}))
    controller.finishCycle(error: StubError())
    #expect(controller.status == .failed("Feed unreachable"))
    #expect(controller.actionTitle == "Check for updates")
  }
}

@MainActor
private final class UpdateDriverStub: AppUpdateDriving {
  var canCheckForUpdates = true {
    didSet { onReadinessChange?() }
  }
  var automaticallyChecksForUpdates = true
  var onReadinessChange: (() -> Void)?
  var manualChecks = 0

  func start() throws {}
  func checkForUpdates() { manualChecks += 1 }
}

private struct StubError: Error, CustomStringConvertible {
  var description: String { "Feed unreachable" }
}

extension StubError: LocalizedError {
  var errorDescription: String? { description }
}
