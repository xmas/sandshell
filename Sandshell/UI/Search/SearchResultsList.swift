import SwiftUI

/// The Search window's results: open sessions, then past conversations. The
/// selection is the store's (the arrow keys in the field move it too).
struct SearchResultsList: View {
    @Bindable var store: SearchStore
    let onOpen: (SearchResult) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $store.selectedID) {
                if !store.liveResults.isEmpty {
                    Section("Open Sessions") {
                        ForEach(store.liveResults) { row($0) }
                    }
                }
                if !store.pastResults.isEmpty {
                    Section("Past Conversations") {
                        ForEach(store.pastResults) { row($0) }
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: SearchResult.ID.self) { ids in
                if let result = store.results.first(where: { ids.contains($0.id) }) {
                    Button(result.isLive ? "Show Session" : "Restore Session") { onOpen(result) }
                    Divider()
                    Button("Copy", action: result.copyToPasteboard)
                    if let folder = result.folder {
                        Button("Reveal Folder in Finder") {
                            NSWorkspace.shared.open(URL(filePath: folder, directoryHint: .isDirectory))
                        }
                    }
                    if let url = result.transcriptURL {
                        Button("Reveal Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            } primaryAction: { ids in
                // Double-click / Return in the list.
                if let result = store.results.first(where: { ids.contains($0.id) }) { onOpen(result) }
            }
            .onChange(of: store.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            // ⌘C: the selected result's title and folder.
            .onCopyCommand {
                guard let result = store.selected else { return [] }
                return [NSItemProvider(object: result.copyText as NSString)]
            }
            .overlay {
                if store.results.isEmpty {
                    if store.busy {
                        ProgressView()
                    } else if store.matchedQuery.isEmpty {
                        ContentUnavailableView("No Sessions Yet", systemImage: "rectangle.stack",
                                               description: Text("Sessions and past conversations in this workspace appear here."))
                    } else {
                        ContentUnavailableView.search(text: store.query)
                    }
                }
            }
        }
    }

    private func row(_ result: SearchResult) -> some View {
        SearchResultRow(result: result, query: store.matchedQuery)
            .tag(result.id)
            .id(result.id)
            // Drags out as its transcript (a file) when there is one, else as text.
            .onDrag {
                if let url = result.transcriptURL { return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: result.copyText as NSString) }
                return NSItemProvider(object: result.copyText as NSString)
            }
    }
}

private extension SearchResult {
    /// What Copy, ⌘C and a drag without a transcript carry.
    var copyText: String {
        [title, folder].compactMap { $0 }.joined(separator: " — ")
    }

    @MainActor
    func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
    }
}
