import AppKit
import SwiftUI
import Testing

@testable import BlitzClean

@MainActor
struct DashboardRenderTests {
  @Test
  func rendersTrayDashboardToPNGWhenRequested() async throws {
    guard let outputDirectory = ProcessInfo.processInfo.environment["BLITZCLEAN_RENDER_DIR"] else {
      return
    }

    let monitor = SystemMonitor()
    let memoryRescue = MemoryRescueModel()
    let devProcesses = DevProcessModel()
    devProcesses.refresh()

    try await Task.sleep(for: .seconds(6))
    monitor.refresh()

    let view = BlitzTrayView(
      monitor: monitor, memory: memoryRescue, recovery: AppRecoveryModel(),
      navigation: CleanNavigation())

    for key in [
      MenuBarPreferenceKey.showCPU, MenuBarPreferenceKey.showMemory, MenuBarPreferenceKey.showDisk,
    ] {
      UserDefaults.standard.set(true, forKey: key)
    }
    let labelRenderer = ImageRenderer(
      content: MenuBarHealthLabel(snapshot: monitor.snapshot, risk: memoryRescue.risk).metrics
        .padding(6)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    )
    labelRenderer.scale = 4
    if let cgImage = labelRenderer.cgImage {
      let rep = NSBitmapImageRep(cgImage: cgImage)
      let data = try #require(rep.representation(using: .png, properties: [:]))
      try data.write(
        to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("menubar.png"))
    }

    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let renderer = ImageRenderer(
        content: view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
      renderer.scale = 2
      if let cgImage = renderer.cgImage {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let rendered = try #require(rep.representation(using: .png, properties: [:]))
        try rendered.write(
          to: URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent("renderer-\(appearance.rawValue).png")
        )
      }
    }
  }
}
