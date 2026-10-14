import AppKit
import SwiftUI

// MARK: - Window controller

/// The workspace's Search window (⇧⌘F): one search over its open sessions and
/// the past conversations that can be restored into it. An open session is
/// shown (focusing its pane if one already displays it); a past conversation
/// is restored as a new session. One per main window, kept across opens so
/// the last query is still there.
@MainActor
final class SearchWindowController: NSWindowController, NSWindowDelegate {
    let store: SearchStore
    private let workspace: WorkspaceController
    private weak var mainWindow: NSWindow?
    /// Where a restored conversation lands when its cwd isn't under any folder
    /// (the folder the "New Session" menu was opened for).
    var preferredFolder: UUID?

    /// `home` / `cacheDirectory` are for self-tests (see `SearchStore.init`).
    init(workspace: WorkspaceController, mainWindow: NSWindow?,
         home: URL? = nil, cacheDirectory: URL? = nil) {
        self.workspace = workspace
        self.mainWindow = mainWindow
        self.store = SearchStore(workspace: workspace, home: home, cacheDirectory: cacheDirectory)
        let w = SearchPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = "Search — \(workspace.rootURL.lastPathComponent)"
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.minSize = NSSize(width: 640, height: 360)
        super.init(window: w)
        w.delegate = self
        w.onCancel = { [weak self] in self?.close() }
        let hosting = NSHostingController(rootView: SearchView(
            store: store,
            onOpen: { [weak self] result in self?.open(result) },
            onClose: { [weak self] in self?.close() }))
        hosting.sizingOptions = []   // keep the window's size, not SwiftUI's ideal
        w.contentViewController = hosting   // (shrinks the window to the empty view; re-size below)
        w.setContentSize(NSSize(width: 880, height: 560))
        w.center()
        // Restore the last size/position, then keep saving it. (Naming before the
        // content is set would save — and later restore — the shrunken frame.)
        _ = w.setFrameUsingName(Self.autosaveName)
        w.setFrameAutosaveName(Self.autosaveName)
    }

    private static let autosaveName = "SandshellSearchWindow"

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Bring the window up with the search field focused (its text selected,
    /// so typing replaces the last query) and rescan past conversations.
    func show() {
        store.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        store.focusRequest += 1
    }

    /// Live → select it (the pane tree focuses a pane already showing it);
    /// past → restore it as a session, then select that.
    func open(_ result: SearchResult) {
        switch result.source {
        case .live(let id):
            guard workspace.session(id: id) != nil else { return }
            workspace.selection = .session(id)
        case .past(let record):
            guard let session = workspace.restoreSession(record, into: preferredFolder) else { return }
            workspace.selection = .session(session.id)
        }
        close()
        // Only take focus back when we're the active app (never steal it).
        if NSApp.isActive { mainWindow?.makeKeyAndOrderFront(nil) }
    }
}

/// Esc anywhere in the window closes it (a focused text field passes
/// `cancelOperation:` up the responder chain to here).
final class SearchPanelWindow: NSWindow {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

// MARK: - Root view

private struct SearchView: View {
    @ObservedObject var store: SearchStore
    let onOpen: (SearchResult) -> Void
    let onClose: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var preview: [PreviewMessage] = []
    @State private var previewLoading = false

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            HSplitView {
                resultsList.frame(minWidth: 300, idealWidth: 400, maxWidth: .infinity)
                previewPane.frame(minWidth: 260, maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .onExitCommand(perform: onClose)
        .onAppear { focusField() }
        .onChange(of: store.focusRequest) { _, _ in focusField() }
        .task(id: store.selected?.previewKey) { await loadPreview() }
    }

    private func focusField() {
        DispatchQueue.main.async { fieldFocused = true }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField("Search sessions and past conversations", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($fieldFocused)
                .onSubmit { if let s = store.selected { onOpen(s) } }
                .onKeyPress(.downArrow) { store.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { store.moveSelection(-1); return .handled }
            if store.busy { ProgressView().controlSize(.small) }
            if !store.query.isEmpty {
                Button { store.query = ""; focusField() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: Results

    private var liveResults: [SearchResult] { store.results.filter(\.isLive) }
    private var pastResults: [SearchResult] { store.results.filter { !$0.isLive } }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            List(selection: $store.selectedID) {
                if !liveResults.isEmpty {
                    Section("Open Sessions") {
                        ForEach(liveResults) { row($0) }
                    }
                }
                if !pastResults.isEmpty {
                    Section("Past Conversations") {
                        ForEach(pastResults) { row($0) }
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: SearchResult.ID.self) { ids in
                if let result = store.results.first(where: { ids.contains($0.id) }) {
                    Button(result.isLive ? "Show Session" : "Restore Session") { onOpen(result) }
                }
            } primaryAction: { ids in
                // Double-click / Return in the list.
                if let result = store.results.first(where: { ids.contains($0.id) }) { onOpen(result) }
            }
            .onChange(of: store.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .overlay { emptyState }
        }
    }

    private func row(_ result: SearchResult) -> some View {
        ResultRow(result: result, query: store.matchedQuery)
            .tag(result.id)
            .id(result.id)
    }

    @ViewBuilder
    private var emptyState: some View {
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

    // MARK: Preview

    @ViewBuilder
    private var previewPane: some View {
        if let sel = store.selected {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(highlighted(sel.title, store.matchedQuery))
                        .font(.headline).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(sel.agent.displayName.capitalized)
                        if let folder = sel.folder { Text("·"); Text(shortPath(folder)).truncationMode(.middle) }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
                transcript
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            Text("Nothing selected")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if preview.isEmpty {
            VStack {
                Spacer()
                if previewLoading { ProgressView().controlSize(.small) }
                else {
                    Text(store.selected?.isLive == true ? "No conversation yet" : "No messages")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(preview) { msg in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(msg.role == "user" ? "You" : "Assistant")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(msg.role == "user" ? Color.accentColor : .secondary)
                                Text(highlighted(msg.text, store.matchedQuery))
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(msg.id)
                        }
                    }
                    .padding(14)
                }
                .onAppear { scrollToFirstMatch(proxy) }
                .onChange(of: preview.first?.id) { _, _ in scrollToFirstMatch(proxy) }
            }
        }
    }

    private func scrollToFirstMatch(_ proxy: ScrollViewProxy) {
        let q = store.matchedQuery
        guard !q.isEmpty, let hit = preview.first(where: { $0.text.range(of: q, options: .caseInsensitive) != nil })
        else { return }
        proxy.scrollTo(hit.id, anchor: .top)
    }

    /// Load the selected conversation's messages off the main thread (an open
    /// session's transcript is located on demand).
    private func loadPreview() async {
        guard let sel = store.selected else { preview = []; return }
        preview = []
        previewLoading = true
        defer { previewLoading = false }
        let home = store.home
        let messages = await Task.detached(priority: .userInitiated) { () -> [PreviewMessage] in
            let url = sel.transcriptURL ?? sel.transcriptID.flatMap {
                TranscriptReader.transcriptURL(agent: sel.agent, workdir: sel.folder ?? "", home: home, id: $0)
            }
            guard let url else { return [] }
            return TranscriptReader.messages(at: url, agent: sel.agent).enumerated()
                .map { PreviewMessage(id: $0.offset, role: $0.element.role, text: $0.element.text) }
        }.value
        guard !Task.isCancelled else { return }
        preview = messages
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(footerText).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text("↑↓ to select · ↩ to open · esc to close")
                .font(.caption).foregroundStyle(.tertiary)
            Button(store.selected?.isLive == false ? "Restore Session" : "Show Session") {
                if let s = store.selected { onOpen(s) }
            }
            .disabled(store.selected == nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var footerText: String {
        let live = store.liveCount, past = store.pastCount
        let counts = "\(live) open session\(live == 1 ? "" : "s"), \(past) past conversation\(past == 1 ? "" : "s")"
        return store.matchedQuery.isEmpty ? counts + " in this workspace"
                                          : "Matches in this workspace: " + counts
    }
}

private struct PreviewMessage: Identifiable {
    let id: Int
    let role: String
    let text: String
}

private extension SearchResult {
    /// Changes when the preview must reload (not on every re-rank).
    var previewKey: String { id + "|" + (transcriptID ?? "") + "|" + (transcriptURL?.path ?? "") }
}

// MARK: - Row

private struct ResultRow: View {
    let result: SearchResult
    let query: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            AgentBadge(agent: result.agent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if result.isChat {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("Chat session")
                    }
                    Text(highlighted(result.title, query))
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if result.isLive {
                        Text("Open")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                    }
                }
                HStack(spacing: 5) {
                    if let folder = result.folder {
                        Text(highlighted(shortPath(folder), query))
                            .lineLimit(1).truncationMode(.middle)
                        Text("·")
                    }
                    Text(result.date, format: .relative(presentation: .named))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let snippet = result.snippet {
                    Text(highlighted(snippet, query))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// The agent's colored badge with its brand logo (glyph fallback).
private struct AgentBadge: View {
    let agent: AgentKind

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color(agent.badgeColor))
            if let name = agent.badgeImageName, let img = NSImage(named: name) {
                Image(nsImage: img).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 12, height: 12).foregroundStyle(.white)
            } else {
                Text(agent.badgeGlyph).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - Helpers

/// Bold + tint every occurrence of `query` in `text`.
private func highlighted(_ text: String, _ query: String) -> AttributedString {
    var attr = AttributedString(text)
    guard !query.isEmpty else { return attr }
    var idx = attr.startIndex
    while idx < attr.endIndex, let r = attr[idx...].range(of: query, options: .caseInsensitive) {
        attr[r].inlinePresentationIntent = .stronglyEmphasized
        attr[r].backgroundColor = Color.accentColor.opacity(0.28)
        idx = r.upperBound
    }
    return attr
}

private func shortPath(_ p: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if p == home { return "~" }
    if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
    return p
}
