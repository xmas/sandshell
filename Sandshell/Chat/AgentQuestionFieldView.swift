import SwiftUI

/// One question in an agent's question card: its title and detail, its options
/// (or text box, or toggle), the preview of the option last picked or pointed
/// at, and its "Other" box.
struct AgentQuestionFieldView: View {
    @Bindable var form: AgentQuestionForm
    let field: AgentQuestion.Field
    private var question: AgentQuestion { form.question }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if question.questions.count > 1 || field.title != nil || field.detail != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = field.title {
                        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .textCase(question.questions.count > 1 ? .uppercase : nil)
                    }
                    if let detail = field.detail, question.questions.count > 1 || field.title == nil {
                        Text(detail).font(.callout).textSelection(.enabled)
                    }
                }
            }
            // Rows are keyed by position: the options are fixed for the form's
            // life, and nothing makes their values unique ("1" and 1, a repeat).
            switch field.kind {
            case .choice(let options):
                ForEach(options.enumerated(), id: \.offset) { i, option in
                    AgentQuestionOptionRow(form: form, option: option, index: i, fieldID: field.id,
                                           selected: form.picks[field.id] == option.value, multi: false) {
                        form.toggle(option, in: field)
                    }
                }
            case .multiChoice(let options):
                ForEach(options.enumerated(), id: \.offset) { i, option in
                    AgentQuestionOptionRow(form: form, option: option, index: i, fieldID: field.id,
                                           selected: form.multiPicks[field.id, default: []].contains(option.value),
                                           multi: true) {
                        form.toggle(option, in: field)
                    }
                }
            case .text(let secret):
                AgentQuestionTextField(form: form, field: field, placeholder: field.title ?? "Your answer", secret: secret)
            case .number(let integer):
                AgentQuestionTextField(form: form, field: field, placeholder: integer ? "A whole number" : "A number",
                                       secret: false)
            case .toggle:
                Toggle(field.title ?? field.detail ?? "Yes", isOn: $form[isOn: field.id])
            }
            if let preview = form.previewed[field.id]?.preview, !preview.isEmpty {
                ScrollView([.vertical, .horizontal]) {
                    Text(preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(maxHeight: 160)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
            }
            if let other = question.companion(of: field) {
                AgentQuestionTextField(form: form, field: other, placeholder: other.detail ?? other.title ?? "Other",
                                       secret: false)
            }
        }
    }
}
