import AppKit
import SwiftUI

/// The Files pane's tree: the session's folder with Finder icons and git
/// status, live-refreshed as files change. A filter field above it narrows to
/// matching files (fuzzy, by name). Single-click opens a file in the editor;
/// Space is Quick Look; rows drag out as files.
@MainActor
final class FileTreeController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                NSSearchFieldDelegate, NSMenuDelegate {
    /// Open a file in the editor (at a line, for search results).
    var onOpen: ((URL) -> Void)?
    var onOpenAtLine: ((URL, Int, String) -> Void)?
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
    /// The repo's .git, when the root is a folder inside the repo (commits and
    /// checkouts happen there, outside the root's own watch).
    private var gitWatcher: FileWatcher?
    private var gitWatcherPath: String?
    private var refreshPending = false
    private var filterResults: [FileNode]?
    /// "?query" content-search results, grouped by file.
    private var searchGroups: [SearchGroup]?
    private var searchQuery = ""

    private let filter = NSSearchField()
    private let outline = FileOutlineView()
    private let branchLabel = NSTextField(labelWithString: "")
    /// Show only changed files (a flat list, git's view), not the tree.
    private(set) var changedOnly = false
    private let changedButton = NSButton()
    /// Whose changes the changed list shows: uncommitted (git status), all
    /// since the branch's base, or one commit (picked under Commits).
    private(set) var scope: ChangeScope = .uncommitted
    /// Show Changes asked for before git status had loaded.
    private var wantsChanges: ChangeScope?
    /// The scope's files with +/- counts, by absolute path.
    private var scoped: [String: ScopedFile] = [:]
    let commits = CommitsListView()
    /// The changed list's scope changed (the editor diffs against it).
    var onScope: ((ChangeScope, Set<String>) -> Void)?
    /// "Sandbox “x” · read-write": these are the sandbox's files too.
    private let sandboxButton = NSButton()
    private var sandboxPopover: NSPopover?

    /// What the session's sandbox can do with this folder (nil hides the line).
    var sandboxAccess: SandboxAccess? {
        didSet {
            guard isViewLoaded, sandboxAccess != oldValue else { return }
            updateSandboxLine()
        }
    }

    override func loadView() {
        let root = NSView()
        filter.placeholderString = "Filter, or ? to search in files"
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

        sandboxButton.isBordered = false
        sandboxButton.imagePosition = .imageLeading
        sandboxButton.alignment = .left
        sandboxButton.lineBreakMode = .byTruncatingTail
        sandboxButton.target = self
        sandboxButton.action = #selector(showSandboxAccess)
        sandboxButton.setAccessibilityIdentifier("files-sandbox-access")
        sandboxButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // "main · 3 changed": click for the changed files.
        branchLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(branchClicked)))
        let footer = NSStackView(views: [sandboxButton, branchLabel])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 5
        updateSandboxLine()

        changedButton.setButtonType(.pushOnPushOff)
        changedButton.bezelStyle = .accessoryBarAction
        changedButton.controlSize = .small
        changedButton.image = NSImage(systemSymbolName: "plusminus.circle", accessibilityDescription: "Changed files")
        changedButton.imagePosition = .imageOnly
        changedButton.toolTip = "Show only changed files"
        changedButton.target = self
        changedButton.action = #selector(toggleChanged)
        changedButton.setAccessibilityIdentifier("files-changed-toggle")
        changedButton.setContentHuggingPriority(.required, for: .horizontal)

        commits.onPick = { [weak self] scope in
            guard let self else { return }
            if let scope { self.pick(scope) } else if self.changedOnly { self.pick(.uncommitted) }
        }

        for v in [filter, changedButton, scroll, commits, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            // Below the window's toolbar (the inspector runs under it), the filter
            // on a row of its own, the changed-files toggle beneath it.
            filter.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            filter.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            filter.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            changedButton.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 6),
            changedButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            changedButton.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: changedButton.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            commits.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            {
                // The tree keeps a few rows however many commits there are.
                let c = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90)
                c.priority = .init(760)
                return c
            }(),
            commits.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commits.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: commits.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            branchLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -20),
            sandboxButton.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -20),
        ])
        view = root
    }

    // MARK: Sandbox

    private func updateSandboxLine() {
        guard let access = sandboxAccess else { sandboxButton.isHidden = true; return }
        sandboxButton.isHidden = false
        let tint: NSColor = access.mode == .readWrite ? .systemOrange : .secondaryLabelColor
        sandboxButton.image = NSImage(systemSymbolName: access.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        sandboxButton.contentTintColor = tint
        sandboxButton.attributedTitle = NSAttributedString(string: " " + access.summary, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: tint])
        sandboxButton.toolTip = "These files are shared with a sandbox — click for what it can do with them"
    }

    @objc private func showSandboxAccess() {
        guard let access = sandboxAccess else { return }
        NSPopover.toggle(&sandboxPopover, below: sandboxButton) { .hosting(SandboxAccessPopover(access: access)) }
    }

    // MARK: Root

    /// Show `url`'s tree (the active session's working directory).
    func setRoot(_ url: URL?) {
        guard url?.standardizedFileURL != root?.standardizedFileURL else { return }
        root = url
        watcher?.stop()
        watcher = nil
        gitWatcher?.stop()
        gitWatcher = nil
        gitWatcherPath = nil
        filter.stringValue = ""
        filterResults = nil
        searchGroups = nil
        changedOnly = false
        changedButton.state = .off
        scope = .uncommitted
        scoped = [:]
        wantsChanges = nil
        commits.select(nil)
        // The last root's status and scope mean nothing here (and the editor
        // mustn't keep diffing the old repo's commit).
        git = .empty
        onScope?(.uncommitted, [])
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

    /// Expand down to `url` and select it (Open Quickly) — unless a filter is showing.
    func reveal(_ url: URL) {
        guard let root, let rootNode, filterResults == nil, searchGroups == nil,
              url.path.hasPrefix(root.path + "/") else { return }
        var node = rootNode
        for name in url.path.dropFirst(root.path.count + 1).split(separator: "/") {
            if !node.isLoaded { node.loadChildren() }
            guard let child = node.children?.first(where: { $0.name == name }) else { return }
            if node !== rootNode { outline.expandItem(node) }
            node = child
        }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
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
            if let repo = status.repoRoot, repo != root.realPath, self.gitWatcherPath != repo + "/.git" {
                self.gitWatcher?.stop()
                self.gitWatcherPath = repo + "/.git"
                self.gitWatcher = FileWatcher(path: repo + "/.git") { [weak self] in self?.scheduleRefresh() }
            }
            if status != self.git {
                self.git = status
                if self.changedOnly && self.filter.stringValue.isEmpty { self.showChangedList() }
                self.outline.reloadData()
                self.onGitStatus?(status)
            }
            let changed = status.changes.count
            self.updateChangedTitle()
            self.changedButton.imagePosition = .imageLeading
            self.changedButton.isEnabled = status.repoRoot != nil
            self.changedButton.toolTip = status.repoRoot == nil ? "Not a git repository"
                : "Show only changed files (\(changed))"
            self.branchLabel.stringValue = status.repoRoot == nil ? "Not a git repository"
                : "\(status.branch ?? "detached")" + (changed > 0 ? " · \(changed) changed" : " · clean")
            self.refreshHistory()
            if let wanted = self.wantsChanges, status.repoRoot != nil { self.showChanges(true, scope: wanted) }
            else if self.changedOnly { self.loadScope() }
        }
    }

    // MARK: Commits

    /// "3 changed" for the working tree; "4 files in ea0f97b" while a commit's
    /// files are listed, "9 changed on branch" for all of them.
    private func updateChangedTitle() {
        let changed = git.changes.count
        switch (changedOnly, scope) {
        case (true, .commit(let c)): changedButton.title = "\(scoped.count) files in \(c.short)"
        case (true, .all): changedButton.title = "\(scoped.count) changed on branch"
        default:
            changedButton.title = git.repoRoot == nil ? "No git" : changed > 0 ? "\(changed) changed" : "No changes"
        }
    }

    /// The branch's commits for the Commits section (hidden outside a repo).
    private func refreshHistory() {
        guard let repo = git.repoRoot else { commits.isHidden = true; return }
        commits.isHidden = false
        Task { [weak self] in
            let history = await Task.detached(priority: .utility) { GitHistory.commits(repo: repo) }.value
            guard let self, self.git.repoRoot == repo else { return }
            // "All changes" follows the base if it moved (a rebase, a pull).
            if case .all = self.scope, let base = history.base, self.scope != .all(base: base) { self.pick(.all(base: base)) }
            self.commits.update(base: history.base, commits: history.commits, picked: self.changedOnly ? self.scope : nil)
        }
    }

    /// Show `scope`'s files as the changed list.
    private func pick(_ scope: ChangeScope) {
        self.scope = scope
        if !changedOnly { showChanges(true, scope: scope) } else { commits.select(scope); loadScope() }
    }

    /// Load the scope's files and counts, then refresh the list and the editor.
    private func loadScope() {
        guard let repo = git.repoRoot else { return }
        let scope = scope
        let untracked = git.changes.filter { $0.value == .untracked }.map(\.key)
        Task { [weak self] in
            let files = await Task.detached(priority: .utility) {
                GitHistory.files(repo: repo, scope: scope, untracked: untracked)
            }.value
            guard let self, self.scope == scope, self.changedOnly, self.git.repoRoot == repo else { return }
            let new = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            let changedSet = Set(new.keys) != Set(self.scoped.keys)
            self.scoped = new
            self.updateChangedTitle()
            if self.filter.stringValue.isEmpty { self.showChangedList() }
            self.outline.reloadData()
            if changedSet, self.outline.selectedRow < 0, self.outline.numberOfRows > 0 {
                self.outline.selectRowIndexes([0], byExtendingSelection: false)
            }
            self.onScope?(scope, Set(new.keys))
        }
    }

    // MARK: Changed files

    /// Toggle the flat "changed files" list (also from the branch chip / footer).
    func showChanges(_ on: Bool) { showChanges(on, scope: .uncommitted) }

    private func showChanges(_ on: Bool, scope: ChangeScope) {
        _ = view
        // Asked for before the status has loaded (a new Files pane): do it then.
        if on, git.repoRoot == nil, root != nil { wantsChanges = scope; return }
        wantsChanges = nil
        changedOnly = on && git.repoRoot != nil
        changedButton.state = changedOnly ? .on : .off
        self.scope = changedOnly ? scope : .uncommitted
        commits.select(changedOnly ? self.scope : nil)
        if changedOnly {
            filter.stringValue = ""
            searchGroups = nil
            showChangedList()
            loadScope()
        } else {
            filterResults = nil
            scoped = [:]
            updateChangedTitle()
            onScope?(.uncommitted, [])
        }
        outline.reloadData()
        if changedOnly, outline.numberOfRows > 0 { outline.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc private func toggleChanged() { showChanges(changedButton.state == .on) }
    @objc private func branchClicked() { if !git.changes.isEmpty || changedOnly { showChanges(!changedOnly) } }

    /// The repo's changes under this folder (git reports real paths; the
    /// folder may be reached through a symlink like /tmp).
    private func showChangedList() {
        guard let root else { filterResults = []; return }
        let real = root.realPath
        let paths = scope == .uncommitted ? Array(git.changes.keys) : Array(scoped.keys)
        filterResults = paths.sorted().compactMap { path in
            let suffix: Substring
            if path.hasPrefix(root.path + "/") { suffix = path.dropFirst(root.path.count) }
            else if path.hasPrefix(real + "/") { suffix = path.dropFirst(real.count) }
            else { return nil }
            return FileNode(url: URL(fileURLWithPath: root.path + suffix), isDirectory: false)
        }
    }

    // MARK: Filter

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    private func applyFilter() {
        guard let root else { return }
        let query = filter.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchGroups = nil
            if changedOnly { showChangedList() } else { filterResults = nil }
            outline.reloadData()
            return
        }
        if query.hasPrefix("?") {
            searchContents(String(query.dropFirst()).trimmingCharacters(in: .whitespaces), in: root)
            return
        }
        searchGroups = nil
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

    /// `?query`: search file contents (git grep incl. untracked in a repo,
    /// grep otherwise), case-insensitive, fixed string; grouped by file.
    private func searchContents(_ query: String, in root: URL) {
        filterResults = nil
        searchQuery = query
        guard !query.isEmpty else {
            searchGroups = []
            outline.reloadData()
            return
        }
        let inRepo = git.repoRoot != nil
        Task { [weak self] in
            let output: String = await Task.detached(priority: .userInitiated) {
                if inRepo {
                    return GitStatus.git(["-C", root.path, "grep", "-n", "-I", "-i", "-F", "--untracked",
                                          "--no-color", "-e", query, "--", "."]) ?? ""
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
                p.currentDirectoryURL = root
                p.arguments = ["-rnIiF", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=build",
                               "--exclude-dir=.build", "--exclude-dir=DerivedData", "-e", query, "."]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return "" }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(decoding: data, as: UTF8.self)
            }.value
            guard let self, self.filter.stringValue.trimmingCharacters(in: .whitespaces) == "?" + query
                    || self.filter.stringValue.trimmingCharacters(in: .whitespaces) == "? " + query else { return }
            var groups: [String: SearchGroup] = [:]
            var order: [String] = []
            var total = 0
            for line in output.split(separator: "\n") where total < 500 {
                // path:line:text (path may contain ':' — split from the left on the first two).
                let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let n = Int(parts[1]) else { continue }
                var rel = String(parts[0])
                if rel.hasPrefix("./") { rel.removeFirst(2) }
                let url = root.appendingPathComponent(rel)
                let group = groups[rel] ?? {
                    order.append(rel)
                    let g = SearchGroup(url: url, relative: rel)
                    groups[rel] = g
                    return g
                }()
                group.matches.append(MatchNode(url: url, line: n, text: String(parts[2])))
                total += 1
            }
            self.searchGroups = order.compactMap { groups[$0] }
            self.outline.reloadData()
            self.outline.expandItem(nil, expandChildren: true)
            self.branchLabel.stringValue = "\(total) match\(total == 1 ? "" : "es") in \(order.count) file\(order.count == 1 ? "" : "s")"
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
            let item = outline.item(atRow: max(outline.selectedRow, 0))
            if let match = item as? MatchNode ?? (item as? SearchGroup)?.matches.first {
                onOpenAtLine?(match.url, match.line, searchQuery)
            } else if let node = item as? FileNode, !node.isDirectory {
                onOpen?(node.url)
            }
            return true
        default: return false
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let groups = searchGroups {
            if item == nil { return groups.count }
            return (item as? SearchGroup)?.matches.count ?? 0
        }
        if let results = filterResults { return item == nil ? results.count : 0 }
        guard let node = (item as? FileNode) ?? rootNode else { return 0 }
        if !node.isLoaded { node.loadChildren() }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let groups = searchGroups {
            if let group = item as? SearchGroup { return group.matches[index] }
            return groups[index]
        }
        if let results = filterResults { return results[index] }
        let node = (item as? FileNode) ?? rootNode!
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is SearchGroup { return true }
        return filterResults == nil && searchGroups == nil && ((item as? FileNode)?.isDirectory ?? false)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        ((item as? FileNode)?.url ?? (item as? SearchGroup)?.url) as NSURL?
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SearchGroup {
            let cell = outlineView.makeView(withIdentifier: FileCell.id, owner: nil) as? FileCell ?? FileCell()
            cell.configure(icon: NSWorkspace.shared.icon(forFile: group.url.path), title: group.relative,
                           change: git.change(for: group.url), dirtyFolder: false)
            return cell
        }
        if let match = item as? MatchNode {
            let cell = outlineView.makeView(withIdentifier: MatchCell.id, owner: nil) as? MatchCell ?? MatchCell()
            cell.configure(match, query: searchQuery)
            return cell
        }
        guard let node = item as? FileNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: FileCell.id, owner: nil) as? FileCell ?? FileCell()
        let path = node.url.path
        let real = node.url.realPath
        let inScope = changedOnly ? scoped[path] ?? scoped[real] : nil
        let change = scope == .uncommitted || !changedOnly
            ? git.changes[path] ?? git.changes[real] : inScope?.change
        let title = filterResults != nil && root != nil
            ? String(path.dropFirst(root!.path.count + 1)) : node.name
        cell.configure(icon: NSWorkspace.shared.icon(forFile: path), title: title, change: change,
                       dirtyFolder: node.isDirectory && (git.dirtyFolders.contains(path) || git.dirtyFolders.contains(real)),
                       counts: inScope.map { ($0.added, $0.removed) })
        return cell
    }

    @objc private func clicked() {
        let item = outline.item(atRow: outline.clickedRow)
        if let match = item as? MatchNode { onOpenAtLine?(match.url, match.line, searchQuery); return }
        if let group = item as? SearchGroup { onOpen?(group.url); return }
        guard let node = item as? FileNode, !node.isDirectory else { return }
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

    func configure(icon image: NSImage, title: String, change: GitStatus.Change?, dirtyFolder: Bool,
                   counts: (added: Int?, removed: Int?)? = nil) {
        icon.image = image
        name.stringValue = title
        name.textColor = change.map { $0 == .deleted ? NSColor.secondaryLabelColor : $0.color } ?? .labelColor
        if let counts {
            // "+22 −1" in the changed list, in place of the status letter.
            let out = NSMutableAttributedString()
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            if let a = counts.added, let r = counts.removed {
                out.append(NSAttributedString(string: "+\(a)", attributes: [.font: font, .foregroundColor: NSColor.systemGreen]))
                out.append(NSAttributedString(string: " −\(r)", attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
            } else {
                out.append(NSAttributedString(string: "bin", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            badge.attributedStringValue = out
        } else if let change {
            badge.stringValue = change.badge
            badge.textColor = change.color
        } else {
            badge.stringValue = dirtyFolder ? "●" : ""
            badge.textColor = .systemOrange.withAlphaComponent(0.7)
        }
    }
}

/// Content-search results for one file.
@MainActor
final class SearchGroup: NSObject {
    let url: URL
    let relative: String
    var matches: [MatchNode] = []
    init(url: URL, relative: String) {
        self.url = url
        self.relative = relative
    }
}

/// One matching line.
final class MatchNode: NSObject {
    let url: URL
    let line: Int
    let text: String
    init(url: URL, line: Int, text: String) {
        self.url = url
        self.line = line
        self.text = text
    }
}

/// "12  …matching line…" with the query emphasised.
final class MatchCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("MatchCell")
    private let number = NSTextField(labelWithString: "")
    private let snippet = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        number.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        number.textColor = .tertiaryLabelColor
        number.alignment = .right
        snippet.lineBreakMode = .byTruncatingTail
        for v in [number, snippet] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor),
            number.widthAnchor.constraint(equalToConstant: 30),
            number.centerYAnchor.constraint(equalTo: centerYAnchor),
            snippet.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 6),
            snippet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            snippet.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ match: MatchNode, query: String) {
        number.stringValue = "\(match.line)"
        let text = match.text.trimmingCharacters(in: .whitespaces)
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
        var range = (text as NSString).range(of: query, options: .caseInsensitive)
        while range.location != NSNotFound {
            s.addAttributes([.foregroundColor: NSColor.labelColor,
                             .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)], range: range)
            let next = NSMaxRange(range)
            range = (text as NSString).range(of: query, options: .caseInsensitive,
                                             range: NSRange(location: next, length: (text as NSString).length - next))
        }
        snippet.attributedStringValue = s
    }
}

#if DEBUG
extension FileTreeController {
    /// Self-test: the filter field's frame in window coordinates.
    var debugFilterFrameInWindow: NSRect { filter.convert(filter.bounds, to: nil) }
    /// Self-test: the changed list's rows as "path +a −r" (or the badge).
    var debugListRows: [String] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView else { return nil }
            let badge = cell.subviews.compactMap { $0 as? NSTextField }.last?.stringValue ?? ""
            return "\(cell.textField?.stringValue ?? "") \(badge)"
        }
    }
    var debugChangedTitle: String { changedButton.title }
    /// Self-test: open the changed list's row like a click.
    func debugOpenRow(_ row: Int) {
        guard let node = outline.item(atRow: row) as? FileNode else { return }
        onOpen?(node.url)
    }
}
#endif
