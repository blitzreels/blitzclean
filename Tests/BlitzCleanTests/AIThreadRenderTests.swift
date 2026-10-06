import AppKit
import SwiftUI
import Testing

@testable import BlitzClean

@MainActor
struct AIThreadRenderTests {
  @Test func rendersLongNamesAndPauseStatesWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["BLITZ_AI_RENDER_DIR"] else { return }
    let directory = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var named = AIThread(
      id: "named", tool: .claudeCode, name: "Claude Code", directory: "/Users/test/dev/blitzreels",
      terminal: "ttys001", startedAt: .now.addingTimeInterval(-300), processIDs: [42, 43],
      memoryBytes: 2_400_000_000, cpuPercent: 128, isPaused: false, isDetached: false)
    named.sessionTitle = "Fix video exports and preserve the original timeline across every format"
    named.delegatedTools = ["Codex CLI"]
    named.hostName = "cmux"
    let paused = AIThread(
      id: "paused", tool: .cursorAgent, name: "Cursor agent", directory: "/Users/test/dev/app",
      terminal: nil, startedAt: .now.addingTimeInterval(-3_600), processIDs: [51, 52, 53],
      memoryBytes: 12_400_000_000, cpuPercent: 0, isPaused: true, isDetached: false)
    let busy = AIThread(
      id: "busy", tool: .codexDesktop, name: "Codex workers", directory: nil, terminal: nil,
      startedAt: nil, processIDs: [61], memoryBytes: 800_000_000, cpuPercent: 2, isPaused: false,
      isDetached: false)
    for width in [CGFloat(708), CGFloat(868)] {
      let view = VStack(alignment: .leading, spacing: 12) {
        Text("AI threads").font(BlitzType.section)
        VStack(spacing: 0) {
          ForEach([named, paused, busy]) { thread in
            AIThreadRow(
              thread: thread, isBusy: thread.id == "busy", onPause: {}, onResume: {},
              onQuit: {}, onForceQuit: {})
          }
        }.blitzTable()
      }.padding(20).frame(width: width, height: 360).blitzTheme()
      let host = NSHostingView(rootView: view)
      host.frame = NSRect(x: 0, y: 0, width: width, height: 360)
      let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: .darkAqua)
      window.contentView = host
      window.orderFrontRegardless()
      try await Task.sleep(for: .milliseconds(300))
      host.layoutSubtreeIfNeeded()
      let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      window.orderOut(nil)
      let data = try #require(rep.representation(using: .png, properties: [:]))
      try data.write(to: directory.appendingPathComponent("threads-\(Int(width)).png"))
    }
  }
}
