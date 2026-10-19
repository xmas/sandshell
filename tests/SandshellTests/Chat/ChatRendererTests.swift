import AppKit
import Foundation
import Testing
@testable import Sandshell

/// Tests for `Chat/ChatRenderer.swift`: `ChatRenderer` (transcript items and
/// Markdown to attributed text, tool-group summaries, chat links),
/// `SyntaxHighlighter`, and the block backgrounds (`BlockStyle`,
/// `BlockBackgroundFragment`, `BlockFragmentProvider`).
///
/// Every rendered segment is wrapped in spacer lines ("\n" at a fixed line
/// height), so most expected strings start and end with a bare newline.
struct ChatRendererTests {

    // MARK: - Links

    @MainActor
    struct Links {
        @Test(arguments: [
            ("abc", "sandshell-chat://toggle/abc"),
            ("ABC123", "sandshell-chat://toggle/ABC123"),
            ("tool-123", "sandshell-chat://toggle/tool%2D123"),
            ("a b/c", "sandshell-chat://toggle/a%20b%2Fc"),
        ])
        func toggleURLEncodesEverythingButLettersAndDigits(id: String, expected: String) {
            #expect(ChatRenderer.toggleURL(id).absoluteString == expected)
        }

        @Test(arguments: ["abc", "thought-7", "tool-toolu_01ABC", "group-c1", "a b/c?d#e", "100%", "🙂"])
        func toggleURLRoundTripsTheID(id: String) {
            verifyToggleRoundTrip(id)
        }

        @Test(.tags(.edgeCase), arguments: ["", "é", "über-straße"])
        func toggleURLCopesWithEmptyAndNonASCIIIDs(id: String) {
            verifyToggleRoundTrip(id)
        }

        @Test func undoURLCarriesTheTurnAsItsLastPathComponent() {
            let turn = "8F2C1D9E-5B7A-4C3D-9E1F-0A2B3C4D5E6F"
            let url = ChatRenderer.undoURL(turn)
            #expect(url.absoluteString == "sandshell-chat://undo/\(turn)")
            #expect(url.host() == "undo")
            #expect(url.lastPathComponent == turn, "The transcript hands url.lastPathComponent to Undo")
        }

        @Test(.tags(.edgeCase), arguments: ["turn/2", "turn?2", "turn#2"])
        func undoURLRoundTripsTurnsWithURLDelimiters(turn: String) {
            let url = ChatRenderer.undoURL(turn)
            #expect(url.host() == "undo")
            #expect(url.lastPathComponent == turn, "A '/', '?' or '#' in the turn is escaped, not read as URL structure")
        }

        /// The link's scheme and host route it, and one percent-decoding of its
        /// path gives the id back.
        private func verifyToggleRoundTrip(_ id: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let url = ChatRenderer.toggleURL(id)
            #expect(url.scheme == "sandshell-chat", sourceLocation: sourceLocation)
            #expect(url.host() == "toggle", sourceLocation: sourceLocation)
            #expect(url.path(percentEncoded: false) == "/" + id, "The id comes back from the decoded path",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: - User messages

    @MainActor
    struct UserMessages {
        @Test func singleLineSitsOnOneUserBlock() {
            let rendered = ChatRenderer.render(.user(id: UUID(), text: "Hello", attachments: []), expanded: false)
            #expect(rendered.string == "\nHello\n\n")
            let runs = CRFixture.blockRuns(rendered)
            #expect(runs.map(\.text) == ["Hello\n"])
            #expect(runs.map(\.kind) == [.user])
            #expect(runs.map(\.position) == [.single])
        }

        @Test func eachLineAndAttachmentIsAParagraphOfTheBlock() {
            let rendered = ChatRenderer.render(.user(id: UUID(), text: "one\n\nthree", attachments: ["notes.txt"]),
                                               expanded: false)
            #expect(rendered.string == "\none\n\nthree\n📎 notes.txt\n\n")
            let runs = CRFixture.blockRuns(rendered)
            #expect(runs.map(\.text) == ["one\n", "\n", "three\n", "📎 notes.txt\n"], "Blank lines are kept")
            #expect(runs.map(\.position) == [.first, .middle, .middle, .last])
            #expect(runs.map(\.kind) == [.user, .user, .user, .user])
        }

        @Test func textUsesTheBodyFaceAndAttachmentsTheSmallDimFace() throws {
            let rendered = ChatRenderer.render(.user(id: UUID(), text: "Look", attachments: ["a.png"]), expanded: false)
            let text = try #require(CRFixture.range(of: "Look", in: rendered))
            #expect(CRFixture.font(in: rendered, at: text.location) == ChatRenderer.body)
            #expect(CRFixture.color(in: rendered, at: text.location) == NSColor.labelColor)
            let clip = try #require(CRFixture.range(of: "📎", in: rendered))
            #expect(CRFixture.font(in: rendered, at: clip.location) == ChatRenderer.mono)
            #expect(CRFixture.color(in: rendered, at: clip.location) == NSColor.secondaryLabelColor)
        }

        @Test func attachmentsAloneStillMakeABlock() {
            let rendered = ChatRenderer.render(.user(id: UUID(), text: "", attachments: ["a.png", "b.pdf"]),
                                               expanded: false)
            #expect(rendered.string == "\n📎 a.png\n📎 b.pdf\n\n", "An empty text adds no blank first line")
            #expect(CRFixture.blockRuns(rendered).map(\.position) == [.first, .last])
        }

        @Test(.tags(.edgeCase))
        func emptyMessageRendersNothing() {
            let rendered = ChatRenderer.render(.user(id: UUID(), text: "", attachments: []), expanded: false)
            #expect(rendered.length == 0, "No spacers either")
        }

        @Test func singleParagraphIsInsetAndPaddedTopAndBottom() throws {
            let rendered = ChatRenderer.render(.user(id: UUID(), text: "Hello", attachments: []), expanded: false)
            let run = try #require(CRFixture.blockRuns(rendered).first)
            let style = try #require(CRFixture.paragraphStyle(in: rendered, at: run.range.location))
            #expect(style.firstLineHeadIndent == ChatRenderer.pad)
            #expect(style.headIndent == ChatRenderer.pad)
            #expect(style.tailIndent == -ChatRenderer.pad)
            #expect(style.paragraphSpacingBefore == 7)
            #expect(style.paragraphSpacing == 7)
        }

        @Test func onlyTheOuterParagraphsCarryTheBlockPadding() throws {
            let rendered = ChatRenderer.render(.user(id: UUID(), text: "a\nb\nc", attachments: []), expanded: false)
            let runs = CRFixture.blockRuns(rendered)
            try #require(runs.count == 3)
            let styles = runs.map { CRFixture.paragraphStyle(in: rendered, at: $0.range.location) }
            let spacingBefore = styles.map { $0?.paragraphSpacingBefore }
            let spacingAfter = styles.map { $0?.paragraphSpacing }
            let indents = styles.map { $0?.headIndent }
            #expect(spacingBefore == [7, 0, 0], "Top padding on the first paragraph only")
            #expect(spacingAfter == [0, 0, 7], "Bottom padding on the last paragraph only")
            #expect(indents == [ChatRenderer.pad, ChatRenderer.pad, ChatRenderer.pad])
        }

        @Test func spacersAreFixedHeightLinesOutsideTheBlock() throws {
            let rendered = ChatRenderer.render(.user(id: UUID(), text: "Hello", attachments: []), expanded: false)
            let last = rendered.length - 1
            #expect(CRFixture.hasBlock(in: rendered, at: 0) == false, "The block background never absorbs a spacer")
            #expect(CRFixture.hasBlock(in: rendered, at: last) == false)
            let top = try #require(CRFixture.paragraphStyle(in: rendered, at: 0))
            #expect(top.minimumLineHeight == 14)
            #expect(top.maximumLineHeight == 14)
            let bottom = try #require(CRFixture.paragraphStyle(in: rendered, at: last))
            #expect(bottom.minimumLineHeight == 6)
            #expect(bottom.maximumLineHeight == 6)
            #expect(CRFixture.font(in: rendered, at: 0)?.pointSize == 1, "A 1-point font so only the line height counts")
        }
    }

    // MARK: - Agent text

    @MainActor
    struct AgentText {
        @Test func agentTextIsMarkdownBetweenFourPointSpacers() throws {
            let rendered = ChatRenderer.render(.agentText(id: "a1", text: "Hello **world**"), expanded: false)
            #expect(rendered.string == "\nHello world\n\n")
            #expect(CRFixture.paragraphStyle(in: rendered, at: 0)?.minimumLineHeight == 4)
            #expect(CRFixture.paragraphStyle(in: rendered, at: rendered.length - 1)?.maximumLineHeight == 4)
            let bold = try #require(CRFixture.range(of: "world", in: rendered))
            #expect(CRFixture.font(in: rendered, at: bold.location)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        }

        @Test func blocksComeFromTheMarkdown() {
            let rendered = ChatRenderer.render(.agentText(id: "a1", text: "```\ncode\n```"), expanded: false)
            let runs = CRFixture.blockRuns(rendered)
            #expect(runs.map(\.text) == ["code\n"])
            #expect(runs.map(\.kind) == [.code])
        }
    }

    // MARK: - Thoughts

    @MainActor
    struct Thoughts {
        @Test func longThoughtShowsTwoLinesAndAShowMoreLink() throws {
            let rendered = ChatRenderer.render(.thought(id: "t1", text: "one\ntwo\nthree"), expanded: false)
            #expect(rendered.string == "\nThinking\none\ntwo\nShow more\n\n")
            let more = try #require(CRFixture.range(of: "Show more", in: rendered))
            let expected = ChatRenderer.toggleURL("thought-t1")
            #expect(CRFixture.link(in: rendered, at: more.location) == expected)
            #expect(CRFixture.color(in: rendered, at: more.location) == NSColor.linkColor)
            #expect(CRFixture.paragraphStyle(in: rendered, at: 0)?.minimumLineHeight == 2)
        }

        @Test func expandedThoughtShowsEveryLineAndAShowLessLink() throws {
            let rendered = ChatRenderer.render(.thought(id: "t1", text: "one\ntwo\nthree"), expanded: true)
            #expect(rendered.string == "\nThinking\none\ntwo\nthree\nShow less\n\n")
            let less = try #require(CRFixture.range(of: "Show less", in: rendered))
            let expected = ChatRenderer.toggleURL("thought-t1")
            #expect(CRFixture.link(in: rendered, at: less.location) == expected)
        }

        @Test func toggleLinkUsesTheItemID() throws {
            let item = ChatItem.thought(id: "t1", text: "a\nb\nc")
            let rendered = ChatRenderer.render(item, expanded: false)
            let more = try #require(CRFixture.range(of: "Show more", in: rendered))
            let expected = ChatRenderer.toggleURL(item.id)
            #expect(CRFixture.link(in: rendered, at: more.location) == expected,
                    "The transcript keeps opened items by item.id, so the link must carry the same id")
        }

        @Test(arguments: [false, true])
        func thoughtOfTwoLinesHasNoLink(expanded: Bool) {
            let rendered = ChatRenderer.render(.thought(id: "t1", text: "one\ntwo"), expanded: expanded)
            #expect(rendered.string == "\nThinking\none\ntwo\n\n")
            #expect(CRFixture.linkCount(in: rendered) == 0)
        }

        @Test func surroundingWhitespaceIsTrimmedBeforeCountingLines() {
            let rendered = ChatRenderer.render(.thought(id: "t1", text: "\n\n  one\ntwo  \n\n"), expanded: false)
            #expect(rendered.string == "\nThinking\none\ntwo\n\n")
            #expect(CRFixture.linkCount(in: rendered) == 0)
        }

        @Test func thoughtIsDimAndItalic() throws {
            let rendered = ChatRenderer.render(.thought(id: "t1", text: "pondering"), expanded: false)
            CRFixture.verifyFace(CRFixture.font(in: rendered, at: 1), matches: .role(.meta, weight: .semibold))
            #expect(CRFixture.color(in: rendered, at: 1) == NSColor.tertiaryLabelColor)
            let text = try #require(CRFixture.range(of: "pondering", in: rendered))
            #expect(CRFixture.font(in: rendered, at: text.location)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
            #expect(CRFixture.color(in: rendered, at: text.location) == NSColor.tertiaryLabelColor)
        }
    }

    // MARK: - Tool cards

    @MainActor
    struct ToolCards {
        @Test func outputFollowsTheTitleOnOneCard() {
            let rendered = card(CRFixture.call(title: "git status", output: "On branch main\nnothing to commit"))
            #expect(rendered.string == "\n✓  git status\nOn branch main\nnothing to commit\n\n")
            let runs = CRFixture.blockRuns(rendered)
            #expect(runs.map(\.text) == ["✓  git status\n", "On branch main\n", "nothing to commit\n"])
            #expect(runs.map(\.kind) == [.card, .card, .card])
            #expect(runs.map(\.position) == [.first, .middle, .last])
            #expect(CRFixture.paragraphStyle(in: rendered, at: 0)?.minimumLineHeight == 4)
        }

        @Test(arguments: [
            ("completed", "✓", "green"), ("failed", "✗", "red"), ("in_progress", "⋯", "blue"),
            ("pending", "◌", "secondary"), ("", "◌", "secondary"), ("cancelled", "◌", "secondary"),
        ])
        func statusPicksTheGlyphAndItsColor(status: String, glyph: String, colorName: String) {
            let rendered = card(CRFixture.call(title: "Work", status: status))
            #expect(rendered.string == "\n\(glyph)  Work\n\n")
            let expected: NSColor = switch colorName {
            case "green": .systemGreen
            case "red": .systemRed
            case "blue": .systemBlue
            default: .secondaryLabelColor
            }
            #expect(CRFixture.color(in: rendered, at: 1) == expected)
        }

        @Test func emptyTitleFallsBackToTheCapitalizedKind() {
            #expect(card(CRFixture.call(title: "", kind: "read")).string == "\n✓  Read\n\n")
        }

        @Test(arguments: [(120, 120, false), (121, 117, true), (500, 117, true)])
        func titlesOver120CharactersAreCut(length: Int, kept: Int, ellipsis: Bool) throws {
            let rendered = card(CRFixture.call(title: String(repeating: "x", count: length)))
            let head = try #require(CRFixture.blockRuns(rendered).first)
            #expect(head.text == "✓  " + String(repeating: "x", count: kept) + (ellipsis ? "…" : "") + "\n")
        }

        @Test func multiLineTitleShowsItsFirstLineThenTheRestAsInput() throws {
            let rendered = card(CRFixture.call(title: "for f in *; do\n  echo $f\ndone"))
            #expect(rendered.string == "\n✓  for f in *; do\n  echo $f\ndone\n\n")
            let rest = try #require(CRFixture.range(of: "  echo", in: rendered))
            #expect(CRFixture.color(in: rendered, at: rest.location) == NSColor.secondaryLabelColor)
        }

        @Test(arguments: [
            ("git status", "git status"),
            ("Read /repo/a.swift", "/repo/a.swift"),
            ("git status", "  git status  "),
        ])
        func inputThatOnlyRepeatsTheTitleIsLeftOut(title: String, input: String) {
            let rendered = card(CRFixture.call(title: title, input: input))
            #expect(rendered.string == "\n✓  \(title)\n\n")
        }

        @Test func inputThatSaysMoreIsShownDimAboveTheOutput() throws {
            let rendered = card(CRFixture.call(title: "Run tests", output: "ok", input: "swift test --parallel"))
            #expect(rendered.string == "\n✓  Run tests\nswift test --parallel\n\nok\n\n")
            #expect(CRFixture.blockRuns(rendered).map(\.text) == ["✓  Run tests\n", "swift test --parallel\n", "\n", "ok\n"],
                    "A thin blank line separates the input from the output")
            let input = try #require(CRFixture.range(of: "swift test", in: rendered))
            #expect(CRFixture.color(in: rendered, at: input.location) == NSColor.secondaryLabelColor)
            let output = try #require(CRFixture.range(of: "ok", in: rendered))
            #expect(CRFixture.color(in: rendered, at: output.location) == NSColor.labelColor)
            #expect(CRFixture.font(in: rendered, at: output.location) == ChatRenderer.mono)
        }

        @Test func inputThatContinuesTheTitleShowsOnlyTheRest() {
            let rendered = card(CRFixture.call(title: "cat a.txt", input: "cat a.txt\n| head -5"))
            #expect(rendered.string == "\n✓  cat a.txt\n| head -5\n\n")
        }

        @Test(arguments: [
            ("```\nhello\n```", ["hello"]),
            ("```swift\nlet a = 1\n```\n", ["let a = 1"]),
            ("plain\n```", ["plain"]),
            ("a\n```\nb", ["a", "```", "b"]),
            ("\n\nspaced\n\n", ["spaced"]),
        ] as [(String, [String])])
        func outputLosesItsFencesAndSurroundingBlankLines(output: String, shown: [String]) {
            let rendered = card(CRFixture.call(title: "t", output: output))
            let body = shown.map { $0 + "\n" }.joined()
            #expect(rendered.string == "\n✓  t\n" + body + "\n")
        }

        @Test(.tags(.edgeCase), arguments: ["```\n```", "```", "\n\n"])
        func outputOfOnlyFencesOrNewlinesShowsNoBody(output: String) {
            #expect(card(CRFixture.call(title: "t", output: output)).string == "\n✓  t\n\n")
        }

        @Test func eightOutputLinesFitWithoutALink() {
            let rendered = card(CRFixture.call(title: "t", output: CRFixture.lines(8)))
            #expect(CRFixture.blockRuns(rendered).count == 9)
            #expect(CRFixture.linkCount(in: rendered) == 0)
        }

        @Test(arguments: [(9, "Show 1 more line"), (10, "Show 2 more lines"), (30, "Show 22 more lines")])
        func collapsedOutputShowsEightLinesThenAShowMoreLink(lineCount: Int, linkTitle: String) throws {
            let rendered = card(CRFixture.call(title: "t", output: CRFixture.lines(lineCount)))
            let expected = ["✓  t\n"] + (1...8).map { "line \($0)\n" } + [linkTitle + "\n"]
            #expect(CRFixture.blockRuns(rendered).map(\.text) == expected)
            let link = try #require(CRFixture.range(of: linkTitle, in: rendered))
            let toggle = ChatRenderer.toggleURL("tool-c1")
            #expect(CRFixture.link(in: rendered, at: link.location) == toggle)
        }

        @Test func expandedOutputShowsEveryLineAndAShowLessLink() {
            let rendered = card(CRFixture.call(title: "t", output: CRFixture.lines(10)), expanded: true)
            let expected = ["✓  t\n"] + (1...10).map { "line \($0)\n" } + ["Show less\n"]
            #expect(CRFixture.blockRuns(rendered).map(\.text) == expected)
        }

        @Test(.tags(.edgeCase))
        func expandedOutputStopsAtFourHundredLines() {
            let rendered = card(CRFixture.call(title: "t", output: CRFixture.lines(450)), expanded: true)
            let runs = CRFixture.blockRuns(rendered)
            #expect(runs.count == 402, "Title, 400 lines and the Show less link")
            #expect(rendered.string.contains("\nline 400\n"))
            #expect(rendered.string.contains("\nline 401\n") == false)
            #expect(runs.last?.text == "Show less\n")
        }

        @Test func hiddenInputAndOutputLinesAddUp() {
            let call = CRFixture.call(title: "script", output: CRFixture.lines(10), input: CRFixture.lines(5, prefix: "i"))
            let runs = CRFixture.blockRuns(card(call))
            #expect(runs.count == 14, "Title, 3 input lines, a separator, 8 output lines and the link")
            #expect(runs.last?.text == "Show 4 more lines\n", "2 hidden input lines plus 2 hidden output lines")
        }

        @Test func diffShowsItsPathThenRemovedAndAddedLines() throws {
            let diff = ChatItem.Diff(path: "/repo/Sources/App.swift", oldText: "a\nb", newText: "a\nc")
            let rendered = card(CRFixture.call(title: "Edit file", kind: "edit", diffs: [diff]))
            #expect(rendered.string == "\n✓  Edit file\n/repo/Sources/App.swift\n- a\n- b\n+ a\n+ c\n\n")
            let path = try #require(CRFixture.range(of: "/repo", in: rendered))
            #expect(CRFixture.color(in: rendered, at: path.location) == NSColor.secondaryLabelColor)
            let removed = try #require(CRFixture.range(of: "- b", in: rendered))
            #expect(CRFixture.color(in: rendered, at: removed.location) == NSColor.systemRed)
            let added = try #require(CRFixture.range(of: "+ c", in: rendered))
            #expect(CRFixture.color(in: rendered, at: added.location) == NSColor.systemGreen)
        }

        @Test(arguments: ["Edit App.swift", "Edit /repo/Sources/App.swift"])
        func diffPathIsLeftOutWhenTheTitleNamesTheFile(title: String) {
            let diff = ChatItem.Diff(path: "/repo/Sources/App.swift", oldText: "a", newText: "b")
            let rendered = card(CRFixture.call(title: title, kind: "edit", diffs: [diff]))
            #expect(rendered.string == "\n✓  \(title)\n- a\n+ b\n\n")
        }

        @Test func newFileDiffHasOnlyAddedLines() {
            let diff = ChatItem.Diff(path: "/x/new.txt", oldText: nil, newText: "hello\nworld")
            let rendered = card(CRFixture.call(title: "Write", kind: "write", diffs: [diff]))
            #expect(rendered.string == "\n✓  Write\n/x/new.txt\n+ hello\n+ world\n\n")
        }

        @Test func longDiffIsCutAtTwelveLines() {
            let diff = ChatItem.Diff(path: "/x/new.txt", oldText: nil, newText: CRFixture.lines(15))
            let rendered = card(CRFixture.call(title: "Write /x/new.txt", kind: "write", diffs: [diff]))
            let expected = ["✓  Write /x/new.txt\n"] + (1...12).map { "+ line \($0)\n" } + ["Show 3 more lines\n"]
            #expect(CRFixture.blockRuns(rendered).map(\.text) == expected)
        }

        @Test func expandedDiffShowsEveryLine() {
            let diff = ChatItem.Diff(path: "/x/new.txt", oldText: nil, newText: CRFixture.lines(15))
            let rendered = card(CRFixture.call(title: "Write /x/new.txt", kind: "write", diffs: [diff]), expanded: true)
            let expected = ["✓  Write /x/new.txt\n"] + (1...15).map { "+ line \($0)\n" } + ["Show less\n"]
            #expect(CRFixture.blockRuns(rendered).map(\.text) == expected)
        }

        @Test func imagesFollowTheCardOutsideItsBlock() throws {
            let png = try CRFixture.png(width: 8, height: 8)
            let rendered = card(CRFixture.call(title: "Read", kind: "read", images: [png]))
            #expect(rendered.string == "\n✓  Read\n\u{FFFC}\n\n")
            let mark = try #require(CRFixture.range(of: "\u{FFFC}", in: rendered))
            let attachment = try #require(CRFixture.value(.attachment, in: rendered, at: mark.location) as? ImageAttachment)
            #expect(attachment.data == png)
            #expect(CRFixture.hasBlock(in: rendered, at: mark.location) == false)
        }

        @Test(.tags(.edgeCase))
        func unreadableImagesAreSkipped() {
            let rendered = card(CRFixture.call(title: "Read", kind: "read", images: [Data("not an image".utf8)]))
            #expect(rendered.string == "\n✓  Read\n\n")
        }

        private func card(_ call: ChatItem.ToolCall, expanded: Bool = false) -> NSAttributedString {
            ChatRenderer.render(.tool(call), expanded: expanded)
        }
    }

    // MARK: - Tool groups

    @MainActor
    struct ToolGroups {
        @Test func collapsedGroupIsOneSummaryLineThatToggles() {
            let rendered = ChatRenderer.render(.toolGroup([CRFixture.call(id: "c1", title: "git status")]), expanded: false)
            #expect(rendered.string == "\nRan git status  ›\n\n")
            let toggle = ChatRenderer.toggleURL("group-c1")
            #expect(CRFixture.link(in: rendered, at: 1) == toggle)
            #expect(CRFixture.toolTip(in: rendered, at: 1) == "Show the tool calls")
            #expect(CRFixture.color(in: rendered, at: 1) == NSColor.secondaryLabelColor)
            #expect(CRFixture.blockRuns(rendered).isEmpty, "A collapsed group shows no cards")
        }

        @Test func expandedGroupListsACardPerCall() {
            let calls = [CRFixture.call(id: "c1", title: "git status"), CRFixture.call(id: "c2", title: "git diff")]
            let rendered = ChatRenderer.render(.toolGroup(calls), expanded: true)
            #expect(rendered.string == "\nRan 2 commands  ⌄\n\n✓  git status\n\n\n✓  git diff\n\n\n")
            #expect(CRFixture.toolTip(in: rendered, at: 1) == "Hide the tool calls")
            let runs = CRFixture.blockRuns(rendered)
            #expect(runs.map(\.text) == ["✓  git status\n", "✓  git diff\n"])
            #expect(runs.map(\.position) == [.single, .single], "Each call is its own card")
        }

        @Test func linkUsesTheFirstCallsID() {
            let calls = [CRFixture.call(id: "first"), CRFixture.call(id: "second")]
            let rendered = ChatRenderer.render(.toolGroup(calls), expanded: false)
            let toggle = ChatRenderer.toggleURL("group-first")
            #expect(CRFixture.link(in: rendered, at: 1) == toggle)
        }

        @Test(arguments: [
            (["failed"], "  · failed"),
            (["completed", "failed"], "  · 1 failed"),
            (["failed", "failed"], "  · 2 failed"),
            (["failed", "completed", "failed"], "  · 2 failed"),
        ] as [([String], String)])
        func failedCallsAreCountedInRed(statuses: [String], note: String) throws {
            let calls = statuses.enumerated().map { CRFixture.call(id: "c\($0.offset)", title: "x", status: $0.element) }
            let rendered = ChatRenderer.render(.toolGroup(calls), expanded: false)
            #expect(rendered.string.hasSuffix("›" + note + "\n\n"))
            let range = try #require(CRFixture.range(of: note, in: rendered))
            #expect(CRFixture.color(in: rendered, at: range.location) == NSColor.systemRed)
            #expect(CRFixture.link(in: rendered, at: range.location) == nil, "Only the summary toggles the group")
        }

        @Test func noFailureNoteWhenNothingFailed() {
            let calls = [CRFixture.call(id: "c1", status: "completed"), CRFixture.call(id: "c2", status: "pending")]
            let rendered = ChatRenderer.render(.toolGroup(calls), expanded: false)
            #expect(rendered.string.contains("failed") == false)
        }

        @Test(arguments: ["pending", "in_progress"])
        func anUnfinishedCallPutsTheSummaryInThePresentTense(status: String) {
            let calls = [CRFixture.call(id: "c1", status: "completed"), CRFixture.call(id: "c2", status: status)]
            let rendered = ChatRenderer.render(.toolGroup(calls), expanded: false)
            #expect(rendered.string == "\nRunning 2 commands…  ›\n\n")
        }

        @Test func cardsAskWhetherTheyAreOpenByToolID() {
            let calls = [CRFixture.call(id: "c1", output: CRFixture.lines(10)),
                         CRFixture.call(id: "c2", output: CRFixture.lines(10))]
            var asked: [String] = []
            let rendered = ChatRenderer.render(.toolGroup(calls), expanded: true) { id in
                asked.append(id)
                return id == "tool-c2"
            }
            #expect(asked == ["tool-c1", "tool-c2"], "Each card asks by the same tool-<id> its Show more link toggles")
            #expect(rendered.string.contains("Show 2 more lines"), "c1 stays collapsed")
            #expect(rendered.string.contains("Show less"), "c2 is open")
        }

        @Test func collapsedGroupNeverAsksAboutItsCards() {
            var asked: [String] = []
            _ = ChatRenderer.render(.toolGroup([CRFixture.call(id: "c1")]), expanded: false) { id in
                asked.append(id)
                return true
            }
            #expect(asked.isEmpty, "A collapsed group renders no cards, so it has nothing to ask")
        }
    }

    // MARK: - Group summaries

    /// A one-call summary case: the call's kind, title and input, whether it's running, and the line.
    struct SummaryCase: Sendable, CustomTestStringConvertible {
        let kind: String
        var title = ""
        var input = ""
        var running = false
        let expected: String

        var testDescription: String { "\(kind)\(running ? " (running)" : ""): \(expected.debugDescription)" }

        static let singleCalls: [SummaryCase] = [
            // Commands: the command, cut to 45 characters past 48, or to its first line.
            SummaryCase(kind: "execute", title: "git status", expected: "Ran git status"),
            SummaryCase(kind: "execute", title: "git status", running: true, expected: "Running git status"),
            SummaryCase(kind: "bash", title: "Run the test suite", input: "swift test", expected: "Ran swift test"),
            SummaryCase(kind: "Bash", title: "`ls -la`", expected: "Ran ls -la"),
            SummaryCase(kind: "BashOutput", title: "tail -f log", expected: "Ran tail -f log"),
            SummaryCase(kind: "execute", expected: "Ran a command"),
            SummaryCase(kind: "execute", running: true, expected: "Running a command"),
            SummaryCase(kind: "execute", title: "cd app\nmake", expected: "Ran cd app…"),
            SummaryCase(kind: "execute", input: String(repeating: "a", count: 48),
                        expected: "Ran " + String(repeating: "a", count: 48)),
            SummaryCase(kind: "execute", input: String(repeating: "a", count: 49),
                        expected: "Ran " + String(repeating: "a", count: 45) + "…"),
            // Reads and edits: the file name.
            SummaryCase(kind: "read", title: "Read file", input: "/Users/me/app/Sources/main.swift",
                        expected: "Read main.swift"),
            SummaryCase(kind: "read", title: "Read file", input: "/Users/me/app/Sources/main.swift", running: true,
                        expected: "Reading main.swift"),
            SummaryCase(kind: "read", input: "/Users/me/app/Sources/", expected: "Read Sources"),
            SummaryCase(kind: "notebookread", input: "/nb/analysis.ipynb", expected: "Read analysis.ipynb"),
            SummaryCase(kind: "read", expected: "Read a file"),
            SummaryCase(kind: "edit", input: "/a/b/c.txt", expected: "Edited c.txt"),
            SummaryCase(kind: "edit", input: "/a/b/c.txt", running: true, expected: "Editing c.txt"),
            SummaryCase(kind: "write", input: "/x/new.md", expected: "Edited new.md"),
            SummaryCase(kind: "delete", input: "/x/old.md", expected: "Edited old.md"),
            SummaryCase(kind: "move", input: "/x/moved.md", expected: "Edited moved.md"),
            SummaryCase(kind: "MultiEdit", input: "/x/m.swift", expected: "Edited m.swift"),
            SummaryCase(kind: "notebookedit", input: "/nb/a.ipynb", expected: "Edited a.ipynb"),
            SummaryCase(kind: "edit", expected: "Edited a file"),
            // Searches: the pattern, cut to 37 characters past 40.
            SummaryCase(kind: "search", input: "TODO", expected: "Searched for TODO"),
            SummaryCase(kind: "grep", input: "TODO", running: true, expected: "Searching for TODO"),
            SummaryCase(kind: "glob", input: "**/*.swift", expected: "Searched for **/*.swift"),
            SummaryCase(kind: "ls", input: "/tmp", expected: "Searched for /tmp"),
            SummaryCase(kind: "grep", expected: "Searched"),
            SummaryCase(kind: "grep", input: String(repeating: "b", count: 40),
                        expected: "Searched for " + String(repeating: "b", count: 40)),
            SummaryCase(kind: "grep", input: String(repeating: "b", count: 41),
                        expected: "Searched for " + String(repeating: "b", count: 37) + "…"),
            // Fetches: the host.
            SummaryCase(kind: "fetch", input: "https://example.com/docs/page", expected: "Fetched example.com"),
            SummaryCase(kind: "webfetch", input: "https://docs.swift.org/x", running: true,
                        expected: "Fetching docs.swift.org"),
            SummaryCase(kind: "fetch", expected: "Fetched a page"),
            SummaryCase(kind: "websearch", input: "swift testing", expected: "Fetched a page"),
            // Anything else: its title (or kind), cut to 57 characters past 60, never a verb.
            SummaryCase(kind: "think", title: "Planning next steps", expected: "Planning next steps"),
            SummaryCase(kind: "think", title: "Planning next steps", running: true, expected: "Planning next steps"),
            SummaryCase(kind: "think", expected: "Think"),
            SummaryCase(kind: "mcp", title: "`lookup` call", input: "ignored", expected: "lookup call"),
            SummaryCase(kind: "task", title: String(repeating: "c", count: 60), expected: String(repeating: "c", count: 60)),
            SummaryCase(kind: "task", title: String(repeating: "c", count: 61),
                        expected: String(repeating: "c", count: 57) + "…"),
        ]
    }

    @MainActor
    struct GroupSummaries {
        @Test(arguments: ChatRendererTests.SummaryCase.singleCalls)
        func oneCallReadsAsAVerbAndWhatItActedOn(testCase: ChatRendererTests.SummaryCase) {
            let call = CRFixture.call(title: testCase.title, kind: testCase.kind, input: testCase.input)
            #expect(ChatRenderer.groupSummary([call], running: testCase.running) == testCase.expected)
        }

        /// Each verb's phrase, listed the way the locale lists things ("Ran a command and read 2 files").
        @Test(arguments: [
            (["execute", "execute"], false, ["Ran 2 commands"]),
            (["execute", "read", "read"], false, ["Ran a command", "read 2 files"]),
            (["read", "execute", "read"], false, ["Read 2 files", "ran a command"]),
            (["grep", "glob"], false, ["Searched 2 times"]),
            (["grep", "read"], false, ["Searched once", "read a file"]),
            (["edit", "write", "multiedit"], false, ["Edited 3 files"]),
            (["fetch", "websearch"], false, ["Fetched 2 pages"]),
            (["think", "task"], false, ["Used 2 tools"]),
            (["Bash", "execute"], false, ["Ran 2 commands"]),
            (["read", "grep", "edit", "fetch", "think", "execute"], false,
             ["Read a file", "searched once", "edited a file", "fetched a page", "used a tool", "ran a command"]),
            (["execute", "read"], true, ["Running a command", "reading a file"]),
            (["execute", "execute", "edit"], true, ["Running 2 commands", "editing a file"]),
        ] as [([String], Bool, [String])])
        func severalCallsAreCountedPerVerbInFirstSeenOrder(kinds: [String], running: Bool, phrases: [String]) {
            let calls = kinds.enumerated().map { CRFixture.call(id: "c\($0.offset)", title: "ignored", kind: $0.element) }
            #expect(ChatRenderer.groupSummary(calls, running: running) == phrases.formatted() + (running ? "…" : ""))
        }

        @Test func twoVerbsAreJoinedByAnd() {
            let calls = [CRFixture.call(id: "c0", kind: "execute"), CRFixture.call(id: "c1", kind: "read")]
            #expect(ChatRenderer.groupSummary(calls, running: false).hasPrefix("Ran a command and read a file"))
        }

        @Test(.tags(.edgeCase), arguments: [(false, ""), (true, "…")])
        func noCallsSummarizeAsNothing(running: Bool, expected: String) {
            #expect(ChatRenderer.groupSummary([], running: running) == expected)
        }

        @Test(.tags(.edgeCase), arguments: ["ls\n", "\nls"])
        func newlinesAroundACommandAreNotACut(input: String) {
            let summary = ChatRenderer.groupSummary([CRFixture.call(kind: "execute", input: input)], running: false)
            #expect(summary == "Ran ls")
        }
    }

    // MARK: - Plans

    @MainActor
    struct Plans {
        @Test func entriesListUnderAPlanHeadingOnACard() {
            let entries = [ChatItem.PlanEntry(content: "Write tests", status: "completed"),
                           ChatItem.PlanEntry(content: "Run them", status: "in_progress"),
                           ChatItem.PlanEntry(content: "Ship", status: "pending")]
            let rendered = ChatRenderer.render(.plan(id: UUID(), entries: entries), expanded: false)
            #expect(rendered.string == "\nPlan\n☑  Write tests\n◐  Run them\n☐  Ship\n\n")
            let runs = CRFixture.blockRuns(rendered)
            #expect(runs.map(\.kind) == [.card, .card, .card, .card])
            #expect(runs.map(\.position) == [.first, .middle, .middle, .last])
        }

        @Test(arguments: [("completed", "☑"), ("in_progress", "◐"), ("pending", "☐"), ("", "☐"), ("blocked", "☐")])
        func statusPicksTheMark(status: String, mark: String) {
            let entry = ChatItem.PlanEntry(content: "Task", status: status)
            let rendered = ChatRenderer.render(.plan(id: UUID(), entries: [entry]), expanded: false)
            #expect(rendered.string == "\nPlan\n\(mark)  Task\n\n")
        }

        @Test func completedEntriesAreDimmed() throws {
            let entries = [ChatItem.PlanEntry(content: "Done", status: "completed"),
                           ChatItem.PlanEntry(content: "Todo", status: "pending")]
            let rendered = ChatRenderer.render(.plan(id: UUID(), entries: entries), expanded: false)
            let done = try #require(CRFixture.range(of: "Done", in: rendered))
            #expect(CRFixture.color(in: rendered, at: done.location) == NSColor.secondaryLabelColor)
            let todo = try #require(CRFixture.range(of: "Todo", in: rendered))
            #expect(CRFixture.color(in: rendered, at: todo.location) == NSColor.labelColor)
        }

        @Test(.tags(.edgeCase))
        func emptyPlanIsJustItsHeading() {
            let rendered = ChatRenderer.render(.plan(id: UUID(), entries: []), expanded: false)
            #expect(rendered.string == "\nPlan\n\n")
            #expect(CRFixture.blockRuns(rendered).map(\.position) == [.single])
        }
    }

    // MARK: - File changes

    @MainActor
    struct FileChanges {
        @Test func changedFilesListTheirNamesThenAnUndoLink() throws {
            let item = ChatItem.fileChanges(turn: "turn-1", paths: ["/repo/Sources/App.swift"], restored: false)
            let rendered = ChatRenderer.render(item, expanded: false)
            #expect(rendered.string == "\n✎  Changed 1 file: App.swift   Undo\n\n")
            let undo = try #require(CRFixture.range(of: "Undo", in: rendered))
            let expected = ChatRenderer.undoURL("turn-1")
            #expect(CRFixture.link(in: rendered, at: undo.location) == expected)
            #expect(CRFixture.color(in: rendered, at: undo.location) == NSColor.controlAccentColor)
            CRFixture.verifyFace(CRFixture.font(in: rendered, at: undo.location),
                                 matches: .role(.meta, weight: .semibold))
            #expect(CRFixture.link(in: rendered, at: 1) == nil, "Only Undo is a link")
        }

        /// Listed the way the locale lists things ("f1.swift and f2.swift").
        @Test(arguments: [
            (2, ["f1.swift", "f2.swift"]),
            (4, ["f1.swift", "f2.swift", "f3.swift", "f4.swift"]),
            (5, ["f1.swift", "f2.swift", "f3.swift", "f4.swift", "1 more"]),
            (7, ["f1.swift", "f2.swift", "f3.swift", "f4.swift", "3 more"]),
        ])
        func upToFourNamesAreListed(count: Int, names: [String]) {
            let paths = (1...count).map { "/repo/Sources/f\($0).swift" }
            let rendered = ChatRenderer.render(.fileChanges(turn: "t", paths: paths, restored: false), expanded: false)
            #expect(rendered.string == "\n✎  Changed \(count) files: \(names.formatted())   Undo\n\n")
        }

        @Test func toolTipListsEveryPath() {
            let paths = (1...6).map { "/repo/Sources/f\($0).swift" }
            let rendered = ChatRenderer.render(.fileChanges(turn: "t", paths: paths, restored: false), expanded: false)
            #expect(CRFixture.toolTip(in: rendered, at: 1) == paths.joined(separator: "\n"))
        }

        @Test(arguments: [(1, "1 file"), (3, "3 files")])
        func restoredChangesSayWhatWasPutBack(count: Int, noun: String) {
            let paths = (1...count).map { "/repo/f\($0).swift" }
            let rendered = ChatRenderer.render(.fileChanges(turn: "t", paths: paths, restored: true), expanded: false)
            #expect(rendered.string == "\n↺  Restored \(noun) to before this message\n\n")
            #expect(CRFixture.linkCount(in: rendered) == 0, "Nothing left to undo")
        }
    }

    // MARK: - Notices

    @MainActor
    struct Notices {
        @Test(arguments: [true, false])
        func noticeIsOneSmallLineBetweenSpacers(isError: Bool) {
            let rendered = ChatRenderer.render(.notice(id: UUID(), text: "Connection lost", isError: isError), expanded: false)
            #expect(rendered.string == (isError ? "\n⚠︎  Connection lost\n\n" : "\nConnection lost\n\n"),
                    "Errors are marked by more than color")
            CRFixture.verifyFace(CRFixture.font(in: rendered, at: 1), matches: .role(.meta))
            #expect(CRFixture.blockRuns(rendered).isEmpty)
        }

        @Test(arguments: [(true, "red"), (false, "secondary")])
        func errorsAreRedAndOtherNoticesDim(isError: Bool, colorName: String) {
            let rendered = ChatRenderer.render(.notice(id: UUID(), text: "Note", isError: isError), expanded: false)
            let expected: NSColor = colorName == "red" ? .systemRed : .secondaryLabelColor
            #expect(CRFixture.color(in: rendered, at: 1) == expected)
        }
    }

    // MARK: - Images

    @MainActor
    struct Images {
        @Test func imageIsAnAttachmentOnItsOwnLine() throws {
            let data = try CRFixture.png(width: 40, height: 20)
            let natural = try #require(NSImage(data: data)?.size)
            let rendered = ChatRenderer.render(.image(id: UUID(), data: data), expanded: false)
            #expect(rendered.string == "\u{FFFC}\n")
            let attachment = try #require(CRFixture.value(.attachment, in: rendered, at: 0) as? ImageAttachment)
            #expect(attachment.data == data, "The original bytes are kept for Quick Look and drag-out")
            #expect(attachment.bounds.size == natural, "An image narrower than the cap keeps its size")
            let style = try #require(CRFixture.paragraphStyle(in: rendered, at: 0))
            #expect(style.paragraphSpacingBefore == 6)
            #expect(style.paragraphSpacing == 4)
        }

        @Test func wideImageIsScaledToTheMaximumWidth() throws {
            let data = try CRFixture.png(width: 1040, height: 260)
            let natural = try #require(NSImage(data: data)?.size)
            try #require(natural.width > ChatRenderer.maxImageWidth, "The fixture must be wider than the cap")
            let rendered = ChatRenderer.render(.image(id: UUID(), data: data), expanded: false)
            let attachment = try #require(CRFixture.value(.attachment, in: rendered, at: 0) as? ImageAttachment)
            let scale = ChatRenderer.maxImageWidth / natural.width
            #expect(abs(attachment.bounds.width - ChatRenderer.maxImageWidth) < 0.001)
            #expect(abs(attachment.bounds.height - natural.height * scale) < 0.001, "The aspect ratio is kept")
        }

        @Test(.tags(.edgeCase), arguments: [Data(), Data("not an image".utf8)])
        func unreadableImageRendersNothing(data: Data) {
            #expect(ChatRenderer.render(.image(id: UUID(), data: data), expanded: false).length == 0)
        }
    }

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

        @Test func narrowTableIsAGridOnACard() throws {
            let rendered = ChatRenderer.markdown(grid)
            let runs = CRFixture.blockRuns(rendered)
            try #require(runs.count == 3)
            #expect(runs[0].text == "a\tb\n")
            #expect(runs[2].text == "1\t2\n")
            #expect(runs.map(\.kind) == [.card, .card, .card])
            #expect(runs.map(\.position) == [.first, .middle, .last])
            #expect(rendered.string.hasPrefix("\n"), "A spacer above the card")
            #expect(rendered.string.hasSuffix("1\t2\n\n"), "And one below")
        }

        @Test func aRuleSeparatesTheHeaderFromTheRows() throws {
            let rendered = ChatRenderer.markdown(grid)
            let runs = CRFixture.blockRuns(rendered)
            try #require(runs.count == 3)
            let rule = runs[1].text
            let dashes = rule.dropLast()
            let onlyDashes = dashes.allSatisfy { $0 == "─" }
            #expect(rule.hasSuffix("\n"))
            #expect(dashes.isEmpty == false)
            #expect(onlyDashes, "The rule is a row of box-drawing dashes")
            #expect(CRFixture.color(in: rendered, at: runs[1].range.location) == NSColor.tertiaryLabelColor)
        }

        @Test func headerIsSemiboldAndRowsRegular() throws {
            let rendered = ChatRenderer.markdown(grid)
            let runs = CRFixture.blockRuns(rendered)
            try #require(runs.count == 3)
            CRFixture.verifyFace(CRFixture.font(in: rendered, at: runs[0].range.location),
                                 matches: .role(.bodyEmphasis))
            CRFixture.verifyFace(CRFixture.font(in: rendered, at: runs[2].range.location),
                                 matches: .role(.body))
        }

        @Test func separatorColonsAlignTheColumns() throws {
            let rendered = ChatRenderer.markdown("| a | b | c |\n|:--|--:|:--:|\n| 1 | 2 | 3 |")
            let header = try #require(CRFixture.blockRuns(rendered).first)
            let style = try #require(CRFixture.paragraphStyle(in: rendered, at: header.range.location))
            #expect(style.tabStops.map(\.alignment) == [.right, .center],
                    "The first column starts the line; every other column gets a tab stop")
            #expect(style.lineBreakMode == .byTruncatingTail)
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

        @Test func headerOnlyTableIsTheHeaderAndItsRule() {
            let runs = CRFixture.blockRuns(ChatRenderer.markdown("| a | b |\n|---|---|"))
            #expect(runs.count == 2)
            #expect(runs.first?.text == "a\tb\n")
            #expect(runs.map(\.position) == [.first, .last])
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

        @Test(arguments: ["|---|---|", "| --- | --- |", "|:--|--:|", "| :---: | :---: |", "|--|--|", "  |---|---|  "])
        func separatorRowsThatMakeATable(separator: String) {
            let runs = CRFixture.blockRuns(ChatRenderer.markdown("| a | b |\n\(separator)\n| 1 | 2 |"))
            #expect(runs.map(\.text).first == "a\tb\n")
            #expect(runs.map(\.text).last == "1\t2\n")
            #expect(runs.count == 3)
        }

        @Test(.tags(.edgeCase), arguments: ["|-|-|", "| x | y |", "|===|===|"])
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
            #expect(CRFixture.blockRuns(rendered).count == 3)
            #expect(rendered.string.hasSuffix("1\n\nafter\n"))
            let after = try #require(CRFixture.range(of: "after", in: rendered))
            #expect(CRFixture.hasBlock(in: rendered, at: after.location) == false)
        }

        @Test func wideTableBecomesOneRecordPerRow() throws {
            let rendered = ChatRenderer.markdown("| Name | Notes |\n|---|---|\n| alpha | \(Self.long) |\n| beta | short |")
            let runs = CRFixture.blockRuns(rendered)
            #expect(runs.map(\.text) == ["alpha\n", "Notes\t\(Self.long)\n", "\n", "beta\n", "Notes\tshort\n"])
            #expect(runs.map(\.position) == [.first, .middle, .middle, .middle, .last])
            #expect(rendered.string.contains("Name") == false, "The first column heads each record instead of labelling it")
            let title = try #require(runs.first)
            CRFixture.verifyFace(CRFixture.font(in: rendered, at: title.range.location),
                                 matches: .role(.bodyEmphasis))
            let label = try #require(CRFixture.range(of: "Notes", in: rendered))
            #expect(CRFixture.color(in: rendered, at: label.location) == NSColor.secondaryLabelColor)
        }

        @Test func longColumnHeadingsStackAboveTheirValues() {
            let heading = "A rather long column heading that has to wrap"
            let rendered = ChatRenderer.markdown("| Name | \(heading) |\n|---|---|\n| alpha | short value |")
            #expect(CRFixture.blockRuns(rendered).map(\.text) == ["alpha\n", "\(heading)\u{2028}short value\n"])
        }

        @Test(arguments: ["one<br>two", "one<br/>two", "one<BR />two"])
        func lineBreaksInCellsForceRecords(cell: String) {
            let rendered = ChatRenderer.markdown("| Key | Value |\n|---|---|\n| k | \(cell) |")
            #expect(CRFixture.blockRuns(rendered).map(\.text) == ["k\n", "Value\tone\u{2028}two\n"])
        }

        @Test func emptyValuesAreLeftOutOfRecords() {
            let rendered = ChatRenderer.markdown("| Name | Notes | Extra |\n|---|---|---|\n| alpha | \(Self.long) | |")
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
            #expect(ChatRenderer.maxImageWidth == 520)
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
