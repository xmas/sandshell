import AppKit

/// Open Quickly (⇧⌘O): a fuzzy file-name finder over the Files root, in a
/// popover. Type to narrow, ↑/↓ to move, Return to open, Esc to dismiss.
@MainActor
final class OpenQuicklyController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onOpen: ((URL) -> Void)?
    var onCancel: (() -> Void)?
    let root: URL
    private var files: [String] = []
    private(set) var results: [String] = []
    private let field = NSSearchField()
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "")

    init(root: URL) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        field.placeholderString = "Open Quickly"
        field.font = .systemFont(ofSize: 16)
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.setAccessibilityIdentifier("open-quickly-field")

        let column = NSTableColumn(identifier: .init("file"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        empty.textColor = .tertiaryLabelColor
        empty.font = .systemFont(ofSize: 13)
        empty.isHidden = true

        for v in [field, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 520),
            root.heightAnchor.constraint(equalToConstant: 360),
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let base = root.path
        Task { [weak self] in
            let files = await WorkspaceFileIndex.shared.files(under: base)
            guard let self else { return }
            self.files = files
            self.search(self.field.stringValue)
        }
    }

    /// Narrow the list to `query` (also the self-test's entry point).
    func search(_ query: String) {
        if field.stringValue != query { field.stringValue = query }
        let q = query.trimmingCharacters(in: .whitespaces)
        results = WorkspaceFileIndex.match(files, query: q, limit: 60)
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        empty.stringValue = files.isEmpty ? "No files" : "No matches"
        empty.isHidden = !results.isEmpty
    }

    func controlTextDidChange(_ obj: Notification) { search(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): onCancel?(); return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), results.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard results.indices.contains(row) else { return NSSound.beep() }
        onOpen?(root.appendingPathComponent(results[row]))
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: OpenQuicklyCell.id, owner: nil) as? OpenQuicklyCell ?? OpenQuicklyCell()
        cell.configure(path: results[row], root: root, query: field.stringValue)
        return cell
    }
}

/// Icon, file name (matched characters emphasised) and its folder.
final class OpenQuicklyCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("OpenQuicklyCell")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingHead
        name.lineBreakMode = .byTruncatingMiddle
        let text = NSStackView(views: [name, folder])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        for v in [icon, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var shown: (file: String, query: String)?

    /// Selected rows (emphasized) need light text.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if let shown { style(shown.file, shown.query) } }
    }

    func configure(path: String, root: URL, query: String) {
        let url = root.appendingPathComponent(path)
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        let file = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        folder.stringValue = dir.isEmpty ? root.lastPathComponent : dir
        shown = (file, query)
        style(file, query)
    }

    private func style(_ file: String, _ query: String) {
        let emphasized = backgroundStyle == .emphasized
        folder.textColor = emphasized ? .alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        // Emphasise the query's characters, in order, within the name.
        let s = NSMutableAttributedString(string: file, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: emphasized ? NSColor.alternateSelectedControlTextColor : .labelColor])
        let bold = NSFont.systemFont(ofSize: 13, weight: .bold)
        let lower = Array(file.lowercased().utf16)
        var i = 0
        for ch in query.lowercased().utf16 {
            while i < lower.count, lower[i] != ch { i += 1 }
            guard i < lower.count else { break }
            s.addAttribute(.font, value: bold, range: NSRange(location: i, length: 1))
            i += 1
        }
        name.attributedStringValue = s
    }
}

/// Go to Line (⌘L): "line" or "line:column", in a small popover.
@MainActor
final class GoToLineController: NSViewController, NSTextFieldDelegate {
    var onGo: ((Int, Int?) -> Void)?
    var onCancel: (() -> Void)?
    private let field = NSTextField()
    private let lineCount: Int
    private let currentLine: Int

    init(lineCount: Int, currentLine: Int) {
        self.lineCount = lineCount
        self.currentLine = currentLine
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        let label = NSTextField(labelWithString: "Line")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        field.placeholderString = "\(currentLine)  (1–\(lineCount), or line:column)"
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.delegate = self
        field.setAccessibilityIdentifier("go-to-line-field")
        let stack = NSStackView(views: [label, field])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            field.widthAnchor.constraint(equalToConstant: 220),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    /// "12" / "12:5" → (12, 5); nil when it isn't a line number.
    static func parse(_ text: String) -> (line: Int, column: Int?)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
        guard let first = parts.first, let line = Int(first), line > 0 else { return nil }
        return (line, parts.count > 1 ? Int(parts[1]) : nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if let (line, column) = Self.parse(field.stringValue) { onGo?(line, column) } else { NSSound.beep() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default: return false
        }
    }
}
