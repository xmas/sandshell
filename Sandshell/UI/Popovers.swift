import AppKit
import SwiftUI

extension NSPopover {
    /// Show `content` below `anchor` (or below `rect` in it), or — when
    /// `slot`'s popover is already up — close it: a second click on the same
    /// control toggles. "Below" is the anchor's maxY when it's flipped (buttons,
    /// text views) and minY when it isn't.
    @MainActor @discardableResult
    static func toggle(_ slot: inout NSPopover?, below anchor: NSView, rect: NSRect? = nil,
                       behavior: Behavior = .transient, content: () -> NSViewController) -> NSPopover? {
        if let open = slot, open.isShown { open.close(); slot = nil; return nil }
        let popover = NSPopover()
        popover.behavior = behavior
        popover.contentViewController = content()
        popover.show(relativeTo: rect ?? anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
        slot = popover
        return popover
    }
}

extension NSViewController {
    /// A SwiftUI view as popover / sheet content.
    @MainActor static func hosting(_ view: some View) -> NSViewController { NSHostingController(rootView: view) }
}
