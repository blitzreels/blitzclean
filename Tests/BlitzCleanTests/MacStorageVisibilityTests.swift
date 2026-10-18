import Foundation
import Testing

@testable import BlitzClean

struct MacStorageVisibilityTests {
  @Test func storageOpensOnTheDriveBreakdown() {
    #expect(CleanStoragePage.allCases.first == .drive)
    #expect(CleanStoragePage.restored(nil) == .drive)
  }
}
