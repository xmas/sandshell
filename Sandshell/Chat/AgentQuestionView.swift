import SwiftUI

/// An agent's question, answered above the composer: choices as radio or
/// checkbox rows (with each option's detail, and its preview when it has
/// one), an "Other" box per question, text fields. Return submits, Esc skips,
/// 1–9 pick an option when there's a single choice question.
struct AgentQuestionView: View {
    let form: AgentQuestionForm
    private var question: AgentQuestion { form.question }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(question.message).font(.role(.bodyEmphasis)).textSelection(.enabled)
            } icon: {
                Image(systemName: question.mode == .form ? "questionmark.bubble" : "link")
                    .foregroundStyle(Color.accentColor)
            }
            switch question.mode {
            case .form:
                ForEach(question.questions) { field in AgentQuestionFieldView(form: form, field: field) }
            case .url(let url, _):
                Text(url.absoluteString).font(.role(.meta)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(question.mode == .form ? "Skip" : "Not Now", action: form.skip)
                    .keyboardShortcut(.cancelAction)
                    .help("Carry on without answering (Esc)")
                Button(submitTitle, action: form.submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.canSubmit)
                    .accessibilityIdentifier("chat-question-submit")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.10))
                .strokeBorder(Color.accentColor.opacity(0.35))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question from the agent: \(question.message)")
        .accessibilityIdentifier("chat-question")
    }

    private var submitTitle: String {
        if case .url = question.mode { return "Open Link" }
        return question.questions.count > 1 ? "Submit Answers" : "Submit"
    }
}
