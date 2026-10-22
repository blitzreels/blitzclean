import AppKit

// Draws an amber DEV badge on the app icon so the dev build is told apart from the released app in the Dock.
let arguments = CommandLine.arguments
guard arguments.count == 3, let icon = NSImage(contentsOfFile: arguments[1]) else {
  fatalError("usage: badge-dev-icon.swift <icon.png> <output.png>")
}
let size = 1024
let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
  bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high
icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
let badge = NSRect(x: 292, y: 96, width: 440, height: 180)
NSColor(srgbRed: 1, green: 0.72, blue: 0.16, alpha: 1).setFill()
NSBezierPath(roundedRect: badge, xRadius: 90, yRadius: 90).fill()
let text = NSAttributedString(
  string: "DEV",
  attributes: [
    .font: NSFont.systemFont(ofSize: 132, weight: .heavy),
    .foregroundColor: NSColor(srgbRed: 0.12, green: 0.09, blue: 0.02, alpha: 1),
    .kern: 6,
  ])
let textSize = text.size()
text.draw(at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2))
NSGraphicsContext.restoreGraphicsState()
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
