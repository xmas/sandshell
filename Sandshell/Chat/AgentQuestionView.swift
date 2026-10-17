import SwiftUI

/// An agent's question, answered above the composer: choices as radio or
/// checkbox rows (with each option's detail, and its preview when it has
/// one), an "Other" box per question, text fields. Return submits, Esc skips,
/// 1–9 pick an option when there's a single choice question.
/// The answers being filled in, kept outside the view so the AppKit host can
/// route Return / Esc / digits to it (and tests can answer).
@MainActor
final class AgentQuestionForm: ObservableObject {
    let question: AgentQuestion
    let onAnswer: (AgentQuestion.Answer) -> Void
    @Published var picks: [String: String] = [:]
    @Published var multiPicks: [String: Set<String>] = [:]
    @Published var texts: [String: String] = [:]
    @Published var toggles: [String: Bool] = [:]
    @Published var previewed: [String: AgentQuestion.Option] = [:]

    init(_ question: AgentQuestion, onAnswer: @escaping (AgentQuestion.Answer) -> Void) {
        self.question = question
        self.onAnswer = onAnswer
        applyDefaults()
    }

    /// The one choice question, when there is exactly one: 1–9 pick its options.
    var singleChoice: (AgentQuestion.Field, [AgentQuestion.Option])? {
        let choices = question.questions.compactMap { f -> (AgentQuestion.Field, [AgentQuestion.Option])? in
            if case .choice(let o) = f.kind { return (f, o) } else { return nil }
        }
        return choices.count == 1 && question.questions.count == 1 ? choices[0] : nil
    }

    /// Pick option `index` (0-based) of the single choice question.
    func pick(_ index: Int) {
        guard let (field, options) = singleChoice, options.indices.contains(index) else { return }
        picks[field.id] = options[index].value
        previewed[field.id] = options[index]
    }

    func applyDefaults() {
        for field in question.fields {
            switch (field.kind, field.defaultValue) {
            case (.choice, .string(let s)?): picks[field.id] = s
            case (.multiChoice, .array(let a)?): multiPicks[field.id] = Set(a.compactMap(\.string))
            case (.text, .string(let s)?): texts[field.id] = s
            case (.number, .number(let n)?): texts[field.id] = n == n.rounded() ? String(Int(n)) : String(n)
            case (.toggle, .bool(let b)?): toggles[field.id] = b
            default: break
            }
        }
    }

    func value(_ field: AgentQuestion.Field) -> JSONValue? {
        switch field.kind {
        case .choice: return picks[field.id].map(JSONValue.string)
        case .multiChoice(let options):
            let set = multiPicks[field.id] ?? []
            guard !set.isEmpty else { return nil }
            return .array(options.filter { set.contains($0.value) }.map { .string($0.value) })
        case .text:
            let s = (texts[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : .string(s)
        case .number(let integer):
            let s = (texts[field.id] ?? "").trimmingCharacters(in: .whitespaces)
            guard let n = Double(s), !integer || n == n.rounded() else { return nil }
            return .number(n)
        case .toggle: return .bool(toggles[field.id] ?? false)
        }
    }

    var canSubmit: Bool {
        guard case .form = question.mode else { return true }
        return question.fields.allSatisfy { f in
            guard f.required else { return true }
            // A required choice is also answered by its "Other" box.
            return value(f) != nil || question.companion(of: f).flatMap(value) != nil
        }
    }

    func submit() {
        guard canSubmit else { return }
        var content: [String: JSONValue] = [:]
        for field in question.fields { if let v = value(field) { content[field.id] = v } }
        onAnswer(.accept(content))
    }

    func skip() { onAnswer(.decline) }
}

struct AgentQuestionView: View {
    @ObservedObject var form: AgentQuestionForm
    private var question: AgentQuestion { form.question }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(question.message).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
            } icon: {
                Image(systemName: question.mode == .form ? "questionmark.bubble" : "link")
                    .foregroundStyle(Color.accentColor)
            }
            switch question.mode {
            case .form:
                ForEach(question.questions) { field in fieldView(field) }
            case .url(let url, _):
                Text(url.absoluteString).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(question.mode == .form ? "Skip" : "Not Now") { form.skip() }
                    .keyboardShortcut(.cancelAction)
                    .help("Carry on without answering (Esc)")
                Button(submitTitle) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("chat-question-submit")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question from the agent: \(question.message)")
        .accessibilityIdentifier("chat-question")
    }

    private var submitTitle: String {
        if case .url = question.mode { return "Open Link" }
        return question.questions.count > 1 ? "Submit Answers" : "Submit"
    }

    // MARK: Fields

    @ViewBuilder private func fieldView(_ field: AgentQuestion.Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if question.questions.count > 1 || field.title != nil || field.detail != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = field.title {
                        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .textCase(question.questions.count > 1 ? .uppercase : nil)
                    }
                    if let detail = field.detail, question.questions.count > 1 || field.title == nil {
                        Text(detail).font(.system(size: 12.5)).textSelection(.enabled)
                    }
                }
            }
            switch field.kind {
            case .choice(let options):
                ForEach(Array(options.enumerated()), id: \.element) { i, option in
                    optionRow(option, index: i, in: field.id, selected: form.picks[field.id] == option.value, multi: false) {
                        form.picks[field.id] = form.picks[field.id] == option.value ? nil : option.value
                        form.previewed[field.id] = option
                    }
                }
            case .multiChoice(let options):
                ForEach(Array(options.enumerated()), id: \.element) { i, option in
                    optionRow(option, index: i, in: field.id, selected: form.multiPicks[field.id, default: []].contains(option.value), multi: true) {
                        form.multiPicks[field.id, default: []].formSymmetricDifference([option.value])
                        form.previewed[field.id] = option
                    }
                }
            case .text(let secret):
                textField(field, placeholder: field.title ?? "Your answer", secret: secret)
            case .number(let integer):
                textField(field, placeholder: integer ? "A whole number" : "A number", secret: false)
            case .toggle:
                Toggle(field.title ?? field.detail ?? "Yes", isOn: Binding(get: { form.toggles[field.id] ?? false },
                                                                         set: { form.toggles[field.id] = $0 }))
            }
            if let preview = form.previewed[field.id]?.preview, !preview.isEmpty {
                ScrollView([.vertical, .horizontal]) {
                    Text(preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(maxHeight: 160)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            }
            if let other = question.companion(of: field) {
                textField(other, placeholder: other.detail ?? other.title ?? "Other", secret: false)
            }
        }
    }

    private func optionRow(_ option: AgentQuestion.Option, index: Int, in fieldID: String, selected: Bool, multi: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square")
                                        : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    if let detail = option.detail {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if index < 9, form.singleChoice != nil {
                    Text("\(index + 1)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.detail.map { "\(option.title), \($0)" } ?? option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { inside in if inside, option.preview != nil { form.previewed[fieldID] = option } }
    }

    private func textField(_ field: AgentQuestion.Field, placeholder: String, secret: Bool) -> some View {
        let binding = Binding(get: { form.texts[field.id] ?? "" }, set: { form.texts[field.id] = $0 })
        return Group {
            if secret { SecureField(placeholder, text: binding) } else { TextField(placeholder, text: binding) }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12.5))
        .onSubmit { if canSubmit { submit() } }
    }

    private var canSubmit: Bool { form.canSubmit }
    private func submit() { form.submit() }
}

/// Hosts the question above the composer and takes the keyboard while it's
/// up: Return submits, Esc skips, 1–9 pick (a text field in the form keeps its
/// own keys). The composer would otherwise take Return as a new message.
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
        case 36, 76 where plain: form.submit()   // Return, Enter
        case 53: form.skip()                      // Esc
        default:
            if plain, let c = event.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) {
                form.pick(n - 1)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
