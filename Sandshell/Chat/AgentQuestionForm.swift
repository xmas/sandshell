import Foundation
import Observation

/// The answers being filled in for an agent's question, kept outside the view
/// so the AppKit host can route Return / Esc / digits to it (and tests can answer).
@MainActor @Observable
final class AgentQuestionForm {
    let question: AgentQuestion
    let onAnswer: (AgentQuestion.Answer) -> Void
    var picks: [String: String] = [:]
    var multiPicks: [String: Set<String>] = [:]
    var texts: [String: String] = [:]
    var toggles: [String: Bool] = [:]
    var previewed: [String: AgentQuestion.Option] = [:]

    init(_ question: AgentQuestion, onAnswer: @escaping (AgentQuestion.Answer) -> Void) {
        self.question = question
        self.onAnswer = onAnswer
        applyDefaults()
    }

    /// A text box's text, empty until typed: `$form[text: id]` binds a field to it.
    subscript(text id: String) -> String {
        get { texts[id] ?? "" }
        set { texts[id] = newValue }
    }

    /// A toggle's state, off until set: `$form[isOn: id]` binds a toggle to it.
    subscript(isOn id: String) -> Bool {
        get { toggles[id] ?? false }
        set { toggles[id] = newValue }
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

    /// An option's row was clicked: a choice picks it (or clears it when it's
    /// already picked), a multi-choice adds or removes it; either way it's previewed.
    func toggle(_ option: AgentQuestion.Option, in field: AgentQuestion.Field) {
        switch field.kind {
        case .choice: picks[field.id] = picks[field.id] == option.value ? nil : option.value
        case .multiChoice: multiPicks[field.id, default: []].formSymmetricDifference([option.value])
        case .text, .number, .toggle: return
        }
        previewed[field.id] = option
    }

    func applyDefaults() {
        for field in question.fields {
            switch (field.kind, field.defaultValue) {
            case (.choice, .string(let s)?): picks[field.id] = s
            case (.multiChoice, .array(let a)?): multiPicks[field.id] = Set(a.compactMap(\.string))
            case (.text, .string(let s)?): texts[field.id] = s
            // Only a default the field would send: one past 2^53 (an "unlimited"
            // sentinel, say) or non-finite stays a placeholder, rather than text
            // that leaves Submit disabled or is silently left out.
            case (.number(let integer), .number(let n)?) where Self.isAnswer(n, integer: integer):
                texts[field.id] = AgentQuestion.text(of: n)
            case (.toggle, .bool(let b)?): toggles[field.id] = b
            default: break
            }
        }
    }

    func value(_ field: AgentQuestion.Field) -> JSONValue? {
        switch field.kind {
        case .choice: return picks[field.id].map(JSONValue.string)
        case .multiChoice(let options):
            // Only picks among the options (a default may name others).
            let set = multiPicks[field.id] ?? []
            let picked = options.filter { set.contains($0.value) }
            return picked.isEmpty ? nil : .array(picked.map { .string($0.value) })
        case .text:
            let s = (texts[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : .string(s)
        case .number(let integer):
            let s = (texts[field.id] ?? "").trimmingCharacters(in: .whitespaces)
            guard let n = Double(s), Self.isAnswer(n, integer: integer) else { return nil }
            return .number(n)
        case .toggle: return .bool(toggles[field.id] ?? false)
        }
    }

    /// Whether `n` can answer a number field: JSON can't carry inf or nan, and
    /// past 2^53 a Double isn't the whole number that was typed.
    nonisolated static func isAnswer(_ n: Double, integer: Bool) -> Bool {
        n.isFinite && (!integer || (n == n.rounded() && abs(n) < 0x1p53))
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
