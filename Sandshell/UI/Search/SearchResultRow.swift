import SwiftUI

/// One result in the Search window: the agent, title, folder and date, and
/// the text around a body match, with the query highlighted.
struct SearchResultRow: View {
    let result: SearchResult
    let query: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            BadgeMark(color: result.agent.badgeColor, content: result.agent.badgeContent)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(result.agent.displayName)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if result.isChat {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.symbol(.meta)).foregroundStyle(.secondary)
                            .help("Chat session")
                            .accessibilityLabel("Chat session")
                    }
                    Text(AttributedString(result.title, highlighting: query))
                        .font(.role(.body))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if result.isLive {
                        Text("Open")
                            .font(.role(.meta, weight: .semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: .capsule)
                    }
                }
                HStack(spacing: 5) {
                    if let folder = result.folder {
                        Text(AttributedString(folder.tildeAbbreviated, highlighting: query))
                            .lineLimit(1).truncationMode(.middle)
                        Text("·")
                    }
                    Text(result.date, format: .relative(presentation: .named))
                        .lineLimit(1)
                }
                .font(.role(.meta))
                .foregroundStyle(.secondary)
                if let snippet = result.snippet {
                    Text(AttributedString(snippet, highlighting: query))
                        .font(.role(.meta))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
