import Foundation
import Testing

@testable import BlitzClean

struct DriveBreakdownTests {
  private let catalog = DriveCatalog(
    .init(
      home: "/Users/me", temporary: "/private/var/folders/x/T",
      systemRoots: DriveCatalog.systemRoots))

  private func unit(_ path: String, inherited: String? = nil) -> String? {
    catalog.unit(
      .init(path: path, name: (path as NSString).lastPathComponent, inherited: inherited))
  }

  @Test func fixedLocationsOwnTheirFolders() {
    #expect(unit("/Users/me/Library/Caches") == "caches.apps")
    #expect(unit("/Users/me/.Trash") == "trash")
    #expect(unit("/Users/me/Library/Developer/CoreSimulator/Devices") == "simulators.devices")
    #expect(unit("/Users/me/.codex/tmp", inherited: "ai.codex") == "ai.codex.temporary")
    #expect(unit("/private/var/folders/x/T") == "caches.temporary")
  }

  @Test func projectCachesAreFoundOnlyInProjectFolders() {
    #expect(
      unit("/Users/me/dev/app/node_modules", inherited: "home:/Users/me/dev")
        == DriveCatalog.dependencies)
    #expect(unit("/Users/me/dev/app/.next", inherited: "home:/Users/me/dev") == DriveCatalog.builds)
    #expect(
      unit("/Users/me/.vscode/extensions/x/node_modules", inherited: "home:/Users/me/.vscode")
        == nil)
    #expect(
      unit(
        "/Users/me/Library/Application Support/Code/node_modules",
        inherited: "lib:/Users/me/Library/Application Support/Code") == nil)
    #expect(
      unit("/Users/me/dev/app/node_modules/x/node_modules", inherited: DriveCatalog.dependencies)
        == nil)
  }

  @Test func remaindersFallIntoBuckets() {
    #expect(unit("/Users/me/dev") == "home:/Users/me/dev")
    #expect(unit("/Users/me/dev/app", inherited: "home:/Users/me/dev") == nil)
    #expect(
      unit("/Users/me/Library/Application Support/Google")
        == "lib:/Users/me/Library/Application Support/Google")
    #expect(unit("/Applications/Xcode.app") == "app:/Applications/Xcode.app")
    #expect(catalog.describe("app:/Applications/Xcode.app").removal == .uninstall)
    #expect(catalog.describe("home:/Users/me/dev").removal == .browse)
  }

  @Test func systemFillsTheRestOfUsedSpace() {
    let unit = DriveUnit(
      id: "caches.apps", title: "App caches", detail: "", group: .caches, paths: [],
      removal: .deleteContents, minimumAge: 0, bytes: 100, folders: 0, partial: false)
    let breakdown = DriveBreakdown(
      units: [unit],
      capacity: .init(total: 1_000, available: 400, purgeable: 0, system: 50, swap: 30),
      scannedAt: .now
    ).withSystem()
    #expect(breakdown.units.reduce(0) { $0 + $1.bytes } == 600)
    #expect(breakdown.units.first { $0.id == "system.other" }?.bytes == 420)
  }

  @Test func scannerCountsEachFolderOnceAndDeletesOnlyOldContents() throws {
    let base = try #require(
      ReviewFile.canonicalPath(FileManager.default.temporaryDirectory.path))
    let home = base + "/drive-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: home) }
    let fileManager = FileManager.default
    for folder in ["Library/Caches/old", "Library/Caches/new", "dev/app/node_modules/x"] {
      try fileManager.createDirectory(
        atPath: home + "/" + folder, withIntermediateDirectories: true)
    }
    let payload = Data(repeating: 1, count: 64 * 1_024)
    try payload.write(to: URL(fileURLWithPath: home + "/Library/Caches/old/a"))
    try payload.write(to: URL(fileURLWithPath: home + "/Library/Caches/new/b"))
    try payload.write(to: URL(fileURLWithPath: home + "/dev/app/node_modules/x/c"))
    try payload.write(to: URL(fileURLWithPath: home + "/dev/app/main.swift"))
    try fileManager.setAttributes(
      [.modificationDate: Date.now.addingTimeInterval(-7_200)],
      ofItemAtPath: home + "/Library/Caches/old")

    let catalog = DriveCatalog(
      .init(home: home, temporary: home + "/tmp-missing", systemRoots: []))
    let snapshot = DriveScanner(catalog: catalog).scan(.init())
    #expect((snapshot.bytes["caches.apps"] ?? 0) >= 128 * 1_024)
    #expect((snapshot.bytes[DriveCatalog.dependencies] ?? 0) >= 64 * 1_024)
    #expect(snapshot.folders[DriveCatalog.dependencies] == 1)
    #expect((snapshot.bytes["home:" + home + "/dev"] ?? 0) >= 64 * 1_024)

    let spec = try #require(catalog.spec("caches.apps"))
    let caches = DriveUnit(
      id: spec.id, title: spec.title, detail: spec.detail, group: spec.group, paths: spec.paths,
      removal: spec.removal, minimumAge: spec.minimumAge, bytes: 0, folders: 0, partial: false)
    let outcome = DriveRemover.remove(.init(unit: caches, home: home))
    #expect(outcome.removed == [home + "/Library/Caches/old"])
    #expect(outcome.skippedRecent == 1)
    #expect(fileManager.fileExists(atPath: home + "/Library/Caches/new/b"))
    #expect(fileManager.fileExists(atPath: home + "/dev/app/main.swift"))
  }
}

struct SimulatorRuntimeCatalogTests {
  @Test func eachDownloadedIOSVersionIsItsOwnDeletableUnit() {
    let catalog = DriveCatalog(
      .init(home: "/Users/me", temporary: "/tmp/x", systemRoots: DriveCatalog.systemRoots))
    let path = DriveCatalog.runtimeRoot + "/abc.asset"
    let id = catalog.unit(.init(path: path, name: "abc.asset", inherited: "simulators.runtimes"))
    #expect(id == "runtime:" + path)
    #expect(catalog.describe(id ?? "").removal == .simulatorRuntime)
    #expect(DriveRemoval.simulatorRuntime.isDestructive)
  }
}
