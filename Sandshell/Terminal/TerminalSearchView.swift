import AppKit
import SwiftUI

/// The search window's content: the matching lines, and the selected one in
/// its context.
struct TerminalSearchView: View {
    @Bindable var model: TerminalSearchModel
    @FocusState private var searchFocused: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            HSplitView {
                masterPane
                detailPane
            }
        }
        .onExitCommand(perform: handleEscape)
        .frame(minWidth: 720, minHeight: 460)
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            searchFocused = true
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search session history…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.role(.body))
                .focused($searchFocused)
            if !model.query.isEmpty {
                statusText
                    .font(.role(.code)).foregroundStyle(.secondary)

                Button("Clear Search", systemImage: "xmark.circle.fill", action: clearSearch)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusText: Text {
        let n = model.matches.count
        return n == 0 ? Text("No matches") : Text("^[\(n) match](inflect: true)")
    }

    private func clearSearch() {
        model.query = ""
    }

    /// Escape clears the search, then (with nothing to clear) closes the window.
    private func handleEscape() {
        if model.query.isEmpty { onClose() } else { clearSearch() }
    }

    private var masterPane: some View {
        List(model.matches, selection: $model.selectedID) { m in
            MatchRow(match: m, query: model.query).tag(m.id)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, idealWidth: 300, maxWidth: 420)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let sel = model.selectedMatch {
            ContextPane(lines: model.context(for: sel), query: model.query)
        } else {
            Group {
                if model.query.isEmpty {
                    ContentUnavailableView("Search Session History", systemImage: "magnifyingglass",
                                           description: Text("Type above to find lines in this session’s terminal."))
                } else {
                    ContentUnavailableView.search(text: model.query)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct MatchRow: View {
    let match: TerminalSearchModel.Match
    let query: String
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        HStack(spacing: 6) {
            Text("\(match.lineNumber)")
                .font(.role(.code))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Text(highlighted)
                .font(.role(.code))
                .lineLimit(1)
        }
        .padding(.vertical, 1)
    }

    private var highlighted: AttributedString {
        var a = AttributedString(match.snippet.prefix(300))
        if let r = a.range(of: query, options: AttributedString.searchOptions, locale: .current) {
            a[r].markAsMatch(beyondColor: differentiateWithoutColor)
        }
        return a
    }
}

private struct ContextPane: View {
    let lines: [TerminalSearchModel.ContextLine]
    let query: String
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { row in
                    HStack(alignment: .top, spacing: 0) {
                        Text("\(row.id)")
                            .font(.role(.code))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                            .padding(.trailing, 10)
                        Text(row.isMatch ? highlighted(row.text) : AttributedString(row.text))
                            .font(.role(.code))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 10)
                    .background(row.isMatch ? Color.yellow.opacity(0.1) : Color.clear)
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func highlighted(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        var pos = a.startIndex
        while pos < a.endIndex,
              let r = a[pos...].range(of: query, options: AttributedString.searchOptions, locale: .current),
              !r.isEmpty {
            a[r].markAsMatch(beyondColor: differentiateWithoutColor)
            pos = r.upperBound
        }
        return a
    }
}

private extension AttributedString {
    /// How the highlights find the query: as the search found the line
    /// (`localizedStandardContains`, with the current locale).
    static let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
}

private extension AttributedSubstring {
    /// Where the query matched: a yellow wash, and bold and underlined too when
    /// color mustn't be all that sets it apart (Differentiate Without Color).
    mutating func markAsMatch(beyondColor: Bool) {
        self.backgroundColor = Color.yellow.opacity(0.55)
        guard beyondColor else { return }
        self.underlineStyle = Text.LineStyle.single
        self.inlinePresentationIntent = .stronglyEmphasized
    }
}
