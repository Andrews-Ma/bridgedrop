import AppKit

// Package the generated icon into a clean, antialiased macOS rounded-square mask.
// iOS keeps its separate opaque square artwork and receives the system mask.
let arguments = CommandLine.arguments
precondition(arguments.count == 3)
let source = URL(fileURLWithPath: arguments[1])
let destination = URL(fileURLWithPath: arguments[2])
let size = 1024
let image = NSImage(contentsOf: source)!
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.current = context
context.imageInterpolation = .high
let edge = CGFloat(size) * 0.118
let bounds = NSRect(x: edge, y: edge, width: CGFloat(size) - edge * 2, height: CGFloat(size) - edge * 2)
NSBezierPath(roundedRect: bounds, xRadius: CGFloat(size) * 0.16, yRadius: CGFloat(size) * 0.16).addClip()
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: destination, options: .atomic)
