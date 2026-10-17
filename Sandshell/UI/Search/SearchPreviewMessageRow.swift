import SwiftUI

/// One message in the Search window's preview. Its own view, so the
/// highlighting is redone only when the message or the query changes.
struct SearchPreviewMessageRow: View {
    let message: SearchPreviewMessage
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(message.role == "user" ? "You" : "Assistant")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(message.role == "user" ? Color.accentColor : .secondary)
            Text(AttributedString(message.text, highlighting: query))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
