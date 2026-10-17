import Observation

/// The Settings window's selected pane, kept by its window controller so the
/// window can switch panes without rebuilding the view (and the panes' edits).
@MainActor
@Observable
final class InspectorSelection {
    private(set) var pane: InspectorPane

    init(_ pane: InspectorPane) { self.pane = Self.tab(for: pane) }

    func select(_ pane: InspectorPane) {
        let tab = Self.tab(for: pane)
        if tab != self.pane { self.pane = tab }
    }

    /// Git & Remote has no tab yet: it opens on General.
    private static func tab(for pane: InspectorPane) -> InspectorPane { pane == .git ? .general : pane }
}
