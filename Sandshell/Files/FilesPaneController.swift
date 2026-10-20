import AppKit

/// The window's Files sidebar: three columns side by side — the session
/// folder's tree (Commits at its foot), the open file (tabs, editor), and the
/// diff column (the open file's changes) — with its header (`header`) in the
/// title bar above them. Trailing, full height, following the active session.
/// The tree and the diff column hide and show (header buttons, View menu, a
/// divider double-clicked or dragged to the edge); the editor always shows.
@MainActor
final class FilesPaneController: NSViewController, NSSplitViewDelegate {
    let tree = FileTreeController()
    let editor = FileEditorController()
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
    /// The least width the shown columns need changed (a column showed or hid).
    var onMinimumWidthChange: ((CGFloat) -> Void)?

    /// A plain, frame-based split (tree | editor | diff): dragging a divider
    /// moves only its own two sides. (A nested NSSplitViewController's Auto
    /// Layout drag pushed every split in the window around.)
    private let columns = ColumnsSplitView()
    /// The tree with Commits under it.
    private let treeColumn = NSView()
    private var diffColumn: NSView { editor.diffColumn }
    /// Each column's least width.
    static let treeMin: CGFloat = 150
    static let editorMin: CGFloat = 220
    static let diffMin: CGFloat = 220
    /// The tree's and the diff column's widths (the editor takes the rest),
    /// as last dragged; every Files sidebar starts from them.
    private var treeWidth: CGFloat
    private var diffWidth: CGFloat
    private static let treeWidthKey = "filesSidebarTreeWidth"
    private static let diffWidthKey = "filesSidebarDiffWidth"
    /// Whether the tree / the diff column show, per window.
    private let treeHiddenKey: String
    private let diffShownKey: String
    /// Where the editor's open tabs are remembered: the window's own, so its
    /// tabs stay as it follows the selected session from folder to folder.
    private let tabsKey: String?

    /// `layoutKey` names the window, for which columns show.
    init(tabsKey: String? = nil, layoutKey: String = "") {
        self.tabsKey = tabsKey
        treeHiddenKey = "filesTreeHidden:" + layoutKey
        diffShownKey = "filesDiffShown:" + layoutKey
        let defaults = UserDefaults.standard
        let tree = CGFloat(defaults.double(forKey: Self.treeWidthKey))
        let diff = CGFloat(defaults.double(forKey: Self.diffWidthKey))
        treeWidth = tree > 0 ? max(Self.treeMin, tree) : 220
        diffWidth = diff > 0 ? max(Self.diffMin, diff) : 320
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        columns.isVertical = true
        columns.dividerStyle = .thin
        columns.delegate = self
        addChild(tree)
        addChild(editor)
        for v in [tree.view, tree.commits] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            treeColumn.addSubview(v)
        }
        NSLayoutConstraint.activate([
            tree.view.topAnchor.constraint(equalTo: treeColumn.topAnchor),
            tree.view.leadingAnchor.constraint(equalTo: treeColumn.leadingAnchor),
            tree.view.trailingAnchor.constraint(equalTo: treeColumn.trailingAnchor),
            tree.commits.topAnchor.constraint(equalTo: tree.view.bottomAnchor, constant: 4),
            tree.commits.leadingAnchor.constraint(equalTo: treeColumn.leadingAnchor),
            tree.commits.trailingAnchor.constraint(equalTo: treeColumn.trailingAnchor),
            tree.commits.bottomAnchor.constraint(equalTo: treeColumn.bottomAnchor, constant: -8),
        ])
        treeColumn.setAccessibilityIdentifier("files-tree-column")
        for v in [treeColumn, editor.view, diffColumn] { columns.addArrangedSubview(v) }
        treeColumn.isHidden = UserDefaults.standard.bool(forKey: treeHiddenKey)
        diffColumn.isHidden = !UserDefaults.standard.bool(forKey: diffShownKey)
        editor.diffColumnShown = !diffColumn.isHidden

        // Full height: the background runs up under the title bar (where the
        // header's toolbar items sit); the content starts below it.
        let sidebar = FilesSidebarView()
        columns.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: sidebar.safeAreaLayoutGuide.topAnchor),
            columns.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 1),
            columns.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            columns.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
        ])
        header.onBranchClick = { [weak self] in
            guard let self, !self.tree.git.changes.isEmpty || self.tree.changedOnly else { return }
            self.tree.showChanges(!self.tree.changedOnly)
        }
        header.onToggleTree = { [weak self] in self?.toggleTree() }
        header.update(treeShown: !treeColumn.isHidden)
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
        // Unsaved edits are changes too: the tree, header and diff count them.
        editor.onEditedChange = { [weak self] paths in self?.tree.editedPaths = paths }
        tree.onFilesChanged = { [weak self] in self?.editor.filesChangedOnDisk() }
        tree.onFileMoved = { [weak self] from, to in self?.editor.fileMoved(from: from, to: to) }
        tree.onFilesTrashed = { [weak self] urls in self?.editor.filesTrashed(urls) }
    }

    /// The sidebar's colours (background, edge, header) from the window's theme.
    func applyChrome(_ colors: ThemeColors) {
        header.apply(colors)
        (view as? FilesSidebarView)?.apply(colors)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if view.bounds.width > 0 { header.fit(sidebarWidth: view.bounds.width) }
    }

    // MARK: Columns

    var isTreeShown: Bool {
        isViewLoaded ? !treeColumn.isHidden : !UserDefaults.standard.bool(forKey: treeHiddenKey)
    }
    var isDiffColumnShown: Bool {
        isViewLoaded ? !diffColumn.isHidden : UserDefaults.standard.bool(forKey: diffShownKey)
    }

    /// View ▸ File Tree (⌥⌘1), the header's tree button.
    @objc func toggleTree() { setTreeShown(!isTreeShown) }
    /// View ▸ Diff Column (⌥⌘2), the header's diff button.
    @objc func toggleDiffColumn() { setDiffColumnShown(!isDiffColumnShown) }

    func setTreeShown(_ show: Bool) { setColumn(treeColumn, shown: show) }
    func setDiffColumnShown(_ show: Bool) { setColumn(diffColumn, shown: show) }

    /// Slides the column in or out (at once under Reduce Motion, or before
    /// the sidebar is on screen).
    private func setColumn(_ column: NSView, shown: Bool) {
        _ = view
        guard column.isHidden == shown, !animatingColumns else { return }
        let animate = view.window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animate else {
            column.isHidden = !shown
            layoutColumns()
            return columnsChanged()
        }
        animatingColumns = true
        if shown {
            // In from nothing: shown at no width, then opened to its own.
            column.isHidden = false
            var start = column.frame
            start.size.width = 0
            if column === diffColumn { start.origin.x = columns.bounds.width }
            column.frame = start
        }
        let frames = columnFrames(treeShown: column === treeColumn ? shown : !treeColumn.isHidden,
                                  diffShown: column === diffColumn ? shown : !diffColumn.isHidden)
        columns.lines = []
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            treeColumn.animator().frame = frames.tree
            editor.view.animator().frame = frames.editor
            diffColumn.animator().frame = frames.diff
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                column.isHidden = !shown
                self.animatingColumns = false
                self.layoutColumns()
                self.columnsChanged()
            }
        })
    }
    private var animatingColumns = false

    /// A column showed or hid (a button, the menu, a divider): remember it,
    /// and tell the editor, the header and the window (its least width).
    private func columnsChanged() {
        let treeShown = !treeColumn.isHidden, diffShown = !diffColumn.isHidden
        UserDefaults.standard.set(!treeShown, forKey: treeHiddenKey)
        UserDefaults.standard.set(diffShown, forKey: diffShownKey)
        editor.diffColumnShown = diffShown
        header.update(treeShown: treeShown)
        onMinimumWidthChange?(minimumWidth)
    }

    /// The least width of the sidebar with the columns that show (and its
    /// leading hairline): each at its minimum.
    var minimumWidth: CGFloat {
        let t = columns.dividerThickness > 0 ? columns.dividerThickness : 1
        return 1 + Self.editorMin + (isTreeShown ? Self.treeMin : 0) + (isDiffColumnShown ? Self.diffMin : 0) + 2 * t
    }

    /// The columns' frames: the tree and the diff column at their widths, the
    /// editor the rest. Short of room the diff column, then the tree, gives
    /// way down to its minimum; a hidden column is collapsed (no width).
    private func layoutColumns() {
        guard !animatingColumns else { return }
        let treeShown = !treeColumn.isHidden, diffShown = !diffColumn.isHidden
        let frames = columnFrames(treeShown: treeShown, diffShown: diffShown)
        treeColumn.frame = frames.tree
        editor.view.frame = frames.editor
        diffColumn.frame = frames.diff
        // A hairline where two shown columns meet; none for a hidden one.
        columns.lines = (treeShown ? [frames.tree.maxX] : []) + (diffShown ? [frames.editor.maxX] : [])
    }

    private func columnFrames(treeShown: Bool, diffShown: Bool) -> (tree: NSRect, editor: NSRect, diff: NSRect) {
        let size = columns.bounds.size, t = columns.dividerThickness
        var tw = treeShown ? treeWidth : 0
        var dw = diffShown ? diffWidth : 0
        let room = size.width - 2 * t
        var over = tw + dw + Self.editorMin - room
        if over > 0, diffShown {
            let give = min(over, max(0, dw - Self.diffMin))
            dw -= give
            over -= give
        }
        if over > 0, treeShown { tw -= min(over, max(0, tw - Self.treeMin)) }
        let lead = treeShown ? tw + t : 0
        let ew = max(0, size.width - lead - (diffShown ? dw + t : 0))
        return (NSRect(x: 0, y: 0, width: tw, height: size.height),
                NSRect(x: lead, y: 0, width: ew, height: size.height),
                NSRect(x: lead + ew + (diffShown ? t : 0), y: 0, width: dw, height: size.height))
    }

    // MARK: NSSplitViewDelegate

    /// The sidebar itself resized: the editor takes the change.
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        layoutColumns()
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === treeColumn || subview === diffColumn
    }

    /// Double-clicking a divider collapses the column at its outer side.
    nonisolated func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView,
                               forDoubleClickOnDividerAt dividerIndex: Int) -> Bool {
        MainActor.assumeIsolated {
            (dividerIndex == 0 && subview === treeColumn) || (dividerIndex == 1 && subview === diffColumn)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        index == 0 ? Self.treeMin : editor.view.frame.minX + Self.editorMin
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        index == 0 ? editor.view.frame.maxX - splitView.dividerThickness - Self.editorMin
            : splitView.bounds.width - splitView.dividerThickness - Self.diffMin
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // A divider dragged to the edge (or double-clicked) collapses its
        // column: NSSplitView hides it.
        if UserDefaults.standard.bool(forKey: treeHiddenKey) != treeColumn.isHidden
            || UserDefaults.standard.bool(forKey: diffShownKey) == diffColumn.isHidden {
            columnsChanged()
        }
        // Only the user's drags (AppKit tags them with the divider index) set the widths.
        guard notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        if !treeColumn.isHidden, treeColumn.frame.width >= Self.treeMin {
            treeWidth = treeColumn.frame.width
            UserDefaults.standard.set(Double(treeWidth), forKey: Self.treeWidthKey)
        }
        if !diffColumn.isHidden, diffColumn.frame.width >= Self.diffMin {
            diffWidth = diffColumn.frame.width
            UserDefaults.standard.set(Double(diffWidth), forKey: Self.diffWidthKey)
        }
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

    /// Where tabs were once kept: under the first folder shown.
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
    /// Self-test: the columns' frames in window coordinates (nil: hidden).
    var debugColumns: (tree: NSRect?, editor: NSRect, diff: NSRect?, commits: NSRect?) {
        func frame(_ v: NSView) -> NSRect? { v.isHidden ? nil : v.convert(v.bounds, to: nil) }
        return (frame(treeColumn), editor.view.convert(editor.view.bounds, to: nil), frame(diffColumn),
                tree.commits.isHidden ? nil : frame(tree.commits))
    }
    /// Self-test: the editor is a column to the tree's right, as tall as it.
    var debugEditorRightOfTree: Bool {
        let c = debugColumns
        guard let t = c.tree else { return false }
        return c.editor.minX >= t.maxX - 0.5 && abs(c.editor.minY - t.minY) < 1 && abs(c.editor.maxY - t.maxY) < 1
    }
    /// Self-test: a divider dragged to `position` (as a person would drag it).
    func debugDragDivider(_ index: Int, to position: CGFloat) {
        columns.setPosition(position, ofDividerAt: index)
    }
    var debugColumnsWidth: CGFloat { columns.bounds.width }
    /// Where hairlines are drawn between the columns.
    var debugDividerLines: [CGFloat] { columns.lines }
    /// Self-test: where the content starts (its top, in window coordinates).
    var debugContentTop: CGFloat { columns.convert(columns.bounds, to: nil).maxY }
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

/// The Files columns' split: the hairlines are drawn where shown columns meet
/// (`lines`), not by NSSplitView — its own left one behind at a hidden
/// column's old edge.
@MainActor
final class ColumnsSplitView: NSSplitView {
    var lines: [CGFloat] = [] { didSet { if lines != oldValue { needsDisplay = true } } }

    override func drawDivider(in rect: NSRect) {}

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        for x in lines { NSRect(x: x, y: 0, width: 1, height: bounds.height).fill() }
    }
}
