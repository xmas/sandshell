import SwiftUI

/// The Search window's preview: the selected result's conversation, scrolled
/// to the first match. Loaded off the main actor; a newer selection cancels
/// the load it replaces.
struct SearchPreviewPane: View {
    let selection: SearchResult?
    /// The results list has rows. When it doesn't, it shows its own empty state
    /// and this pane stays blank instead of asking for a selection.
    let hasResults: Bool
    let matchedQuery: String
    let home: URL

    @State private var messages: [SearchPreviewMessage] = []
    @State private var loading = false

    var body: some View {
        Group {
            if let selection {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AttributedString(selection.title, highlighting: matchedQuery))
                            .font(.role(.title)).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(selection.agent.displayName.capitalized)
                            if let folder = selection.folder { Text("·"); Text(folder.tildeAbbreviated).truncationMode(.middle) }
                        }
                        .font(.role(.meta)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    Divider()
                    if messages.isEmpty {
                        Group {
                            if loading {
                                ProgressView().controlSize(.small)
                            } else if selection.isLive {
                                ContentUnavailableView("No Conversation Yet", systemImage: "bubble.left.and.bubble.right")
                            } else {
                                ContentUnavailableView("No Messages", systemImage: "bubble.left")
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(messages) { message in
                                        SearchPreviewMessageRow(message: message, query: matchedQuery)
                                            .id(message.id)
                                    }
                                }
                                .padding(14)
                            }
                            .onAppear { scrollToFirstMatch(proxy) }
                            .onChange(of: messages.first?.id) { _, _ in scrollToFirstMatch(proxy) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if hasResults {
                ContentUnavailableView("No Selection", systemImage: "text.magnifyingglass",
                                       description: Text("Select a result to preview its conversation."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: selection?.previewKey) { await load() }
    }

    private func scrollToFirstMatch(_ proxy: ScrollViewProxy) {
        guard !matchedQuery.isEmpty,
              let hit = messages.first(where: { $0.text.range(of: matchedQuery, options: .caseInsensitive) != nil })
        else { return }
        proxy.scrollTo(hit.id, anchor: .top)
    }

    /// Load the selected conversation's messages (an open session's
    /// transcript is located on demand).
    private func load() async {
        guard let selection else { messages = []; loading = false; return }
        messages = []
        loading = true
        let loaded = await Self.messages(of: selection, home: home)
        // Cancelled: a newer selection's load now owns `messages` / `loading`.
        guard !Task.isCancelled else { return }
        messages = loaded
        loading = false
    }

    /// Parses off the main actor but stays structured, so `.task(id:)`
    /// cancellation reaches the transcript parse.
    @concurrent
    nonisolated private static func messages(of result: SearchResult, home: URL) async -> [SearchPreviewMessage] {
        let url = result.transcriptURL ?? result.transcriptID.flatMap {
            TranscriptReader.transcriptURL(agent: result.agent, workdir: result.folder ?? "", home: home, id: $0)
        }
        guard let url, !Task.isCancelled else { return [] }
        return TranscriptReader.messages(at: url, agent: result.agent).enumerated()
            .map { SearchPreviewMessage(id: $0.offset, role: $0.element.role, text: $0.element.text) }
    }
}

private extension SearchResult {
    /// Changes when the preview must reload (not on every re-rank).
    var previewKey: String { id + "|" + (transcriptID ?? "") + "|" + (transcriptURL?.path(percentEncoded: false) ?? "") }
}
