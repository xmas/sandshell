import AppKit
import Quartz
import UniformTypeIdentifiers

/// One open file in the editor.
@MainActor
final class OpenFile {
    enum Mode: Int { case preview, source, changes }
    private(set) var url: URL
    var text: String
    var savedText: String
    /// The disk's modification date for the version last read or saved.
    var modified: Date?
    var mode: Mode
    var isText: Bool
    /// Why the file couldn't be read: said in place of an editor or Quick Look.
    var readError: (any Error)?
    var selection = NSRange(location: 0, length: 0)
    var isDirty: Bool { text != savedText }

    init(url: URL) {
        self.url = url
        // Over 4 MB isn't read at all (a big log would block the app): it shows
        // in Quick Look like any other non-text file. One that isn't there yet
        // opens empty (saving makes it); one that's there but can't be read
        // (permissions, a folder) is never an empty editable copy a save
        // would write over it.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var data: Data?
        if size <= 4_000_000 {
            do { data = try Data(contentsOf: url) }
            catch CocoaError.fileReadNoSuchFile { data = Data() }
            catch { readError = error }
        }
        let decoded = data.flatMap { $0.count <= 4_000_000 && !$0.prefix(8000).contains(0) ? String(data: $0, encoding: .utf8) : nil }
        isText = decoded != nil
        text = decoded ?? ""
        savedText = text
        modified = Self.modificationDate(of: url)
        mode = Self.isMarkdown(url) ? .preview : .source
    }

    /// When the file on disk was last written; nil when it's gone. Read
    /// fresh: a URL caches resource values until the run loop turns, so a read
    /// right after a save would still see the date from before it.
    static func modificationDate(of url: URL) -> Date? {
        var url = url
        url.removeAllCachedResourceValues()
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    enum DiskChange { case rewritten, gone }

    /// How the file on disk differs from the version last read or saved:
    /// rewritten (an agent, another app), or gone (moved, deleted, trashed).
    /// Nil when it's that same version.
    var diskChange: DiskChange? {
        let onDisk = Self.modificationDate(of: url)
        guard onDisk != modified else { return nil }
        return onDisk == nil ? .gone : .rewritten
    }

    /// Write the text to disk; from then on it's the saved version.
    func write() throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        savedText = text
        modified = Self.modificationDate(of: url)
    }

    /// It (or a folder holding it) was renamed or moved: same edits, same
    /// version to compare the disk with, new place.
    func move(to url: URL) { self.url = url }

    static func isMarkdown(_ url: URL) -> Bool { ["md", "markdown", "mdx"].contains(url.pathExtension.lowercased()) }
    var language: String { Self.language(for: url) }

    static func language(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": "swift"
        case "py": "python"
        case "js", "mjs", "cjs", "jsx", "ts", "tsx": "js"
        case "sh", "bash", "zsh", "command": "shell"
        case "go": "go"
        case "rs": "rust"
        case "rb": "ruby"
        case "yml", "yaml": "yaml"
        case "toml": "toml"
        default: url.pathExtension.lowercased()
        }
    }
}

/// Lines changed vs HEAD for the gutter, from `git diff -U0`.
struct LineChanges: Equatable {
    var added: Set<Int> = []
    var modified: Set<Int> = []
    /// Lines after which something was deleted (0 = before the first line).
    var deletedAfter: Set<Int> = []

    /// Off the caller's actor (git runs to completion).
    /// `text`: the file's unsaved edits, diffed instead of what's on disk.
    @concurrent static func load(file: URL, repoRoot: String?, untracked: Bool, lineCount: Int,
                                 text: String? = nil) async -> LineChanges {
        guard let repoRoot else { return LineChanges() }
        if untracked { return LineChanges(added: Set(1...max(lineCount, 1))) }
        if let text { return LineChanges(unifiedDiff: GitStatus.bufferDiff(path: file.plainPath, text: text, against: "HEAD", context: 0)) }
        guard let diff = GitStatus.git(["-C", repoRoot, "diff", "--no-color", "--no-ext-diff", "-U0", "HEAD", "--", file.plainPath])
        else { return LineChanges() }
        return LineChanges(unifiedDiff: diff)
    }
}

extension LineChanges {
    /// What a `git diff -U0`'s `@@ -a,b +c,d @@` headers say changed.
    init(unifiedDiff diff: String) {
        for m in diff.matches(of: /^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.anchorsMatchLineEndings()) {
            let oldCount = m.1.flatMap { Int($0) } ?? 1, start = Int(m.2) ?? 0, newCount = m.3.flatMap { Int($0) } ?? 1
            if newCount == 0 { deletedAfter.insert(start); continue }
            let lines = Set(start..<(start + newCount))
            if oldCount == 0 { added.formUnion(lines) } else { modified.formUnion(lines) }
        }
    }
}

private extension Character {
    /// A line break as `NSString.lineRange` and the ruler count them: LF, CR,
    /// CRLF, NEL, U+2028, U+2029 (`isNewline` also takes VT and FF).
    var isLineBreak: Bool { isNewline && self != "\u{0B}" && self != "\u{0C}" }
    /// Where git ends a diff line: LF ("\r\n" is one Character, a CRLF file's line end).
    var isGitLineEnd: Bool { self == "\n" || self == "\r\n" }
}

/// The Files pane's editor: tabs over a TextKit 2 code editor (highlighting,
/// line numbers, git change bars, ⌘S), a rendered Markdown preview, a Changes
/// view (diff vs HEAD), and Quick Look for everything that isn't text.
@MainActor
final class FileEditorController: NSViewController, NSTextViewDelegate, NSMenuItemValidation {
    private var files: [OpenFile] = [] { didSet { saveTabs() } }

    // MARK: Tabs remembered across launches

    /// Where this editor's open tabs are kept (set by its Files surface).
    var tabsKey: String?

    private func saveTabs() {
        guard let tabsKey, !restoringTabs else { return }
        UserDefaults.standard.set(files.map(\.url.plainPath), forKey: tabsKey)
    }
    private var restoringTabs = false

    /// Reopen the tabs saved under `tabsKey` (those whose files still exist).
    func restoreTabs() {
        guard let tabsKey, files.isEmpty,
              let paths = UserDefaults.standard.stringArray(forKey: tabsKey), !paths.isEmpty else { return }
        restoringTabs = true
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let f = OpenFile(url: URL(filePath: path))
            files.append(f)
        }
        restoringTabs = false
        if let last = files.last { show(last) } else { rebuildTabs() }
    }

    /// A file (or a folder holding it) was renamed or moved: its tab follows,
    /// unsaved edits and all — still comparing the disk with the version it
    /// was opened from, so a save asks before replacing someone else's.
    func fileMoved(from old: URL, to new: URL) {
        // Without a folder URL's trailing slash: "/repo/src", so "/repo/src/" prefixes what's in it.
        let oldPath = old.plainPath, newPath = new.plainPath
        for file in files {
            let path = file.url.plainPath
            guard path == oldPath || path.hasPrefix(oldPath + "/") else { continue }
            file.move(to: URL(filePath: newPath + path.dropFirst(oldPath.count)))
        }
        saveTabs()
        if let current {
            pathLabel.stringValue = displayPath(current.url)
            pathLabel.toolTip = current.url.plainPath
        }
        rebuildTabs()
    }

    /// Files (or folders holding them) were moved to the Trash here: their
    /// tabs close, except ones with unsaved edits — those stay, marked, and
    /// saving one asks before putting it back. Returns what reopens the
    /// closed tabs as they were (Undo Move to Trash, once the files are back).
    @discardableResult
    func filesTrashed(_ urls: [URL]) -> @MainActor () -> Void {
        commitEditorText()
        let paths = urls.map(\.plainPath)
        let trashed = { (file: OpenFile) in paths.contains { file.url.plainPath == $0 || file.url.plainPath.hasPrefix($0 + "/") } }
        let closed = files.enumerated().filter { trashed($0.element) && !$0.element.isDirty }
            .map { (index: $0.offset, file: $0.element) }
        let shown = closed.contains { $0.file === current } ? current : nil
        for tab in closed.reversed() { close(tab.index) }
        filesChangedOnDisk()
        return { [weak self] in self?.reopen(closed, showing: shown) }
    }

    /// Tabs that closed when their files went to the Trash, back where they
    /// were (same place in the tab bar, mode and selection) now that the
    /// files are. One whose file didn't come back, or that's open again, is left.
    private func reopen(_ closed: [(index: Int, file: OpenFile)], showing shown: OpenFile?) {
        commitEditorText()
        for (index, file) in closed where FileManager.default.fileExists(atPath: file.url.plainPath)
            && !files.contains(where: { $0.url.standardizedFileURL == file.url.standardizedFileURL }) {
            files.insert(file, at: min(index, files.count))
        }
        if let shown, files.contains(where: { $0 === shown }) { show(shown) } else { rebuildTabs() }
        // Back as they were opened (or rewritten since: reload); a kept tab
        // with edits loses its "moved or deleted" banner.
        filesChangedOnDisk()
    }

    private var current: OpenFile?
    private var git = GitStatus.empty
    /// What Changes diffs against: uncommitted (with stage/revert), or a
    /// commit / everything since the base (read-only), picked under Commits.
    private var scope: ChangeScope = .uncommitted
    private var scopeFiles: Set<String> = []
    private var changes = LineChanges()
    private var highlightPending = false
    /// The Changes view's hunks (unstaged vs the index, staged vs HEAD) and the
    /// file they belong to, for the per-hunk Stage / Unstage / Revert links.
    private var shownPatches: (file: OpenFile, unstaged: FilePatch, staged: FilePatch)?
    private var goToLinePopover: NSPopover?
    private var documentLinkAttributes: [NSAttributedString.Key: Any]?

    private let tabBar = NSStackView()
    private let tabScroll = NSScrollView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl(labels: ["Preview", "Source", "Changes"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let banner = BannerView()
    private let bannerLabel = NSTextField(labelWithString: "")
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let container = NSView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Select a file")
    /// Path + mode row (popovers anchor here).
    let headerView = NSStackView()
    private var header: NSStackView { headerView }

    private let editorScroll = NSScrollView()
    private let editor = CodeTextView(usingTextLayoutManager: true)
    private var ruler: LineNumberRuler!
    private let previewScroll = NSScrollView()
    private let preview = TranscriptTextView(usingTextLayoutManager: true)
    private let blocks = BlockFragmentProvider()
    private let quickLook = QLPreviewView(frame: .zero, style: .normal)!

    /// The diff column: the open file's Changes beside its text (the Files
    /// sidebar places it to the editor's right and shows or hides it).
    let diffColumn = NSView()
    private let diffTitle = NSTextField(labelWithString: "Diff")
    private let diffScroll = NSScrollView()
    private let diffText = TranscriptTextView(usingTextLayoutManager: true)
    private let diffBlocks = BlockFragmentProvider()
    private let diffEmpty = NSTextField(wrappingLabelWithString: "")
    /// Whether the diff column shows: the open file's changes go there, and
    /// the editor keeps its text (its Changes mode is for when it's hidden).
    var diffColumnShown = false {
        didSet {
            guard oldValue != diffColumnShown, isViewLoaded else { return }
            commitEditorText()
            if !diffColumnShown { diffText.textStorage?.setAttributedString(NSAttributedString()) }
            show(current)
        }
    }
    /// Where Changes render: the diff column while it shows, the editor otherwise.
    private var changesView: TranscriptTextView { diffColumnShown ? diffText : preview }

    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    override func loadView() {
        let root = NSView()
        tabBar.orientation = .horizontal
        tabBar.spacing = 2
        tabBar.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        tabScroll.documentView = tabBar
        tabScroll.hasHorizontalScroller = false
        tabScroll.drawsBackground = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.font = .role(.code)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modeControl.controlSize = .small
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityIdentifier("files-mode")
        header.setViews([pathLabel, NSView(), modeControl], in: .leading)
        header.orientation = .horizontal
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)

        bannerLabel.font = .role(.meta)
        reloadButton.target = self
        reloadButton.action = #selector(reloadFromDisk)
        let keep = NSButton(title: "Keep Mine", target: self, action: #selector(dismissBanner))
        for b in [reloadButton, keep] { b.controlSize = .small; b.bezelStyle = .rounded }
        banner.setViews([bannerLabel, NSView(), keep, reloadButton], in: .leading)
        banner.orientation = .horizontal
        banner.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 10)
        banner.wantsLayer = true
        banner.isHidden = true

        setUpEditor()
        setUpPreview()
        setUpDiffColumn()
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .role(.body)
        // A read error is a sentence with the reason in its middle: it wraps,
        // centered, rather than truncate in a narrow pane.
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.isSelectable = false

        let stack = NSStackView(views: [tabScroll, header, banner, container])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        for v in [editorScroll, previewScroll, quickLook, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            if v !== emptyLabel {
                NSLayoutConstraint.activate([
                    v.topAnchor.constraint(equalTo: container.topAnchor),
                    v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                ])
            }
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // The stack's .width alignment is only a preference: the empty
            // label (pinned inside with margins, so a long reason wraps) would
            // otherwise shrink the editor to its own width.
            container.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tabScroll.heightAnchor.constraint(equalToConstant: 30),
            tabBar.heightAnchor.constraint(equalTo: tabScroll.heightAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            emptyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = root
        show(nil)
    }

    private func setUpEditor() {
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.font = Self.codeFont
        editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.delegate = self
        editor.setAccessibilityIdentifier("files-editor")
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.drawsBackground = false
        ruler = LineNumberRuler(textView: editor)
        editorScroll.verticalRulerView = ruler
        editorScroll.hasVerticalRuler = true
        editorScroll.rulersVisible = true
    }

    private func setUpPreview() {
        preview.minSize = .zero
        preview.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        preview.isEditable = false
        preview.drawsBackground = false
        preview.usesFindBar = true
        preview.textContainerInset = NSSize(width: 22, height: 16)
        preview.textLayoutManager?.delegate = blocks
        preview.delegate = self   // Changes view: per-hunk action links
        documentLinkAttributes = preview.linkTextAttributes
        previewScroll.documentView = preview
        previewScroll.hasVerticalScroller = true
        previewScroll.drawsBackground = false
    }

    private func setUpDiffColumn() {
        diffText.minSize = .zero
        diffText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        diffText.isVerticallyResizable = true
        diffText.autoresizingMask = [.width]
        diffText.textContainer?.widthTracksTextView = true
        diffText.isEditable = false
        diffText.drawsBackground = false
        diffText.usesFindBar = true
        diffText.textContainerInset = NSSize(width: 10, height: 8)
        diffText.textLayoutManager?.delegate = diffBlocks
        diffText.delegate = self   // per-hunk action links, line numbers to ask about
        // Hunk actions read as buttons, not web links.
        diffText.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        diffText.setAccessibilityIdentifier("files-diff")
        diffScroll.documentView = diffText
        diffScroll.hasVerticalScroller = true
        diffScroll.drawsBackground = false

        diffTitle.font = .role(.bodyEmphasis)
        diffTitle.textColor = .secondaryLabelColor
        diffEmpty.font = .role(.body)
        diffEmpty.textColor = .tertiaryLabelColor
        diffEmpty.alignment = .center
        diffEmpty.isSelectable = false
        diffColumn.setAccessibilityIdentifier("files-diff-column")
        for v in [diffTitle, diffScroll, diffEmpty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            diffColumn.addSubview(v)
        }
        NSLayoutConstraint.activate([
            // Its title on the editor's tab row.
            diffTitle.centerYAnchor.constraint(equalTo: diffColumn.topAnchor, constant: 15),
            diffTitle.leadingAnchor.constraint(equalTo: diffColumn.leadingAnchor, constant: 12),
            diffTitle.trailingAnchor.constraint(lessThanOrEqualTo: diffColumn.trailingAnchor, constant: -10),
            diffScroll.topAnchor.constraint(equalTo: diffColumn.topAnchor, constant: 30),
            diffScroll.leadingAnchor.constraint(equalTo: diffColumn.leadingAnchor),
            diffScroll.trailingAnchor.constraint(equalTo: diffColumn.trailingAnchor),
            diffScroll.bottomAnchor.constraint(equalTo: diffColumn.bottomAnchor),
            diffEmpty.leadingAnchor.constraint(equalTo: diffColumn.leadingAnchor, constant: 16),
            diffEmpty.trailingAnchor.constraint(equalTo: diffColumn.trailingAnchor, constant: -16),
            diffEmpty.centerYAnchor.constraint(equalTo: diffColumn.centerYAnchor),
        ])
    }

    /// The diff column, for the file showing: its changes, or why there are none.
    private func updateDiffColumn() {
        guard diffColumnShown, isViewLoaded else { return }
        guard let file = current, file.isText, hasChanges(file.url) else {
            shownPatches = nil
            diffText.textStorage?.setAttributedString(NSAttributedString())
            diffEmpty.stringValue = current == nil ? "No file open"
                : current?.isText == false ? "No diff for this file" : "No changes"
            diffEmpty.isHidden = false
            diffScroll.isHidden = true
            return
        }
        diffEmpty.isHidden = true
        diffScroll.isHidden = false
        showDiff(file)
    }

    // MARK: Opening

    func open(_ url: URL) {
        commitEditorText()
        let file = files.first { $0.url.standardizedFileURL == url.standardizedFileURL } ?? {
            let f = OpenFile(url: url)
            files.append(f)
            return f
        }()
        show(file, focus: true)
    }

    /// Open at a line (search results), selecting and flashing `highlight`.
    func open(_ url: URL, line: Int, highlight: String) {
        open(url)
        guard let file = current, file.isText else { return }
        if file.mode != .source { file.mode = .source; show(file, focus: true) }
        jump(toLine: line, highlight: highlight)
    }

    /// Select `line` (1-based; at `column`, or the first `highlight` match on it).
    private func jump(toLine line: Int, column: Int? = nil, highlight: String = "") {
        let ns = editor.string as NSString
        var start = 0
        var n = 1
        while n < line, start < ns.length {
            start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0)))
            n += 1
        }
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                        for: NSRange(location: min(start, ns.length), length: 0))
        let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
        let content = contentsEnd - lineStart   // without its break: LF, CRLF, a lone CR…
        var target = NSRange(location: lineRange.location, length: 0)
        if let column, column > 1 { target.location += min(column - 1, content) }
        if !highlight.isEmpty {
            let hit = ns.range(of: highlight, options: .caseInsensitive, range: lineRange)
            if hit.location != NSNotFound { target = hit }
        }
        editor.setSelectedRange(target)
        editor.scrollRangeToVisible(target)
        let flash = target.length > 0 ? target : NSRange(location: lineRange.location, length: content)
        if flash.length > 0 { editor.showFindIndicator(for: flash) }
        view.window?.makeFirstResponder(editor)
    }

    /// The caret's line (1-based).
    private var caretLine: Int {
        let ns = editor.string as NSString
        return Self.lineCount(of: ns.substring(to: min(editor.selectedRange().location, ns.length)))
    }

    /// The lines in `text` as the editor and its ruler number them (a CRLF is
    /// one break, a form feed none); a final line break starts an empty line.
    nonisolated static func lineCount(of text: String) -> Int { text.count(where: \.isLineBreak) + 1 }

    /// Edit ▸ Find ▸ Go to Line… (⌘L).
    @objc func goToLine(_ sender: Any?) {
        guard let file = current, file.isText else { return NSSound.beep() }
        if let open = goToLinePopover, open.isShown { open.close(); goToLinePopover = nil; return }
        commitEditorText()
        if file.mode != .source { file.mode = .source; show(file, focus: true) }
        let lines = Self.lineCount(of: editor.string)
        let prompt = GoToLineController(lineCount: lines, currentLine: caretLine)
        prompt.onGo = { [weak self] line, column in
            self?.goToLinePopover?.close()
            self?.jump(toLine: min(line, lines), column: column)
        }
        prompt.onCancel = { [weak self] in self?.goToLinePopover?.close() }
        NSPopover.toggle(&goToLinePopover, below: header) { prompt }
    }

    #if DEBUG
    // Self-test hooks.
    func goToLineForTesting(_ line: Int, column: Int? = nil) { jump(toLine: line, column: column) }
    var caretLineForTesting: Int { caretLine }
    var previewText: NSAttributedString? { preview.textStorage }
    var currentURL: URL? { current?.url }
    var openURLs: [URL] { files.map(\.url) }
    var debugIsDirty: Bool { current?.isDirty ?? false }
    var debugDiskChange: OpenFile.DiskChange? { current?.diskChange }
    /// The "changed on disk" / "moved or deleted" banner's text; nil when hidden.
    var debugBanner: String? { banner.isHidden ? nil : bannerLabel.stringValue }
    /// What shows in place of an editor ("Select a file", why a file couldn't be read); nil when hidden.
    var debugEmptyMessage: String? { emptyLabel.isHidden ? nil : emptyLabel.stringValue }
    var debugMode: OpenFile.Mode? { current?.mode }
    /// The diff column's text, and what it says when it has none (nil: it has a diff).
    var diffColumnText: NSAttributedString? { diffText.textStorage }
    var debugDiffColumnEmpty: String? { diffEmpty.isHidden ? nil : diffEmpty.stringValue }
    /// Whether the editor's Changes mode can be picked.
    var debugChangesModeEnabled: Bool { modeControl.isEnabled(forSegment: OpenFile.Mode.changes.rawValue) }
    /// Type at the caret, as a person would.
    func debugType(_ text: String, at location: Int) {
        view.window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: location, length: 0))
        editor.insertText(text, replacementRange: editor.selectedRange())
    }
    var debugCaret: Int { editor.selectedRange().location }
    /// The change bars' lines (nil: none loaded).
    var debugLineChanges: Set<Int> { changes.added.union(changes.modified) }
    var debugEditorText: String { editor.string }
    func debugCloseCurrent() {
        if let current, let i = files.firstIndex(where: { $0 === current }) { close(i) }
    }
    func setMode(_ mode: OpenFile.Mode) {
        guard let file = current else { return }
        commitEditorText()
        file.mode = mode
        show(file, focus: true)
    }
    func performHunkAction(_ action: FilePatch.Action, hunk: Int, staged: Bool) async -> String? {
        await runHunkAction(action, hunk: hunk, staged: staged, confirmed: true)
    }
    var hunkCounts: (unstaged: Int, staged: Int)? {
        shownPatches.map { ($0.unstaged.hunks.count, $0.staged.hunks.count) }
    }
    #endif

    /// The tree's changed list switched scope: diff files against it.
    func setScope(_ scope: ChangeScope, files: Set<String>) {
        guard scope != self.scope || files != scopeFiles else { return }
        self.scope = scope
        scopeFiles = files
        guard let current else { return }
        // Refreshes arrive while you type (any file changing changes the list):
        // a file being edited only gets its Changes button updated.
        commitEditorText()
        if current.mode == .source, current.isText, hasChanges(current.url) {
            modeControl.setEnabled(!diffColumnShown, forSegment: OpenFile.Mode.changes.rawValue)
            updateDiffColumn()
        } else {
            show(current)
        }
    }

    /// Open from the changed list: straight to its Changes when it has some.
    func open(_ url: URL, showingChanges: Bool) {
        open(url)
        guard showingChanges, let file = current, file.isText, file.mode != .changes, hasChanges(file.url) else { return }
        file.mode = .changes
        show(file)
    }

    private func hasChanges(_ url: URL) -> Bool {
        if scope == .uncommitted { return git.change(for: url) != nil }
        return scopeFiles.contains(url.plainPath) || scopeFiles.contains(url.realPath)
    }

    func updateGit(_ status: GitStatus) {
        git = status
        rebuildTabs()
        guard let current else { return }
        if current.mode == .changes { show(current) } else {
            refreshChanges(for: current)
            updateDiffColumn()
        }
    }

    /// Files changed on disk (FSEvents via the tree): reload clean files,
    /// flag ones with unsaved edits (rewritten, or moved or deleted), and
    /// take the flag down once the disk has the version the tab was opened
    /// from again (Undo Move to Trash put it back, a save wrote it).
    func filesChangedOnDisk() {
        commitEditorText()
        for file in files {
            guard let change = file.diskChange else {
                if file === current { banner.isHidden = true }
                continue
            }
            if file.isDirty {
                if file === current { showDiskBanner(change, for: file) }
            } else if change == .rewritten {
                reload(file)
            }
        }
    }

    /// The current file has unsaved edits and isn't what's on disk any more:
    /// say so (Reload only when there's something to reload).
    private func showDiskBanner(_ change: OpenFile.DiskChange, for file: OpenFile) {
        let name = file.url.lastPathComponent
        bannerLabel.stringValue = change == .gone ? "\(name) was moved or deleted." : "\(name) changed on disk."
        reloadButton.isHidden = change == .gone
        banner.isHidden = false
    }

    private func reload(_ file: OpenFile) {
        let fresh = OpenFile(url: file.url)
        // Now too big, or not UTF-8 text: Quick Look, never an empty editable
        // copy; unreadable now: why, instead.
        file.isText = fresh.isText
        file.readError = fresh.readError
        if !fresh.isText { file.mode = .source }
        file.text = fresh.text
        file.savedText = fresh.text
        file.modified = fresh.modified
        if file === current {
            let sel = editor.selectedRange()
            show(file)
            editor.setSelectedRange(NSRange(location: min(sel.location, (file.text as NSString).length), length: 0))
        }
        rebuildTabs()
    }

    @objc private func reloadFromDisk() {
        banner.isHidden = true
        if let current { reload(current) }
    }

    @objc private func dismissBanner() {
        banner.isHidden = true
        if let current { current.modified = OpenFile.modificationDate(of: current.url) }
    }

    // MARK: Showing

    /// `focus`: the user picked it (open, a tab, a mode) — only then does the
    /// editor take the keyboard; refreshes (files changing on disk, git, a new
    /// scope) never pull it away from where you're typing.
    private func show(_ file: OpenFile?, focus: Bool = false) {
        current = file
        // The diff column (when it shows) has the file's changes; the editor its text.
        if diffColumnShown, let file, file.mode == .changes { file.mode = .source }
        defer { updateDiffColumn() }
        banner.isHidden = true
        rebuildTabs()
        editorScroll.isHidden = true
        previewScroll.isHidden = true
        quickLook.isHidden = true
        emptyLabel.stringValue = "Select a file"
        emptyLabel.isHidden = file != nil
        guard let file else {
            pathLabel.stringValue = ""
            modeControl.isHidden = true
            return
        }
        pathLabel.stringValue = displayPath(file.url)
        pathLabel.toolTip = file.url.plainPath
        guard file.isText else {
            modeControl.isHidden = true
            if let error = file.readError {
                // It couldn't be read: say why (it names the file), rather than an empty preview.
                emptyLabel.stringValue = error.localizedDescription
                emptyLabel.isHidden = false
            } else {
                quickLook.previewItem = file.url as NSURL
                quickLook.isHidden = false
            }
            return
        }
        let changed = hasChanges(file.url)
        modeControl.isHidden = false
        modeControl.setEnabled(OpenFile.isMarkdown(file.url), forSegment: OpenFile.Mode.preview.rawValue)
        modeControl.setEnabled(changed && !diffColumnShown, forSegment: OpenFile.Mode.changes.rawValue)
        if file.mode == .changes && !changed { file.mode = .source }
        modeControl.selectedSegment = file.mode.rawValue

        switch file.mode {
        case .source:
            if file.isDirty, let change = file.diskChange { showDiskBanner(change, for: file) }
            editor.isEditable = true
            // The same text already showing (a refresh): leave the caret,
            // scroll and undo alone.
            if editor.string != file.text || shownInEditor !== file {
                editor.string = file.text
                editor.setSelectedRange(file.selection)
                editor.undoManager?.removeAllActions(withTarget: editor.textStorage as Any)
            }
            shownInEditor = file
            highlight()
            editorScroll.isHidden = false
            ruler.lineCountChanged()
            if focus { view.window?.makeFirstResponder(editor) }
            refreshChanges(for: file)
        case .preview:
            preview.linkTextAttributes = documentLinkAttributes
            preview.textStorage?.setAttributedString(ChatRenderer.markdown(file.text, prose: .document))
            previewScroll.isHidden = false
        case .changes:
            // Hunk actions read as buttons, not web links.
            // Links color themselves (accent actions, quiet line numbers).
            preview.linkTextAttributes = [.cursor: NSCursor.pointingHand]
            previewScroll.isHidden = false
            showDiff(file)
        }
    }

    private func displayPath(_ url: URL) -> String {
        if let repo = git.repoRoot {
            for path in [url.plainPath, url.realPath] where path.hasPrefix(repo + "/") { return String(path.dropFirst(repo.count + 1)) }
        }
        return url.plainPath.tildeAbbreviated
    }

    @objc private func modeChanged() {
        guard let file = current, let mode = OpenFile.Mode(rawValue: modeControl.selectedSegment) else { return }
        commitEditorText()
        file.mode = mode
        show(file, focus: true)
    }

    /// Changes: unstaged hunks (working tree vs the index) and staged hunks
    /// (index vs HEAD), each with Stage / Revert or Unstage; an untracked file
    /// shows as all added, with Stage File.
    private func showDiff(_ file: OpenFile) {
        if scope != .uncommitted { return showScopedDiff(file) }
        let untracked = git.change(for: file.url) == .untracked
        let repo = git.repoRoot
        let path = file.url.plainPath
        let text = file.text
        let dirty = file.isDirty
        let target = changesView
        Task { [weak self] in
            let (unstaged, staged) = await Self.loadDiffs(repo: repo, path: path, text: text, untracked: untracked, dirty: dirty)
            guard let self, self.showsChanges(of: file, in: target) else { return }
            if untracked {
                self.shownPatches = nil
                target.textStorage?.setAttributedString(Self.renderDiff(unstaged, untracked: true, editable: !file.isDirty))
                return
            }
            let patches = (file: file, unstaged: FilePatch(unstaged), staged: FilePatch(staged))
            self.shownPatches = patches
            target.textStorage?.setAttributedString(
                Self.renderChanges(unstaged: patches.unstaged, staged: patches.staged, editable: !file.isDirty))
        }
    }

    /// Whether `file`'s changes still belong in `target`: it's the file
    /// showing, and its changes show there (the diff column, or Changes mode).
    private func showsChanges(of file: OpenFile, in target: TranscriptTextView) -> Bool {
        current === file && changesView === target && (diffColumnShown || file.mode == .changes)
    }

    /// The file's diffs off the main actor: unstaged (working tree vs the
    /// index) and staged (index vs HEAD); an untracked file's text, all added.
    /// With unsaved edits (`dirty`), the unstaged diff is the editor's text against the index.
    @concurrent nonisolated private static func loadDiffs(repo: String?, path: String, text: String,
                                                          untracked: Bool, dirty: Bool) async -> (unstaged: String, staged: String) {
        if untracked { return (untrackedDiff(text), "") }
        guard let repo else { return ("", "") }
        let base = ["-C", repo, "diff", "--no-color", "--no-ext-diff"]
        let unstaged = dirty ? GitStatus.bufferDiff(path: path, text: text, against: "") : GitStatus.git(base + ["--", path]) ?? ""
        return (unstaged, GitStatus.git(base + ["--cached", "--", path]) ?? "")
    }

    /// An untracked file's text as a diff with every line added, one per
    /// line the editor numbers.
    nonisolated static func untrackedDiff(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isLineBreak).map { "+" + $0 }.joined(separator: "\n")
    }

    @concurrent nonisolated private static func scopedDiff(repo: String, scope: ChangeScope, path: String) async -> String {
        GitHistory.diff(repo: repo, scope: scope, path: path)
    }

    /// A commit's (or the branch's) changes to the file: read-only.
    private func showScopedDiff(_ file: OpenFile) {
        guard let repo = git.repoRoot else { return }
        let scope = scope
        let path = scopeFiles.contains(file.url.plainPath) ? file.url.plainPath : file.url.realPath
        shownPatches = nil
        let target = changesView
        Task { [weak self] in
            let diff = await Self.scopedDiff(repo: repo, scope: scope, path: path)
            guard let self, self.showsChanges(of: file, in: target), self.scope == scope else { return }
            let out = NSMutableAttributedString()
            switch scope {
            case .commit(let c): out.append(Self.sectionTitle("\(c.short) \(c.subject)"))
            case .all: out.append(Self.sectionTitle("All changes on this branch"))
            case .uncommitted: break
            }
            out.append(Self.renderDiff(diff))
            target.textStorage?.setAttributedString(out)
        }
    }

    static let hunkScheme = "sandshell-hunk"
    static let askScheme = "sandshell-ask"

    /// A diff line's number in the new file (or the old one, for a removed line).
    struct LineNumber { var line: Int; var old: Bool }

    /// Numbers for a diff's lines, following its `@@ -a,b +c,d @@` headers.
    static func lineNumbers(_ lines: [String]) -> [LineNumber?] { annotate(lines).map(\.number) }

    /// Each diff line's number in the new file (the old one for a removed
    /// line), and whether it's file-header noise. Header lines (index, ---,
    /// +++, modes) only come before a file's first `@@`: inside a hunk, a
    /// removed `-- comment` line is content.
    static func annotate(_ lines: [String]) -> [(number: LineNumber?, header: Bool)] {
        var old = 0, new = 0, inHunk = false
        return lines.enumerated().map { i, s in
            if s.hasPrefix("diff --git") { inHunk = false; return (nil, true) }
            if s.hasPrefix("@@") {
                let nums = s.split(separator: " ").dropFirst().prefix(2).map {
                    Int($0.dropFirst().split(separator: ",").first ?? "") ?? 1
                }
                old = nums.first ?? 1
                new = nums.count > 1 ? nums[1] : 1
                inHunk = true
                return (nil, false)
            }
            if !inHunk { return (nil, true) }
            if i == lines.count - 1, s.isEmpty { return (nil, true) }   // after the last newline
            if s.hasPrefix("\\") { return (nil, false) }               // "\ No newline at end of file"
            if s.hasPrefix("-") { defer { old += 1 }; return (LineNumber(line: old, old: true), false) }
            if s.hasPrefix("+") { defer { new += 1 }; return (LineNumber(line: new, old: false), false) }
            defer { old += 1; new += 1 }
            return (LineNumber(line: new, old: false), false)
        }
    }

    /// Both halves of a file's changes, as sections of hunks with action links.
    static func renderChanges(unstaged: FilePatch, staged: FilePatch, editable: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if unstaged.isEmpty && staged.isEmpty {
            out.append(NSAttributedString(string: "No changes against HEAD.", attributes: [
                .font: NSFont.role(.body), .foregroundColor: NSColor.secondaryLabelColor]))
            return out
        }
        if !editable {
            out.append(sectionTitle("Save the file to stage or revert its hunks."))
        }
        if !unstaged.isEmpty {
            out.append(sectionTitle(staged.isEmpty ? "Changes" : "Unstaged Changes"))
            for (i, hunk) in unstaged.hunks.enumerated() {
                let actions: [(String, String)] = editable ? [("Stage", "stage/\(i)"), ("Revert…", "revert/\(i)")] : []
                out.append(renderHunk(hunk, actions: actions))
            }
        }
        if !staged.isEmpty {
            out.append(sectionTitle("Staged Changes"))
            for (i, hunk) in staged.hunks.enumerated() {
                out.append(renderHunk(hunk, actions: editable ? [("Unstage", "unstage/\(i)")] : []))
            }
        }
        // End on a plain paragraph so the last hunk's tint stops at its last line.
        out.append(NSAttributedString(string: "\n", attributes: [.font: diffFont]))
        return out
    }

    /// Unified diff with tinted added/removed lines and hunk headers.
    static func renderDiff(_ diff: String, untracked: Bool = false, editable: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if untracked {
            out.append(sectionTitle("Untracked File", actions: editable ? [("Stage File", "add/0")] : []))
        }
        var lines = diff.split(omittingEmptySubsequences: false, whereSeparator: \.isGitLineEnd).map(String.init)
        if untracked {
            // All "+" lines with no header: number them from 1.
            if lines.last == "+" || lines.last == "" { lines.removeLast() }
            for (i, s) in lines.enumerated() { out.append(diffLine(s, number: LineNumber(line: i + 1, old: false))) }
        } else {
            for (s, info) in zip(lines, annotate(lines)) where !info.header {
                out.append(diffLine(s, number: info.number))
            }
        }
        if out.length == 0 {
            out.append(NSAttributedString(string: "No changes against HEAD.", attributes: [
                .font: NSFont.role(.body), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return out
    }

    private static let diffFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static func diffLine(_ s: String, trailing: NSAttributedString? = nil, number: LineNumber? = nil) -> NSAttributedString {
        let kind: BlockStyle.Kind? = s.hasPrefix("@@") ? .hunk : s.hasPrefix("+") ? .added : s.hasPrefix("-") ? .removed : nil
        let color: NSColor = kind == .hunk ? .secondaryLabelColor : .labelColor
        let piece = NSMutableAttributedString()
        if let number {
            // The line's number: click it to ask the agent for a change there.
            piece.append(NSAttributedString(string: String(format: "%5d ", number.line), attributes: [
                .font: diffFont, .foregroundColor: NSColor.tertiaryLabelColor,
                .link: URL(string: "\(askScheme)://\(number.old ? "old" : "new")/\(number.line)")!,
                .toolTip: "Tell the agent what to change at line \(number.line)",
            ]))
        } else if kind != .hunk {
            piece.append(NSAttributedString(string: "      ", attributes: [.font: diffFont]))
        }
        piece.append(NSAttributedString(string: s, attributes: [.font: diffFont, .foregroundColor: color]))
        if let trailing { piece.append(trailing) }
        piece.append(NSAttributedString(string: "\n", attributes: [.font: diffFont]))
        if let kind {
            piece.addAttribute(.chatBlock, value: BlockStyle(kind, .middle), range: NSRange(location: 0, length: piece.length))
        }
        return piece
    }

    /// "   Stage   Revert…" — links handled by `textView(_:clickedOnLink:at:)`.
    private static func actionLinks(_ actions: [(title: String, path: String)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (title, path) in actions {
            out.append(NSAttributedString(string: "   ", attributes: [.font: diffFont]))
            out.append(NSAttributedString(string: title, attributes: [
                .font: NSFont.role(.meta, weight: .semibold),
                .foregroundColor: NSColor.controlAccentColor,
                .link: URL(string: "\(hunkScheme)://\(path)")!,
                .toolTip: title.hasPrefix("Revert") ? "Discard this hunk's changes from the file" : "\(title) this hunk",
            ]))
        }
        return out
    }

    /// The `@@` line carries the actions up front and truncates its context
    /// text rather than wrapping in a narrow pane.
    private static func renderHunk(_ lines: [String], actions: [(String, String)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let numbers = lineNumbers(lines)
        for (n, line) in lines.enumerated() {
            guard n == 0, !actions.isEmpty else { out.append(diffLine(line, number: numbers[n])); continue }
            let header = NSMutableAttributedString(attributedString: actionLinks(actions))
            header.deleteCharacters(in: NSRange(location: 0, length: 3))   // no leading gap
            header.append(NSAttributedString(string: "   ", attributes: [.font: diffFont]))
            header.append(diffLine(line))
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byTruncatingTail
            header.addAttributes([.paragraphStyle: p, .chatBlock: BlockStyle(.hunk, .middle)],
                                 range: NSRange(location: 0, length: header.length))
            out.append(header)
        }
        return out
    }

    private static func sectionTitle(_ text: String, actions: [(String, String)] = []) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 6
        p.paragraphSpacing = 4
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.role(.bodyEmphasis), .foregroundColor: NSColor.secondaryLabelColor])
        if !actions.isEmpty { out.append(actionLinks(actions)) }
        out.append(NSAttributedString(string: "\n"))
        out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: out.length))
        return out
    }

    // MARK: Asking for a change at a line

    /// Sends "change this" text to the session the Files surface belongs to.
    var onAskAgent: ((String) -> Void)?
    private var askPopover: NSPopover?

    /// A line number in a diff was clicked: a box under it for what to change.
    private func askAboutLine(_ line: Int, removed: Bool, at charIndex: Int) {
        guard let file = current, onAskAgent != nil else { return NSSound.beep() }
        let shown = changesView
        let text = (shown.string as NSString)
        let paragraph = text.substring(with: text.paragraphRange(for: NSRange(location: charIndex, length: 0)))
        // Drop the gutter and the +/-/space marker.
        var code = String(paragraph.dropFirst(6))
        if let first = code.first, "+- ".contains(first) { code.removeFirst() }
        code = code.trimmingCharacters(in: .newlines)
        let path = displayPath(file.url)
        let field = AskField(placeholder: "Tell the agent what to change at line \(line)")
        field.onSubmit = { [weak self] comment in
            guard let self else { return }
            self.askPopover?.close()
            let place = removed ? "the removed line \(line) of" : "line \(line) of"
            let message = "At \(place) `\(path)`:\n```\n\(code)\n```\n\(comment)"
            self.onAskAgent?(message)
        }
        var rect = shown.firstRect(forCharacterRange: NSRange(location: charIndex, length: 5), actualRange: nil)
        rect = shown.window?.convertFromScreen(rect) ?? rect
        rect = shown.convert(rect, from: nil)
        askPopover?.close()
        askPopover = nil
        NSPopover.toggle(&askPopover, below: shown, rect: rect) { field }
        field.focus()
    }

    #if DEBUG
    /// Self-test: the editor's text area spans its column.
    var debugEditorFillsColumn: Bool { abs(container.frame.width - view.bounds.width) < 1 }

    /// Self-test: ask about a line as if its number was clicked and submitted.
    func debugAsk(line: Int, _ comment: String) -> Bool {
        let ns = changesView.string as NSString
        var found: Int?
        changesView.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: ns.length)) { value, range, stop in
            if let url = value as? URL, url.scheme == Self.askScheme, url.host() == "new", Int(url.lastPathComponent) == line {
                found = range.location; stop.pointee = true
            }
        }
        guard let found else { return false }
        askAboutLine(line, removed: false, at: found)
        (askPopover?.contentViewController as? AskField)?.submit(comment)
        return true
    }
    #endif

    // MARK: Hunk actions

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if textView === changesView, let url = link as? URL, url.scheme == Self.askScheme,
           let line = Int(url.lastPathComponent) {
            askAboutLine(line, removed: url.host() == "old", at: charIndex)
            return true
        }
        guard textView === changesView, let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)),
              url.scheme == Self.hunkScheme, let host = url.host(),
              let index = Int(url.lastPathComponent) else { return false }
        Task { [weak self] in
            guard let self else { return }
            let error: String?
            switch host {
            case "add": error = await self.stageWholeFile()
            case "stage": error = await self.runHunkAction(.stage, hunk: index, staged: false, confirmed: false)
            case "revert": error = await self.runHunkAction(.revert, hunk: index, staged: false, confirmed: false)
            case "unstage": error = await self.runHunkAction(.unstage, hunk: index, staged: true, confirmed: false)
            default: error = nil
            }
            if let error {
                Alerts.inform("Couldn’t \(host == "add" ? "stage the file" : "\(host) the hunk")", error,
                              style: .warning, in: self.view.window)
            }
        }
        return true
    }

    /// Stage / unstage / revert one hunk of the shown file. Revert asks first.
    private func runHunkAction(_ action: FilePatch.Action, hunk: Int, staged: Bool, confirmed: Bool) async -> String? {
        guard let shown = shownPatches, let repo = git.repoRoot, !shown.file.isDirty else { return nil }
        let patch = staged ? shown.staged : shown.unstaged
        guard patch.hunks.indices.contains(hunk) else { return nil }
        if action == .revert && !confirmed {
            guard Alerts.confirm("Revert this change in “\(shown.file.url.lastPathComponent)”?",
                                 "The hunk’s edits are removed from the file on disk. This can’t be undone.",
                                 confirm: "Revert", destructive: true) else { return nil }
        }
        if let error = await patch.apply(action, hunk: hunk, repo: repo) { return error }
        await afterRepoChange(shown.file, reloadText: action == .revert)
        return nil
    }

    /// Untracked file → `git add`.
    private func stageWholeFile() async -> String? {
        guard let file = current, let repo = git.repoRoot else { return nil }
        let path = file.url.plainPath
        let error = await Self.gitChange(["-C", repo, "add", "--", path])
        if error == nil { await afterRepoChange(file, reloadText: false) }
        return error
    }

    /// `GitStatus.change` off the main actor.
    @concurrent nonisolated private static func gitChange(_ args: [String]) async -> String? {
        GitStatus.change(args)
    }

    /// Refresh status, the Changes view (and the text, after a revert) right
    /// away rather than waiting for FSEvents.
    private func afterRepoChange(_ file: OpenFile, reloadText: Bool) async {
        if reloadText { reload(file) }
        guard let root = git.repoRoot else { return }
        let status = await GitStatus.load(for: URL(filePath: root, directoryHint: .isDirectory))
        git = status
        rebuildTabs()
        if current === file { show(file) }
    }

    /// Unsaved edits in any tab: Save All / Discard / Cancel (false = cancel).
    func confirmCloseAll() -> Bool {
        commitEditorText()
        let dirty = files.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        switch Alerts.saveChanges(dirty.map(\.url.lastPathComponent)) {
        case .save:
            dirty.forEach(save)
            return !files.contains(where: \.isDirty)
        case .cancel: return false
        case .discard: return true
        }
    }

    private func refreshChanges(for file: OpenFile) {
        guard file.mode == .source else { return }
        let lines = Self.lineCount(of: file.text)
        let edits = file.isDirty ? file.text : nil
        Task { [weak self] in
            let c = await LineChanges.load(file: file.url, repoRoot: self?.git.repoRoot,
                                           untracked: self?.git.change(for: file.url) == .untracked, lineCount: lines,
                                           text: edits)
            guard let self, self.current === file else { return }
            self.changes = c
            self.ruler.changes = c
        }
    }

    // MARK: Tabs

    /// Files with unsaved edits changed (real paths): the tree counts them as changes.
    var onEditedChange: ((Set<String>) -> Void)?
    private var reportedEdited: Set<String> = []
    private var liveDiff: Task<Void, Never>?

    private func reportEdited() {
        let edited = Set(files.filter(\.isDirty).map(\.url.realPath))
        guard edited != reportedEdited else { return }
        reportedEdited = edited
        onEditedChange?(edited)
    }

    private func rebuildTabs() {
        reportEdited()
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, file) in files.enumerated() {
            let tab = EditorTab(title: file.url.lastPathComponent, icon: NSWorkspace.shared.icon(forFile: file.url.plainPath),
                                selected: file === current, dirty: file.isDirty,
                                change: git.change(for: file.url))
            tab.onSelect = { [weak self] in self?.select(i) }
            tab.onClose = { [weak self] in self?.close(i) }
            tabBar.addArrangedSubview(tab)
        }
        tabScroll.isHidden = files.isEmpty
    }

    private func select(_ index: Int) {
        guard files.indices.contains(index) else { return }
        commitEditorText()
        show(files[index], focus: true)
    }

    private func close(_ index: Int) {
        guard files.indices.contains(index) else { return }
        commitEditorText()
        let file = files[index]
        if file.isDirty {
            switch Alerts.saveChanges([file.url.lastPathComponent]) {
            case .save:
                save(file)
                if file.isDirty { return }   // the save failed (and said why): keep the tab
            case .cancel: return
            case .discard: break
            }
        }
        files.remove(at: index)
        if file === current { show(files.isEmpty ? nil : files[min(index, files.count - 1)]) } else { rebuildTabs() }
    }

    // MARK: Editing

    /// The file whose text is in `editor` now.
    private weak var shownInEditor: OpenFile?

    private func commitEditorText() {
        guard let file = current, file.mode == .source, file.isText else { return }
        file.text = editor.string
        file.selection = editor.selectedRange()
    }

    func textDidChange(_ notification: Notification) {
        guard let file = current else { return }
        let wasDirty = file.isDirty
        file.text = editor.string
        if wasDirty != file.isDirty {
            rebuildTabs()
            updateDiffColumn()   // its hunk actions only work on a saved file
        }
        ruler.lineCountChanged()
        scheduleHighlight()
        scheduleLiveDiff()
    }

    /// While you type: the change bars and the diff column follow the edits
    /// (a moment after the last keystroke).
    private func scheduleLiveDiff() {
        liveDiff?.cancel()
        liveDiff = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let file = self.current else { return }
            self.refreshChanges(for: file)
            self.updateDiffColumn()
        }
    }

    private func scheduleHighlight() {
        guard !highlightPending else { return }
        highlightPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.highlightPending = false
            self?.highlight()
        }
    }

    /// Re-color the whole buffer (colors only, so typing/undo/selection are untouched).
    private func highlight() {
        guard let file = current, let storage = editor.textStorage, storage.length < 300_000 else { return }
        let colored = SyntaxHighlighter.highlight(storage.string, language: file.language, font: Self.codeFont)
        storage.beginEditing()
        colored.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: colored.length)) { value, range, _ in
            if let color = value as? NSColor, NSMaxRange(range) <= storage.length {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        storage.endEditing()
    }

    /// ⌘S (File ▸ Save).
    @objc func saveDocument(_ sender: Any?) {
        commitEditorText()
        if let current { save(current) }
    }

    private func save(_ file: OpenFile) {
        // Changed on disk since it was opened (an agent, while this tab sat in
        // the background), or moved, deleted or trashed since: don't overwrite
        // that, or quietly bring it back, without asking.
        let name = file.url.lastPathComponent
        switch file.diskChange {
        case .rewritten?:
            guard Alerts.confirm("\(name) changed on disk since you opened it.",
                                 "Saving replaces that version with yours.", confirm: "Save Anyway", destructive: true)
            else { return }
        case .gone?:
            guard Alerts.confirm("\(name) was moved or deleted since you opened it.",
                                 "Saving puts your version back where it was.", confirm: "Save Anyway")
            else { return }
        case nil: break
        }
        do {
            try file.write()
            // What's on disk is this tab's version now: no "changed on disk"
            // or "moved or deleted" any more.
            if file === current { banner.isHidden = true }
            rebuildTabs()
            refreshChanges(for: file)
            if file === current { updateDiffColumn() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// What File ▸ Print prints: the tab as it shows — its text in Source, the
    /// rendered Markdown in Preview, the diff in Changes. (Only Source puts the
    /// file's text in `editor`; otherwise it holds whichever file was last
    /// shown there.) Nil for a file that isn't text.
    var printView: NSView? {
        guard let file = current, file.isText else { return nil }
        return file.mode == .source ? editor : preview
    }

    /// File ▸ Print.
    @objc func printDocument(_ sender: Any?) {
        guard let file = current, let printView else { return NSSound.beep() }
        let op = NSPrintOperation(view: printView)
        op.jobTitle = file.url.lastPathComponent
        if let window = view.window { op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
    }

    /// File ▸ Revert to Saved: drop unsaved edits (after asking).
    @objc func revertDocumentToSaved(_ sender: Any?) {
        commitEditorText()
        guard let file = current, file.isDirty else { return }
        guard Alerts.confirm("Revert “\(file.url.lastPathComponent)” to the saved version?",
                             "Your unsaved changes will be lost.", confirm: "Revert") else { return }
        reload(file)
    }

    /// The open file's tab, closed (asking about unsaved edits); false if none is open.
    @discardableResult
    func closeCurrentTab() -> Bool {
        guard let current, let i = files.firstIndex(where: { $0 === current }) else { return false }
        close(i)
        return true
    }
    var hasOpenTab: Bool { current != nil }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(saveDocument(_:)) { return current?.isDirty == true }
        if item.action == #selector(revertDocumentToSaved(_:)) { commitEditorText(); return current?.isDirty == true }
        if item.action == #selector(goToLine(_:)) { return current?.isText == true }
        return true
    }
}

/// A tab: icon, name (tinted by git status), unsaved dot / close button.
final class EditorTab: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    private let selected: Bool

    init(title: String, icon: NSImage, selected: Bool, dirty: Bool, change: GitStatus.Change?) {
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        let image = NSImageView(image: icon)
        image.setAccessibilityElement(false)   // the tab's label names the file
        let label = NSTextField(labelWithString: title)
        label.font = .role(selected ? .bodyEmphasis : .body)
        label.textColor = change?.color ?? (selected ? .labelColor : .secondaryLabelColor)
        let close = NSButton(image: NSImage(systemSymbolName: dirty ? "circle.fill" : "xmark",
                                            accessibilityDescription: dirty ? "Unsaved" : "Close")!
                                .withSymbolConfiguration(dirty ? .init(pointSize: 7, weight: .semibold) : .role(.meta))!,
                             target: nil, action: nil)
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = dirty ? "Unsaved changes — click to close" : "Close"
        // Named for what it does, not for the unsaved dot it shows.
        close.setAccessibilityLabel("Close")
        if dirty { close.setAccessibilityHelp("Unsaved changes") }
        let stack = NSStackView(views: [image, label, close])
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            image.widthAnchor.constraint(equalToConstant: 14),
            image.heightAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title + (dirty ? ", edited" : ""))
        setAccessibilitySelected(selected)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Layer colors don't follow light/dark on their own; resolve them here.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = selected ? NSColor.labelColor.withAlphaComponent(0.09).cgColor : NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "Close Tab") { [weak self] in self?.onClose?(); return true }]
    }
    @objc private func closeClicked() { onClose?() }
}

/// The "changed on disk" banner: its tint follows light and dark.
private final class BannerView: NSStackView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.15).cgColor }
}

/// Editor text view: Tab inserts spaces matching the line's indentation width
/// convention (4), Return keeps the current line's indentation.
final class CodeTextView: NSTextView {
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = ns.substring(with: lineRange)
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(String(indent), replacementRange: selectedRange()) }
    }
}

/// Line numbers + git change bars for a TextKit 2 text view.
final class LineNumberRuler: NSRulerView {
    var changes = LineChanges() { didSet { needsDisplay = true } }
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        // Views don't clip by default (macOS 14+); the stock ruler's edge line
        // ran up through the tab bar and path row.
        clipsToBounds = true
        // This editor scrolling or reflowing, not every view in the app.
        let clip = textView.enclosingScrollView?.contentView
        clip?.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                                               object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.frameDidChangeNotification,
                                               object: textView)
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func redraw() { needsDisplay = true }

    func lineCountChanged() {
        guard let s = textView?.string as NSString? else { return }
        lineStarts = Self.lineStarts(in: s)
        let digits = max(3, String(lineStarts.count).count)
        ruleThickness = CGFloat(digits) * 7.5 + 22
        needsDisplay = true
    }

    /// Where each line starts (UTF-16 offsets): after every break NSString
    /// finds (LF, CR, CRLF, NEL, U+2028, U+2029), so a final break of any kind
    /// starts an empty last line — the lines `FileEditorController.lineCount(of:)` counts.
    nonisolated static func lineStarts(in s: NSString) -> [Int] {
        var starts = [0]
        var location = 0
        while location < s.length {
            var end = 0, contentsEnd = 0
            s.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            guard contentsEnd < end, end > location else { break }   // the last line, with no break
            starts.append(end)
            location = end
        }
        return starts
    }

    private func line(forOffset offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    /// The editor's own background with just the numbers and change bars —
    /// no stock ruler fill or edge line.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { return }
        NSColor.textBackgroundColor.withAlphaComponent(0.0).setFill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.role(.code),
            .foregroundColor: NSColor.tertiaryLabelColor]
        let visible = tv.visibleRect
        let origin = convert(NSPoint.zero, from: tv)
        let inset = tv.textContainerInset.height
        // From the fragment at the cull line below (in layout coordinates),
        // not laying out everything above it; from the top when nothing's
        // laid out there yet.
        let start = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(visible.minY - 50 - inset, 0)))?.rangeInElement.location
            ?? tlm.documentRange.location
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.maxY < visible.minY - 50 { return true }
            if frame.minY > visible.maxY + 50 { return false }
            let offset = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
            let n = line(forOffset: offset)
            let y = frame.minY + inset + origin.y
            let label = "\(n)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: y + 1), withAttributes: attrs)
            // Change bar on the right edge of the gutter, as tall as the text
            // (the last paragraph's fragment also holds the empty end line).
            let textLines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
            let height = textLines.last.map { $0.typographicBounds.maxY } ?? frame.height
            let bar = NSRect(x: ruleThickness - 4, y: y, width: 3, height: height)
            if changes.added.contains(n) { NSColor.systemGreen.setFill(); bar.fill() }
            else if changes.modified.contains(n) { NSColor.systemBlue.setFill(); bar.fill() }
            if changes.deletedAfter.contains(n) {
                NSColor.systemRed.setFill()
                NSRect(x: ruleThickness - 6, y: y + height - 1.5, width: 6, height: 3).fill()
            }
            return true
        }
    }
}

/// The "what should change here?" box under a diff line: Return sends it.
@MainActor
final class AskField: NSViewController, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    private let field = NSTextField()
    private let placeholder: String

    init(placeholder: String) {
        self.placeholder = placeholder
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        field.placeholderString = placeholder
        field.font = .role(.body)
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.target = self
        field.action = #selector(enter)
        field.setAccessibilityIdentifier("files-ask-field")
        let hint = NSTextField(labelWithString: "↩ send to the session · esc to cancel")
        hint.font = .role(.meta)

        hint.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [field, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10)
        field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        view = stack
    }

    func focus() { view.window?.makeFirstResponder(field) }

    @objc private func enter() { submit(field.stringValue) }

    func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit?(trimmed)
    }
}
