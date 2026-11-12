import Foundation
import Testing
@testable import Sandshell

/// Comments on diff lines in Files, as the message the agent gets.
struct DiffCommentTests {
    private func comment(_ path: String, _ line: Int, removed: Bool = false, _ text: String) -> DiffComment {
        DiffComment(path: path, file: "/repo/" + path, line: line, removed: removed, code: "let x = \(line)", text: text)
    }

    @Test func oneCommentIsAskedAsBefore() {
        #expect(DiffComment.message([comment("Sources/A.swift", 12, "Use a guard")])
                == "At line 12 of `Sources/A.swift`:\n```\nlet x = 12\n```\nUse a guard")
        #expect(DiffComment.message([comment("A.swift", 3, removed: true, "Keep this")])
                == "At the removed line 3 of `A.swift`:\n```\nlet x = 3\n```\nKeep this")
    }

    @Test func aReviewIsNumberedInFileAndLineOrder() {
        let message = DiffComment.message([comment("b.swift", 4, "Second file"), comment("a.swift", 9, "Later line"),
                                           comment("a.swift", 2, "First")])
        #expect(message == """
            Review comments on the changes:

            1. At line 2 of `a.swift`:
            ```
            let x = 2
            ```
            First

            2. At line 9 of `a.swift`:
            ```
            let x = 9
            ```
            Later line

            3. At line 4 of `b.swift`:
            ```
            let x = 4
            ```
            Second file
            """)
    }

    @Test func theSameLineIsTheSameFileLineAndSide() {
        let c = comment("a.swift", 2, "x")
        #expect(c.isOnSameLine(as: comment("a.swift", 2, "y")))
        #expect(!c.isOnSameLine(as: comment("a.swift", 2, removed: true, "y")), "the old file's line 2 is another line")
        #expect(!c.isOnSameLine(as: comment("b.swift", 2, "y")))
    }

    @Test func nothingIsAnEmptyMessage() { #expect(DiffComment.message([]).isEmpty) }
}
