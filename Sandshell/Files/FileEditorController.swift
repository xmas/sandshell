import AppKit
import Quartz
import UniformTypeIdentifiers

/// One open file in the editor.
@MainActor
final class OpenFile {
    enum Mode: Int { case preview, source, changes }
    let url: URL
    var text: String
    var savedText: String
    var modified: Date?
    var mode: Mode
    let isText: Bool
    var selection = NSRange(location: 0, length: 0)
    var isDirty: Bool { text != savedText }

    init(url: URL) {
        self.url = url
        let data = (try? Data(contentsOf: url)) ?? Data()
        let decoded = data.count <= 4_000_000 && !data.prefix(8000).contains(0) ? String(data: data, encoding: .utf8) : nil
        isText = decoded != nil
        text = decoded ?? ""
        savedText = text
        modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        mode = Self.isMarkdown(url) ? .preview : .source
    }

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

    static func load(file: URL, repoRoot: String?, untracked: Bool, lineCount: Int) async -> LineChanges {
        guard let repoRoot else { return LineChanges() }
        if untracked { return LineChanges(added: Set(1...max(lineCount, 1))) }
        return await Task.detached(priority: .utility) {
            guard let diff = GitStatus.git(["-C", repoRoot, "diff", "--no-color", "--no-ext-diff", "-U0", "HEAD", "--", file.path])
            else { return LineChanges() }
            var out = LineChanges()
            let re = try! NSRegularExpression(pattern: #"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#, options: .anchorsMatchLines)
            let ns = diff as NSString
            for m in re.matches(in: diff, range: NSRange(location: 0, length: ns.length)) {
                func num(_ i: Int, _ fallback: Int) -> Int {
                    m.range(at: i).location == NSNotFound ? fallback : Int(ns.substring(with: m.range(at: i))) ?? fallback
                }
                let oldCount = num(1, 1), start = num(2, 0), newCount = num(3, 1)
                if newCount == 0 { out.deletedAfter.insert(start); continue }
                let lines = Set(start..<(start + newCount))
                if oldCount == 0 { out.added.formUnion(lines) } else { out.modified.formUnion(lines) }
            }
            return out
        }.value
    }
}

/// The Files pane's editor: tabs over a TextKit 2 code editor (highlighting,
/// line numbers, git change bars, ⌘S), a rendered Markdown preview, a Changes
/// view (diff vs HEAD), and Quick Look for everything that isn't text.
@MainActor
final class FileEditorController: NSViewController, NSTextViewDelegate, NSMenuItemValidation {
    private var files: [OpenFile] = []
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
    private let banner = NSStackView()
    private let bannerLabel = NSTextField(labelWithString: "")
    private let container = NSView()
    private let emptyLabel = NSTextField(labelWithString: "Select a file")
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

        pathLabel.font = .systemFont(ofSize: 12)
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

        bannerLabel.font = .systemFont(ofSize: 12)
        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadFromDisk))
        let keep = NSButton(title: "Keep Mine", target: self, action: #selector(dismissBanner))
        for b in [reload, keep] { b.controlSize = .small; b.bezelStyle = .rounded }
        banner.setViews([bannerLabel, NSView(), keep, reload], in: .leading)
        banner.orientation = .horizontal
        banner.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 10)
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.15).cgColor
        banner.isHidden = true

        setUpEditor()
        setUpPreview()
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)

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
            tabScroll.heightAnchor.constraint(equalToConstant: 30),
            tabBar.heightAnchor.constraint(equalTo: tabScroll.heightAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
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

    // MARK: Opening

    func open(_ url: URL) {
        commitEditorText()
        let file = files.first { $0.url.standardizedFileURL == url.standardizedFileURL } ?? {
            let f = OpenFile(url: url)
            files.append(f)
            return f
        }()
        show(file)
    }

    /// Open at a line (search results), selecting and flashing `highlight`.
    func open(_ url: URL, line: Int, highlight: String) {
        open(url)
        guard let file = current, file.isText else { return }
        if file.mode != .source { file.mode = .source; show(file) }
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
        let lineRange = ns.lineRange(for: NSRange(location: min(start, ns.length), length: 0))
        let content = lineRange.length - (ns.substring(with: lineRange).hasSuffix("\n") ? 1 : 0)
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
        let upTo = ns.substring(to: min(editor.selectedRange().location, ns.length))
        return upTo.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// Edit ▸ Find ▸ Go to Line… (⌘L).
    @objc func goToLine(_ sender: Any?) {
        guard let file = current, file.isText else { return NSSound.beep() }
        if let open = goToLinePopover, open.isShown { open.close(); return }
        commitEditorText()
        if file.mode != .source { file.mode = .source; show(file) }
        let lines = editor.string.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let prompt = GoToLineController(lineCount: lines, currentLine: caretLine)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = prompt
        prompt.onGo = { [weak self, weak popover] line, column in
            popover?.close()
            self?.jump(toLine: min(line, lines), column: column)
        }
        prompt.onCancel = { [weak popover] in popover?.close() }
        goToLinePopover = popover
        popover.show(relativeTo: header.bounds, of: header, preferredEdge: .minY)
    }

    #if DEBUG
    // Self-test hooks.
    func goToLineForTesting(_ line: Int, column: Int? = nil) { jump(toLine: line, column: column) }
    var caretLineForTesting: Int { caretLine }
    var previewText: NSAttributedString? { preview.textStorage }
    var currentURL: URL? { current?.url }
    func setMode(_ mode: OpenFile.Mode) {
        guard let file = current else { return }
        commitEditorText()
        file.mode = mode
        show(file)
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
        if let current { show(current) }
    }

    /// Open from the changed list: straight to its Changes when it has some.
    func open(_ url: URL, showingChanges: Bool) {
        open(url)
        guard showingChanges, let file = current, file.isText, file.mode != .changes, hasChanges(file.url) else { return }
        file.mode = .changes
        show(file)
    }

    private func hasChanges(_ url: URL) -> Bool {
        if scope == .uncommitted { return git.changes[url.path] != nil }
        return scopeFiles.contains(url.path) || scopeFiles.contains(url.resolvingSymlinksInPath().path)
    }

    func updateGit(_ status: GitStatus) {
        git = status
        rebuildTabs()
        guard let current else { return }
        if current.mode == .changes { show(current) } else { refreshChanges(for: current) }
    }

    /// Files changed on disk (FSEvents via the tree): reload clean files,
    /// offer a choice for ones with unsaved edits.
    func filesChangedOnDisk() {
        commitEditorText()
        for file in files {
            let mtime = try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            guard let mtime, mtime != file.modified else { continue }
            if !file.isDirty {
                reload(file)
            } else if file === current {
                bannerLabel.stringValue = "\(file.url.lastPathComponent) changed on disk."
                banner.isHidden = false
            }
        }
    }

    private func reload(_ file: OpenFile) {
        let fresh = OpenFile(url: file.url)
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
        current?.modified = try? current?.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: Showing

    private func show(_ file: OpenFile?) {
        current = file
        banner.isHidden = true
        rebuildTabs()
        editorScroll.isHidden = true
        previewScroll.isHidden = true
        quickLook.isHidden = true
        emptyLabel.isHidden = file != nil
        guard let file else {
            pathLabel.stringValue = ""
            modeControl.isHidden = true
            return
        }
        pathLabel.stringValue = displayPath(file.url)
        pathLabel.toolTip = file.url.path
        guard file.isText else {
            modeControl.isHidden = true
            quickLook.previewItem = file.url as NSURL
            quickLook.isHidden = false
            return
        }
        let changed = hasChanges(file.url)
        modeControl.isHidden = false
        modeControl.setEnabled(OpenFile.isMarkdown(file.url), forSegment: OpenFile.Mode.preview.rawValue)
        modeControl.setEnabled(changed, forSegment: OpenFile.Mode.changes.rawValue)
        if file.mode == .changes && !changed { file.mode = .source }
        modeControl.selectedSegment = file.mode.rawValue

        switch file.mode {
        case .source:
            editor.isEditable = true
            editor.string = file.text
            editor.setSelectedRange(file.selection)
            highlight()
            editorScroll.isHidden = false
            ruler.lineCountChanged()
            view.window?.makeFirstResponder(editor)
            refreshChanges(for: file)
        case .preview:
            preview.linkTextAttributes = documentLinkAttributes
            preview.textStorage?.setAttributedString(ChatRenderer.markdown(file.text, prose: .document))
            previewScroll.isHidden = false
        case .changes:
            // Hunk actions read as buttons, not web links.
            // Links color themselves (accent actions, quiet line numbers).
            preview.linkTextAttributes = [.cursor: NSCursor.pointingHand]
            showDiff(file)
        }
    }

    private func displayPath(_ url: URL) -> String {
        if let repo = git.repoRoot, url.path.hasPrefix(repo + "/") { return String(url.path.dropFirst(repo.count + 1)) }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    @objc private func modeChanged() {
        guard let file = current, let mode = OpenFile.Mode(rawValue: modeControl.selectedSegment) else { return }
        commitEditorText()
        file.mode = mode
        show(file)
    }

    /// Changes: unstaged hunks (working tree vs the index) and staged hunks
    /// (index vs HEAD), each with Stage / Revert or Unstage; an untracked file
    /// shows as all added, with Stage File.
    private func showDiff(_ file: OpenFile) {
        previewScroll.isHidden = false
        if scope != .uncommitted { return showScopedDiff(file) }
        let untracked = git.changes[file.url.path] == .untracked
        let repo = git.repoRoot
        let path = file.url.path
        let text = file.text
        Task { [weak self] in
            let (unstaged, staged): (String, String) = await Task.detached(priority: .utility) {
                if untracked {
                    return (text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n"), "")
                }
                guard let repo else { return ("", "") }
                let base = ["-C", repo, "diff", "--no-color", "--no-ext-diff"]
                return (GitStatus.git(base + ["--", path]) ?? "", GitStatus.git(base + ["--cached", "--", path]) ?? "")
            }.value
            guard let self, self.current === file, file.mode == .changes else { return }
            if untracked {
                self.shownPatches = nil
                self.preview.textStorage?.setAttributedString(Self.renderDiff(unstaged, untracked: true, editable: !file.isDirty))
                return
            }
            let patches = (file: file, unstaged: FilePatch(unstaged), staged: FilePatch(staged))
            self.shownPatches = patches
            self.preview.textStorage?.setAttributedString(
                Self.renderChanges(unstaged: patches.unstaged, staged: patches.staged, editable: !file.isDirty))
        }
    }

    /// A commit's (or the branch's) changes to the file: read-only.
    private func showScopedDiff(_ file: OpenFile) {
        guard let repo = git.repoRoot else { return }
        let scope = scope
        let path = scopeFiles.contains(file.url.path) ? file.url.path : file.url.resolvingSymlinksInPath().path
        shownPatches = nil
        Task { [weak self] in
            let diff = await Task.detached(priority: .utility) { GitHistory.diff(repo: repo, scope: scope, path: path) }.value
            guard let self, self.current === file, file.mode == .changes, self.scope == scope else { return }
            let out = NSMutableAttributedString()
            switch scope {
            case .commit(let c): out.append(Self.sectionTitle("\(c.short) \(c.subject)"))
            case .all: out.append(Self.sectionTitle("All changes on this branch"))
            case .uncommitted: break
            }
            out.append(Self.renderDiff(diff))
            self.preview.textStorage?.setAttributedString(out)
        }
    }

    static let hunkScheme = "sandshell-hunk"
    static let askScheme = "sandshell-ask"

    /// A diff line's number in the new file (or the old one, for a removed line).
    struct LineNumber { var line: Int; var old: Bool }

    /// Numbers for a diff's lines, following its `@@ -a,b +c,d @@` headers.
    static func lineNumbers(_ lines: [String]) -> [LineNumber?] {
        var old = 0, new = 0
        return lines.map { s in
            if s.hasPrefix("@@") {
                let nums = s.split(separator: " ").dropFirst().prefix(2).map {
                    Int($0.dropFirst().split(separator: ",").first ?? "") ?? 1
                }
                old = nums.first ?? 1
                new = nums.count > 1 ? nums[1] : 1
                return nil
            }
            if s.hasPrefix("diff --git") || s.hasPrefix("index ") || s.hasPrefix("--- ") || s.hasPrefix("+++ ") { return nil }
            if s.hasPrefix("-") { defer { old += 1 }; return LineNumber(line: old, old: true) }
            if s.hasPrefix("+") { defer { new += 1 }; return LineNumber(line: new, old: false) }
            if s.hasPrefix("\\") || (s.isEmpty && new == 0) { return nil }
            defer { old += 1; new += 1 }
            return LineNumber(line: new, old: false)
        }
    }

    /// Both halves of a file's changes, as sections of hunks with action links.
    static func renderChanges(unstaged: FilePatch, staged: FilePatch, editable: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if unstaged.isEmpty && staged.isEmpty {
            out.append(NSAttributedString(string: "No changes against HEAD.", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
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
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // An untracked file is all "+" lines with no header: number them from 1.
        let numbers: [LineNumber?] = untracked
            ? lines.indices.map { LineNumber(line: $0 + 1, old: false) } : lineNumbers(lines)
        for (s, number) in zip(lines, numbers) {
            if s.hasPrefix("diff --git") || s.hasPrefix("index ") || s.hasPrefix("--- ") || s.hasPrefix("+++ ")
                || s.hasPrefix("new file mode") || s.hasPrefix("deleted file mode") { continue }
            out.append(diffLine(s, number: number))
        }
        if out.length == 0 {
            out.append(NSAttributedString(string: "No changes against HEAD.", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
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
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
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
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
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
        let text = (preview.string as NSString)
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
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = field
        askPopover = popover
        var rect = preview.firstRect(forCharacterRange: NSRange(location: charIndex, length: 5), actualRange: nil)
        rect = preview.window?.convertFromScreen(rect) ?? rect
        rect = preview.convert(rect, from: nil)
        popover.show(relativeTo: rect, of: preview, preferredEdge: .maxY)
        field.focus()
    }

    #if DEBUG
    /// Self-test: ask about a line as if its number was clicked and submitted.
    func debugAsk(line: Int, _ comment: String) -> Bool {
        let ns = preview.string as NSString
        var found: Int?
        preview.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: ns.length)) { value, range, stop in
            if let url = value as? URL, url.scheme == Self.askScheme, url.host == "new", Int(url.lastPathComponent) == line {
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
        if textView === preview, let url = link as? URL, url.scheme == Self.askScheme,
           let line = Int(url.lastPathComponent) {
            askAboutLine(line, removed: url.host == "old", at: charIndex)
            return true
        }
        guard textView === preview, let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)),
              url.scheme == Self.hunkScheme, let host = url.host,
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
                let alert = NSAlert()
                alert.messageText = "Couldn’t \(host == "add" ? "stage the file" : "\(host) the hunk")"
                alert.informativeText = error
                alert.runModal()
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
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Revert this change in “\(shown.file.url.lastPathComponent)”?"
            alert.informativeText = "The hunk’s edits are removed from the file on disk. This can’t be undone."
            alert.addButton(withTitle: "Revert")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        }
        if let error = await patch.apply(action, hunk: hunk, repo: repo) { return error }
        await afterRepoChange(shown.file, reloadText: action == .revert)
        return nil
    }

    /// Untracked file → `git add`.
    private func stageWholeFile() async -> String? {
        guard let file = current, let repo = git.repoRoot else { return nil }
        let path = file.url.path
        let error = await Task.detached(priority: .userInitiated) { GitStatus.change(["-C", repo, "add", "--", path]) }.value
        if error == nil { await afterRepoChange(file, reloadText: false) }
        return error
    }

    /// Refresh status, the Changes view (and the text, after a revert) right
    /// away rather than waiting for FSEvents.
    private func afterRepoChange(_ file: OpenFile, reloadText: Bool) async {
        if reloadText { reload(file) }
        guard let root = git.repoRoot else { return }
        let status = await GitStatus.load(for: URL(fileURLWithPath: root))
        git = status
        rebuildTabs()
        if current === file { show(file) }
    }

    /// Unsaved edits in any tab: Save All / Discard / Cancel (false = cancel).
    func confirmCloseAll() -> Bool {
        commitEditorText()
        let dirty = files.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1 ? "Save changes to “\(dirty[0].url.lastPathComponent)”?"
            : "Save changes to \(dirty.count) files?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            dirty.forEach(save)
            return !files.contains(where: \.isDirty)
        case .alertSecondButtonReturn: return false
        default: return true
        }
    }

    private func refreshChanges(for file: OpenFile) {
        guard file.mode == .source else { return }
        let lines = file.text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        Task { [weak self] in
            let c = await LineChanges.load(file: file.url, repoRoot: self?.git.repoRoot,
                                           untracked: self?.git.changes[file.url.path] == .untracked, lineCount: lines)
            guard let self, self.current === file else { return }
            self.changes = c
            self.ruler.changes = c
        }
    }

    // MARK: Tabs

    private func rebuildTabs() {
        tabBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, file) in files.enumerated() {
            let tab = EditorTab(title: file.url.lastPathComponent, icon: NSWorkspace.shared.icon(forFile: file.url.path),
                                selected: file === current, dirty: file.isDirty,
                                change: git.changes[file.url.path])
            tab.onSelect = { [weak self] in self?.select(i) }
            tab.onClose = { [weak self] in self?.close(i) }
            tabBar.addArrangedSubview(tab)
        }
        tabScroll.isHidden = files.isEmpty
    }

    private func select(_ index: Int) {
        guard files.indices.contains(index) else { return }
        commitEditorText()
        show(files[index])
    }

    private func close(_ index: Int) {
        guard files.indices.contains(index) else { return }
        commitEditorText()
        let file = files[index]
        if file.isDirty {
            let alert = NSAlert()
            alert.messageText = "Save changes to “\(file.url.lastPathComponent)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn: save(file)
            case .alertSecondButtonReturn: return
            default: break
            }
        }
        files.remove(at: index)
        if file === current { show(files.isEmpty ? nil : files[min(index, files.count - 1)]) } else { rebuildTabs() }
    }

    // MARK: Editing

    private func commitEditorText() {
        guard let file = current, file.mode == .source, file.isText else { return }
        file.text = editor.string
        file.selection = editor.selectedRange()
    }

    func textDidChange(_ notification: Notification) {
        guard let file = current else { return }
        let wasDirty = file.isDirty
        file.text = editor.string
        if wasDirty != file.isDirty { rebuildTabs() }
        ruler.lineCountChanged()
        scheduleHighlight()
    }

    private func scheduleHighlight() {
        guard !highlightPending else { return }
        highlightPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
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
        do {
            try file.text.write(to: file.url, atomically: true, encoding: .utf8)
            file.savedText = file.text
            file.modified = try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            rebuildTabs()
            refreshChanges(for: file)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(saveDocument(_:)) { return current?.isDirty == true }
        if item.action == #selector(goToLine(_:)) { return current?.isText == true }
        return true
    }
}

/// A tab: icon, name (tinted by git status), unsaved dot / close button.
final class EditorTab: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    init(title: String, icon: NSImage, selected: Bool, dirty: Bool, change: GitStatus.Change?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = selected ? NSColor.labelColor.withAlphaComponent(0.09).cgColor : NSColor.clear.cgColor
        let image = NSImageView(image: icon)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: selected ? .medium : .regular)
        label.textColor = change?.color ?? (selected ? .labelColor : .secondaryLabelColor)
        let close = NSButton(image: NSImage(systemSymbolName: dirty ? "circle.fill" : "xmark",
                                            accessibilityDescription: dirty ? "Unsaved" : "Close")!
                                .withSymbolConfiguration(.init(pointSize: dirty ? 7 : 9, weight: .semibold))!,
                             target: nil, action: nil)
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = dirty ? "Unsaved changes — click to close" : "Close"
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
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onSelect?() }
    @objc private func closeClicked() { onClose?() }
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
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: nil)
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func redraw() { needsDisplay = true }

    func lineCountChanged() {
        guard let s = textView?.string as NSString? else { return }
        var starts = [0]
        var i = 0
        while i < s.length {
            let r = s.lineRange(for: NSRange(location: i, length: 0))
            i = NSMaxRange(r)
            if i < s.length || (i == s.length && s.length > 0 && s.character(at: s.length - 1) == 10) { starts.append(i) }
            if r.length == 0 { break }
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        ruleThickness = CGFloat(digits) * 7.5 + 22
        needsDisplay = true
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
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor]
        let visible = tv.visibleRect
        let origin = convert(NSPoint.zero, from: tv)
        let inset = tv.textContainerInset.height
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
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
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.target = self
        field.action = #selector(enter)
        field.setAccessibilityIdentifier("files-ask-field")
        let hint = NSTextField(labelWithString: "↩ send to the session · esc to cancel")
        hint.font = .systemFont(ofSize: 10.5)
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
