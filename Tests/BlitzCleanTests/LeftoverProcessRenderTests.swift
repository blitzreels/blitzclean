import AppKit
import SwiftUI
import Testing

@testable import BlitzClean

/// Writes Leftover processes rows with synthetic data when `BLITZ_LEFTOVER_RENDER_DIR` is set.
@MainActor
struct LeftoverProcessRenderTests {
  @Test func rendersLeftoverRowsWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["BLITZ_LEFTOVER_RENDER_DIR"] else {
      return
    }
    let directory = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let leftovers = [
      LeftoverProcess(
        processID: 48_213, executableName: "node", title: "node vite.js",
        workingDirectory: "/Users/test/dev/storefront-with-a-very-long-folder-name/apps/web",
        memoryBytes: 1_870_000_000, cpuPercent: 96, startedAt: .now.addingTimeInterval(-15_000)),
      LeftoverProcess(
        processID: 51_007, executableName: "java", title: "java GradleDaemon",
        workingDirectory: "/Users/test/dev/android-app", memoryBytes: 742_000_000,
        cpuPercent: 0, startedAt: .now.addingTimeInterval(-190_000)),
      LeftoverProcess(
        processID: 3_388, executableName: "python3.12", title: "python http.server",
        workingDirectory: nil, memoryBytes: nil, cpuPercent: 0,
        startedAt: .now.addingTimeInterval(-600)),
    ]
    for width in [CGFloat(708), CGFloat(868)] {
      let view = VStack(alignment: .leading, spacing: 10) {
        BlitzSectionHeader(title: "Leftover processes", count: leftovers.count) {
          Button("Quit \(leftovers.count)…") {}.blitzButton(.secondary).controlSize(.small)
        }
        BlitzStatusLine(
          text: "python http.server is still running. Use Force Quit to end it now.", tone: .working
        )
        VStack(spacing: 0) {
          ForEach(leftovers) { process in
            LeftoverProcessRow(
              process: process, isBusy: process.processID == 3_388, onQuit: {}, onForceQuit: {},
              onHide: {})
            if process.id != leftovers.last?.id { BlitzRowDivider(leading: 56) }
          }
        }.blitzTable()
        HStack(spacing: 8) {
          Text("Hidden leftovers: esbuild").font(BlitzType.caption)
            .foregroundStyle(BlitzUI.tertiaryText)
          Button("Show again") {}.blitzButton(.quiet).controlSize(.small)
        }
      }.padding(20).frame(width: width, height: 340, alignment: .top).blitzTheme()
      let host = NSHostingView(rootView: view)
      host.frame = NSRect(x: 0, y: 0, width: width, height: 340)
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
      try data.write(to: directory.appendingPathComponent("leftovers-\(Int(width)).png"))
    }
  }
}
