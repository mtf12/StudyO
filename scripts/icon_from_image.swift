// Turns a square artwork into a macOS app icon: rounded tile, standard margins, soft shadow,
// transparent corners. Usage: swift icon_from_image.swift artwork.png out.png
import AppKit

let args = CommandLine.arguments
guard args.count > 2, let art = NSImage(contentsOfFile: args[1]) else { fatalError("usage: artwork.png out.png") }
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.interpolationQuality = .high

// macOS icon grid: an 824-point tile centred on a 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor(white: 0, alpha: 0.35).cgColor)
NSColor(red: 0.04, green: 0.13, blue: 0.27, alpha: 1).setFill() // the icon's navy, behind any transparent edge
shape.fill()
ctx.restoreGState()

ctx.saveGState()
shape.addClip()
// Draw a touch oversized so no edge line shows; the badge in the corner must stay inside.
art.draw(in: tile.insetBy(dx: -6, dy: -6), from: .zero, operation: .sourceOver, fraction: 1)
ctx.restoreGState()

NSGraphicsContext.current?.flushGraphics()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
