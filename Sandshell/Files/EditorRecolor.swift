import AppKit

/// Re-coloring the Files editor without moving its text.
///
/// TextKit 2 lays out only what's near the viewport and estimates the rest;
/// any attribute change invalidates the layout of its range, and the
/// re-estimate shifts everything below the top of the document — touch the
/// whole buffer (the old highlighter, after every keystroke) and the text
/// you're looking at jumps by dozens of lines. So: only the runs whose color
/// actually changed are touched (one keystroke: a few characters), and the
/// line at the top of the view is kept where it was regardless (an opened
/// string or block comment really does recolor the rest of the file).
enum EditorRecolor {
    struct Run: Equatable {
        let range: NSRange
        let color: NSColor
    }

    /// The runs of `colored`'s foreground colors that `current` doesn't
    /// already have (same text, same length — else every run).
    static func changedRuns(from colored: NSAttributedString, in current: NSAttributedString) -> [Run] {
        let full = NSRange(location: 0, length: colored.length)
        var runs: [Run] = []
        colored.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = value as? NSColor else { return }
            if colored.length == current.length {
                var have = NSRange()
                let old = current.attribute(.foregroundColor, at: range.location, longestEffectiveRange: &have, in: range)
                if (old as? NSColor) == color, have == range { return }
            }
            runs.append(Run(range: range, color: color))
        }
        return runs
    }

    /// Apply `colored`'s colors to `storage`, touching only what changed.
    /// Returns how many runs changed.
    @discardableResult
    static func apply(_ colored: NSAttributedString, to storage: NSTextStorage) -> Int {
        guard colored.length == storage.length else { return 0 }
        let runs = changedRuns(from: colored, in: storage)
        guard !runs.isEmpty else { return 0 }
        storage.beginEditing()
        for run in runs { storage.addAttribute(.foregroundColor, value: run.color, range: run.range) }
        storage.endEditing()
        return runs.count
    }
}

extension NSTextView {
    /// Run `change` (one that re-lays out text) keeping the line at the top
    /// of the view where it is on screen.
    func keepingTopLine(_ change: () -> Void) {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return change() }
        let inset = textContainerOrigin.y
        let top = visibleRect.minY - inset
        guard top > 0, let fragment = tlm.textLayoutFragment(for: CGPoint(x: 0, y: top)) else { return change() }
        let offset = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
        let below = top - fragment.layoutFragmentFrame.minY
        change()
        guard let location = tcm.location(tcm.documentRange.location, offsetBy: offset) else { return }
        tlm.ensureLayout(for: NSTextRange(location: location))
        guard let again = tlm.textLayoutFragment(for: location) else { return }
        let y = again.layoutFragmentFrame.minY + below + inset
        if abs(y - visibleRect.minY) > 0.5 { scroll(NSPoint(x: visibleRect.minX, y: y)) }
    }
}
