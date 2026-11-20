import AppKit

/// The menubar item: pratico's mark, four tiles, as a template image macOS tints for any
/// menubar. One shape whatever the state, so it stays findable among other items; state is
/// a change within it, and nothing is drawn beside it.
enum MenubarIcon: Equatable {
    /// Outlined tiles: the daemon is not running.
    case stopped
    /// Filled tiles.
    case running
    /// Filled, the fourth tile (the mark's accent) a dot: something needs a look, an image
    /// blocked, a destination refused, a container unhealthy. Not for findings that only
    /// inform, which the menu lists.
    case attention

    /// 18 points square, the menubar's glyph size; tiles on the mark's 32-unit grid.
    static let points: CGFloat = 18

    var image: NSImage {
        let image = NSImage(size: NSSize(width: Self.points, height: Self.points), flipped: true) { rect in
            let unit = rect.width / 32
            NSColor.black.set()
            for (col, row) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                // The mark's tiles are 7 units at 8 and 17; here 12 at 3 and 17, so each
                // stays legible at menubar size.
                let tile = NSRect(x: (3 + 14 * CGFloat(col)) * unit, y: (3 + 14 * CGFloat(row)) * unit, width: 12 * unit, height: 12 * unit)
                let last = col == 1 && row == 1
                switch self {
                case .stopped:
                    let path = NSBezierPath(roundedRect: tile.insetBy(dx: unit, dy: unit), xRadius: 2.5 * unit, yRadius: 2.5 * unit)
                    path.lineWidth = 2 * unit
                    path.stroke()
                case .attention where last:
                    NSBezierPath(ovalIn: tile.insetBy(dx: unit, dy: unit)).fill()
                case .running, .attention:
                    NSBezierPath(roundedRect: tile, xRadius: 3 * unit, yRadius: 3 * unit).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = switch self {
        case .stopped: "Pratico, stopped"
        case .running: "Pratico, running"
        case .attention: "Pratico, needs attention"
        }
        return image
    }
}
