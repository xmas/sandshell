import AppKit

/// One row in the composer's completion panel.
struct CompletionItem: Equatable {
    enum Kind: Equatable { case command(name: String), file(URL, relative: String) }
    let kind: Kind
    let title: String
    let detail: String
}

/// Borderless, non-activating suggestion panel shown under the composer's
/// caret for `/commands` and `@files`. Keyboard stays in the composer, which
/// forwards ↑/↓/Return/Tab/⎋ while the panel is visible.
@MainActor
final class CompletionPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onAccept: ((CompletionItem) -> Void)?
    private(set) var items: [CompletionItem] = []
    private let panel: NSPanel
    private let table = NSTableView()
    private static let rowHeight: CGFloat = 40

    var isVisible: Bool { panel.isVisible }
    var selected: CompletionItem? { table.selectedRow >= 0 && table.selectedRow < items.count ? items[table.selectedRow] : nil }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        super.init()
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.style = .inset
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityIdentifier("chat-completions")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        panel.contentView = effect
    }

    /// Show `items` with the panel's top-left just below `caret` (screen rect).
    func show(_ items: [CompletionItem], below caret: NSRect, parent: NSWindow?) {
        guard !items.isEmpty else { hide(); return }
        self.items = items
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
        let height = min(CGFloat(items.count) * (Self.rowHeight + 2) + 12, 320)
        var origin = NSPoint(x: caret.minX - 10, y: caret.minY - height - 4)
        if let screen = parent?.screen ?? NSScreen.main, origin.y < screen.visibleFrame.minY {
            origin.y = caret.maxY + 4   // no room below: open upward
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: 440, height: height)), display: true)
        if !panel.isVisible {
            parent?.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0, table.clickedRow < items.count else { return }
        onAccept?(items[table.clickedRow])
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let icon = NSImageView(image: NSImage(systemSymbolName: {
            if case .command = item.kind { return "command" } else { return "doc" }
        }(), accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }
}

/// An inline `@file` chip in the composer. Serialized as `@relative/path` in
/// the prompt text plus a `resource_link` for the file itself.
final class MentionAttachment: NSTextAttachment {
    let url: URL
    let relative: String

    init(url: URL, relative: String) {
        self.url = url
        self.relative = relative
        super.init(data: nil, ofType: nil)
        let label = url.lastPathComponent
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        let size = NSSize(width: ceil(textSize.width) + 30, height: 20)
        image = NSImage(size: size, flipped: false) { rect in
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
            if let doc = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) {
                doc.draw(in: NSRect(x: 7, y: 4, width: 10, height: 12))
            }
            (label as NSString).draw(at: NSPoint(x: 21, y: (rect.height - textSize.height) / 2),
                                     withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
            return true
        }
        // The name is only pixels in the chip: say it to VoiceOver.
        image?.accessibilityDescription = "File \(relative)"
        bounds = CGRect(x: 0, y: -5, width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Files under a workspace folder for `@` completion: indexed once (off the
/// main thread), skipping VCS/build/dependency directories, then filtered
/// with a simple filename-first fuzzy match.
actor WorkspaceFileIndex {
    static let shared = WorkspaceFileIndex()
    private var cache: [String: (files: [String], at: Date)] = [:]
    private static let skip: Set<String> = [".git", "node_modules", ".build", "build", "build-release", "DerivedData",
                                            ".venv", "venv", "dist", ".sandshell", ".beads", "__pycache__", ".next",
                                            "target", "Pods", ".gradle", ".idea", ".hatch", ".sbx"]

    func files(under root: String) -> [String] {
        if let hit = cache[root], Date.now.timeIntervalSince(hit.at) < 30 { return hit.files }
        var out: [String] = []
        let base = URL(filePath: root, directoryHint: .isDirectory)
        // The enumerator may hand back the real path (/tmp → /private/tmp).
        let prefixes = Set([base.path(percentEncoded: false), base.realPath])
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        if let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsPackageDescendants]) {
            for case let url as URL in e {
                let name = url.lastPathComponent
                if Self.skip.contains(name) || name == ".DS_Store" { e.skipDescendants(); continue }
                if e.level > 8 { e.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                let path = url.path(percentEncoded: false)
                guard let prefix = prefixes.first(where: { path.hasPrefix($0) }) else { continue }
                out.append(String(path.dropFirst(prefix.count)))
                if out.count >= 20_000 { break }
            }
        }
        cache[root] = (out, Date.now)
        return out
    }

    nonisolated static func match(_ files: [String], query: String, limit: Int = 30) -> [String] {
        guard !query.isEmpty else { return Array(files.sorted { $0.count < $1.count }.prefix(limit)) }
        let q = query.lowercased()
        let scored = files.compactMap { path -> (String, Int)? in
            // As the system searches: case and accents aside ("resume" finds Résumé.md).
            let name = (path as NSString).lastPathComponent
            if let r = name.localizedStandardRange(of: query) { return (path, r.lowerBound == name.startIndex ? 0 : 1) }
            if path.localizedStandardContains(query) { return (path, 2) }
            // Subsequence match on the filename (e.g. "chtv" → ChatTranscriptView).
            return Self.isSubsequence(q, of: name.lowercased()) ? (path, 3) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.count < $1.0.count }.prefix(limit).map(\.0)
    }

    nonisolated private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var h = haystack.makeIterator()
        outer: for ch in needle {
            while let c = h.next() { if c == ch { continue outer } }
            return false
        }
        return true
    }
}
