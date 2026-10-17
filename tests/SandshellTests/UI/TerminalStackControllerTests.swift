import AppKit
import Testing
@testable import Sandshell

// Tests for two of a pane's decisions: which ⌘-keys it takes from a focused
// terminal before the terminal sees them (`TerminalStackController
// .terminalKeyIntercept(for:)`), and how a draft waiting for its chat to start
// takes in another (`ChatDraft.add`). Key events are built, never posted; the
// drafts' files are paths under `/srv`, which doesn't exist and isn't read.

@MainActor
struct TerminalKeyInterceptTests {
    typealias Intercept = TerminalStackController.TerminalKeyIntercept

    /// A key-down as AppKit builds it: `characters` with the modifiers
    /// applied, `charactersIgnoringModifiers` without (Option and Control).
    private func keyDown(_ key: String, typing characters: String? = nil,
                         _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: characters ?? key,
                                      charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
    }

    @Test("Plain ⌘V and ⌘F are the pane's", arguments: [("v", .paste), ("f", .search)] as [(String, Intercept)])
    func plainCommand(key: String, expected: Intercept) throws {
        let event = try keyDown(key, .command)
        #expect(TerminalStackController.terminalKeyIntercept(for: event) == expected)
    }

    @Test("Caps Lock doesn't take ⌘F or ⌘V from the pane", arguments: [("v", .paste), ("f", .search)] as [(String, Intercept)])
    func capsLockOn(key: String, expected: Intercept) throws {
        let event = try keyDown(key, [.command, .capsLock])
        #expect(TerminalStackController.terminalKeyIntercept(for: event) == expected)
    }

    @Test("⌥⌘F (Filter Sessions), ⌃⌘F (Full Screen) and other chords go on to the menu", arguments: [
        ("f", "ƒ", [.command, .option]),
        ("f", "\u{6}", [.command, .control]),
        ("f", "f", [.command, .option, .control]),
        ("v", "√", [.command, .option]),
        ("v", "\u{16}", [.command, .control]),
        ("f", "F", [.command, .shift]),
    ] as [(String, String, NSEvent.ModifierFlags)])
    func otherChords(key: String, characters: String, flags: NSEvent.ModifierFlags) throws {
        let event = try keyDown(key, typing: characters, flags)
        #expect(TerminalStackController.terminalKeyIntercept(for: event) == nil)
    }

    @Test("Other ⌘-keys, and V or F without ⌘, reach the terminal", arguments: [
        ("c", [.command]), ("w", [.command]), ("z", [.command]),
        ("v", []), ("f", []), ("f", [.option]), ("f", [.control]),
    ] as [(String, NSEvent.ModifierFlags)])
    func notIntercepted(key: String, flags: NSEvent.ModifierFlags) throws {
        let event = try keyDown(key, flags)
        #expect(TerminalStackController.terminalKeyIntercept(for: event) == nil)
    }
}

struct ChatDraftTests {
    private let notes = URL(filePath: "/srv/project/notes.md")
    private let diff = URL(filePath: "/srv/project/change.diff")

    @Test func aFileDroppedWhileTheChatStartsJoinsTheMessageWaitingToGo() {
        let pasted = ChatAttachment(kind: .image(data: Data([1, 2, 3]), mimeType: "image/png", name: "shot.png"))
        var draft = ChatDraft(text: "run the tests", urls: [], attachments: [pasted], send: true)
        draft.add(text: "", urls: [notes], send: false)
        #expect(draft.text == "run the tests")
        #expect(draft.urls == [notes])
        #expect(draft.attachments == [pasted])
        #expect(draft.send, "the message that was waiting still goes")
    }

    @Test func twoAsksBeforeTheChatStartsAreBothSent() {
        var draft = ChatDraft(text: "", urls: [], send: false)
        draft.add(text: "change this line", urls: [], send: true)
        draft.add(text: "and this one", urls: [diff], send: true)
        #expect(draft.text == "change this line\n\nand this one")
        #expect(draft.urls == [diff])
        #expect(draft.send)
    }

    @Test func filesForTheComposerStayADraft() {
        var draft = ChatDraft(text: "", urls: [notes], send: false)
        draft.add(text: "", urls: [diff], send: false)
        #expect(draft.text.isEmpty)
        #expect(draft.urls == [notes, diff])
        #expect(!draft.send)
    }

    @Test(.tags(.edgeCase), arguments: [("", "b", "b"), ("a", "", "a"), ("", "", "")])
    func anEmptyTextAddsNoBlankParagraph(first: String, second: String, expected: String) {
        var draft = ChatDraft(text: first, urls: [], send: false)
        draft.add(text: second, urls: [], send: false)
        #expect(draft.text == expected)
    }
}
