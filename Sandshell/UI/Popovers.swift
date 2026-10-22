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
        popover.show(content(), relativeTo: rect ?? anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
        slot = popover
        return popover
    }

    /// Show `controller` at `rect` in `anchor`, sized to its content first.
    /// SwiftUI content (an `NSHostingController`) has no size until after the
    /// popover is placed, and the macOS 27 popover then lands far from its
    /// anchor (a few hundred points off), so size it before it's placed.
    @MainActor
    func show(_ controller: NSViewController, relativeTo rect: NSRect, of anchor: NSView, preferredEdge: NSRectEdge) {
        contentViewController = controller
        let fit = controller.view.fittingSize
        if fit.width > 0, fit.height > 0 { contentSize = fit }
        show(relativeTo: rect, of: anchor, preferredEdge: preferredEdge)
    }
}

extension NSViewController {
    /// A SwiftUI view as popover / sheet content.
    @MainActor static func hosting(_ view: some View) -> NSViewController { NSHostingController(rootView: view) }
}
