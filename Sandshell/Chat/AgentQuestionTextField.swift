import SwiftUI

/// A text box in an agent's question card (a text or number question, or an
/// "Other" box): secure for a secret; Return sends the answers once they can go.
struct AgentQuestionTextField: View {
    @Bindable var form: AgentQuestionForm
    let field: AgentQuestion.Field
    let placeholder: String
    let secret: Bool

    var body: some View {
        Group {
            if secret {
                SecureField(placeholder, text: $form[text: field.id])
            } else {
                TextField(placeholder, text: $form[text: field.id])
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.callout)
        .onSubmit { form.submit() }
    }
}
