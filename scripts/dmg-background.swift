// Draws Support/dmg-background.tiff, the disk image window's background: what to do, and
// where Finder puts each item (scripts/dmg.sh places the icons at these same points).
// Usage: swift scripts/dmg-background.swift <out.tiff>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Support/dmg-background.tiff"
// The window's content, in points; dmg.sh opens the window this size.
let size = NSSize(width: 640, height: 420)
// Icon centers dmg.sh uses, from the top left: the app and Applications, then the texts.
let appCenter = NSPoint(x: 170, y: 140), applicationsCenter = NSPoint(x: 470, y: 140)
let iconHalf: CGFloat = 40  // icons are 80 points

let ink = NSColor(srgbRed: 0x11 / 255, green: 0x18 / 255, blue: 0x27 / 255, alpha: 1)
let muted = NSColor(srgbRed: 0x5b / 255, green: 0x62 / 255, blue: 0x70 / 255, alpha: 1)
let accent = NSColor(srgbRed: 0x25 / 255, green: 0x63 / 255, blue: 0xeb / 255, alpha: 1)
let paper = NSColor(srgbRed: 0xf7 / 255, green: 0xf7 / 255, blue: 0xf8 / 255, alpha: 1)

func text(_ s: String, _ font: NSFont, _ color: NSColor, centerX: CGFloat, top: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let width = (s as NSString).size(withAttributes: attrs).width
    (s as NSString).draw(at: NSPoint(x: centerX - width / 2, y: top), withAttributes: attrs)
}

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    // Top-left origin, as Finder positions items.
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    paper.setFill()
    NSRect(origin: .zero, size: size).fill()
    let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    NSGraphicsContext.current = flipped
    text("Install Pratico", .systemFont(ofSize: 26, weight: .bold), ink, centerX: size.width / 2, top: 20)
    text("Drag Pratico onto Applications", .systemFont(ofSize: 14), muted, centerX: size.width / 2, top: 56)
    // The arrow between the two icons.
    let y = appCenter.y, from = appCenter.x + iconHalf + 28, to = applicationsCenter.x - iconHalf - 28
    accent.set()
    let line = NSBezierPath()
    line.move(to: NSPoint(x: from, y: y))
    line.line(to: NSPoint(x: to - 10, y: y))
    line.lineWidth = 3
    line.lineCapStyle = .round
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: to, y: y))
    head.line(to: NSPoint(x: to - 14, y: y - 8))
    head.line(to: NSPoint(x: to - 14, y: y + 8))
    head.close()
    head.fill()
    // A rule, then what the first launch needs, above the two texts (centered at y 315,
    // their labels clear of the bar Finder may show at the window's bottom).
    NSColor(srgbRed: 0xe7 / 255, green: 0xe7 / 255, blue: 0xea / 255, alpha: 1).setFill()
    NSRect(x: 40, y: 216, width: size.width - 80, height: 1).fill()
    text("Not notarized yet: the first launch needs one approval.", .systemFont(ofSize: 13, weight: .medium), ink,
         centerX: size.width / 2, top: 226)
    text("READ ME FIRST shows the two ways.", .systemFont(ofSize: 13), muted, centerX: size.width / 2, top: 245)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let tiff = NSImage(size: size)
tiff.addRepresentation(draw(scale: 1))
tiff.addRepresentation(draw(scale: 2))
try tiff.tiffRepresentation(using: .lzw, factor: 0)!.write(to: URL(fileURLWithPath: out))
print("dmg background: \(out)")
