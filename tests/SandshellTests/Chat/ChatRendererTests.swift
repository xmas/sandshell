import AppKit
import Foundation
import Testing
@testable import Sandshell

/// Tests for `Chat/ChatRenderer.swift`: `ChatRenderer` (Markdown to
/// attributed text, for the Files preview), `SyntaxHighlighter`, and the
/// block backgrounds (`BlockStyle`, `BlockBackgroundFragment`, `BlockFragmentProvider`).
struct ChatRendererTests {

    // MARK: - Markdown blocks

    @MainActor
    struct MarkdownBlocks {
        /// Every line is a paragraph: blank lines are kept, leading indentation is dropped.
        @Test(arguments: [
            ("First line\nSecond line", "First line\nSecond line\n"),
            ("Para\n\nNext", "Para\n\nNext\n"),
            ("Para\n", "Para\n\n"),
            ("   indented", "indented\n"),
        ])
        func plainLinesBecomeParagraphs(source: String, expected: String) {
            #expect(ChatRenderer.markdown(source).string == expected)
        }

        @Test func chatParagraphsUseTheSystemFace() throws {
            let rendered = ChatRenderer.markdown("Hello")
            CRFixture.verifyFace(CRFixture.font(in: rendered, at: 0), matches: .role(.body))
            let style = try #require(CRFixture.paragraphStyle(in: rendered, at: 0))
            #expect(style.paragraphSpacing == 4)
            #expect(style.lineSpacing == 1.5)
            #expect(CRFixture.blockRuns(rendered).isEmpty, "Prose sits on no block")
        }

        @Test func documentParagraphsAreSerifAndLooser() throws {
            let rendered = ChatRenderer.markdown("Hello", prose: .document)
            #expect(CRFixture.font(in: rendered, at: 0) == ChatRenderer.Prose.document.font())
            let style = try #require(CRFixture.paragraphStyle(in: rendered, at: 0))
            #expect(style.paragraphSpacing == 7)
            #expect(style.lineSpacing == 3)
        }

        @Test(arguments: [
            ("# Title", .title), ("## Title", .title), ("### Title", .bodyEmphasis),
            ("#### Title", .bodyEmphasis), ("##### Title", .bodyEmphasis), ("###### Title", .bodyEmphasis),
        ] as [(String, TypeRole)])
        func headingsAreTitlesThenEmphasizedBody(line: String, role: TypeRole) {
            let rendered = ChatRenderer.markdown(line)
            #expect(rendered.string == "Title\n")
            CRFixture.verifyFace(CRFixture.font(in: rendered, at: 0), matches: .role(role))
            #expect(CRFixture.paragraphStyle(in: rendered, at: 0)?.paragraphSpacingBefore == 8)
        }

        @Test func documentHeadingsAreSerifTitles() {
            let rendered = ChatRenderer.markdown("# Title", prose: .document)
            #expect(CRFixture.font(in: rendered, at: 0) == ChatRenderer.Prose.document.font(.title))
        }

        @Test(.tags(.edgeCase), arguments: ["#Title", "####### Title"])
        func notQuiteHeadingsArePlainText(line: String) {
            let rendered = ChatRenderer.markdown(line)
            #expect(rendered.string == line + "\n")
            #expect(CRFixture.font(in: rendered, at: 0) == ChatRenderer.body)
        }

        @Test(arguments: ["- item", "* item", "+ item"])
        func bulletsGetADotAndAHangingIndent(line: String) throws {
            let rendered = ChatRenderer.markdown(line)
            #expect(rendered.string == "•\titem\n")
            let style = try #require(CRFixture.paragraphStyle(in: rendered, at: 0))
            #expect(style.headIndent == 20)
            #expect(style.firstLineHeadIndent == 4)
            #expect(style.tabStops.map(\.location) == [20])
            #expect(style.paragraphSpacing == 2)
            #expect(CRFixture.color(in: rendered, at: 0) == NSColor.secondaryLabelColor, "The bullet is dim")
            #expect(CRFixture.color(in: rendered, at: 2) == NSColor.labelColor, "The item isn't")
        }

        @Test(arguments: [("  - item", 38), ("   - item", 38), ("    - item", 56)] as [(String, CGFloat)])
        func everyTwoLeadingSpacesNestABulletDeeper(line: String, indent: CGFloat) throws {
            let rendered = ChatRenderer.markdown(line)
            #expect(rendered.string == "•\titem\n")
            let style = try #require(CRFixture.paragraphStyle(in: rendered, at: 0))
            #expect(style.headIndent == indent)
            #expect(style.firstLineHeadIndent == indent - 16)
            #expect(style.tabStops.map(\.location) == [indent])
        }

        @Test(arguments: [("1. first", "1.\tfirst\n"), ("2) second", "2)\tsecond\n"), ("10. tenth", "10.\ttenth\n")])
        func numberedItemsKeepTheirNumber(line: String, expected: String) {
            let rendered = ChatRenderer.markdown(line)
            #expect(rendered.string == expected)
            #expect(CRFixture.paragraphStyle(in: rendered, at: 0)?.headIndent == 20)
        }

        @Test(.tags(.edgeCase), arguments: ["-item", "1.first"])
        func markersWithoutASpaceAreNotLists(line: String) {
            let rendered = ChatRenderer.markdown(line)
            #expect(rendered.string == line + "\n")
            #expect(CRFixture.paragraphStyle(in: rendered, at: 0)?.headIndent == 0)
        }

        @Test(arguments: ["> quoted", ">quoted", "  >  quoted"])
        func quotesAreIndentedAndDimmed(line: String) throws {
            let rendered = ChatRenderer.markdown(line)
            #expect(rendered.string == "quoted\n")
            #expect(CRFixture.color(in: rendered, at: 0) == NSColor.secondaryLabelColor)
            let style = try #require(CRFixture.paragraphStyle(in: rendered, at: 0))
            #expect(style.headIndent == 14)
            #expect(style.firstLineHeadIndent == 14)
        }

        @Test(arguments: ["---", "***", "___", "-----", "  ---  "])
        func rulesBecomeABlankLine(line: String) {
            #expect(ChatRenderer.markdown(line).string == "\n")
        }

        @Test func ruleSeparatesTheParagraphsAroundIt() {
            #expect(ChatRenderer.markdown("above\n---\nbelow").string == "above\n\nbelow\n")
        }
    }

    // MARK: - Inline Markdown

    @MainActor
    struct MarkdownInline {
        @Test func plainTextTakesTheBaseFontAndColor() {
            let text = ChatRenderer.inline("plain words")
            #expect(text.string == "plain words")
            #expect(CRFixture.font(in: text, at: 0) == ChatRenderer.body)
            #expect(CRFixture.color(in: text, at: 0) == NSColor.labelColor)
        }

        @Test func baseFontSetsTheSize() {
            let text = ChatRenderer.inline("x", font: .systemFont(ofSize: 20))
            #expect(CRFixture.font(in: text, at: 0)?.pointSize == 20)
        }

        @Test func colorCoversEveryRun() {
            let text = ChatRenderer.inline("a **b** *c* `d`", color: .systemRed)
            #expect(text.string == "a b c d")
            #expect(CRFixture.colors(in: text) == [NSColor.systemRed], "One color over the whole text")
        }

        @Test func strongTextIsBold() {
            let text = ChatRenderer.inline("a **b** c")
            #expect(text.string == "a b c")
            #expect(CRFixture.traits(in: text, at: 2)?.contains(.bold) == true)
            #expect(CRFixture.traits(in: text, at: 0)?.contains(.bold) == false)
        }

        @Test func emphasizedTextIsItalic() {
            let text = ChatRenderer.inline("a *b* c")
            #expect(text.string == "a b c")
            #expect(CRFixture.traits(in: text, at: 2)?.contains(.italic) == true)
            #expect(CRFixture.traits(in: text, at: 0)?.contains(.italic) == false)
        }

        @Test func strongEmphasisIsBoldAndItalic() {
            let text = ChatRenderer.inline("***both***")
            #expect(text.string == "both")
            let traits = CRFixture.traits(in: text, at: 0)
            #expect(traits?.contains(.bold) == true)
            #expect(traits?.contains(.italic) == true)
        }

        @Test func codeSpansAreInTheCodeRoleOnATint() {
            let text = ChatRenderer.inline("run `ls` now")
            #expect(text.string == "run ls now")
            CRFixture.verifyFace(CRFixture.font(in: text, at: 4), matches: .role(.code))
            #expect(CRFixture.value(.backgroundColor, in: text, at: 4) != nil, "Code sits on a tint")
            #expect(CRFixture.value(.backgroundColor, in: text, at: 0) == nil, "Prose doesn't")
        }

        @Test func linksKeepTheirDestination() {
            let text = ChatRenderer.inline("see [docs](https://example.com)")
            #expect(text.string == "see docs")
            #expect(CRFixture.link(in: text, at: 4)?.absoluteString == "https://example.com")
        }

        @Test func whitespaceIsPreserved() {
            #expect(ChatRenderer.inline("a  b\nc").string == "a  b\nc")
        }

        @Test func headingsKeepTheirSizeUnderInlineStyles() throws {
            let rendered = ChatRenderer.markdown("## **Bold** title")
            #expect(rendered.string == "Bold title\n")
            let bold = try #require(CRFixture.font(in: rendered, at: 0))
            #expect(bold.pointSize == TypeRole.title.pointSize)
            #expect(bold.fontDescriptor.symbolicTraits.contains(.bold))
            CRFixture.verifyFace(CRFixture.font(in: rendered, at: 5), matches: .role(.title))
        }
    }

    // MARK: - Fenced code

    @MainActor
    struct MarkdownCode {
        @Test func fencedCodeSitsOnACodeBlockBetweenSpacers() throws {
            let rendered = ChatRenderer.markdown("```swift\nlet x = 1\n```")
            #expect(rendered.string == "\nlet x = 1\n\n")
            let runs = CRFixture.blockRuns(rendered)
            #expect(runs.map(\.text) == ["let x = 1\n"])
            #expect(runs.map(\.kind) == [.code])
            #expect(runs.map(\.position) == [.single])
            let run = try #require(runs.first)
            #expect(CRFixture.font(in: rendered, at: run.range.location) == ChatRenderer.mono)
            #expect(CRFixture.paragraphStyle(in: rendered, at: 0)?.minimumLineHeight == 4)
        }

        @Test func codeIsHighlightedInTheFenceLanguage() throws {
            let rendered = ChatRenderer.markdown("```swift\nlet x = 1\n```")
            try CRFixture.verifyTokenColor("let", in: rendered, is: .systemPink)
            try CRFixture.verifyTokenColor("1", in: rendered, is: .systemBlue)
        }

        @Test func fenceLanguageIsTrimmedAndLowercased() throws {
            let rendered = ChatRenderer.markdown("```  Python  \n# note\n```")
            try CRFixture.verifyTokenColor("# note", in: rendered, is: .secondaryLabelColor)
        }

        @Test func eachCodeLineIsAParagraphOfTheBlock() {
            let runs = CRFixture.blockRuns(ChatRenderer.markdown("```\na\nb\nc\n```"))
            #expect(runs.map(\.text) == ["a\n", "b\n", "c\n"])
            #expect(runs.map(\.position) == [.first, .middle, .last])
        }

        @Test func indentationInsideTheFenceIsKept() {
            #expect(ChatRenderer.markdown("  ```\n    indented\n  ```").string == "\n    indented\n\n")
        }

        @Test(.tags(.edgeCase))
        func emptyFenceStillDrawsAnEmptyBlock() {
            let rendered = ChatRenderer.markdown("```\n```")
            #expect(rendered.string == "\n\n\n")
            let runs = CRFixture.blockRuns(rendered)
            #expect(runs.map(\.text) == ["\n"])
            #expect(runs.map(\.position) == [.single])
        }

        @Test func unclosedFenceRunsToTheEndWhileStreaming() {
            let rendered = ChatRenderer.markdown("```js\nconst a = 1\nstill code")
            #expect(rendered.string == "\nconst a = 1\nstill code\n\n")
            #expect(CRFixture.blockRuns(rendered).map(\.position) == [.first, .last])
        }

        @Test func textAfterTheClosingFenceIsProse() throws {
            let rendered = ChatRenderer.markdown("```\ncode\n```\nafter")
            #expect(rendered.string == "\ncode\n\nafter\n")
            let after = try #require(CRFixture.range(of: "after", in: rendered))
            #expect(CRFixture.hasBlock(in: rendered, at: after.location) == false)
        }

        @Test(.tags(.edgeCase))
        func linesWithEmojiSplitCleanly() {
            let runs = CRFixture.blockRuns(ChatRenderer.markdown("```\n🙂 a\nb\n```"))
            #expect(runs.map(\.text) == ["🙂 a\n", "b\n"], "Lines are cut by UTF-16 length, so a surrogate pair must not shift them")
        }
    }

    // MARK: - Tables

    @MainActor
    struct MarkdownTables {
        private static let long = Array(repeating: "wide", count: 60).joined(separator: " ")
        private let grid = "| a | b |\n|---|---|\n| 1 | 2 |"
        /// Too narrow for any grid of three columns: tables become records.
        private static let cramped: CGFloat = 100

        @Test func narrowTableIsAGridOnACard() throws {
            let rendered = ChatRenderer.markdown(grid)
            let runs = CRFixture.blockRuns(rendered)
            try #require(runs.count == 2)
            #expect(runs[0].text == "a\tb\n")
            #expect(runs[1].text == "1\t2\n")
            #expect(runs.map(\.kind) == [.card, .card])
            #expect(runs.map(\.position) == [.first, .last])
            #expect(rendered.string.hasPrefix("\n"), "A spacer above the card")
            #expect(rendered.string.hasSuffix("1\t2\n\n"), "And one below")
        }

        @Test func aRuleSeparatesTheHeaderFromTheRows() throws {
            let rendered = ChatRenderer.markdown("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")
            let runs = CRFixture.blockRuns(rendered)
            try #require(runs.count == 3)
            #expect(CRFixture.value(.chatTableRule, in: rendered, at: runs[0].range.location) == nil,
                    "Nothing above the header")
            let header = try #require(CRFixture.value(.chatTableRule, in: rendered, at: runs[1].range.location) as? TableRule)
            let between = try #require(CRFixture.value(.chatTableRule, in: rendered, at: runs[2].range.location) as? TableRule)
            #expect(header.isHeader && !between.isHeader)
            #expect(header.color == NSColor.tertiaryLabelColor)
            #expect(header.thickness > between.thickness, "The header's rule is the stronger one")
            #expect(header.leading == ChatRenderer.pad, "Rules start where the table's text does")
            #expect(header.width == between.width && header.width > 0)
        }

        @Test func headerIsSemiboldAndRowsRegular() throws {
            let rendered = ChatRenderer.markdown(grid)
            let runs = CRFixture.blockRuns(rendered)
            try #require(runs.count == 2)
            CRFixture.verifyFace(CRFixture.font(in: rendered, at: runs[0].range.location),
                                 matches: .role(.bodyEmphasis))
            CRFixture.verifyFace(CRFixture.font(in: rendered, at: runs[1].range.location),
                                 matches: .role(.body))
        }

        @Test func tableTextIsMarkedForRefitting() throws {
            let rendered = ChatRenderer.markdown("before\n\n\(grid)\n\nafter")
            let row = try #require(CRFixture.range(of: "1\t2", in: rendered))
            let after = try #require(CRFixture.range(of: "after", in: rendered))
            #expect(CRFixture.value(.chatTable, in: rendered, at: row.location) as? Bool == true)
            #expect(CRFixture.value(.chatTable, in: rendered, at: after.location) == nil)
        }

        @Test func separatorColonsAlignTheColumns() throws {
            let rendered = ChatRenderer.markdown("| a | b | c |\n|:--|--:|:--:|\n| 1 | 2 | 3 |")
            let header = try #require(CRFixture.blockRuns(rendered).first)
            let style = try #require(CRFixture.paragraphStyle(in: rendered, at: header.range.location))
            #expect(style.tabStops.map(\.alignment) == [.right, .center],
                    "A left-aligned first column starts the line; every other column gets a tab stop")
            #expect(style.lineBreakMode == .byTruncatingTail)
        }

        @Test func aFirstColumnThatIsntLeftAlignedStartsOnATab() throws {
            let rendered = ChatRenderer.markdown("| n | b |\n|--:|---|\n| 10 | x |")
            let runs = CRFixture.blockRuns(rendered)
            #expect(runs.map(\.text) == ["\tn\tb\n", "\t10\tx\n"])
            let style = try #require(CRFixture.paragraphStyle(in: rendered, at: runs[0].range.location))
            #expect(style.tabStops.map(\.alignment) == [.right, .left])
        }

        @Test func tabStopsAdvanceAcrossTheRow() throws {
            let rendered = ChatRenderer.markdown("| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |")
            let header = try #require(CRFixture.blockRuns(rendered).first)
            let stops = try #require(CRFixture.paragraphStyle(in: rendered, at: header.range.location)?.tabStops)
            let locations = stops.map(\.location)
            let pastInset = locations.allSatisfy { $0 > ChatRenderer.pad }
            #expect(locations.count == 2)
            #expect(locations == locations.sorted())
            #expect(pastInset, "Stops are past the block inset")
        }

        @Test func headerOnlyTableIsTheHeaderAlone() {
            let runs = CRFixture.blockRuns(ChatRenderer.markdown("| a | b |\n|---|---|"))
            #expect(runs.map(\.text) == ["a\tb\n"])
            #expect(runs.map(\.position) == [.single])
        }

        @Test(.tags(.edgeCase))
        func shortRowsArePaddedWithEmptyCells() {
            let runs = CRFixture.blockRuns(ChatRenderer.markdown("| a | b | c |\n|---|---|---|\n| 1 |"))
            #expect(runs.last?.text == "1\t\t\n")
        }

        @Test(.tags(.edgeCase))
        func extraCellsWidenTheTable() {
            let runs = CRFixture.blockRuns(ChatRenderer.markdown("| a |\n|---|\n| 1 | 2 |"))
            #expect(runs.first?.text == "a\t\n")
            #expect(runs.last?.text == "1\t2\n")
        }

        @Test func escapedPipesStayInTheirCell() {
            let runs = CRFixture.blockRuns(ChatRenderer.markdown("| a \\| b | c |\n|---|---|"))
            #expect(runs.first?.text == "a | b\tc\n")
        }

        @Test func pipesInCodeSpansStayInTheirCell() {
            let runs = CRFixture.blockRuns(ChatRenderer.markdown("| `a|b` | c |\n|---|---|"))
            #expect(runs.first?.text == "a|b\tc\n")
        }

        @Test func inlineMarkdownRendersInCells() throws {
            let rendered = ChatRenderer.markdown("| k | v |\n|---|---|\n| **bold** | [docs](https://example.com) `x` |")
            #expect(CRFixture.blockRuns(rendered).last?.text == "bold\tdocs x\n")
            let bold = try #require(CRFixture.range(of: "bold", in: rendered))
            #expect(CRFixture.traits(in: rendered, at: bold.location)?.contains(.bold) == true)
            let docs = try #require(CRFixture.range(of: "docs", in: rendered))
            #expect(CRFixture.link(in: rendered, at: docs.location)?.absoluteString == "https://example.com")
            let code = try #require(CRFixture.range(of: "x\n", in: rendered))
            #expect(CRFixture.font(in: rendered, at: code.location)?.isFixedPitch == true)
        }

        @Test(arguments: ["|---|---|", "| --- | --- |", "|:--|--:|", "| :---: | :---: |", "|--|--|", "  |---|---|  ",
                          "|-|-|", "--- | ---", "|---|---"])
        func separatorRowsThatMakeATable(separator: String) {
            let runs = CRFixture.blockRuns(ChatRenderer.markdown("| a | b |\n\(separator)\n| 1 | 2 |"))
            // A centered or right-aligned first column starts its lines on a tab.
            #expect(runs.map { String($0.text.drop { $0 == "\t" }) } == ["a\tb\n", "1\t2\n"])
        }

        @Test(.tags(.edgeCase), arguments: ["| x | y |", "|===|===|", "|---|", "|---|---|---|", "---"])
        func rowsThatAreNoSeparatorLeaveTheLinesAsText(separator: String) {
            let rendered = ChatRenderer.markdown("| a | b |\n\(separator)\n| 1 | 2 |")
            #expect(CRFixture.blockRuns(rendered).isEmpty)
            #expect(rendered.string.hasPrefix("| a | b |\n"))
        }

        @Test func pipeLineWithoutASeparatorIsText() {
            let rendered = ChatRenderer.markdown("| just text |")
            #expect(rendered.string == "| just text |\n")
            #expect(CRFixture.blockRuns(rendered).isEmpty)
        }

        @Test func tableEndsAtTheFirstLineWithoutAPipe() throws {
            let rendered = ChatRenderer.markdown("| a |\n|---|\n| 1 |\nafter")
            #expect(CRFixture.blockRuns(rendered).count == 2)
            #expect(rendered.string.hasSuffix("1\n\nafter\n"))
            let after = try #require(CRFixture.range(of: "after", in: rendered))
            #expect(CRFixture.hasBlock(in: rendered, at: after.location) == false)
        }

        /// The shapes replies put tables in: each renders the same grid.
        @Test(arguments: [
            "| a | b |\n|---|---|\n| 1 | 2 |",
            "a | b\n--- | ---\n1 | 2",
            "| a | b |\n| :-: | --: |\n| 1 | 2 |",
            "Intro line\n| a | b |\n|---|---|\n| 1 | 2 |",
            "- In a list:\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |",
            "> | a | b |\n> |---|---|\n> | 1 | 2 |",
            "> > | a | b |\n> > |---|---|\n> > | 1 | 2 |",
        ])
        func tablesInEveryShapeAreGrids(source: String) {
            let runs = CRFixture.blockRuns(ChatRenderer.markdown(source))
            let texts = runs.map { $0.text.trimmingCharacters(in: CharacterSet(charactersIn: "\t")) }
            #expect(texts == ["a\tb\n", "1\t2\n"])
            #expect(runs.allSatisfy { $0.kind == .card })
        }

        @Test func aQuotedTableEndsWhereTheQuoteDoes() {
            let rendered = ChatRenderer.markdown("> | a |\n> |---|\n> | 1 |\n| 2 |")
            #expect(CRFixture.blockRuns(rendered).map(\.text) == ["a\n", "1\n"])
            #expect(rendered.string.hasSuffix("| 2 |\n"))
        }

        /// A reply streams in: text until the delimiter row is whole, then a
        /// table that gains rows (a half-arrived row is a row already).
        @Test(arguments: [
            ("| a | b |", nil),
            ("| a | b |\n|--", nil),
            ("| a | b |\n|---|-", ["a\tb\n"]),
            ("| a | b |\n|---|---|\n| 1", ["a\tb\n", "1\t\n"]),
            ("| a | b |\n|---|---|\n| 1 | 2 |\n", ["a\tb\n", "1\t2\n"]),
        ] as [(String, [String]?)])
        func streamedTablesBecomeTablesOnceTheirDelimiterRowArrives(prefix: String, rows: [String]?) {
            let rendered = ChatRenderer.markdown(prefix)
            let runs = CRFixture.blockRuns(rendered).map(\.text)
            if let rows {
                #expect(runs == rows)
            } else {
                #expect(runs.isEmpty)
                #expect(rendered.string.hasPrefix("| a | b |"))
            }
        }

        @Test func longCellsWrapInsideTheirColumn() throws {
            let rendered = ChatRenderer.markdown("| Name | Notes |\n|---|---|\n| alpha | \(Self.long) |\n| beta | short |",
                                                 width: 600)
            let runs = CRFixture.blockRuns(rendered).map(\.text)
            try #require(runs.count > 4)
            #expect(runs[0] == "Name\tNotes\n")
            #expect(runs[1].hasPrefix("alpha\twide wide"))
            #expect(runs[2].hasPrefix("\twide"), "The row's next line leaves the first column empty")
            #expect(runs.last == "beta\tshort\n")
            let words = runs.dropFirst().dropLast().map { $0.split(separator: "\t").last ?? "" }
                .flatMap { $0.split(whereSeparator: \.isWhitespace) }
            #expect(words.count == 60, "Every word is there, none cut off")
        }

        @Test func aNarrowerColumnWrapsOntoMoreLines() {
            let source = "| Name | Notes |\n|---|---|\n| alpha | \(Self.long) |"
            let wide = CRFixture.blockRuns(ChatRenderer.markdown(source, width: 800)).count
            let narrow = CRFixture.blockRuns(ChatRenderer.markdown(source, width: 400)).count
            #expect(narrow > wide)
        }

        @Test func onlyTheFirstLineOfARowCarriesItsRule() throws {
            let rendered = ChatRenderer.markdown("| Name | Notes |\n|---|---|\n| alpha | \(Self.long) |", width: 400)
            let runs = CRFixture.blockRuns(rendered)
            let rules = runs.map { CRFixture.value(.chatTableRule, in: rendered, at: $0.range.location) != nil }
            #expect(rules.first == false && rules.dropFirst().first == true)
            #expect(rules.dropFirst(2).allSatisfy { !$0 })
        }

        @Test(arguments: ["one<br>two", "one<br/>two", "one<BR />two"])
        func lineBreaksInCellsBreakTheRow(cell: String) {
            let rendered = ChatRenderer.markdown("| Key | Value |\n|---|---|\n| k | \(cell) |")
            #expect(CRFixture.blockRuns(rendered).map(\.text) == ["Key\tValue\n", "k\tone\n", "\ttwo\n"])
        }

        @Test func tooManyColumnsBecomeOneRecordPerRow() throws {
            let rendered = ChatRenderer.markdown("| Name | Notes | More |\n|---|---|---|\n| alpha | n1 | m1 |\n| beta | n2 | m2 |",
                                                 width: Self.cramped)
            let runs = CRFixture.blockRuns(rendered)
            #expect(runs.map(\.text) == ["alpha\n", "Notes\tn1\n", "More\tm1\n", "\n", "beta\n", "Notes\tn2\n", "More\tm2\n"])
            #expect(rendered.string.contains("Name") == false, "The first column heads each record instead of labelling it")
            let title = try #require(runs.first)
            CRFixture.verifyFace(CRFixture.font(in: rendered, at: title.range.location),
                                 matches: .role(.bodyEmphasis))
            let label = try #require(CRFixture.range(of: "Notes", in: rendered))
            #expect(CRFixture.color(in: rendered, at: label.location) == NSColor.secondaryLabelColor)
            #expect(CRFixture.value(.chatTable, in: rendered, at: title.range.location) as? Bool == true)
        }

        @Test func longColumnHeadingsStackAboveTheirValues() {
            let heading = "A rather long column heading that has to wrap"
            let rendered = ChatRenderer.markdown("| Name | \(heading) | x |\n|---|---|---|\n| alpha | short value | |",
                                                 width: Self.cramped)
            #expect(CRFixture.blockRuns(rendered).map(\.text) == ["alpha\n", "\(heading)\u{2028}short value\n"])
        }

        @Test func emptyValuesAreLeftOutOfRecords() {
            let rendered = ChatRenderer.markdown("| Name | Notes | Extra |\n|---|---|---|\n| alpha | \(Self.long) | |",
                                                 width: Self.cramped)
            #expect(CRFixture.blockRuns(rendered).map(\.text) == ["alpha\n", "Notes\t\(Self.long)\n"])
            #expect(rendered.string.contains("Extra") == false)
        }
    }

    // MARK: - Line endings

    @MainActor
    struct MarkdownLineEndings {
        @Test func unixLineEndingsSplitListItems() {
            let rendered = ChatRenderer.markdown("- one\n- two", prose: .document)
            #expect(rendered.string == "•\tone\n•\ttwo\n")
        }

        @Test(.tags(.edgeCase))
        func windowsLineEndingsSplitListItems() {
            let rendered = ChatRenderer.markdown("- one\r\n- two", prose: .document)
            #expect(rendered.string == "•\tone\n•\ttwo\n", "\"\\r\\n\" is a single Character in Swift, but still ends a line")
        }

        @Test(.tags(.edgeCase))
        func windowsLineEndingsKeepFencedCodeAndWhatFollows() {
            let rendered = ChatRenderer.markdown("```\r\nlet x = 1\r\n```\r\nAfter", prose: .document)
            #expect(rendered.string.contains("let x = 1"))
            #expect(rendered.string.contains("After"))
            #expect(rendered.string.contains("\r") == false)
        }

        @Test(.tags(.edgeCase))
        func mixedLineEndingsSplitAlike() {
            let rendered = ChatRenderer.markdown("# Title\r\n- one\n- two\r\n", prose: .document)
            #expect(rendered.string == ChatRenderer.markdown("# Title\n- one\n- two\n", prose: .document).string)
        }
    }

    // MARK: - Typography

    @MainActor
    struct Typography {
        @Test func transcriptFacesAndMetrics() {
            #expect(ChatRenderer.body == .role(.body))
            #expect(ChatRenderer.mono == .role(.code))
            #expect(ChatRenderer.mono.isFixedPitch)
            #expect(ChatRenderer.pad == 14)
        }

        @Test func prosePresetsMatchTheTranscriptAndTheDocumentPreview() {
            #expect(ChatRenderer.Prose.chat.serif == false)
            #expect(ChatRenderer.Prose.document.serif)
        }

        @Test(arguments: TypeRole.allCases)
        func sansProseIsTheRoleFont(role: TypeRole) {
            CRFixture.verifyFace(ChatRenderer.Prose.chat.font(role), matches: .role(role))
        }

        @Test(arguments: [TypeRole.body, .bodyEmphasis, .title, .meta])
        func serifProseIsTheRoleInTheSerifDesign(role: TypeRole) {
            let font = ChatRenderer.Prose.document.font(role)
            #expect(font.pointSize == role.pointSize)
            #expect(font.fontName != NSFont.role(role).fontName, "New York, not San Francisco")
        }

    }

    // MARK: - Syntax highlighting

    /// A token's expected color role in highlighted source.
    struct HighlightCase: Sendable, CustomTestStringConvertible {
        let language: String
        let source: String
        let token: String
        /// keyword, number, type, string, comment or plain.
        let role: String

        var testDescription: String {
            "\(language.isEmpty ? "(no language)" : language): \(token.debugDescription) in \(source.debugDescription) is \(role)"
        }

        static let all: [HighlightCase] = [
            HighlightCase(language: "swift", source: "let x = 1", token: "let", role: "keyword"),
            HighlightCase(language: "swift", source: "let x = 1", token: "1", role: "number"),
            HighlightCase(language: "swift", source: "let pi = 3.14", token: "3.14", role: "number"),
            HighlightCase(language: "swift", source: "var s: String", token: "String", role: "type"),
            HighlightCase(language: "swift", source: "let s = \"hello\"", token: "\"hello\"", role: "string"),
            HighlightCase(language: "js", source: "const c = 'x'", token: "'x'", role: "string"),
            HighlightCase(language: "", source: "it's 'quoted'", token: "'quoted'", role: "string"),
            HighlightCase(language: "python", source: "s = f'{n}'", token: "f'{n}'", role: "string"),
            HighlightCase(language: "python", source: "p = rb'\\d'", token: "rb'\\d'", role: "string"),
            HighlightCase(language: "shell", source: "echo 'a\\' b", token: "'a\\'", role: "string"),
            // ' opens only a character literal in Rust (and Swift, Go, the C family…).
            HighlightCase(language: "rust", source: "let c = 'x';", token: "'x'", role: "string"),
            HighlightCase(language: "rust", source: "let c = '\\'';", token: "'\\''", role: "string"),
            HighlightCase(language: "rust", source: "let c = '\\u{1F600}';", token: "'\\u{1F600}'", role: "string"),
            HighlightCase(language: "rust", source: "fn f<'a>(x: &'a str) -> &'a str", token: "'a>(x: &'", role: "plain"),
            HighlightCase(language: "go", source: "r := '\\n'", token: "'\\n'", role: "string"),
            HighlightCase(language: "js", source: "const t = `tpl ${x}`", token: "`tpl ${x}`", role: "string"),
            HighlightCase(language: "swift", source: "x // note", token: "// note", role: "comment"),
            HighlightCase(language: "swift", source: "a /* one\ntwo */ b", token: "/* one\ntwo */", role: "comment"),
            HighlightCase(language: "swift", source: "x // note\nlet y = 2", token: "let", role: "keyword"),
            HighlightCase(language: "python", source: "x = 1  # note", token: "# note", role: "comment"),
            HighlightCase(language: "shell", source: "echo hi # note", token: "# note", role: "comment"),
            HighlightCase(language: "ruby", source: "x # note", token: "# note", role: "comment"),
            HighlightCase(language: "yaml", source: "key: 1 # note", token: "# note", role: "comment"),
            HighlightCase(language: "toml", source: "a = 1 # note", token: "# note", role: "comment"),
            // Each language's keywords, under its aliases too.
            HighlightCase(language: "python", source: "def f(): pass", token: "def", role: "keyword"),
            HighlightCase(language: "py", source: "def f(): pass", token: "def", role: "keyword"),
            HighlightCase(language: "shell", source: "echo hi", token: "echo", role: "keyword"),
            HighlightCase(language: "sh", source: "echo hi", token: "echo", role: "keyword"),
            HighlightCase(language: "bash", source: "echo hi", token: "echo", role: "keyword"),
            HighlightCase(language: "zsh", source: "echo hi", token: "echo", role: "keyword"),
            HighlightCase(language: "console", source: "echo hi", token: "echo", role: "keyword"),
            HighlightCase(language: "js", source: "const a = 1", token: "const", role: "keyword"),
            HighlightCase(language: "javascript", source: "const a = 1", token: "const", role: "keyword"),
            HighlightCase(language: "ts", source: "const a = 1", token: "const", role: "keyword"),
            HighlightCase(language: "typescript", source: "const a = 1", token: "const", role: "keyword"),
            HighlightCase(language: "tsx", source: "const a = 1", token: "const", role: "keyword"),
            HighlightCase(language: "jsx", source: "const a = 1", token: "const", role: "keyword"),
            HighlightCase(language: "go", source: "defer f()", token: "defer", role: "keyword"),
            HighlightCase(language: "golang", source: "defer f()", token: "defer", role: "keyword"),
            HighlightCase(language: "rust", source: "fn main() {}", token: "fn", role: "keyword"),
            HighlightCase(language: "rs", source: "fn main() {}", token: "fn", role: "keyword"),
            // No or unknown language: Swift and JavaScript keywords together.
            HighlightCase(language: "", source: "func f() { const a = 1 }", token: "func", role: "keyword"),
            HighlightCase(language: "", source: "func f() { const a = 1 }", token: "const", role: "keyword"),
            HighlightCase(language: "unknown", source: "x = 1; const y = 2", token: "const", role: "keyword"),
            HighlightCase(language: "unknown", source: "def x", token: "def", role: "plain"),
            // Near misses stay plain.
            HighlightCase(language: "swift", source: "letter", token: "letter", role: "plain"),
            HighlightCase(language: "swift", source: "x1", token: "1", role: "plain"),
            HighlightCase(language: "swift", source: "T", token: "T", role: "plain"),
            HighlightCase(language: "python", source: "a // b", token: "//", role: "plain"),
            HighlightCase(language: "swift", source: "x # y", token: "#", role: "plain"),
            // Later passes win: strings over keywords, comments over both, keywords over type names.
            HighlightCase(language: "swift", source: "\"let\"", token: "let", role: "string"),
            HighlightCase(language: "swift", source: "// let", token: "let", role: "comment"),
            HighlightCase(language: "rust", source: "Self", token: "Self", role: "keyword"),
            HighlightCase(language: "python", source: "None", token: "None", role: "keyword"),
        ]
    }

    @MainActor
    struct SyntaxHighlighting {
        private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        @Test(arguments: ChatRendererTests.HighlightCase.all)
        func tokensAreColoredByRole(testCase: ChatRendererTests.HighlightCase) throws {
            let highlighted = SyntaxHighlighter.highlight(testCase.source, language: testCase.language, font: font)
            try CRFixture.verifyTokenColor(testCase.token, in: highlighted, is: CRFixture.highlightColor(testCase.role))
        }

        @Test func sourceAndFontAreKept() {
            let source = "let s = \"x\" // done\nfunc f() {}"
            let highlighted = SyntaxHighlighter.highlight(source, language: "swift", font: font)
            #expect(highlighted.string == source)
            #expect(CRFixture.fonts(in: highlighted) == [font], "One font over the whole text")
        }

        @Test func plainTextIsLabelColored() {
            let highlighted = SyntaxHighlighter.highlight("hello world", language: "swift", font: font)
            #expect(CRFixture.colors(in: highlighted) == [NSColor.labelColor])
        }

        @Test(.tags(.edgeCase))
        func emptySourceGivesEmptyText() {
            #expect(SyntaxHighlighter.highlight("", language: "swift", font: font).length == 0)
        }

        @Test(.tags(.edgeCase), arguments: [
            ("swift", "let url = \"https://example.com\"", "example.com"),
            ("python", "tag = \"#hashtag\"", "hashtag"),
        ])
        func commentMarkersInsideStringsStayString(language: String, source: String, inside: String) throws {
            let highlighted = SyntaxHighlighter.highlight(source, language: language, font: font)
            let range = try #require(CRFixture.range(of: inside, in: highlighted))
            #expect(CRFixture.color(in: highlighted, at: range.location) == NSColor.systemRed)
        }

        @Test(.tags(.edgeCase), arguments: [
            ("swift", "x // don't \"quote\" me", "quote"),
            ("swift", "/* \"a\" */ let b = 1", "a"),
            ("python", "x = 1  # it's \"here\"", "here"),
        ])
        func quotesInsideCommentsStayComment(language: String, source: String, inside: String) throws {
            let highlighted = SyntaxHighlighter.highlight(source, language: language, font: font)
            let range = try #require(CRFixture.range(of: inside, in: highlighted))
            #expect(CRFixture.color(in: highlighted, at: range.location) == NSColor.secondaryLabelColor)
        }

        /// A ' that opens no string — a Rust lifetime or label, an escaped
        /// shell quote, an apostrophe in a word — doesn't run on into the comment
        /// after it, ending at an apostrophe there.
        @Test(.tags(.edgeCase), arguments: [
            ("rust", "fn f() -> &'static str { // it's", "it"),
            ("rust", "pub fn name(&self) -> &'static str { // it's fixed", "fixed"),
            ("rust", "fn f<'a>(x: &'a str) {} // it's", "it"),
            ("rust", "'outer: loop { // don't", "don"),
            ("shell", "echo it\\'s # it's here", "here"),
            ("", "Don't panic // it's fine", "fine"),
            ("js", "x = y // it's", "it"),
            ("yaml", "note: it's here # it's fine", "fine"),
        ])
        func apostrophesThatOpenNoStringLeaveTheCommentAlone(language: String, source: String, inside: String) throws {
            let highlighted = SyntaxHighlighter.highlight(source, language: language, font: font)
            let comment = try #require(source.range(of: language == "shell" || language == "yaml" ? "# " : "// "))
            let start = source.distance(from: source.startIndex, to: comment.lowerBound)
            try CRFixture.verifyTokenColor(String(source[comment.lowerBound...]), in: highlighted, is: .secondaryLabelColor)
            let range = try #require(CRFixture.range(of: inside, in: highlighted))
            #expect(range.location > start, "\(inside.debugDescription) is in the comment")
            #expect(CRFixture.color(in: highlighted, at: range.location) == NSColor.secondaryLabelColor)
        }

        @Test func aStringAfterACommentOnTheNextLineIsStillAString() throws {
            let highlighted = SyntaxHighlighter.highlight("// see \"x\"\nlet s = \"https://a.b\" // c", language: "swift", font: font)
            try CRFixture.verifyTokenColor("\"https://a.b\"", in: highlighted, is: .systemRed)
            try CRFixture.verifyTokenColor("// c", in: highlighted, is: .secondaryLabelColor)
        }
    }

    // MARK: - Block backgrounds

    @MainActor
    struct BlockBackgrounds {
        @Test(arguments: [
            ("code", 0.055), ("card", 0.04), ("user", 0.11), ("added", 0.14), ("removed", 0.13), ("hunk", 0.08),
        ] as [(String, CGFloat)])
        func fillIsATranslucentTintPerKind(name: String, alpha: CGFloat) throws {
            let kind = try #require(CRFixture.blockKind(named: name))
            let fill = BlockStyle(kind, .single).fill
            #expect(abs(fill.alphaComponent - alpha) < 0.0001)
        }

        @Test(arguments: [
            ("code", false), ("card", false), ("user", false), ("added", true), ("removed", true), ("hunk", true),
        ])
        func onlyDiffLinesSpanTheFullWidth(name: String, fullWidth: Bool) throws {
            let kind = try #require(CRFixture.blockKind(named: name))
            #expect(BlockStyle(kind, .middle).isFullWidth == fullWidth)
        }

        @Test func styleKeepsItsKindAndPosition() {
            let style = BlockStyle(.hunk, .last)
            #expect(style.kind == .hunk)
            #expect(style.position == .last)
        }

        @Test func backgroundGeometry() {
            #expect(BlockBackgroundFragment.margin == 4)
            #expect(BlockBackgroundFragment.radius == 8)
        }

        @Test func styledParagraphsGetABackgroundFragmentWithTheirStyle() throws {
            let style = BlockStyle(.code, .single)
            let text = NSMutableAttributedString(string: "plain\n")
            text.append(NSAttributedString(string: "boxed\n", attributes: [.chatBlock: style]))
            try CRFixture.withParagraphs(of: text) { paragraphs in
                let match = paragraphs.first { $0.attributedString.string.hasPrefix("boxed") }
                let boxed = try #require(match)
                let location = try #require(boxed.elementRange?.location)
                let fragment = BlockFragmentProvider().textLayoutManager(NSTextLayoutManager(),
                                                                          textLayoutFragmentFor: location, in: boxed)
                let background = try #require(fragment as? BlockBackgroundFragment)
                #expect(background.style === style)
            }
        }

        @Test func otherParagraphsGetAPlainFragment() throws {
            let text = NSMutableAttributedString(string: "plain\n")
            text.append(NSAttributedString(string: "boxed\n", attributes: [.chatBlock: BlockStyle(.card, .single)]))
            try CRFixture.withParagraphs(of: text) { paragraphs in
                let match = paragraphs.first { $0.attributedString.string.hasPrefix("plain") }
                let plain = try #require(match)
                let location = try #require(plain.elementRange?.location)
                let fragment = BlockFragmentProvider().textLayoutManager(NSTextLayoutManager(),
                                                                          textLayoutFragmentFor: location, in: plain)
                #expect((fragment is BlockBackgroundFragment) == false)
            }
        }
    }
}

// MARK: - Fixtures

/// Builders and attributed-string probes shared by the suites in this file
/// (main-actor, like the renderer and every suite that uses them).
@MainActor
fileprivate enum CRFixture {
    /// A tool call with quiet defaults: a completed command with no output.
    static func call(id: String = "c1", title: String = "", kind: String = "execute", status: String = "completed",
                     output: String = "", diffs: [ChatItem.Diff] = [], images: [Data] = [],
                     input: String = "") -> ChatItem.ToolCall {
        ChatItem.ToolCall(id: id, title: title, kind: kind, status: status, output: output, diffs: diffs,
                          images: images, input: input)
    }

    /// "line 1\nline 2\n…" up to `count` (at least 1).
    static func lines(_ count: Int, prefix: String = "line ") -> String {
        (1...count).map { "\(prefix)\($0)" }.joined(separator: "\n")
    }

    /// One paragraph that sits on a block background.
    struct BlockRun {
        let kind: BlockStyle.Kind
        let position: BlockStyle.Position
        let text: String
        let range: NSRange
    }

    /// The paragraphs carrying `.chatBlock`, in order (each has its own `BlockStyle`).
    static func blockRuns(_ text: NSAttributedString) -> [BlockRun] {
        var runs: [BlockRun] = []
        let string = text.string as NSString
        text.enumerateAttribute(.chatBlock, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let style = value as? BlockStyle else { return }
            runs.append(BlockRun(kind: style.kind, position: style.position, text: string.substring(with: range), range: range))
        }
        return runs
    }

    static func range(of needle: String, in text: NSAttributedString) -> NSRange? {
        let range = (text.string as NSString).range(of: needle)
        return range.location == NSNotFound ? nil : range
    }

    /// The attribute at `location`, or nil when it's out of bounds.
    static func value(_ key: NSAttributedString.Key, in text: NSAttributedString, at location: Int) -> Any? {
        guard location >= 0, location < text.length else { return nil }
        return text.attribute(key, at: location, effectiveRange: nil)
    }

    static func font(in text: NSAttributedString, at location: Int) -> NSFont? {
        value(.font, in: text, at: location) as? NSFont
    }

    static func traits(in text: NSAttributedString, at location: Int) -> NSFontDescriptor.SymbolicTraits? {
        font(in: text, at: location)?.fontDescriptor.symbolicTraits
    }

    static func color(in text: NSAttributedString, at location: Int) -> NSColor? {
        value(.foregroundColor, in: text, at: location) as? NSColor
    }

    static func paragraphStyle(in text: NSAttributedString, at location: Int) -> NSParagraphStyle? {
        value(.paragraphStyle, in: text, at: location) as? NSParagraphStyle
    }

    static func link(in text: NSAttributedString, at location: Int) -> URL? {
        value(.link, in: text, at: location) as? URL
    }

    static func toolTip(in text: NSAttributedString, at location: Int) -> String? {
        value(.toolTip, in: text, at: location) as? String
    }

    static func hasBlock(in text: NSAttributedString, at location: Int) -> Bool {
        value(.chatBlock, in: text, at: location) is BlockStyle
    }

    static func linkCount(in text: NSAttributedString) -> Int {
        var count = 0
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }

    /// The distinct runs of foreground color, in order.
    static func colors(in text: NSAttributedString) -> [NSColor?] {
        var colors: [NSColor?] = []
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            colors.append(value as? NSColor)
        }
        return colors
    }

    /// The distinct runs of font, in order.
    static func fonts(in text: NSAttributedString) -> [NSFont?] {
        var fonts: [NSFont?] = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            fonts.append(value as? NSFont)
        }
        return fonts
    }

    /// PNG bytes of a blank image `width` × `height` pixels.
    static func png(width: Int, height: Int, sourceLocation: SourceLocation = #_sourceLocation) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                               sourceLocation: sourceLocation)
        return try #require(rep.representation(using: .png, properties: [:]), sourceLocation: sourceLocation)
    }

    static func blockKind(named name: String) -> BlockStyle.Kind? {
        switch name {
        case "code": .code
        case "card": .card
        case "user": .user
        case "added": .added
        case "removed": .removed
        case "hunk": .hunk
        default: nil
        }
    }

    /// The color `SyntaxHighlighter` paints each role.
    static func highlightColor(_ role: String) -> NSColor {
        switch role {
        case "keyword": .systemPink
        case "number": .systemBlue
        case "type": .systemTeal
        case "string": .systemRed
        case "comment": .secondaryLabelColor
        default: .labelColor
        }
    }

    /// Same face and size (fonts are compared by name, not identity).
    static func verifyFace(_ font: NSFont?, matches expected: NSFont, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(font?.fontName == expected.fontName, sourceLocation: sourceLocation)
        #expect(font?.pointSize == expected.pointSize, sourceLocation: sourceLocation)
    }

    /// The first occurrence of `token` is `expected` from its first character to its last.
    static func verifyTokenColor(_ token: String, in text: NSAttributedString, is expected: NSColor,
                                 sourceLocation: SourceLocation = #_sourceLocation) throws {
        let found = range(of: token, in: text)
        let tokenRange = try #require(found, "\(token.debugDescription) is in the text", sourceLocation: sourceLocation)
        for location in [tokenRange.location, NSMaxRange(tokenRange) - 1] {
            #expect(color(in: text, at: location) == expected, "Color at \(location) of \(token.debugDescription)",
                    sourceLocation: sourceLocation)
        }
    }

    /// Runs `body` with the paragraphs TextKit 2 makes of `text`, keeping their content storage alive meanwhile.
    static func withParagraphs(of text: NSAttributedString, _ body: ([NSTextParagraph]) throws -> Void) throws {
        let content = NSTextContentStorage()
        content.textStorage = NSTextStorage(attributedString: text)
        defer { withExtendedLifetime(content) {} }
        let paragraphs = content.textElements(for: content.documentRange).compactMap { $0 as? NSTextParagraph }
        try body(paragraphs)
    }
}

/// What's typed and not sent survives whatever happens to the chat (`ComposerDrafts`).
@MainActor
@Suite(.serialized)
struct ComposerDraftTests {
    private func withDrafts(_ body: @MainActor (UUID) throws -> Void) throws {
        let suite = "SandshellComposerDrafts-\(UUID().uuidString)"
        let saved = ComposerDrafts.defaults
        ComposerDrafts.defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            ComposerDrafts.defaults.removePersistentDomain(forName: suite)
            ComposerDrafts.defaults = saved
        }
        try body(UUID())
    }

    @Test func typingIsKeptAsItHappens() throws {
        try withDrafts { id in
            let composer = ChatComposerView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
            composer.draftID = id
            composer.debugTypeKeys("half a thought")
            #expect(ComposerDrafts.typed(for: id) == "half a thought")
        }
    }

    @Test func sendingClearsItAndARefusalDoesnt() throws {
        try withDrafts { id in
            let composer = ChatComposerView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
            composer.draftID = id
            composer.debugTypeKeys("hello")
            composer.onSubmit = { _, _ in false }
            composer.submitFromButton()
            #expect(ComposerDrafts.typed(for: id) == "hello", "Nothing took it")
            composer.onSubmit = { _, _ in true }
            composer.submitFromButton()
            #expect(ComposerDrafts.typed(for: id).isEmpty)
        }
    }

    @Test func aNewChatGetsItBackQueuedMessagesFirst() throws {
        try withDrafts { id in
            ComposerDrafts.save(typed: "typed", for: id)
            ComposerDrafts.save(queued: ["first", "second"], for: id)
            #expect(ComposerDrafts.restore(for: id, keepQueued: true) == "first\n\nsecond\n\ntyped")
            #expect(ComposerDrafts.queued(for: id).isEmpty)
            #expect(ComposerDrafts.typed(for: id) == "first\n\nsecond\n\ntyped", "Still kept until it goes")
        }
    }

    /// A reconnect hands queued messages to the next chat to send: not also in the field.
    @Test func queuedMessagesBeingCarriedDontComeBackToo() throws {
        try withDrafts { id in
            ComposerDrafts.save(typed: "typed", for: id)
            ComposerDrafts.save(queued: ["carried"], for: id)
            #expect(ComposerDrafts.restore(for: id, keepQueued: false) == "typed")
            #expect(ComposerDrafts.queued(for: id).isEmpty)
        }
    }

    @Test func anUnsentMessageGoesBackAheadOfWhatsBeenTyped() throws {
        try withDrafts { id in
            ComposerDrafts.save(typed: "since", for: id)
            ComposerDrafts.putBack("unsent", for: id)
            #expect(ComposerDrafts.typed(for: id) == "unsent\n\nsince")
        }
    }

    @Test func draftsAreBySession() throws {
        try withDrafts { id in
            ComposerDrafts.save(typed: "mine", for: id)
            #expect(ComposerDrafts.typed(for: UUID()).isEmpty)
            ComposerDrafts.forget(id)
            #expect(ComposerDrafts.typed(for: id).isEmpty)
        }
    }

    /// Added to what's there, never over it: restored text mustn't be replaced.
    @Test func addingADraftKeepsWhatsThere() throws {
        try withDrafts { id in
            let composer = ChatComposerView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
            composer.draftID = id
            composer.setDraft("kept")
            composer.addToDraft("added")
            #expect(composer.debugText == "kept\n\nadded")
        }
    }
}

