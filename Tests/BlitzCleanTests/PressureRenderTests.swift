import AppKit
import SwiftUI
import Testing

@testable import BlitzClean

@MainActor
struct PressureRenderTests {
  @Test func rendersProjectScreensWhenRequested() async throws {
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
    for width in [CGFloat(708), CGFloat(868)] {
      let view = WorkspaceProjectsView(
        processes: processes, controller: controller, monitor: SystemMonitor()
      ).blitzTheme()
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
