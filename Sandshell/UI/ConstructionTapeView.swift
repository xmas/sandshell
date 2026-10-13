import AppKit

/// Diagonal yellow/black hazard stripes ("construction tape"). Used only in DEBUG
/// builds, inserted **behind** the window toolbar as a faint full-width watermark
/// so a locally-built debug instance is unmistakable. Draws itself; no assets.
final class ConstructionTapeView: NSView {
    /// Amber "safety yellow" and a warm near-black, both semi-transparent so the
    /// tape reads as intentional hazard striping without fighting the toolbar.
    private let tapeYellow = NSColor(srgbRed: 0.97, green: 0.74, blue: 0.06, alpha: 0.55)
    private let tapeBlack  = NSColor(srgbRed: 0.11, green: 0.10, blue: 0.07, alpha: 0.55)

    override var isOpaque: Bool { false }

    /// Click-through: the watermark sits behind the toolbar and must never eat
    /// clicks or window-drag from the titlebar.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true
        tapeYellow.setFill()
        bounds.fill()

        tapeBlack.setFill()
        let stripe: CGFloat = 13   // width of each black diagonal
        let gap: CGFloat = 13      // yellow gap between blacks
        let period = stripe + gap
        let h = bounds.height
        // 45° parallelograms marching left→right; start off-screen left by `h` so
        // the slanted edges cover the whole band with no bald corners.
        var x = -h - period
        while x < bounds.width + h {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: 0))
            p.line(to: NSPoint(x: x + stripe, y: 0))
            p.line(to: NSPoint(x: x + stripe + h, y: h))
            p.line(to: NSPoint(x: x + h, y: h))
            p.close()
            p.fill()
            x += period
        }
    }
}
