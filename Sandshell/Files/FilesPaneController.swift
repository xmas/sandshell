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
            return (URL(filePath: s.workdir, directoryHint: .checkFileSystem), controller.displayName(of: s))
        }
        let url = URL(filePath: folder, directoryHint: .checkFileSystem)
        return (url, url.lastPathComponent)
    }
}

/// Files: the session folder's tree and an editor. The window's Files sidebar
/// (trailing, full height, following the active session) stacks the editor
/// under the tree, with Commits at its foot and its header in the title bar
/// (`header`); a split pane (`compact`, `FilesTarget`) puts them side by side.
@MainActor
final class FilesPaneController: NSViewController, NSSplitViewDelegate {
    let tree = FileTreeController()
    let editor = FileEditorController()
    /// A split pane's layout (tree beside the editor, narrower minimums); the
    /// window's sidebar otherwise.
    private let compact: Bool
    private var isSidebar: Bool { !compact }
    /// The sidebar's header — "Files · main · 6 changed" — for the title bar above it.
    let header = FilesHeaderView()
    private var openQuicklyPopover: NSPopover?
    /// "Change this" text from a diff line, for the session's agent.
    var onAskAgent: ((String) -> Void)? {
        get { editor.onAskAgent }
        set { editor.onAskAgent = newValue }
    }
    /// "Add to Chat" from the tree's context menu.
    var onAddToChat: (([URL]) -> Void)? {
        get { tree.onAddToChat }
        set { tree.onAddToChat = newValue }
    }

    /// A plain, frame-based split: dragging its divider moves only its own two
    /// sides. (A nested NSSplitViewController's Auto Layout drag pushed every
    /// split in the window around, the sidebar included.)
    private let split = NSSplitView()
    private var placedDivider = false
    /// The tree's and the editor's least extent along the split (widths side
    /// by side, heights stacked in the sidebar).
    private var treeMin: CGFloat { isSidebar ? 120 : 170 }
    private var editorMin: CGFloat { isSidebar ? 140 : 150 }
    private static let treeMax: CGFloat = 420
    /// The last tree width (height, in the sidebar) the user dragged to: where
    /// new Files surfaces start.
    private var extentKey: String { isSidebar ? "filesSidebarTreeHeight" : "filesPaneTreeWidth" }
    /// Where the editor's open tabs are remembered. The window's sidebar has
    /// its own (its tabs stay as it follows the selected session from folder
    /// to folder); a split pane's is the first folder it shows.
    private let tabsKey: String?

    init(compact: Bool = false, tabsKey: String? = nil) {
        self.compact = compact
        self.tabsKey = tabsKey
        super.init(nibName: nil, bundle: nil)
        // The sidebar shows Commits at its foot and the branch in its header.
        tree.hostsCommits = compact
        tree.showsBranchLine = compact
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        split.isVertical = compact
        split.dividerStyle = .thin
        split.delegate = self
        addChild(tree)
        addChild(editor)
        split.addArrangedSubview(tree.view)
        split.addArrangedSubview(editor.view)
        guard isSidebar else { view = split; return }

        // Full height: the background runs up under the title bar (where the
        // header's toolbar items sit); the content starts below it.
        let sidebar = FilesSidebarView()
        for v in [split, tree.commits] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: sidebar.safeAreaLayoutGuide.topAnchor),
            split.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 1),
            split.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tree.commits.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 4),
            tree.commits.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 1),
            tree.commits.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tree.commits.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),
        ])
        header.onBranchClick = { [weak self] in
            guard let self, !self.tree.git.changes.isEmpty || self.tree.changedOnly else { return }
            self.tree.showChanges(!self.tree.changedOnly)
        }
        view = sidebar
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tree.onOpen = { [weak self] url in
            guard let self else { return }
            self.editor.open(url, showingChanges: self.tree.changedOnly)
        }
        tree.onScope = { [weak self] scope, files in self?.editor.setScope(scope, files: files) }
        tree.onOpenAtLine = { [weak self] url, line, query in self?.editor.open(url, line: line, highlight: query) }
        tree.onGitStatus = { [weak self] status in
            self?.editor.updateGit(status)
            self?.header.update(status)
        }
        tree.onFilesChanged = { [weak self] in self?.editor.filesChangedOnDisk() }
        tree.onFileMoved = { [weak self] from, to in self?.editor.fileMoved(from: from, to: to) }
        tree.onFilesTrashed = { [weak self] urls in self?.editor.filesTrashed(urls) }
    }

    /// The sidebar's colours (background, edge, header) from the window's theme.
    func applyChrome(_ colors: ThemeColors) {
        header.apply(colors)
        (view as? FilesSidebarView)?.apply(colors)
    }

    private func extent(_ v: NSView) -> CGFloat { compact ? v.frame.width : v.frame.height }
    private var splitExtent: CGFloat { compact ? split.bounds.width : split.bounds.height }

    override func viewDidLayout() {
        super.viewDidLayout()
        if isSidebar, view.bounds.width > 0 { header.fit(sidebarWidth: view.bounds.width) }
        guard !placedDivider, splitExtent >= treeMin + editorMin + split.dividerThickness else { return }
        placedDivider = true
        let saved = CGFloat(UserDefaults.standard.double(forKey: extentKey))
        let initial = isSidebar ? (splitExtent * 0.45).rounded() : 220
        split.setPosition(clampTree(saved > 0 ? saved : initial), ofDividerAt: 0)
    }

    /// Side by side the tree tops out at `treeMax`; stacked it can take all
    /// but the editor's minimum.
    private func treeLimit() -> CGFloat {
        let room = splitExtent - editorMin - split.dividerThickness
        return compact ? min(Self.treeMax, room) : room
    }

    private func clampTree(_ extent: CGFloat) -> CGFloat {
        max(treeMin, min(extent, treeLimit()))
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        treeMin
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        treeLimit()
    }

    /// When the surface itself resizes, the editor takes the change; the tree keeps its size.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== tree.view
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only the user's drags (AppKit tags them with the divider index) set the default.
        guard placedDivider, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        UserDefaults.standard.set(Double(extent(tree.view)), forKey: extentKey)
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
    static func folderTabsKey(_ folder: URL) -> String { "filesTabs:" + folder.standardizedFileURL.plainPath }

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
    /// Self-test: the editor sits under the tree (the sidebar), not beside it.
    var debugEditorBelowTree: Bool {
        let t = tree.view.convert(tree.view.bounds, to: nil), e = editor.view.convert(editor.view.bounds, to: nil)
        return e.maxY <= t.minY + 1
    }
    /// Self-test: where the content starts (its top, in window coordinates).
    var debugContentTop: CGFloat { split.convert(split.bounds, to: nil).maxY }
    var openQuicklyController: OpenQuicklyController? {
        openQuicklyPopover?.contentViewController as? OpenQuicklyController
    }
    #endif
}

// MARK: - The sidebar's ground

/// The Files sidebar's background: its own colour, full height, with a
/// hairline down its leading edge and one under the header (the title bar's
/// height), so it reads as a sidebar and not a pane.
@MainActor
private final class FilesSidebarView: NSView {
    private var fill = NSColor.windowBackgroundColor
    private var line = NSColor.separatorColor

    override var isFlipped: Bool { true }

    func apply(_ colors: ThemeColors) {
        fill = colors.filesSidebar
        line = colors.chromeLine
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
        line.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        let top = safeAreaInsets.top
        if top > 0 { NSRect(x: 0, y: top - 1, width: bounds.width, height: 1).fill() }
    }

    override func layout() {
        super.layout()
        needsDisplay = true   // the header's rule follows the title bar's height
    }
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
