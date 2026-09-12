import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)
let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.12, blue: 0.115, alpha: 1),
  ending: NSColor(srgbRed: 0.035, green: 0.035, blue: 0.043, alpha: 1))!.draw(in: tile, angle: 90)
NSColor.white.withAlphaComponent(0.10).setStroke()
tile.lineWidth = 3
tile.stroke()
let bolt = NSBezierPath()
bolt.move(to: NSPoint(x: 574, y: 208))
bolt.line(to: NSPoint(x: 302, y: 554))
bolt.line(to: NSPoint(x: 468, y: 554))
bolt.line(to: NSPoint(x: 413, y: 816))
bolt.line(to: NSPoint(x: 711, y: 449))
bolt.line(to: NSPoint(x: 535, y: 449))
bolt.close()
NSColor(srgbRed: 0.09, green: 1, blue: 0.65, alpha: 1).setFill()
bolt.fill()
let sparkle = NSBezierPath()
sparkle.move(to: NSPoint(x: 751, y: 234))
sparkle.curve(to: NSPoint(x: 818, y: 301), controlPoint1: NSPoint(x: 759, y: 281), controlPoint2: NSPoint(x: 771, y: 293))
sparkle.curve(to: NSPoint(x: 751, y: 368), controlPoint1: NSPoint(x: 771, y: 309), controlPoint2: NSPoint(x: 759, y: 321))
sparkle.curve(to: NSPoint(x: 684, y: 301), controlPoint1: NSPoint(x: 743, y: 321), controlPoint2: NSPoint(x: 731, y: 309))
sparkle.curve(to: NSPoint(x: 751, y: 234), controlPoint1: NSPoint(x: 731, y: 293), controlPoint2: NSPoint(x: 743, y: 281))
sparkle.fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
