import Foundation
import Testing
@testable import Sandshell

/// Tests for `Files/FileNavigation.swift`: what Go to Line (⌘L) accepts.
///
/// Not covered: Open Quickly's popover and table (its matching is
/// `WorkspaceFileIndex.match`).
@MainActor
struct FileNavigationTests {

    // MARK: - GoToLineController.parse

    @Test(arguments: [
        ("12", 12, nil), ("12:5", 12, 5), (" 3 ", 3, nil), ("1", 1, nil), ("7:1", 7, 1),
    ] as [(String, Int, Int?)])
    func lineAndOptionalColumn(text: String, line: Int, column: Int?) throws {
        let parsed = try #require(GoToLineController.parse(text))
        #expect(parsed.line == line)
        #expect(parsed.column == column)
    }

    @Test(.tags(.edgeCase), arguments: ["", "  ", "0", "-3", "x", "x:5", "1.5"])
    func notALineNumber(text: String) {
        #expect(GoToLineController.parse(text) == nil)
    }

    /// A column that isn't a number is left out; the line still counts.
    @Test(.tags(.edgeCase), arguments: ["12:x", "12:", "12:5:9"])
    func badColumnKeepsTheLine(text: String) throws {
        let parsed = try #require(GoToLineController.parse(text))
        #expect(parsed.line == 12)
        #expect(parsed.column == nil)
    }
}
