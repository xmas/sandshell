import SwiftUI

/// The Keyboard Shortcuts window's list: the menu bar's shortcuts by menu,
/// filtered by what's typed above it.
struct ShortcutsView: View {
    let groups: [ShortcutsWindowController.MenuGroup]
    @State private var filter = ""

    private var query: String { filter.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let shown = ShortcutsWindowController.filter(groups, by: query)
        VStack(spacing: 0) {
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).padding(10)
            List {
                ForEach(shown) { group in
                    Section(group.menu) {
                        ForEach(group.items) { s in
                            HStack {
                                Text(s.title)
                                Spacer()
                                Text(s.keys).font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .overlay {
                if shown.isEmpty, !query.isEmpty { ContentUnavailableView.search(text: query) }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}
