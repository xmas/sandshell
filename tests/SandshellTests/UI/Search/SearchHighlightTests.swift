import SwiftUI
import Testing
@testable import Sandshell

/// `AttributedString(_:highlighting:)` (UI/Search/AttributedString+SearchHighlight.swift):
/// how the Search window marks the query in titles, folders, snippets and the preview.
struct SearchHighlightTests {
    /// The text of each bolded run, in order.
    private func highlighted(_ attributed: AttributedString) -> [String] {
        attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(attributed[$0.range].characters) }
    }

    @Test func everyOccurrenceIsBoldedIgnoringCase() {
        let attributed = AttributedString("Alpha build, then the ALPHA notes", highlighting: "alpha")
        #expect(highlighted(attributed) == ["Alpha", "ALPHA"])
    }

    @Test func highlightedTextIsTintedToo() {
        let attributed = AttributedString("fix the parser", highlighting: "parser")
        let tinted = attributed.runs.filter { $0.swiftUI.backgroundColor != nil }
            .map { String(attributed[$0.range].characters) }
        #expect(tinted == ["parser"])
    }

    @Test(arguments: ["", "zebra"])
    func anEmptyOrUnmatchedQueryLeavesTheTextPlain(query: String) {
        let attributed = AttributedString("Plan the migration", highlighting: query)
        #expect(highlighted(attributed).isEmpty)
        #expect(attributed.runs.count == 1)
    }

    @Test(arguments: ["", "the", "MIGRATION", "zebra"])
    func theCharactersAreUnchanged(query: String) {
        let text = "Plan the migration, then the move"
        #expect(String(AttributedString(text, highlighting: query).characters) == text)
    }

    /// Matches don't overlap: after one, the search picks up where it ended.
    @Test(.tags(.edgeCase))
    func overlappingMatchesAreFoundOnce() {
        let attributed = AttributedString("aaa", highlighting: "aa")
        #expect(highlighted(attributed) == ["aa"])
    }
}
