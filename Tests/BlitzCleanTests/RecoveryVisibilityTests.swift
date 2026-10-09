import Darwin
import Foundation
import Testing

@testable import BlitzClean

struct RecoveryVisibilityTests {
  private struct AppInput {
    let identifier: String
    let path: String
  }

  private func app(_ input: AppInput) -> MemoryApp {
    .init(
      processID: 42, name: "Built-in app", bundleIdentifier: input.identifier,
      bundleURL: URL(fileURLWithPath: input.path), memoryBytes: 100,
      protectionReason: "macOS system app", isActive: false,
      launchDate: Date(timeIntervalSince1970: 100), childProcessCount: 0)
  }

  private func descriptor(_ app: MemoryApp) -> MemoryAppDescriptor {
    .init(
      processID: app.processID, name: app.name, bundleIdentifier: app.bundleIdentifier,
      bundleURL: app.bundleURL, protectionReason: app.protectionReason,
      isActive: app.isActive, launchDate: app.launchDate)
  }

  @Test func builtInUserAppsAppearWithoutMemoryMeasurements() {
    for input in [
      AppInput(identifier: "com.apple.mail", path: "/System/Applications/Mail.app"),
      .init(identifier: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app"),
      .init(
        identifier: "com.apple.Safari",
        path: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"),
    ] {
      let expected = app(input)
      let roster = RecoveryAppRoster.merge(.init(descriptors: [descriptor(expected)], measured: []))
      #expect(roster.map(\.bundleIdentifier) == [input.identifier])
    }
  }

  @Test func aStoppedMailProcessCanBeResumedWithoutUnlockingQuit() {
    let mail = app(.init(identifier: "com.apple.mail", path: "/System/Applications/Mail.app"))
    let process = RecoveryProcess(
      processID: 42, owner: 501, startSeconds: 100,
      startMicroseconds: 0, state: UInt32(SSTOP))
    #expect(
      RecoverySafety.refusal(
        .init(
          expected: mail, current: descriptor(mail),
          process: process, ownProcessID: 100, ownUserID: 501)) == nil)
    #expect(
      MemoryQuitSafety.refusal(
        .init(
          expected: mail, current: descriptor(mail),
          policy: .review, explicit: true)) != nil)
  }

  @Test func finderCoreServicesAndBlitzCleanRemainProtected() {
    for input in [
      AppInput(identifier: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app"),
      .init(identifier: "com.apple.dock", path: "/System/Library/CoreServices/Dock.app"),
      .init(identifier: AppBrand.bundleIdentifier, path: "/Users/test/Applications/BlitzClean.app"),
    ] {
      let expected = app(input)
      #expect(
        RecoveryAppRoster.merge(.init(descriptors: [descriptor(expected)], measured: [])).isEmpty)
    }
  }
}
