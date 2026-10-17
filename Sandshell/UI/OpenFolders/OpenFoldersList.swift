import SwiftUI

/// The Open Workspace browser's folders (already filtered and sorted), or why
/// there are none. A click opens a row; the keyboard selection is kept in view.
struct OpenFoldersList: View {
    let roots: [RootProfile]
    /// Whether any folder is known at all (no workspaces yet vs. no matches).
    let hasAnyRoots: Bool
    let query: String
    /// The row Return opens.
    let selectedID: RootProfile.ID?
    let onOpen: (URL) -> Void

    var body: some View {
        if roots.isEmpty {
            Group {
                if hasAnyRoots {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView("No Workspaces Yet", systemImage: "folder.badge.questionmark")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(roots) { root in
                            OpenFoldersRow(root: root, isSelected: root.id == selectedID) { onOpen(root.url) }
                                .id(root.id)
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .onChange(of: selectedID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: nil) } }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}
