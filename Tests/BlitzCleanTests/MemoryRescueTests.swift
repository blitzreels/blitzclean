import Testing

@testable import BlitzClean

struct MemoryRescueTests {
  @Test
  func mapsNativeMemoryPressureLevels() {
    #expect(MemoryPressureLevel(nativeValue: 1) == .normal)
    #expect(MemoryPressureLevel(nativeValue: 2) == .warning)
    #expect(MemoryPressureLevel(nativeValue: 4) == .critical)
    #expect(MemoryPressureLevel(nativeValue: 0) == .unknown)
  }

  @Test
  func aggregatesEachProcessOnceAcrossAnAppTree() {
    let total = ProcessMemoryTree.total(
      ProcessMemoryTreeInput(
        rootProcessID: 10,
        childrenByParent: [
          10: [11, 12],
          11: [13],
          12: [13],
        ],
        footprintByProcess: [
          10: 100,
          11: 50,
          12: 25,
          13: 10,
        ]
      )
    )

    #expect(total == 185)
  }

  @Test
  func protectsBlitzCleanFinderAndSystemCoreServices() {
    let blitzClean = MemoryAppProtection.reason(
      MemoryAppProtectionInput(
        processID: 100,
        bundleIdentifier: "com.blitzreels.BlitzClean",
        bundlePath: "/Users/me/Applications/BlitzClean.app",
        currentProcessID: 100,
        currentBundleIdentifier: "com.blitzreels.BlitzClean"
      )
    )
    let finder = MemoryAppProtection.reason(
      MemoryAppProtectionInput(
        processID: 200,
        bundleIdentifier: "com.apple.finder",
        bundlePath: "/System/Library/CoreServices/Finder.app",
        currentProcessID: 100,
        currentBundleIdentifier: "com.blitzreels.BlitzClean"
      )
    )
    let app = MemoryAppProtection.reason(
      MemoryAppProtectionInput(
        processID: 300,
        bundleIdentifier: "com.example.Editor",
        bundlePath: "/Applications/Editor.app",
        currentProcessID: 100,
        currentBundleIdentifier: "com.blitzreels.BlitzClean"
      )
    )

    #expect(blitzClean == "\(AppBrand.name) stays running during rescue")
    #expect(finder == "macOS system app")
    #expect(app == nil)
  }

  @Test
  func scansRunningApplicationsByPhysicalFootprint() async {
    let descriptors = await MainActor.run {
      MemoryAppProvider().descriptors()
    }
    let apps = NativeProcessMemoryScanner().scan(descriptors)

    #expect(!apps.isEmpty)
    #expect(apps.allSatisfy { app in app.memoryBytes > 0 })
    #expect(apps == apps.sorted { left, right in left.memoryBytes > right.memoryBytes })
  }
}
