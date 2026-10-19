import SwiftUI

/// The Search window's content: the query field over the results and the
/// selected result's conversation, with the counts and Open button below.
struct SearchView: View {
    @Bindable var store: SearchStore
    let onOpen: (SearchResult) -> Void
    let onClose: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.symbol(.body))
                    .foregroundStyle(.secondary)
                TextField("Search sessions and past conversations", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.role(.body))
                    .focused($fieldFocused)
                    .onSubmit(openSelected)
                    .onKeyPress(.downArrow) { store.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { store.moveSelection(-1); return .handled }
                if store.busy { ProgressView().controlSize(.small) }
                if !store.query.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill", action: clearQuery)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.tertiary)
                        .buttonStyle(.plain)
                        .help("Clear")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Divider()
            HSplitView {
                SearchResultsList(store: store, onOpen: onOpen)
                    .frame(minWidth: 300, idealWidth: 400, maxWidth: .infinity)
                SearchPreviewPane(selection: store.selected, hasResults: !store.results.isEmpty,
                                  matchedQuery: store.matchedQuery, home: store.home)
                    .frame(minWidth: 260, maxWidth: .infinity)
            }
            Divider()
            SearchFooter(store: store, onOpenSelected: openSelected)
        }
        .onExitCommand(perform: onClose)
        .onAppear(perform: focusField)
        .onChange(of: store.focusRequest) { _, _ in focusField() }
    }

    /// Focus the field on the next turn, once the window showing it is key.
    private func focusField() {
        Task { fieldFocused = true }
    }

    private func clearQuery() {
        store.query = ""
        focusField()
    }

    private func openSelected() {
        if let selected = store.selected { onOpen(selected) }
    }
}
