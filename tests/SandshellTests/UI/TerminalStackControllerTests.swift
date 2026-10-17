import AppKit
import Testing
@testable import Sandshell

// Tests for a pane's decisions: which ⌘-keys it takes from a focused terminal
// before the terminal sees them (`TerminalStackController
// .terminalKeyIntercept(for:)`), how a draft waiting for its chat to start
// takes in another (`ChatDraft`), and where dropped files end up
// (`materializeDroppedURLs`). Key events are built, never posted; the drafts'
// files are paths under `/srv`, which doesn't exist and isn't read.

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
    private let pasted = ChatAttachment(kind: .image(data: Data([1, 2, 3]), mimeType: "image/png", name: "shot.png"))

    @Test func aFileDroppedWhileAMessageWaitsGoesToTheComposerNotOutWithIt() {
        var draft = ChatDraft()
        draft.putFirst(text: "run the tests", attachments: [pasted])
        draft.add(text: "", urls: [notes], send: false)
        #expect(draft.message == ChatDraft.Part(text: "run the tests", attachments: [pasted]),
                "the message that was waiting still goes, as it was")
        #expect(draft.composer == ChatDraft.Part(urls: [notes]), "the file waits in the composer to be looked over")
    }

    @Test func textForTheComposerIsNeverSentWithAnAsk() {
        var draft = ChatDraft()
        draft.add(text: "a note to edit", urls: [notes], send: false)
        draft.add(text: "change this line", urls: [], send: true)
        #expect(draft.message == ChatDraft.Part(text: "change this line"))
        #expect(draft.composer == ChatDraft.Part(text: "a note to edit", urls: [notes]))
    }

    @Test func twoAsksBeforeTheChatStartsAreBothSent() {
        var draft = ChatDraft()
        draft.add(text: "change this line", urls: [], send: true)
        draft.add(text: "and this one", urls: [diff], send: true)
        #expect(draft.message == ChatDraft.Part(text: "change this line\n\nand this one", urls: [diff]))
        #expect(draft.composer.isEmpty)
    }

    @Test func filesForTheComposerStayADraft() {
        var draft = ChatDraft()
        draft.add(text: "", urls: [notes], send: false)
        draft.add(text: "", urls: [diff], send: false)
        #expect(draft.composer == ChatDraft.Part(urls: [notes, diff]))
        #expect(draft.message.isEmpty, "nothing to send")
    }

    @Test func aMessageQueuedInTheLastChatGoesAheadOfAsksSince() {
        var draft = ChatDraft()
        draft.add(text: "and this one", urls: [diff], send: true)
        draft.putFirst(text: "run the tests", attachments: [pasted])
        #expect(draft.message == ChatDraft.Part(text: "run the tests\n\nand this one", urls: [diff], attachments: [pasted]))
    }

    @Test(.tags(.edgeCase), arguments: [("", "b", "b"), ("a", "", "a"), ("", "", "")])
    func anEmptyTextAddsNoBlankParagraph(first: String, second: String, expected: String) {
        var part = ChatDraft.Part(text: first)
        part.add(text: second)
        #expect(part.text == expected)
    }
}

/// Files dropped or pasted into a session, copied into `.sbx/drops` of its
/// folder: a temp folder here, with files made for the test.
@MainActor @Suite(.tags(.fileSystem))
struct DroppedFilesTests {
    let root: URL

    init() throws {
        root = URL.temporaryDirectory.appending(path: "drops-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func file(_ name: String) throws -> URL {
        let url = root.appending(path: name)
        try Data("hello".utf8).write(to: url)
        return url
    }

    @Test func aDroppedFileIsCopiedWhereTheSandboxSeesIt() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try file("notes.md")
        let workdir = root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        var failures = 0
        let paths = TerminalStackController.materializeDroppedURLs([source], workdir: workdir.path(percentEncoded: false)) { _ in
            failures += 1
        }
        let copy = workdir.appending(path: ".sbx/drops/notes.md")
        #expect(paths == [copy.path(percentEncoded: false)])
        #expect(FileManager.default.contents(atPath: copy.path(percentEncoded: false)) == Data("hello".utf8))
        #expect(failures == 0)
    }

    @Test func withNoDropsFolderTheFilesKeepTheirHostPaths() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = [try file("notes.md"), try file("change.diff")]
        // The session's "folder" is a file, so .sbx/drops can't be made in it.
        let workdir = try file("not-a-folder")
        var failures = 0
        let paths = TerminalStackController.materializeDroppedURLs(sources, workdir: workdir.path(percentEncoded: false)) { _ in
            failures += 1
        }
        #expect(paths == sources.map(\.path), "the paths are still typed or attached")
        #expect(failures == 1, "said once")
    }

    @Test(.tags(.edgeCase)) func aFileThatIsGoneKeepsItsPathWithoutAWarning() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = root.appending(path: "gone.md")
        var failures = 0
        let paths = TerminalStackController.materializeDroppedURLs([gone], workdir: root.path(percentEncoded: false)) { _ in
            failures += 1
        }
        #expect(paths == [gone.path])
        #expect(failures == 0)
    }
}
