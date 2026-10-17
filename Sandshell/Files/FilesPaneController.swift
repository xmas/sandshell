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
final class FilesPaneController: NSViewController, NSSplitViewDelegate {
    let tree = FileTreeController()
    let editor = FileEditorController()
    /// Narrower minimums for a split pane (the inspector has room to spare).
    private let compact: Bool
    private var openQuicklyPopover: NSPopover?
    /// "Add to Chat" from the tree's context menu.
    /// "Change this" text from a diff line, for the session's agent.
    var onAskAgent: ((String) -> Void)? {
        get { editor.onAskAgent }
        set { editor.onAskAgent = newValue }
    }
    var onAddToChat: (([URL]) -> Void)? {
        get { tree.onAddToChat }
        set { tree.onAddToChat = newValue }
    }

    /// A plain, frame-based split: dragging its divider moves only its own two
    /// sides. (A nested NSSplitViewController's Auto Layout drag pushed every
    /// split in the window around, the sidebar included.)
    private let split = NSSplitView()
    private var placedDivider = false
    private var treeMin: CGFloat { compact ? 170 : 180 }
    private var editorMin: CGFloat { compact ? 150 : 280 }
    private static let treeMax: CGFloat = 420
    /// The last tree width the user dragged to: where new Files panes start.
    private var widthKey: String { compact ? "filesPaneTreeWidth" : "filesTreeWidth" }
    /// Where the editor's open tabs are remembered. The window's inspector has
    /// its own (its tabs stay as it follows the selected session from folder
    /// to folder); a split pane's is the first folder it shows.
    private let tabsKey: String?

    init(compact: Bool = false, tabsKey: String? = nil) {
        self.compact = compact
        self.tabsKey = tabsKey
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        addChild(tree)
        addChild(editor)
        split.addArrangedSubview(tree.view)
        split.addArrangedSubview(editor.view)
        view = split
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tree.onOpen = { [weak self] url in
            guard let self else { return }
            self.editor.open(url, showingChanges: self.tree.changedOnly)
        }
        tree.onScope = { [weak self] scope, files in self?.editor.setScope(scope, files: files) }
        tree.onOpenAtLine = { [weak self] url, line, query in self?.editor.open(url, line: line, highlight: query) }
        tree.onGitStatus = { [weak self] status in self?.editor.updateGit(status) }
        tree.onFilesChanged = { [weak self] in self?.editor.filesChangedOnDisk() }
        tree.onFileMoved = { [weak self] from, to in self?.editor.fileMoved(from: from, to: to) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !placedDivider, split.bounds.width >= treeMin + editorMin + split.dividerThickness else { return }
        placedDivider = true
        let saved = CGFloat(UserDefaults.standard.double(forKey: widthKey))
        split.setPosition(clampTree(saved > 0 ? saved : 220), ofDividerAt: 0)
    }

    private func clampTree(_ width: CGFloat) -> CGFloat {
        max(treeMin, min(width, Self.treeMax, split.bounds.width - editorMin - split.dividerThickness))
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        treeMin
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        min(Self.treeMax, splitView.bounds.width - editorMin - splitView.dividerThickness)
    }

    /// When the pane itself resizes, the editor takes the change; the tree keeps its width.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== tree.view
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only the user's drags (AppKit tags them with the divider index) set the default.
        guard placedDivider, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        UserDefaults.standard.set(Double(tree.view.frame.width), forKey: widthKey)
    }

    /// Only the changed files (git), as a flat list.
    func showChanges() { _ = view; tree.showChanges(true) }

    /// Show `folder` (nil = nothing).
    func setRoot(_ folder: URL?, access: SandboxAccess? = nil) {
        _ = view   // make sure children are loaded
        tree.setRoot(folder)
        tree.sandboxAccess = access
        if editor.tabsKey == nil, let key = tabsKey ?? folder.map(Self.folderTabsKey) {
            if tabsKey != nil, let folder { Self.adoptTabs(from: Self.folderTabsKey(folder), into: key) }
            editor.tabsKey = key
            editor.restoreTabs()
        }
    }

    /// A split Files pane's tabs: under the first folder it shows.
    static func folderTabsKey(_ folder: URL) -> String { "filesTabs:" + folder.standardizedFileURL.path }

    /// The inspector's tabs used to be kept under the first folder it showed:
    /// the first time it has its own key, it starts from that list. Copied, not
    /// moved — a split Files pane on that folder may be using it too.
    static func adoptTabs(from old: String, into key: String, defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(defaults.stringArray(forKey: old) ?? [], forKey: key)
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
        let finder = OpenQuicklyController(root: root)
        finder.onOpen = { [weak self] url in
            self?.openQuicklyPopover?.close()
            self?.editor.open(url)
            self?.tree.reveal(url)
        }
        finder.onCancel = { [weak self] in self?.openQuicklyPopover?.close() }
        NSPopover.toggle(&openQuicklyPopover, below: editor.headerView) { finder }
    }

    #if DEBUG
    var openQuicklyController: OpenQuicklyController? {
        openQuicklyPopover?.contentViewController as? OpenQuicklyController
    }
    #endif
}

// MARK: - ⌘W in Files

extension FilesPaneController: NSMenuItemValidation {
    /// ⌘W with Files focused closes the open file's tab; with none open, it's
    /// the window's usual Close Session / Close Window.
    @objc func closeSessionOrWindow(_ sender: Any?) {
        if editor.closeCurrentTab() { return }
        (NSApp.delegate as? AppDelegate)?.closeSessionOrWindow(sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(closeSessionOrWindow(_:)) else { return true }
        if editor.hasOpenTab { item.title = "Close Tab"; return true }
        return (NSApp.delegate as? AppDelegate)?.validateMenuItem(item) ?? true
    }
}

