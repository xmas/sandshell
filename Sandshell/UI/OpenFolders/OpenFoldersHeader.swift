import SwiftUI

/// The Open Workspace browser's header: title, sort, and the search field
/// (Return opens the selected folder, ↑/↓ move the selection).
struct OpenFoldersHeader: View {
    @Binding var sort: OpenFoldersView.Sort
    @Binding var query: String
    var searchFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onMove: (Int) -> KeyPress.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Open Workspace").font(.title3.bold())
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(OpenFoldersView.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .accessibilityIdentifier("open-workspace-sort")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type to search folders", text: $query)
                    .textFieldStyle(.plain)
                    .focused(searchFocused)
                    .onSubmit(onSubmit)
                    .onKeyPress(.upArrow) { onMove(-1) }
                    .onKeyPress(.downArrow) { onMove(1) }
                    .accessibilityIdentifier("open-workspace-search")
                if !query.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Clear Search")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .stroke(Color(nsColor: .separatorColor))
            }
        }
        .padding(16)
    }
}
