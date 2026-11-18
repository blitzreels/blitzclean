import Foundation
import Testing

@testable import BlitzClean

struct MacStorageVisibilityTests {
  @Test func storageOpensOnTheDriveBreakdown() {
    #expect(CleanStoragePage.allCases.first == .drive)
    #expect(CleanStoragePage.restored(nil) == .drive)
  }

  @Test func driveChartsUseOnlyKnownCapacity() {
    func used(_ capacity: (total: UInt64, free: UInt64)) -> UInt64? {
      StorageDrive(
        path: "/Volumes/SSD", name: "SSD", internalDisk: false, browsable: true,
        available: capacity.free, total: capacity.total
      ).usedBytes
    }
    #expect(used((2_000_000_000_000, 311_000_000_000)) == 1_689_000_000_000)
    #expect(used((100, 0)) == 100)
    #expect(used((100, 100)) == 0)
    #expect(used((0, 0)) == nil)
    #expect(used((100, 101)) == nil)
    #expect(ByteText.capacity(2_000_000_000_000) == "2 TB")
  }

  @Test func folderCapacityUsesTheDeepestMountedVolume() {
    let paths = ["/", "/Volumes/SSD", "/Volumes/SSD/Archive"]
    let drives = paths.map {
      StorageDrive(
        path: $0, name: $0, internalDisk: $0 == "/", browsable: true,
        available: 100, total: 200)
    }
    #expect(StorageDrives.containing(("/Users/me", drives))?.path == "/")
    #expect(StorageDrives.containing(("/Volumes/SSD", drives))?.path == "/Volumes/SSD")
    #expect(StorageDrives.containing(("/Volumes/SSD/Archive/file", drives))?.path == paths.last)
    #expect(StorageDrives.containing(("/Volumes/SSD2/file", drives)) == nil)
    #expect(drives[1].scanRoots == [paths[1]])
    #expect(CleanStoragePage.restored("Drive") == .drive)
  }
}
