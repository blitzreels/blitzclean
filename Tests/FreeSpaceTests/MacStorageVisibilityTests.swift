import Foundation
import Testing

@testable import FreeSpace

struct MacStorageVisibilityTests {
  @Test func storageNavigationIncludesMacInventory() {
    #expect(CleanStoragePage.allCases.contains { $0 == .mac })
  }

  @Test func installedAppInventoryFindsVendorFolders() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let adobe = root.appendingPathComponent("Adobe After Effects 2026/Adobe After Effects 2026.app")
    let direct = root.appendingPathComponent("BlitzClean.app")
    let helper = adobe.appendingPathComponent("Contents/Helpers/Helper.app")
    for path in [direct, helper] {
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    let paths = InstalledApplications.paths(in: [root.path], fileManager: .default)
    #expect(paths == [adobe, direct].compactMap { ReviewFile.canonicalPath($0.path) }.sorted())
  }
}
