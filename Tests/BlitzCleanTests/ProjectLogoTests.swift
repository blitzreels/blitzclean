import AppKit
import Foundation
import Testing

@testable import BlitzClean

struct ProjectLogoTests {
  @Test func prefersAppIconsOverFaviconsAndSkipsBuildOutput() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "logo-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = NSImage(size: .init(width: 64, height: 64), flipped: false) { rect in
      NSColor.systemBlue.setFill()
      rect.fill()
      return true
    }
    let png = try #require(
      image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(
        using: .png, properties: [:]))
    for folder in ["public", "node_modules/pkg/public", "apps/web/public"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    try png.write(to: root.appendingPathComponent("public/favicon.png"))
    try png.write(to: root.appendingPathComponent("node_modules/pkg/public/apple-touch-icon.png"))
    try png.write(to: root.appendingPathComponent("apps/web/public/apple-touch-icon.png"))
    #expect(
      ProjectLogo.find(root.path)
        == .file(root.appendingPathComponent("apps/web/public/apple-touch-icon.png").path))
  }

  @Test func ranksLogoNames() {
    let icon = ProjectLogo.score(.init(name: "icon.png", depth: 1, path: "/p/public/icon.png"))
    let favicon = ProjectLogo.score(
      .init(name: "favicon.ico", depth: 1, path: "/p/public/favicon.ico"))
    #expect((icon ?? 0) > (favicon ?? 0))
    #expect(ProjectLogo.score(.init(name: "readme.md", depth: 0, path: "/p/readme.md")) == nil)
  }
}
