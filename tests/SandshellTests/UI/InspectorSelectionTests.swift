import Observation
import Synchronization
import Testing
@testable import Sandshell

// `InspectorSelection`: the pane a Settings window shows, which the window
// switches without rebuilding its view. Git & Remote has no tab yet, so it
// opens on General.

@MainActor
struct InspectorSelectionTests {
    @Test(arguments: InspectorPane.allCases.filter { $0 != .git })
    func startsOnThePaneAskedFor(pane: InspectorPane) {
        #expect(InspectorSelection(pane).pane == pane)
    }

    @Test func gitOpensOnGeneral() {
        #expect(InspectorSelection(.git).pane == .general)
        let selection = InspectorSelection(.mounts)
        selection.select(.git)
        #expect(selection.pane == .general)
    }

    @Test func selectSwitchesPanes() {
        let selection = InspectorSelection(.general)
        selection.select(.kits)
        #expect(selection.pane == .kits)
        selection.select(.terminal)
        #expect(selection.pane == .terminal)
    }

    /// Showing the window again on the pane it shows doesn't redraw it.
    @Test(.tags(.edgeCase))
    func selectingTheShownPaneDoesNotNotify() {
        let selection = InspectorSelection(.kits)
        let flag = ChangeFlag()
        withObservationTracking { _ = selection.pane } onChange: { flag.changed.withLock { $0 = true } }
        selection.select(.kits)
        #expect(flag.changed.withLock { $0 } == false)
        selection.select(.mcp)
        #expect(flag.changed.withLock { $0 })
    }
}

/// Set when an observed property changes (`onChange` is `@Sendable`).
private final class ChangeFlag: Sendable {
    let changed = Mutex(false)
}

struct InspectorPaneTests {
    @Test func titlesAreCapitalizedExceptMCP() {
        #expect(InspectorPane.mcp.title == "MCP")
        #expect(InspectorPane.general.title == "General")
        #expect(InspectorPane.sandboxes.title == "Sandboxes")
    }
}
