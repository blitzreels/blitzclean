import AppKit
import SwiftUI
import Testing

@testable import BlitzClean

@MainActor
struct CompactStorageRenderTests {
  @Test func rendersStorageWithSampleDataWhenRequested() async throws {
    guard let path = ProcessInfo.processInfo.environment["BLITZCLEAN_COMPACT_RENDER_DIR"] else {
      return
    }
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    for page in [CleanStoragePage.drive, .cleanup] {
      let view = VStack(spacing: 0) {
        StoragePageHeader(selection: .constant(page)) { EmptyView() }
        Divider()
        VStack(spacing: 12) {
          if page == .cleanup {
            ForEach(
              ["System Data cleanup", "Dependencies", "Removed before", "Docker"], id: \.self
            ) { title in
              BlitzStorageSection(
                title: title, symbol: "shippingbox", detail: "Sample data", trailing: "2 GB",
                showsContent: true
              ) {
                Text("Sample item")
              }
            }
          } else {
            Text("Storage overview · sample data").font(BlitzType.headline)
              .frame(maxWidth: .infinity, alignment: .leading).blitzCard(padding: 16)
          }
          Spacer()
        }.padding(BlitzUI.pagePadding)
      }
      .environment(\.cleanupExpandedSections, .constant([]))
      .frame(width: 720, height: 420)
      .background(BlitzUI.canvasBackground).blitzTheme()
      let host = NSHostingView(rootView: view)
      host.frame = NSRect(x: 0, y: 0, width: 720, height: 420)
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
      let png = try #require(rep.representation(using: .png, properties: [:]))
      try png.write(
        to: URL(fileURLWithPath: path).appendingPathComponent(
          "storage-\(page.rawValue.lowercased()).png"))
    }
  }
}
