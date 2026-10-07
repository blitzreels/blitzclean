import AppKit
import SwiftUI
import Testing

@testable import BlitzClean

@MainActor
struct FeedbackFeatureRenderTests {
  @Test func rendersMemoryAndSystemDataWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["BLITZCLEAN_FEEDBACK_RENDER_DIR"] else {
      return
    }
    let directory = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let resources: [ResourceProcess] = [
      .init(
        processID: 99901, parentProcessID: 1, name: "Browser Helper (Renderer)", owner: "Browser",
        directory: nil, memoryBytes: 3_600_000_000, cpuPercent: 0, isTool: false),
      .init(
        processID: 99902, parentProcessID: 1,
        name: "A long background process name with a long owner",
        owner: "An application with a long name", directory: "/dev/project",
        memoryBytes: 128_000_000, cpuPercent: 0, isTool: false),
      .init(
        processID: 99903, parentProcessID: 1, name: "Restricted helper",
        owner: "Background service",
        directory: nil, memoryBytes: nil, cpuPercent: 0, isTool: false),
    ]
    for query in ["", "no-results"] {
      try write(
        .init(
          view: AnyView(
            MemoryProcessesView(
              processes: resources, isLoading: false, query: query, scanMessage: nil)),
          directory: directory, name: query.isEmpty ? "processes" : "empty-processes"))
    }
    let historyRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "feedback-render-\(UUID())")
    defer { try? FileManager.default.removeItem(at: historyRoot) }
    let history = CleanupOverviewModel(
      .init(
        store: .init(url: historyRoot.appendingPathComponent("history.json")),
        scanRequest: .init(roots: [], minimumBytes: 0, maxEntries: 1),
        synchronizesInBackground: false))
    let model = QuickCleanModel(driver: FeedbackRenderDriver())
    model.scan()
    while model.isScanning { try await Task.sleep(for: .milliseconds(10)) }
    try write(
      .init(
        view: AnyView(QuickCleanView(model: model, history: history)),
        directory: directory, name: "system-data-selection"))
  }

  private struct RenderInput {
    let view: AnyView
    let directory: URL
    let name: String
  }

  private func write(_ input: RenderInput) throws {
    for width in [648.0, 812.0] {
      let renderer = ImageRenderer(
        content: input.view.padding(28).frame(width: width)
          .background(BlitzUI.canvasBackground).blitzTheme())
      renderer.scale = 2
      let image = try #require(renderer.cgImage)
      let data = try #require(
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
      try data.write(to: input.directory.appendingPathComponent("\(input.name)-\(Int(width)).png"))
    }
  }
}

private struct FeedbackRenderDriver: QuickCleanDriver {
  func scan() async -> CacheScanResult {
    .init(
      candidates: [
        .init(
          path: "/fixture/browser-cache",
          rule: .init(
            title: "Browser cache", path: "/fixture",
            recipe: "Rebuildable cache", owners: [], kind: .cache),
          tree: .init(fingerprint: "cache", bytes: 1_500_000_000, newest: .distantPast)),
        .init(
          path: "/fixture/application-crash-report-from-last-month.ips",
          rule: .init(
            title: "Diagnostic reports",
            path: "/fixture", recipe: "Report cannot be recovered", owners: [],
            kind: .diagnosticReport),
          tree: .init(fingerprint: "report", bytes: 8_000_000, newest: .distantPast)),
      ], notes: ["Safari cache: its tools are running; kept."])
  }

  func delete(_ candidate: CacheCandidate) async throws -> CleanupWin {
    throw CacheCleanError.unverified
  }
}
