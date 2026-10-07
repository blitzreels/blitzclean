import AppKit
import SwiftUI
import Testing

@testable import BlitzClean

struct OverviewCleanupSummaryTests {
  @Test func dockerIsCountedWhenNoCachesAreEligible() {
    let summary = OverviewCleanupSummary(
      .init(
        items: [], dockerBytes: 2_300_000_000, hasSkippedLocations: true, dockerUnavailable: false))
    #expect(summary.totalBytes == 2_300_000_000)
    #expect(summary.bytesBySource[.docker] == 2_300_000_000)
    #expect(summary.isPartial)
  }

  @Test func overlappingScannersAndNestedFoldersAreCountedOnce() {
    let summary = OverviewCleanupSummary(
      .init(
        items: [
          .init(path: "/fixture/project/node_modules", bytes: 500, source: .projects),
          .init(path: "/fixture/project/node_modules/", bytes: 500, source: .regrown),
          .init(path: "/fixture/project/node_modules/.cache", bytes: 100, source: .caches),
          .init(path: "/fixture/project/node_modules-other", bytes: 50, source: .projects),
          .init(path: "/fixture/report.ips", bytes: 10, source: .reports),
        ], dockerBytes: 40, hasSkippedLocations: false, dockerUnavailable: false))
    #expect(summary.totalBytes == 600)
    #expect(summary.bytesBySource[.projects] == 550)
    #expect(summary.bytesBySource[.caches] == nil)
    #expect(summary.bytesBySource[.regrown] == nil)
  }

  @Test func unavailableDockerIsNotPresentedAsAnEmptySuccessfulScan() {
    let summary = OverviewCleanupSummary(
      .init(
        items: [], dockerBytes: 2_300_000_000, hasSkippedLocations: false, dockerUnavailable: true))
    #expect(summary.isPartial)
    #expect(summary.totalBytes == 0)
    #expect(summary.emptyMessage.contains("could not be checked"))
    #expect(!summary.emptyMessage.contains("0 B"))
  }

  @MainActor @Test func renderSummaryStatesWhenRequested() throws {
    guard let output = ProcessInfo.processInfo.environment["BLITZCLEAN_SUMMARY_RENDER_DIR"] else {
      return
    }
    let directory = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = QuickCleanModel()
    let states: [(String, OverviewCleanupSummary.Input, Bool)] = [
      (
        "empty",
        .init(items: [], dockerBytes: 0, hasSkippedLocations: false, dockerUnavailable: false),
        false
      ),
      (
        "partial",
        .init(items: [], dockerBytes: 0, hasSkippedLocations: true, dockerUnavailable: true), false
      ),
      (
        "scanning",
        .init(items: [], dockerBytes: 0, hasSkippedLocations: false, dockerUnavailable: false), true
      ),
      (
        "docker",
        .init(
          items: [], dockerBytes: 2_300_000_000, hasSkippedLocations: true, dockerUnavailable: false
        ), false
      ),
      (
        "combined",
        .init(
          items: [
            .init(path: "/fixture/cache", bytes: 3_000_000_000, source: .caches),
            .init(path: "/fixture/dependencies", bytes: 12_400_000_000, source: .projects),
            .init(path: "/fixture/regrown", bytes: 4_000_000_000, source: .regrown),
            .init(path: "/fixture/device", bytes: 400_000_000, source: .simulators),
          ], dockerBytes: 2_300_000_000, hasSkippedLocations: true, dockerUnavailable: false), false
      ),
    ]
    for (name, input, scanning) in states {
      for width in [648.0, 812.0] {
        let renderer = ImageRenderer(
          content: AuditRenderFixture.card(
            .init(model: model, summary: .init(input), isScanning: scanning)
          )
          .padding(28).frame(width: width).background(BlitzUI.canvasBackground).blitzTheme())
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let data = try #require(
          NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name)-\(Int(width)).png"))
      }
    }
  }
}
