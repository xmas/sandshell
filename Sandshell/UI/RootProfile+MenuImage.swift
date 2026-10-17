import AppKit

extension RootProfile {
    /// Menu-sized rendering of the colored icon mark (for NSMenuItem images).
    @MainActor
    func menuImage(side: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: side * 0.28, yRadius: side * 0.28)
            NSColor.hex(colorHex).setFill()
            path.fill()
            let config = NSImage.SymbolConfiguration(pointSize: side * 0.55, weight: .semibold)
            if let symbol = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let tinted = symbol.tinted(.white)
                let size = tinted.size
                let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
                tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

private extension NSImage {
    /// A copy filled with `color` (for drawing a template symbol in a fixed tint).
    func tinted(_ color: NSColor) -> NSImage {
        let copy = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        copy.isTemplate = false
        return copy
    }
}
