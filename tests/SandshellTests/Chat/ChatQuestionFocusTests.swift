#if DEBUG
import AppKit
import Testing
@testable import Sandshell

/// A window that says it's key (or not) without ever coming on screen.
@MainActor
private final class PretendKeyWindow: NSWindow {
    var pretendsKey = true
    override var isKeyWindow: Bool { pretendsKey }
}

/// A chat (never started) in an offscreen window, beside a text view that
/// stands in for whatever else could have the keyboard: a terminal in another
/// pane, a sidebar rename, the Files editor.
@MainActor
private struct ChatInWindow {
    let window = PretendKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: true)
    let session: ChatSession
    let chat: ChatSessionView
    let elsewhere = NSTextView(frame: NSRect(x: 0, y: 500, width: 700, height: 100))

    init(folder: URL) {
        session = ChatSession(title: "Claude", containerName: "test-sandbox", workdir: folder.path,
                              home: folder.path, mcpURL: nil)
        chat = ChatSessionView(session: session)
        chat.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        content.addSubview(chat)
        content.addSubview(elsewhere)
        window.isReleasedWhenClosed = false
        window.contentView = content
    }

    var keyboardIsElsewhere: Bool { window.firstResponder === elsewhere }

    /// A question with one optional text field (so it can be answered as is).
    static func question(_ id: Int = 1) -> AgentQuestion {
        AgentQuestion(rpcID: .number(Double(id)), message: "Anything else?", mode: .form,
                      fields: [AgentQuestion.Field(id: "note", title: "Note", detail: nil, kind: .text(secret: false),
                                                   required: false, companionOf: nil, defaultValue: nil)],
                      toolCallID: nil)
    }

    /// Type into a text field inside the question card (as clicking into its
    /// SwiftUI field would): the window's field editor gets the keys.
    func typeInTheCard() throws -> NSTextField {
        let host = try #require(chat.debugQuestionHost, "the question shows")
        let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 200, height: 22))
        host.addSubview(field)
        #expect(window.makeFirstResponder(field))
        return field
    }
}

/// Runs `body` with a chat in a window and a scratch folder, cleaned up after.
@MainActor
private func withChat(_ body: (ChatInWindow) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chat-focus-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let harness = ChatInWindow(folder: folder)
    defer {
        harness.window.close()
        try? FileManager.default.removeItem(at: folder)
    }
    try body(harness)
}

@MainActor
struct ChatQuestionFocusTests {
    @Test func questionTakesTheKeyboardFromTheComposer() throws {
        try withChat { h in
            h.chat.focusComposer()
            #expect(h.chat.debugComposerHasKeyboard)
            h.session.debugAsk(ChatInWindow.question())
            #expect(h.chat.debugQuestionHasKeyboard, "Return / 1–9 / Esc reach the card")
        }
    }

    /// e7q.33: a hidden chat's question (or one in a pane you're not typing in)
    /// doesn't take the keyboard, nor does its going away hand it to the composer.
    @Test(arguments: [true, false])
    func questionLeavesTheKeyboardWhereItIs(chatHidden: Bool) throws {
        try withChat { h in
            h.chat.isHidden = chatHidden
            #expect(h.window.makeFirstResponder(h.elsewhere))
            h.session.debugAsk(ChatInWindow.question())
            #expect(h.keyboardIsElsewhere)
            h.session.debugAsk(nil)
            #expect(h.keyboardIsElsewhere)
        }
    }

    /// e7q.34: asked while the window wasn't key, the question takes the
    /// keyboard when the window comes back — once.
    @Test func questionAskedWhileAwayTakesTheKeyboardOnReturn() throws {
        try withChat { h in
            h.chat.focusComposer()
            h.window.pretendsKey = false
            h.session.debugAsk(ChatInWindow.question())
            #expect(h.chat.debugComposerHasKeyboard, "nothing moves while the window isn't key")
            h.window.pretendsKey = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: h.window)
            #expect(h.chat.debugQuestionHasKeyboard)
            // Only that once: the next time the window is key, the keyboard
            // stays where it was left (here, nowhere in particular).
            #expect(h.window.makeFirstResponder(nil))
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: h.window)
            #expect(h.window.firstResponder === h.window)
        }
    }

    /// e7q.34: showing the chat (`focusComposer`) hands the keyboard to its open question.
    @Test func showingTheChatGivesTheQuestionTheKeyboard() throws {
        try withChat { h in
            h.chat.isHidden = true
            #expect(h.window.makeFirstResponder(h.elsewhere))
            h.session.debugAsk(ChatInWindow.question())
            h.chat.isHidden = false
            h.chat.focusComposer()
            #expect(h.chat.debugQuestionHasKeyboard)
            #expect(!h.chat.debugComposerHasKeyboard)
        }
    }

    /// The pane re-shows a chat on every refresh: typing in one of the card's
    /// fields keeps the keyboard there (the card itself would turn the next
    /// keys into picks, a skip, or a half-typed submit).
    @Test func focusingTheChatLeavesACardFieldBeingTypedIn() throws {
        try withChat { h in
            h.session.debugAsk(ChatInWindow.question())
            let field = try h.typeInTheCard()
            let editor = try #require(h.window.firstResponder as? NSTextView)
            #expect(editor.delegate === field, "the card's field is being edited")
            h.chat.focusComposer()
            #expect(h.window.firstResponder === editor)
        }
    }

    /// e7q.36: answering from one of the card's fields gives the keyboard back
    /// to the composer, not to the window.
    @Test func answeringFromACardFieldGivesTheComposerTheKeyboard() throws {
        try withChat { h in
            h.session.debugAsk(ChatInWindow.question())
            _ = try h.typeInTheCard()
            #expect(h.chat.debugQuestionHasKeyboard, "focus in a card's field is focus in the card")
            let form = try #require(h.chat.debugQuestionForm)
            form.submit()
            #expect(h.session.question == nil)
            #expect(h.chat.debugComposerHasKeyboard)
        }
    }
}
#endif
