import Testing

@testable import FreeSpace

struct StorageVolumeBreakdownTests {
  @Test
  func separatesMacAndExternalVolumeItems() {
    let category = testCategory(
      items: [
        testItem(TestStorageItemInput(path: "/Users/me/dev/app/node_modules", bytes: 20)),
        testItem(
          TestStorageItemInput(
            path: "/Volumes/Developer/dev/app/node_modules",
            bytes: 80
          )
        ),
      ]
    )
    let mac = StorageVolumeContext(
      id: "mac",
      name: "Mac",
      rootPath: "/",
      availableBytes: 100,
      totalBytes: 200
    )

    let result = StorageVolumeBreakdown.result(
      StorageVolumeBreakdownRequest(categories: [category], volume: mac)
    )

    #expect(result.categories.first { $0.id == "test" }?.bytes == 20)
    #expect(result.coverage.identifiedBytes == 20)
    #expect(result.coverage.otherBytes == 80)
    #expect(result.categories.first?.id == "other-storage")
    #expect(result.categories.first?.name == "Other files & macOS")
  }

  @Test
  func avoidsCountingNestedItemsTwice() {
    let category = testCategory(
      items: [
        testItem(TestStorageItemInput(path: "/Users/me/Library/App", bytes: 60)),
        testItem(TestStorageItemInput(path: "/Users/me/Library/App/cache.bin", bytes: 40)),
      ]
    )
    let mac = StorageVolumeContext(
      id: "mac",
      name: "Mac",
      rootPath: "/",
      availableBytes: 0,
      totalBytes: 100
    )

    let result = StorageVolumeBreakdown.result(
      StorageVolumeBreakdownRequest(categories: [category], volume: mac)
    )

    #expect(result.coverage.identifiedBytes == 60)
    #expect(result.coverage.otherBytes == 40)
    #expect(result.categories.map(\.bytes).reduce(0, +) == 100)
  }

  private func testCategory(items: [StorageItem]) -> StorageCategory {
    StorageCategory(
      id: "test",
      name: "Test",
      detail: "Test data",
      systemImage: "internaldrive",
      safety: .review,
      bytes: items.reduce(0) { result, item in result + item.bytes },
      items: items
    )
  }

  private func testItem(_ input: TestStorageItemInput) -> StorageItem {
    StorageItem(
      name: input.path,
      path: input.path,
      bytes: input.bytes,
      cleanupKind: nil,
      cleanupAvailability: nil,
      lastActivityAt: nil,
      contentBytes: nil,
      nodeOrigin: nil,
      projectRootPath: nil,
      dependencyInstalledAt: nil,
      activeProcesses: nil
    )
  }
}

private struct TestStorageItemInput {
  let path: String
  let bytes: UInt64
}
