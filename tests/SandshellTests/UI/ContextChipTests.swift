import AppKit
import Testing
@testable import Sandshell

/// What VoiceOver hears for a title-strip chip (`ContextChip.set`): its title,
/// and for a branch the lines changed, with "line" agreeing with the count.
@MainActor
struct ContextChipTests {
    @Test("A branch's line counts follow its name, singular for one line", arguments: [
        (1, 0, "main, 1 line added, 0 removed"),
        (5, 2, "main, 5 lines added, 2 removed"),
        (0, 3, "main, 0 lines added, 3 removed"),
    ] as [(Int, Int, String)])
    func lineCounts(added: Int, removed: Int, expected: String) {
        let chip = ContextChip(symbol: "arrow.triangle.branch")
        chip.set(title: "main", added: added, removed: removed, tip: "")
        #expect(chip.accessibilityLabel() == expected)
    }

    @Test func noChangesReadsJustTheTitle() {
        let chip = ContextChip(symbol: "folder")
        chip.set(title: "project", tip: "")
        #expect(chip.accessibilityLabel() == "project")
    }
}
