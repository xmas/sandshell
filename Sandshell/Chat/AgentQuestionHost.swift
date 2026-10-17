import SwiftUI

/// Hosts an agent's question above the composer and takes the keyboard while
/// it's up: Return submits, Esc skips, 1–9 pick (a text field in the form keeps
/// its own keys). The composer would otherwise take Return as a new message.
final class AgentQuestionHost: NSHostingView<AgentQuestionView> {
    let form: AgentQuestionForm

    init(_ form: AgentQuestionForm) {
        self.form = form
        super.init(rootView: AgentQuestionView(form: form))
        // Its height from SwiftUI; its width from the composer column.
        sizingOptions = [.intrinsicContentSize]
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityIdentifier("chat-question-host")
    }

    @available(*, unavailable) required init(rootView: AgentQuestionView) { fatalError() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        switch event.keyCode {
        case 36 where plain, 76 where plain: form.submit()   // Return, Enter
        case 53: form.skip()                                  // Esc
        default:
            if plain, let c = event.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) {
                form.pick(n - 1)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
