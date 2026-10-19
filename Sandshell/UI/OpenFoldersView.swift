import SwiftUI

/// The Open Workspace browser (⌘O, "See More…" in the recents menus): every
/// folder Sandshell has ever opened, each with its colored icon, sortable by
/// last-opened or name, filtered as you type. ↑/↓ move the selection (the
/// top match by default), Return opens it, Esc closes; rows highlight on hover.
struct OpenFoldersView: View {
    let onOpen: (URL) -> Void
    let onOpenNew: () -> Void
    let onClose: () -> Void

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recent", name = "Name"
        var id: String { rawValue }
    }

    @State private var sort: Sort = .recent
    @State private var query = ""
    /// Loaded when the browser appears, and again when the sort changes.
    @State private var roots: [RootProfile] = []
    /// Keyboard selection — the row Return opens. Follows the top match as
    /// the filter changes; ↑/↓ move it.
    @State private var selectedID: RootProfile.ID?
    @FocusState private var searchFocused: Bool

    private var filtered: [RootProfile] { Self.filter(roots, query: query) }

    /// The roots matching `query`: name matches first, then path matches — both
    /// case- and diacritic-insensitive. All of them for a blank query.
    nonisolated static func filter(_ roots: [RootProfile], query: String) -> [RootProfile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return roots }
        let byName = roots.filter { $0.name.localizedStandardContains(q) }
        let byPath = roots.filter { !$0.name.localizedStandardContains(q) && $0.path.localizedStandardContains(q) }
        return byName + byPath
    }

    var body: some View {
        let rows = filtered
        VStack(spacing: 0) {
            OpenFoldersHeader(sort: $sort, query: $query, searchFocused: $searchFocused,
                              onSubmit: openSelected, onMove: moveSelection)
            Divider()
            OpenFoldersList(roots: rows, hasAnyRoots: !roots.isEmpty, query: query,
                            selectedID: Self.selection(in: rows, id: selectedID)?.id, onOpen: onOpen)
            Divider()
            HStack {
                Text("^[\(roots.count) folder](inflect: true)")
                    .font(.role(.meta)).foregroundStyle(.tertiary)
                Spacer()
                Button("Open New…", action: onOpenNew)
                    .help("Choose a folder. A folder you’ve opened before opens directly; a new one runs the setup wizard.")
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .onChange(of: sort) { _, _ in reload() }
        .onChange(of: query) { _, _ in selectedID = filtered.first?.id }
        .onAppear { reload(); searchFocused = true }
        .onExitCommand { onClose() }
    }

    /// The row Return opens: the keyboard selection, else the top match.
    private static func selection(in rows: [RootProfile], id: RootProfile.ID?) -> RootProfile? {
        rows.first { $0.id == id } ?? rows.first
    }

    /// Move the keyboard selection by `delta` rows, clamped to the list.
    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        let rows = filtered
        guard !rows.isEmpty else { return .ignored }
        let current = rows.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), rows.count - 1)
        selectedID = rows[next].id
        return .handled
    }

    private func openSelected() {
        if let root = Self.selection(in: filtered, id: selectedID) { onOpen(root.url) }
    }

    private func reload() {
        roots = sort == .recent ? RootFolderStore.byRecency() : RootFolderStore.byName()
        let rows = filtered
        if !rows.contains(where: { $0.id == selectedID }) { selectedID = rows.first?.id }
    }
}
