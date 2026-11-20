// Draws Support/AppIcon.icns from pratico's mark (the site's logo): a dark rounded
// square with four tiles, the last in the accent blue, on macOS's 1024-point icon grid.
// Usage: swift scripts/app-icon.swift <out.icns>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Support/AppIcon.icns"
let ink = NSColor(srgbRed: 0x11 / 255, green: 0x18 / 255, blue: 0x27 / 255, alpha: 1)  // #111827
let paper = NSColor.white
let accent = NSColor(srgbRed: 0x25 / 255, green: 0x63 / 255, blue: 0xeb / 255, alpha: 1)  // #2563eb

func draw(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    // The icon grid: an 824-point body, 100 points in from each edge, with a soft shadow below.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 20 * s
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    ink.setFill()
    NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    // The mark's 32-unit grid: tiles of 7 at 8 and 17, corners of 1.5.
    let unit = body.width / 32
    for (col, row, color) in [(0, 0, paper), (1, 0, paper), (0, 1, paper), (1, 1, accent)] {
        let x = body.minX + (8 + 9 * CGFloat(col)) * unit
        let y = body.maxY - (8 + 9 * CGFloat(row) + 7) * unit  // rows from the top, as in the SVG
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 7 * unit, height: 7 * unit), xRadius: 1.5 * unit, yRadius: 1.5 * unit).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: set) }
for points in [16, 32, 128, 256, 512] {
    try draw(points).write(to: set.appending(path: "icon_\(points)x\(points).png"))
    try draw(points * 2).write(to: set.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set.path, "-o", out]
try iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
print("icon: \(out)")
