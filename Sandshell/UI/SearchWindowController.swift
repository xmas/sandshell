import AppKit
import SwiftUI

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
