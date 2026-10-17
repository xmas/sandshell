import AppKit
import Testing
@testable import Sandshell

/// Takes the keys the question card passes on, as the chat behind it would.
@MainActor
private final class KeySink: NSResponder {
    var keyCodes: [UInt16] = []
    override func keyDown(with event: NSEvent) { keyCodes.append(event.keyCode) }
}

/// A card for one optional choice (so it can be sent as is), and what it answers.
@MainActor
private final class QuestionCard {
    static let colors = ["Red", "Blue", "Green"].map {
        AgentQuestion.Option(value: $0, title: $0, detail: nil, preview: nil)
    }

    let sink = KeySink()
    private(set) var answers: [AgentQuestion.Answer] = []
    private(set) lazy var host: AgentQuestionHost = {
        let question = AgentQuestion(
            rpcID: 1, message: "Pick one.", mode: .form,
            fields: [AgentQuestion.Field(id: "color", title: nil, detail: nil, kind: .choice(Self.colors),
                                         required: false, companionOf: nil, defaultValue: nil)],
            toolCallID: nil)
        let host = AgentQuestionHost(AgentQuestionForm(question) { [unowned self] in self.answers.append($0) })
        host.nextResponder = sink
        return host
    }()

    func press(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        host.keyDown(with: event)
    }
}

/// The keys the question card takes while it has the keyboard: Return and
/// Enter submit, Esc skips, 1–9 pick — only without ⌘, ⌥ or ⌃.
@MainActor
struct AgentQuestionHostTests {
    @Test(arguments: [UInt16(36), 76])   // Return, Enter
    func returnAndEnterSubmit(keyCode: UInt16) throws {
        let card = QuestionCard()
        try card.press(keyCode, "\r")
        #expect(card.answers == [.accept([:])])
    }

    /// ⌥Return and the like are the chat's, not the card's (a modified Return
    /// used to submit: the `where` only covered Enter).
    @Test(arguments: [UInt16(36), 76], [NSEvent.ModifierFlags.command, .option, .control])
    func modifiedReturnAndEnterArePassedOn(keyCode: UInt16, flag: NSEvent.ModifierFlags) throws {
        let card = QuestionCard()
        try card.press(keyCode, "\r", flag)
        #expect(card.answers.isEmpty)
        #expect(card.sink.keyCodes == [keyCode])
    }

    @Test func escapeSkips() throws {
        let card = QuestionCard()
        try card.press(53, "\u{1B}")
        #expect(card.answers == [.decline])
    }

    @Test func digitsPickOnlyWithoutModifiers() throws {
        let card = QuestionCard()
        try card.press(19, "2")
        #expect(card.host.form.picks["color"] == "Blue")
        try card.press(20, "3", .command)
        #expect(card.host.form.picks["color"] == "Blue", "⌘3 isn't a pick")
        #expect(card.sink.keyCodes == [20])
        #expect(card.answers.isEmpty)
    }
}
