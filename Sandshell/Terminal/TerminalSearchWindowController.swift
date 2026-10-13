import AppKit
import SwiftUI

// MARK: - Model

@MainActor
final class TerminalSearchModel: ObservableObject {
    struct Match: Identifiable, Hashable {
        let id: Int
        let lineNumber: Int
        let lineIndex: Int
        let snippet: String
    }

    struct ContextLine: Identifiable {
        let id: Int     // 1-based line number; unique within any context window
        let text: String
        let isMatch: Bool
    }

    @Published var query: String = "" {
        didSet { guard query != oldValue else { return }; runSearch() }
    }
    @Published private(set) var matches: [Match] = []
    @Published var selectedID: Int? = nil

    var selectedMatch: Match? { matches.first { $0.id == selectedID } }
    private(set) var lines: [String] = []

    func load(text: String) {
        lines = Self.stripANSI(text).components(separatedBy: "\n")
        runSearch()
    }

    func context(for match: Match, radius: Int = 14) -> [ContextLine] {
        let lo = max(0, match.lineIndex - radius)
        let hi = min(lines.count, match.lineIndex + radius + 1)
        return (lo..<hi).map { i in
            ContextLine(id: i + 1, text: lines[i], isMatch: i == match.lineIndex)
        }
    }

    private func runSearch() {
        guard !query.isEmpty else { matches = []; selectedID = nil; return }
        var found: [Match] = []
        let q = query
        for (i, line) in lines.enumerated() {
            if line.range(of: q, options: .caseInsensitive) != nil {
                found.append(Match(id: found.count, lineNumber: i + 1, lineIndex: i, snippet: line))
            }
        }
        matches = found
        selectedID = found.first?.id
    }

    private static func stripANSI(_ s: String) -> String {
        var t = s
        let patterns = [
            #"\x1B\[[0-?]*[ -/]*[@-~]"#,              // CSI (colors, cursor, etc.)
            #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#,    // OSC (window title, hyperlinks)
            #"\x1B[@-Z\\\-_]"#,                        // Two-char ESC sequences
        ]
        for pat in patterns {
            if let re = try? NSRegularExpression(pattern: pat) {
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
            }
        }
        return t
    }
}

// MARK: - Views

struct TerminalSearchView: View {
    @ObservedObject var model: TerminalSearchModel
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
        .onExitCommand {
            if !model.query.isEmpty { model.query = "" } else { onClose() }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search session history…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
            if !model.query.isEmpty {
                Text(statusText)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        let n = model.matches.count
        if n == 0 { return "No matches" }
        return "\(n) match\(n == 1 ? "" : "es")"
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
            Text(model.query.isEmpty ? "Type to search session history" : "No matches found")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct MatchRow: View {
    let match: TerminalSearchModel.Match
    let query: String

    var body: some View {
        HStack(spacing: 6) {
            Text("\(match.lineNumber)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
                .monospacedDigit()
            Text(highlighted)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.vertical, 1)
    }

    private var highlighted: AttributedString {
        var a = AttributedString(match.snippet.prefix(300))
        if let r = a.range(of: query, options: .caseInsensitive) {
            a[r].backgroundColor = .yellow.opacity(0.55)
        }
        return a
    }
}

private struct ContextPane: View {
    let lines: [TerminalSearchModel.ContextLine]
    let query: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { row in
                    HStack(alignment: .top, spacing: 0) {
                        Text("\(row.id)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                            .padding(.trailing, 10)
                            .monospacedDigit()
                        Text(row.isMatch ? highlighted(row.text) : AttributedString(row.text))
                            .font(.system(size: 12, design: .monospaced))
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
        while pos < a.endIndex, let r = a[pos...].range(of: query, options: .caseInsensitive) {
            a[r].backgroundColor = .yellow.opacity(0.55)
            pos = r.upperBound
        }
        return a
    }
}

// MARK: - Window Controller

@MainActor
final class TerminalSearchWindowController: NSWindowController, NSWindowDelegate {
    let model = TerminalSearchModel()
    var onClose: (() -> Void)?

    init(sessionName: String) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = "Search — \(sessionName)"
        w.isRestorable = false
        w.center()
        super.init(window: w)
        w.delegate = self
        w.contentViewController = NSHostingController(
            rootView: TerminalSearchView(model: model, onClose: { [weak self] in self?.close() })
        )
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func loadText(_ text: String) { model.load(text: text) }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
