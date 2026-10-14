import AppKit

/// What a split pane's Files surface shows: a session's folder (following its
/// working directory) or, once that session is gone, the folder it last had.
struct FilesTarget: Codable, Equatable {
    var session: UUID?
    var folder: String

    /// The folder to show and the pane title ("Files — <session or folder>").
    @MainActor
    func resolve(in controller: WorkspaceController) -> (url: URL, title: String) {
        if let id = session, let s = controller.session(id: id) {
            return (URL(fileURLWithPath: s.workdir), s.name)
        }
        let url = URL(fileURLWithPath: folder)
        return (url, url.lastPathComponent)
    }
}

/// The Files pane: the session folder's tree beside an editor — docked on the
/// window's trailing edge (following the active session), or hosted in a
/// split pane (`FilesTarget`).
@MainActor
final class FilesPaneController: NSSplitViewController {
    let tree = FileTreeController()
    let editor = FileEditorController()
    /// Narrower minimums for a split pane (the inspector has room to spare).
    private let compact: Bool
    private var openQuicklyPopover: NSPopover?
    /// "Add to Chat" from the tree's context menu.
    var onAddToChat: (([URL]) -> Void)? {
        get { tree.onAddToChat }
        set { tree.onAddToChat = newValue }
    }

    init(compact: Bool = false) {
        self.compact = compact
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = compact ? "SandshellFilesPaneSplit" : "SandshellFilesSplit"
        let treeItem = NSSplitViewItem(viewController: tree)
        treeItem.minimumThickness = compact ? 170 : 180
        treeItem.maximumThickness = 420
        treeItem.canCollapse = true
        treeItem.holdingPriority = .init(260)
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = compact ? 150 : 280
        addSplitViewItem(treeItem)
        addSplitViewItem(editorItem)
        tree.onOpen = { [weak self] url in self?.editor.open(url) }
        tree.onOpenAtLine = { [weak self] url, line, query in self?.editor.open(url, line: line, highlight: query) }
        tree.onGitStatus = { [weak self] status in self?.editor.updateGit(status) }
        tree.onFilesChanged = { [weak self] in self?.editor.filesChangedOnDisk() }
    }

    /// Show `folder` (nil = nothing).
    func setRoot(_ folder: URL?) {
        _ = view   // make sure children are loaded
        tree.setRoot(folder)
    }

    func open(_ url: URL) {
        _ = view
        editor.open(url)
    }

    /// Before this surface goes away: save or discard unsaved edits (false = cancel).
    func confirmClose() -> Bool { !isViewLoaded || editor.confirmCloseAll() }

    // MARK: Open Quickly (⇧⌘O)

    @objc func openQuickly(_ sender: Any?) {
        guard let root = tree.root else { NSSound.beep(); return }
        if let open = openQuicklyPopover, open.isShown { open.close(); return }
        let finder = OpenQuicklyController(root: root)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = finder
        finder.onOpen = { [weak self, weak popover] url in
            popover?.close()
            self?.editor.open(url)
            self?.tree.reveal(url)
        }
        finder.onCancel = { [weak popover] in popover?.close() }
        openQuicklyPopover = popover
        let anchor = editor.headerView
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    #if DEBUG
    var openQuicklyController: OpenQuicklyController? {
        openQuicklyPopover?.contentViewController as? OpenQuicklyController
    }
    #endif
}
