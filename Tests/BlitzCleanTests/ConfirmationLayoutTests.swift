import AppKit
import SwiftUI
import Testing

@testable import BlitzClean

/// A long review must not push Cancel and the confirm button out of reach.
@MainActor
struct ConfirmationLayoutTests {
  private static let paths = (1...20).map {
    "/Users/sample/Projects/workspace-\($0)/packages/web-app/node_modules/.pnpm/"
      + "example-package-with-a-long-name@1.2.\($0)/node_modules"
  }
  private static let note =
    "20 items, 1.3 GB. This cannot be undone. Rebuild and activity checks run before deletion;"
    + " changed or busy items are skipped."

  /// The dependency review before review items: paths after a one-line sentence parse as a note.
  private static var pathsInMessage: BlitzConfirmation {
    BlitzConfirmation(
      title: "Delete 20 selected items?", message: note + "\n\n" + paths.joined(separator: "\n"),
      confirmTitle: "Delete 20 items", onConfirm: {}, onCancel: {})
  }

  private static var reviewItems: BlitzConfirmation {
    BlitzConfirmation(
      title: "Delete 20 selected items?", message: note, confirmTitle: "Delete 20 items",
      onConfirm: {}, onCancel: {},
      reviewItems: paths.enumerated().map { .init(name: $1, value: "\(($0 + 1) * 12) MB") })
  }

  @Test func longReviewListKeepsTheCardBounded() {
    let width: CGFloat = 460
    let bounded = NSHostingView(rootView: Self.reviewItems.frame(width: width).blitzTheme())
    let unbounded = NSHostingView(rootView: Self.pathsInMessage.frame(width: width).blitzTheme())
    #expect(bounded.fittingSize.height < 420)
    #expect(unbounded.fittingSize.height > bounded.fittingSize.height * 1.5)
  }

  @Test func rendersBothReviewsWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["BLITZCLEAN_DESIGN_DIR"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let size = CGSize(width: 560, height: 520)
    for (name, card) in [
      ("confirmation-paths-in-message", Self.pathsInMessage),
      ("confirmation-review-items", Self.reviewItems),
    ] {
      let view = VStack {
        Spacer(minLength: 0)
        card.padding(20)
      }
      .frame(width: size.width, height: size.height)
      .background(BlitzUI.canvasBackground).blitzTheme()
      let host = NSHostingView(rootView: view)
      host.frame = NSRect(origin: .zero, size: size)
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
      try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
  }
}
