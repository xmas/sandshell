import Foundation
import Testing
@testable import Sandshell

/// The composer's pure logic: queued messages (order, edit, remove), walking
/// back through what was sent (↑/↓/⎋), and the `/command` ghost Tab takes.
struct ComposerHistoryTests {
    // MARK: Queue

    private static func queue(_ texts: String...) -> PromptQueue {
        var queue = PromptQueue()
        for text in texts { queue.append(text: text) }
        return queue
    }

    @Test func queuedMessagesKeepTheirOrder() {
        let queue = Self.queue("one", "two", "three")
        #expect(queue.items.map(\.text) == ["one", "two", "three"])
        #expect(Set(queue.items.map(\.id)).count == 3, "each has its own id")
    }

    @Test func removingOneKeepsTheOthersInOrder() throws {
        var queue = Self.queue("one", "two", "three")
        let two = try #require(queue.items.first { $0.text == "two" })
        let removed = queue.remove(two.id)
        #expect(removed == two)
        #expect(queue.items.map(\.text) == ["one", "three"])
    }

    @Test(.tags(.edgeCase))
    func removingOneThatsGoneDoesNothing() {
        var queue = Self.queue("one")
        #expect(queue.remove(UUID()) == nil)
        #expect(queue.items.map(\.text) == ["one"])
    }

    /// Edit takes it out; sending it again puts it at the back.
    @Test func anEditedMessageRequeuesLast() throws {
        var queue = Self.queue("one", "two", "three")
        let taken = queue.remove(queue.items[0].id)
        let one = try #require(taken)
        queue.append(text: one.text + " (edited)")
        #expect(queue.items.map(\.text) == ["two", "three", "one (edited)"])
    }

    @Test func theyGoTogetherInOrderAsOnePrompt() throws {
        let image = ChatAttachment(kind: .image(data: Data([1]), mimeType: "image/png", name: "a.png"))
        let file = ChatAttachment(kind: .file(URL(filePath: "/tmp/b.txt")))
        var queue = PromptQueue()
        queue.append(text: "first", attachments: [image])
        queue.append(text: "", attachments: [file])
        queue.append(text: "second")
        let taken = queue.takeAll()
        let all = try #require(taken)
        #expect(all.text == "first\n\nsecond", "blank texts add no gap")
        #expect(all.attachments == [image, file])
        #expect(queue.isEmpty)
        let again = queue.takeAll()
        #expect(again == nil)
    }

    @Test func aHeldBackMessageGoesFirst() {
        var queue = Self.queue("later")
        queue.prepend(text: "held")
        #expect(queue.items.map(\.text) == ["held", "later"])
    }

    // MARK: History

    @Test func upBringsBackTheLastSentThenEarlierOnes() {
        var history = ComposerHistory(sent: ["a", "b", "c"])
        #expect(history.older(current: "") == "c")
        #expect(history.older(current: "c") == "b")
        #expect(history.older(current: "b") == "a")
        #expect(history.older(current: "a") == nil, "nothing before the first")
        #expect(history.isShowingEntry("a"))
    }

    @Test func downWalksForwardThenBackToTheDraft() {
        var history = ComposerHistory(sent: ["a", "b"])
        _ = history.older(current: "")
        _ = history.older(current: "b")
        #expect(history.newer() == "b")
        #expect(history.newer() == "", "past the newest: the draft it started from")
        #expect(!history.isWalking)
        #expect(history.newer() == nil, "not walking: ↓ is the caret's")
    }

    @Test func escapePutsBackTheDraft() {
        var history = ComposerHistory(sent: ["a"])
        _ = history.older(current: "")
        #expect(history.cancel() == "")
        #expect(!history.isWalking)
        #expect(history.cancel() == nil)
    }

    @Test func anEditedEntryIsNoLongerTheEntry() {
        var history = ComposerHistory(sent: ["hello"])
        _ = history.older(current: "")
        #expect(history.isShowingEntry("hello"))
        #expect(!history.isShowingEntry("hello there"), "edited: the keys go back to the text")
        #expect(history.entries == ["hello"], "editing doesn't change the history")
    }

    @Test func blanksAndRepeatsAreSkipped() {
        let history = ComposerHistory(sent: ["a", "a", " ", "b", "a"])
        #expect(history.entries == ["a", "b", "a"])
    }

    @Test(.tags(.edgeCase))
    func nothingSentNothingToBringBack() {
        var history = ComposerHistory(sent: [])
        #expect(history.older(current: "") == nil)
        #expect(!history.isWalking)
    }

    @Test(arguments: [
        ("one line", 3, true, true),
        ("first\nsecond", 2, true, false),
        ("first\nsecond", 8, false, true),
        ("first\nsecond", 6, false, true),
        ("", 0, true, true),
    ])
    func arrowsWalkOnlyFromTheEdgeLines(text: String, caret: Int, first: Bool, last: Bool) {
        let at = NSRange(location: caret, length: 0)
        #expect(ComposerHistory.caretOnFirstLine(of: text, caret: at) == first)
        #expect(ComposerHistory.caretOnLastLine(of: text, caret: at) == last)
    }

    @Test(.tags(.edgeCase))
    func aSelectionIsntACaret() {
        let selection = NSRange(location: 0, length: 2)
        #expect(!ComposerHistory.caretOnFirstLine(of: "abc", caret: selection))
        #expect(!ComposerHistory.caretOnLastLine(of: "abc", caret: selection))
    }

    // MARK: Ghost

    private static let commands = ["compact", "context", "clear", "review"]

    @Test(arguments: [
        ("/co", "mpact"),     // the list's first match
        ("/CON", "text"),     // case doesn't matter; the typed case stays
        ("/r", "eview"),
        ("/review", nil),     // nothing left to add
        ("/x", nil),
        ("/", nil),           // the list shows them all; no one to pick
        ("co", nil),          // not a command
        ("/co mp", nil),      // past the command
    ] as [(String, String?)])
    func theGhostIsTheRestOfTheFirstMatch(text: String, ghost: String?) {
        #expect(CommandGhost.suffix(for: text, commands: Self.commands) == ghost)
    }

    @Test func theListsHighlightedCommandWins() {
        #expect(CommandGhost.suffix(for: "/co", commands: Self.commands, selected: "context") == "ntext")
    }

    @Test(.tags(.edgeCase))
    func aHighlightedCommandThatDoesntContinueIsNoGhost() {
        // The list also offers names that contain the text; Tab takes those, unghosted.
        #expect(CommandGhost.suffix(for: "/view", commands: Self.commands, selected: "review") == nil)
    }
}
