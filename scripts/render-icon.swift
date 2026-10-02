import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let layer = output.deletingLastPathComponent().appendingPathComponent(
  "BlitzClean.icon/Assets/Mark.svg")
guard let mark = NSImage(contentsOf: layer) else {
  fatalError("Missing BlitzClean foreground layer")
}
let size = 1024
let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
  bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high
let tile = NSBezierPath(
  roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
NSGradient(
  starting: NSColor(srgbRed: 0.09, green: 0.16, blue: 0.14, alpha: 1),
  ending: NSColor(srgbRed: 0.045, green: 0.065, blue: 0.06, alpha: 1))!
  .draw(in: tile, angle: -90)
mark.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
