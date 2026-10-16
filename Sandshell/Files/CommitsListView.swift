import AppKit

/// Files' Commits section, under the tree: All changes (since the branch's
/// base), Uncommitted changes, then the branch's commits. Picking one shows
/// just the files it touched. Collapsible from its header.
@MainActor
final class CommitsListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Row: Equatable {
        case all(base: String)
        case uncommitted
        case commit(GitCommit)

        var scope: ChangeScope {
            switch self {
            case .all(let base): .all(base: base)
            case .uncommitted: .uncommitted
            case .commit(let c): .commit(c)
            }
        }
    }

    /// A row was picked (nil: the selection was cleared).
    var onPick: ((ChangeScope?) -> Void)?

    private let header = NSButton()
    private let count = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var heightConstraint: NSLayoutConstraint!
    private(set) var rows: [Row] = []
    private var settingSelection = false
    private static let expandedKey = "filesCommitsExpanded"
    private(set) var isExpanded = (UserDefaults.standard.object(forKey: expandedKey) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(isExpanded, forKey: Self.expandedKey); updateHeader() }
    }

    init() {
        super.init(frame: .zero)
        header.isBordered = false
        header.imagePosition = .imageLeading
        header.alignment = .left
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.contentTintColor = .secondaryLabelColor
        header.target = self
        header.action = #selector(toggle)
        header.setAccessibilityIdentifier("files-commits-header")
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .tertiaryLabelColor

        let column = NSTableColumn(identifier: .init("commit"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("files-commits")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let line = NSBox()
        line.boxType = .separator
        for v in [line, header, count, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            count.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 6),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
        updateHeader()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// New history. Keeps the picked row when it's still there.
    func update(base: String?, commits: [GitCommit], picked: ChangeScope?) {
        var new: [Row] = []
        if let base { new.append(.all(base: base)) }
        new.append(.uncommitted)
        new += commits.map(Row.commit)
        count.stringValue = commits.isEmpty ? "" : "\(commits.count)"
        if new != rows {
            rows = new
            table.reloadData()
        }
        select(picked)
        updateHeight()
    }

    /// Reflect a scope picked elsewhere (the Changed toggle) without firing onPick.
    func select(_ scope: ChangeScope?) {
        settingSelection = true
        defer { settingSelection = false }
        if let scope, let i = rows.firstIndex(where: { $0.scope == scope }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    @objc private func toggle() {
        isExpanded.toggle()
        updateHeight()
    }

    private func updateHeader() {
        header.title = "Commits"
        header.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                               accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    }

    /// Up to about seven rows; the list scrolls beyond that.
    private func updateHeight() {
        guard isExpanded else { heightConstraint.constant = 0; scroll.isHidden = true; return }
        scroll.isHidden = false
        // The table's own measure, row spacing included.
        let last = min(rows.count, 7) - 1
        heightConstraint.constant = last < 0 ? 0 : table.rect(ofRow: last).maxY + 6
    }

    private func rowHeight(for row: Row) -> CGFloat {
        if case .commit = row { return 38 }
        return 24
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight(for: rows[row]) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: CommitCell.id, owner: nil) as? CommitCell ?? CommitCell()
        switch rows[row] {
        case .all: cell.configure(title: "All changes", detail: nil)
        case .uncommitted: cell.configure(title: "Uncommitted changes", detail: nil)
        case .commit(let c):
            let when = Format.relative(c.date)
            cell.configure(title: c.subject, detail: "\(c.short) · \(c.author) · \(when)")
            cell.toolTip = "\(c.short) \(c.subject)\n\(c.author), \(c.date.formatted(date: .abbreviated, time: .shortened))"
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !settingSelection else { return }
        let i = table.selectedRow
        onPick?(i >= 0 && i < rows.count ? rows[i].scope : nil)
    }

    #if DEBUG
    func debugPick(_ index: Int) { table.selectRowIndexes([index], byExtendingSelection: false) }
    #endif
}

/// Title over an optional "sha · author · when" line.
private final class CommitCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("CommitCell")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        textField = title
        title.font = .systemFont(ofSize: 12.5)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for l in [title, detail] { l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, detail: String?) {
        self.title.stringValue = title
        self.detail.stringValue = detail ?? ""
        self.detail.isHidden = detail == nil
        toolTip = nil
    }
}
