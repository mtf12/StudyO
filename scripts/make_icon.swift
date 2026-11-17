// Draws the StudyO Player app icon. Usage: swift make_icon.swift out.png
// A dark tile, a glowing play triangle (media), the MT monogram, and a spark (AI).
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let blue = NSColor(red: 0.99, green: 0.45, blue: 0.37, alpha: 1)   // warm coral
let violet = NSColor(red: 0.90, green: 0.20, blue: 0.31, alpha: 1) // deep red

// macOS icon grid: an 824-point rounded tile centred on a 1024 canvas, with a soft shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor(white: 0, alpha: 0.45).cgColor)
NSColor(white: 0.08, alpha: 1).setFill()
shape.fill()
ctx.restoreGState()

ctx.saveGState()
shape.addClip()
// Dark graphite base, lighter at the top
NSGradient(colors: [NSColor(red: 0.17, green: 0.17, blue: 0.21, alpha: 1),
                    NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)])!.draw(in: tile, angle: -90)
// Soft coloured glow behind the triangle
NSGradient(colors: [blue.withAlphaComponent(0.34), violet.withAlphaComponent(0.12), NSColor(white: 0, alpha: 0)])!
    .draw(fromCenter: NSPoint(x: 540, y: 512), radius: 0, toCenter: NSPoint(x: 540, y: 512), radius: 470, options: [])

// Play triangle in the app's red
let cx: CGFloat = 548, cy: CGFloat = 512
let tri = NSBezierPath()
tri.move(to: NSPoint(x: cx - 205, y: cy + 262))
tri.line(to: NSPoint(x: cx + 262, y: cy))
tri.line(to: NSPoint(x: cx - 205, y: cy - 262))
tri.close()
tri.lineJoinStyle = .round
tri.lineWidth = 96
ctx.saveGState()
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
NSColor.white.setFill(); NSColor.white.setStroke()
tri.fill(); tri.stroke()
// Colour only where the triangle was drawn
ctx.setBlendMode(.sourceIn)
NSGradient(colors: [blue, violet])!.draw(in: NSRect(x: 250, y: 180, width: 640, height: 664), angle: -50)
ctx.endTransparencyLayer()
ctx.restoreGState()

// MT monogram
var font = NSFont.systemFont(ofSize: 372, weight: .heavy)
if let rounded = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: rounded, size: 372) ?? font }
let shadow = NSShadow()
shadow.shadowColor = NSColor(red: 0.30, green: 0.03, blue: 0.06, alpha: 0.5)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 28
let text = NSAttributedString(string: "MT", attributes: [
    .font: font, .foregroundColor: NSColor.white, .kern: -14, .shadow: shadow,
])
let textSize = text.size()
text.draw(at: NSPoint(x: 512 - textSize.width / 2 + 4, y: 512 - textSize.height / 2 - 6))

// Spark (the AI part), top right
func spark(at p: NSPoint, r: CGFloat, alpha: CGFloat) {
    let s = NSBezierPath()
    let k = r * 0.20
    s.move(to: NSPoint(x: p.x, y: p.y + r))
    s.curve(to: NSPoint(x: p.x + r, y: p.y), controlPoint1: NSPoint(x: p.x + k, y: p.y + k), controlPoint2: NSPoint(x: p.x + k, y: p.y + k))
    s.curve(to: NSPoint(x: p.x, y: p.y - r), controlPoint1: NSPoint(x: p.x + k, y: p.y - k), controlPoint2: NSPoint(x: p.x + k, y: p.y - k))
    s.curve(to: NSPoint(x: p.x - r, y: p.y), controlPoint1: NSPoint(x: p.x - k, y: p.y - k), controlPoint2: NSPoint(x: p.x - k, y: p.y - k))
    s.curve(to: NSPoint(x: p.x, y: p.y + r), controlPoint1: NSPoint(x: p.x - k, y: p.y + k), controlPoint2: NSPoint(x: p.x - k, y: p.y + k))
    NSColor(white: 1, alpha: alpha).setFill()
    s.fill()
}
spark(at: NSPoint(x: 770, y: 775), r: 74, alpha: 1)
spark(at: NSPoint(x: 846, y: 668), r: 34, alpha: 0.85)

// Thin light edge, like glass
ctx.restoreGState()
let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
edge.lineWidth = 4
NSColor(white: 1, alpha: 0.10).setStroke()
edge.stroke()

NSGraphicsContext.current?.flushGraphics()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
