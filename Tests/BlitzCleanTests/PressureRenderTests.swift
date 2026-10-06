import AppKit
import SwiftUI
import Testing

@testable import BlitzClean

@MainActor
struct PressureRenderTests {
  @Test func rendersPressureAndProjectScreensWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["BLITZ_PRESSURE_RENDER_DIR"] else {
      return
    }
    let directory = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let processes = DevProcessModel()
    for _ in 0..<50 where processes.scannedAt == nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    let controller = WorkspaceController()
    let assessment = PressureAssessment(
      risk: .critical, limit: .memory, title: "Memory and disk under pressure",
      detail:
        "Swap is competing with a low disk reserve. 3 GB RAM available · 29 GB swap · 9 GB disk free",
      action: "Avoid starting new threads or builds. Pause slows work; Quit releases RAM.",
      date: .now)
    for width in [CGFloat(708), CGFloat(868)] {
      let view = VStack(spacing: 0) {
        PressureBanner(
          assessment: assessment, review: .init(title: "Review projects", action: {})
        )
        .padding(20)
        WorkspaceProjectsView(processes: processes, controller: controller)
      }.blitzTheme()
      let host = NSHostingView(rootView: view.frame(width: width, height: 780))
      host.frame = NSRect(x: 0, y: 0, width: width, height: 780)
      let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: .darkAqua)
      window.contentView = host
      window.orderFrontRegardless()
      try await Task.sleep(for: .seconds(1))
      host.layoutSubtreeIfNeeded()
      let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      window.orderOut(nil)
      let data = try #require(rep.representation(using: .png, properties: [:]))
      try data.write(to: directory.appendingPathComponent("projects-\(Int(width)).png"))
    }
  }
}
