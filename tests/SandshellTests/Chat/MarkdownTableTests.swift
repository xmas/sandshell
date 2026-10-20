import AppKit
import Testing
@testable import Sandshell

/// Tests for `Chat/MarkdownTable.swift`: finding a GitHub-flavored table in a
/// reply's lines, splitting its cells, and fitting its columns to a width.
struct MarkdownTableTests {

    // MARK: - Finding a table

    struct Parsing {
        struct Shape: Sendable, CustomTestStringConvertible {
            let name: String
            let source: String
            var testDescription: String { name }
        }

        @Test(arguments: [
            Shape(name: "outer pipes", source: "| a | b |\n|---|---|\n| 1 | 2 |"),
            Shape(name: "no outer pipes", source: "a | b\n---|---\n1 | 2"),
            Shape(name: "leading pipes only", source: "| a | b\n|---|---\n| 1 | 2"),
            Shape(name: "one-dash delimiters", source: "|a|b|\n|-|-|\n|1|2|"),
            Shape(name: "indented in a list item", source: "  | a | b |\n  |---|---|\n  | 1 | 2 |"),
            Shape(name: "quoted", source: "> | a | b |\n> |---|---|\n> | 1 | 2 |"),
            Shape(name: "quoted without spaces", source: ">| a | b |\n>|---|---|\n>| 1 | 2 |"),
        ])
        func findsTheTableInEveryShape(shape: Shape) throws {
            let lines = shape.source.components(separatedBy: "\n")
            let found = try #require(MarkdownTable.parse(lines, at: 0))
            #expect(found.table.header == ["a", "b"])
            #expect(found.table.rows == [["1", "2"]])
            #expect(found.end == 3)
        }

        @Test func aTableRightUnderAParagraphLine() throws {
            let lines = ["Here they are:", "| a | b |", "|---|---|", "| 1 | 2 |"]
            #expect(MarkdownTable.parse(lines, at: 0) == nil, "The paragraph line isn't a header")
            let found = try #require(MarkdownTable.parse(lines, at: 1))
            #expect(found.table.header == ["a", "b"])
        }

        @Test(arguments: [
            ("|:--|:-:|--:|---|", [MarkdownTable.Alignment.left, .center, .right, .left]),
            ("| :--- | :---: | ---: |", [.left, .center, .right]),
            ("-|:-", [.left, .left]),
            ("|-:|", [.right]),
        ])
        func delimiterRowsGiveAlignments(row: String, expected: [MarkdownTable.Alignment]) {
            #expect(MarkdownTable.alignments(row) == expected)
        }

        @Test(arguments: ["---", "| a | b |", "|===|", "|--x|", "|", "| |", "|:|", ""])
        func linesThatAreNoDelimiterRow(row: String) {
            #expect(MarkdownTable.alignments(row) == nil)
        }

        @Test(arguments: [
            ["| a | b |"],                           // still streaming: no delimiter row yet
            ["| a | b |", "|--"],                    // a delimiter row cut short: one column for two
            ["| a | b |", "|---|---|---|"],          // the column counts disagree
            ["a b", "|---|"],                        // a header needs a pipe
            ["> | a | b |", "|---|---|"],            // the quote ends between them
            ["text", "---"],                         // a paragraph over a rule
        ])
        func noTableWithoutAHeaderAndAMatchingDelimiterRow(lines: [String]) {
            #expect(MarkdownTable.parse(lines, at: 0) == nil)
        }

        @Test(arguments: [
            (["| a |", "|---|", "| 1 |", "", "| 2 |"], 3),        // a blank line
            (["| a |", "|---|", "| 1 |", "after"], 3),             // a line without a pipe
            (["> | a |", "> |---|", "> | 1 |", "| 2 |"], 3),       // the quote ends
            (["| a |", "|---|", "| 1 |", "```", "| 2 |"], 3),      // a code fence
            (["| a |", "|---|", "| 1 |", "| 2 |"], 4),             // the end of the reply
        ])
        func theTableEndsAtTheFirstLineThatIsNoRow(lines: [String], end: Int) {
            #expect(MarkdownTable.parse(lines, at: 0)?.end == end)
        }

        @Test func columnsCountTheWidestRow() throws {
            let found = try #require(MarkdownTable.parse(["| a |", "|---|", "| 1 | 2 | 3 |", "| 4 |"], at: 0))
            #expect(found.table.columns == 3)
        }

        @Test(arguments: [
            ("> > x", 2, "x"),
            ("  > y  ", 1, "y"),
            ("    z", 0, "z"),
            (">", 1, ""),
        ])
        func containersComeOffTheLine(line: String, quote: Int, text: String) {
            let container = MarkdownTable.container(line)
            #expect(container.quote == quote)
            #expect(container.text == text)
        }
    }

    // MARK: - Cells

    struct Cells {
        @Test(arguments: [
            ("| a | b |", ["a", "b"]),
            ("a | b", ["a", "b"]),
            ("| a \\| b | c |", ["a | b", "c"]),
            ("| `a|b` | c |", ["`a|b`", "c"]),
            ("| `a\\|b` | c |", ["`a|b`", "c"]),
            ("| `open | c |", ["`open", "c"]),                 // an unclosed backtick doesn't swallow the row
            ("| \\*not italic\\* | c |", ["\\*not italic\\*", "c"]),
            ("| | b |", ["", "b"]),
            ("| a | b \\|", ["a", "b |"]),
        ])
        func rowsSplitOnUnescapedPipes(row: String, cells: [String]) {
            #expect(MarkdownTable.cells(row) == cells)
        }

        @Test(arguments: [("a | b", true), ("a \\| b", false), ("plain", false), ("\\\\|", true)])
        func pipesThatSplitCells(line: String, has: Bool) {
            #expect(MarkdownTable.hasPipe(line) == has)
        }
    }

    // MARK: - Fitting the columns

    struct ColumnWidths {
        @Test func columnsThatFitKeepTheirWidth() {
            #expect(MarkdownTable.columnWidths(natural: [40, 60], minimum: [20, 30], available: 200) == [40, 60])
        }

        @Test func shortColumnsStayWholeAndTheLongOnesShareTheRest() throws {
            let widths = try #require(MarkdownTable.columnWidths(natural: [80, 900, 700], minimum: [50, 60, 60],
                                                                 available: 600))
            #expect(widths[0] == 80, "The short column needs less than its share: it stays on one line")
            #expect(widths[1] == widths[2], "The long ones split what's left")
            #expect(widths.reduce(0, +) <= 600)
            #expect(widths.reduce(0, +) >= 598)
        }

        @Test func noColumnIsNarrowerThanItsWidestWord() throws {
            let widths = try #require(MarkdownTable.columnWidths(natural: [500, 500], minimum: [150, 30], available: 300))
            #expect(widths[0] >= 150 && widths[1] >= 30)
            #expect(widths.reduce(0, +) <= 300)
        }

        @Test func longWordsShrinkWhenTheirColumnsCantAllFit() throws {
            let widths = try #require(MarkdownTable.columnWidths(natural: [300, 300, 30], minimum: [160, 160, 30],
                                                                 available: 200))
            #expect(widths.reduce(0, +) <= 200)
            #expect(widths[2] == 30, "A narrow column keeps its width")
            #expect(widths.allSatisfy { $0 >= 40 || $0 == 30 })
        }

        @Test(arguments: [(16, CGFloat(600)), (3, 100)])
        func tooManyColumnsDontFit(columns: Int, available: CGFloat) {
            let natural = [CGFloat](repeating: 80, count: columns)
            #expect(MarkdownTable.columnWidths(natural: natural, minimum: natural, available: available) == nil)
        }
    }

    // MARK: - Wrapping a cell

    @MainActor
    struct Wrapping {
        private func text(_ s: String) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: NSFont.role(.body)])
        }

        @Test func shortTextIsOneLine() {
            #expect(MarkdownTable.wrap(text("short"), width: 200).map(\.string) == ["short"])
        }

        @Test func longTextBreaksBetweenWords() {
            let lines = MarkdownTable.wrap(text("one two three four five six seven eight"), width: 80).map(\.string)
            #expect(lines.count > 1)
            #expect(lines.joined(separator: " ") == "one two three four five six seven eight")
            #expect(lines.allSatisfy { !$0.hasSuffix(" ") }, "Spaces at the breaks are dropped")
            #expect(lines.allSatisfy { text($0).size().width <= 81 })
        }

        @Test func aWordTooWideForItsColumnBreaksInside() {
            let lines = MarkdownTable.wrap(text("Sandshell/Chat/ChatTranscriptView.swift"), width: 60).map(\.string)
            #expect(lines.count > 1)
            #expect(lines.joined() == "Sandshell/Chat/ChatTranscriptView.swift")
        }

        @Test func lineSeparatorsBreakTheCell() {
            #expect(MarkdownTable.wrap(text("one\u{2028}two"), width: 400).map(\.string) == ["one", "two"])
        }

        @Test func emptyCellsAreOneEmptyLine() {
            #expect(MarkdownTable.wrap(text(""), width: 100).map(\.string) == [""])
        }

        @Test func widestWordMeasuresBetweenSpaces() {
            let long = MarkdownTable.widestWord(text("a considerably b"))
            #expect(long == ceil(text("considerably").size().width))
        }
    }
}
