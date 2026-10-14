import AppKit

/// The Files pane's tree: the session's folder with Finder icons and git
/// status, live-refreshed as files change. A filter field above it narrows to
/// matching files (fuzzy, by name). Single-click opens a file in the editor;
/// Space is Quick Look; rows drag out as files.
@MainActor
final class FileTreeController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                NSSearchFieldDelegate, NSMenuDelegate {
    /// Open a file in the editor.
    var onOpen: ((URL) -> Void)?
    /// "Add to Chat" from the context menu.
    var onAddToChat: (([URL]) -> Void)?
    /// Git status changed (the editor refreshes its change markers).
    var onGitStatus: ((GitStatus) -> Void)?
    /// Something under the root changed on disk (the editor reloads clean files).
    var onFilesChanged: (() -> Void)?

    private(set) var root: URL?
    private(set) var git = GitStatus.empty
    private var rootNode: FileNode?
    private var watcher: FileWatcher?
    private var refreshPending = false
    private var filterResults: [FileNode]?

    private let filter = NSSearchField()
    private let outline = FileOutlineView()
    private let branchLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView()
        filter.placeholderString = "Filter files"
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.setAccessibilityIdentifier("files-filter")

        let column = NSTableColumn(identifier: .init("file"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 22
        outline.indentationPerLevel = 13
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.doubleAction = #selector(doubleClicked)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.onQuickLook = { [weak self] in self?.quickLookSelection() }
        outline.setAccessibilityIdentifier("files-tree")
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        branchLabel.font = .systemFont(ofSize: 11)
        branchLabel.textColor = .secondaryLabelColor
        branchLabel.lineBreakMode = .byTruncatingMiddle

        for v in [filter, scroll, branchLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            filter.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            filter.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            filter.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            branchLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            branchLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            branchLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            branchLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
    }

    // MARK: Root

    /// Show `url`'s tree (the active session's working directory).
    func setRoot(_ url: URL?) {
        guard url?.standardizedFileURL != root?.standardizedFileURL else { return }
        root = url
        watcher?.stop()
        watcher = nil
        filter.stringValue = ""
        filterResults = nil
        guard let url else {
            rootNode = nil
            outline.reloadData()
            return
        }
        let node = FileNode(url: url, isDirectory: true)
        node.loadChildren()
        rootNode = node
        outline.reloadData()
        watcher = FileWatcher(path: url.path) { [weak self] in self?.scheduleRefresh() }
        refreshGit()
    }

    /// Coalesce file-system bursts into one re-list + git status.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.onFilesChanged?()
            self.rootNode?.reloadLoaded()
            if !self.filter.stringValue.isEmpty { self.applyFilter() } else { self.outline.reloadData() }
            self.refreshGit()
        }
    }

    private func refreshGit() {
        guard let root else { return }
        Task { [weak self] in
            let status = await GitStatus.load(for: root)
            guard let self, self.root == root else { return }
            if status != self.git {
                self.git = status
                self.outline.reloadData()
                self.onGitStatus?(status)
            }
            let changed = status.changes.count
            self.branchLabel.stringValue = status.repoRoot == nil ? "Not a git repository"
                : "\(status.branch ?? "detached")" + (changed > 0 ? " · \(changed) changed" : " · clean")
        }
    }

    // MARK: Filter

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    private func applyFilter() {
        guard let root else { return }
        let query = filter.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            filterResults = nil
            outline.reloadData()
            return
        }
        let base = root.path
        Task { [weak self] in
            let files = await WorkspaceFileIndex.shared.files(under: base)
            let matches = WorkspaceFileIndex.match(files, query: query, limit: 200)
            guard let self, self.filter.stringValue.trimmingCharacters(in: .whitespaces) == query else { return }
            self.filterResults = matches.map { FileNode(url: URL(fileURLWithPath: base).appendingPathComponent($0), isDirectory: false) }
            self.outline.reloadData()
            if !matches.isEmpty { self.outline.selectRowIndexes([0], byExtendingSelection: false) }
        }
    }

    /// ↓ from the filter moves into the results; Return opens the first.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            view.window?.makeFirstResponder(outline)
            if outline.selectedRow < 0, outline.numberOfRows > 0 { outline.selectRowIndexes([0], byExtendingSelection: false) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let node = (outline.item(atRow: max(outline.selectedRow, 0)) as? FileNode), !node.isDirectory {
                onOpen?(node.url)
            }
            return true
        default: return false
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let results = filterResults { return item == nil ? results.count : 0 }
        guard let node = (item as? FileNode) ?? rootNode else { return 0 }
        if !node.isLoaded { node.loadChildren() }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let results = filterResults { return results[index] }
        let node = (item as? FileNode) ?? rootNode!
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        filterResults == nil && ((item as? FileNode)?.isDirectory ?? false)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        (item as? FileNode)?.url as NSURL?
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: FileCell.id, owner: nil) as? FileCell ?? FileCell()
        let path = node.url.path
        let change = git.changes[path]
        let title = filterResults != nil && root != nil
            ? String(path.dropFirst(root!.path.count + 1)) : node.name
        cell.configure(icon: NSWorkspace.shared.icon(forFile: path), title: title, change: change,
                       dirtyFolder: node.isDirectory && git.dirtyFolders.contains(path))
        return cell
    }

    @objc private func clicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode, !node.isDirectory else { return }
        onOpen?(node.url)
    }

    @objc private func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else {
            NSWorkspace.shared.open(node.url)   // double-click: the default app, like Finder
        }
    }

    // MARK: Context menu

    private var menuTargets: [URL] {
        let clicked = outline.clickedRow
        let rows = clicked >= 0 && !outline.selectedRowIndexes.contains(clicked)
            ? IndexSet(integer: clicked) : outline.selectedRowIndexes
        return rows.compactMap { (outline.item(atRow: $0) as? FileNode)?.url }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = menuTargets
        guard !urls.isEmpty else { return }
        func add(_ title: String, _ handler: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(ClosureMenuItem.run), keyEquivalent: "")
            let box = ClosureMenuItem(handler)
            item.target = box
            item.representedObject = box
            menu.addItem(item)
        }
        if urls.count == 1, !urls[0].hasDirectoryPath { add("Open") { [weak self] in self?.onOpen?(urls[0]) } }
        add("Quick Look") { QuickLook.shared.show(urls) }
        add("Add to Chat") { [weak self] in self?.onAddToChat?(urls) }
        menu.addItem(.separator())
        add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        add("Open with Default App") { urls.forEach { NSWorkspace.shared.open($0) } }
        menu.addItem(.separator())
        add("Copy Path") { Self.copy(urls.map(\.path)) }
        if let root {
            add("Copy Relative Path") {
                Self.copy(urls.map { $0.path.hasPrefix(root.path + "/") ? String($0.path.dropFirst(root.path.count + 1)) : $0.path })
            }
        }
    }

    private static func copy(_ lines: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func quickLookSelection() {
        let urls = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? FileNode)?.url }
        QuickLook.shared.show(urls)
    }
}

/// Outline that maps Space to Quick Look (the Finder convention).
final class FileOutlineView: NSOutlineView {
    var onQuickLook: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onQuickLook?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Icon + name + git badge.
final class FileCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("FileCell")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        imageView = icon
        textField = name
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 13)
        badge.font = .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        badge.alignment = .right
        for v in [icon, name, badge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(icon image: NSImage, title: String, change: GitStatus.Change?, dirtyFolder: Bool) {
        icon.image = image
        name.stringValue = title
        name.textColor = change.map { $0 == .deleted ? NSColor.secondaryLabelColor : $0.color } ?? .labelColor
        if let change {
            badge.stringValue = change.badge
            badge.textColor = change.color
        } else {
            badge.stringValue = dirtyFolder ? "●" : ""
            badge.textColor = .systemOrange.withAlphaComponent(0.7)
        }
    }
}
