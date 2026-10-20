import AppKit

/// The Files sidebar's header, in the title bar above it: the file tree's
/// toggle, "Files", then the folder's branch and how many files changed
/// ("main · 6 changed"; click for the changed files). The sidebar's close
/// button sits at the bar's far end; the diff column toggles from View ▸ Diff
/// Column (⌥⌘2).
@MainActor
final class FilesHeaderView: NSStackView {
    private let title = NSTextField(labelWithString: "Files")
    let branch = NSTextField(labelWithString: "")
    /// The branch line was clicked.
    var onBranchClick: (() -> Void)?
    /// Show or hide the file tree's column / the diff column.
    var onToggleTree: (() -> Void)?
    private(set) lazy var treeToggle = NSButton.symbol(
        "sidebar.left", label: "Hide the File Tree (⌥⌘1)", pointSize: TypeRole.meta.symbolPointSize,
        size: NSSize(width: 24, height: 22), target: self, action: #selector(treeClicked), id: "files-tree-toggle")

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4
        title.font = .role(.title)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        branch.font = .role(.code)
        branch.lineBreakMode = .byTruncatingMiddle
        branch.setContentCompressionResistancePriority(.init(40), for: .horizontal)
        branch.setAccessibilityIdentifier("files-header-branch")
        branch.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(branchClicked)))
        // "Files" and the branch share a baseline; the toggles center on them.
        let labels = NSStackView(views: [title, branch])
        labels.orientation = .horizontal
        labels.alignment = .firstBaseline
        labels.spacing = 8
        labels.setClippingResistancePriority(.init(45), for: .horizontal)
        labels.setContentCompressionResistancePriority(.init(40), for: .horizontal)
        setViews([treeToggle, labels], in: .leading)
        edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        setClippingResistancePriority(.init(45), for: .horizontal)
        setAccessibilityIdentifier("files-header")
        // As wide as the sidebar leaves it (`fit(sidebarWidth:)`): the toolbar
        // measures items at their compressed size, which would drop the branch.
        width.isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private lazy var width = widthAnchor.constraint(equalToConstant: 200)

    /// Take the sidebar's width, less its close button and margins.
    func fit(sidebarWidth: CGFloat) {
        let wanted = max(120, (sidebarWidth - 76).rounded())
        if width.constant != wanted { width.constant = wanted }
    }

    /// "main · 6 changed", "main · clean", "detached · …"; nothing outside a repo.
    static func branchLine(_ git: GitStatus) -> String {
        guard git.repoRoot != nil else { return "" }
        let changed = git.changes.count
        return (git.branch ?? "detached") + (changed > 0 ? " · \(changed) changed" : " · clean")
    }

    func update(_ git: GitStatus) {
        branch.stringValue = Self.branchLine(git)
        branch.toolTip = git.changes.isEmpty ? nil : "Show the changed files"
    }

    func apply(_ colors: ThemeColors) {
        title.textColor = colors.text
        branch.textColor = colors.text2
        treeToggle.contentTintColor = colors.text2
    }

    /// The toggles say what they'll do.
    func update(treeShown: Bool) {
        let tree = treeShown ? "Hide the File Tree (⌥⌘1)" : "Show the File Tree (⌥⌘1)"
        treeToggle.toolTip = tree
        treeToggle.setAccessibilityLabel(tree)
    }

    #if DEBUG
    /// Self-test: the header's buttons that show or hide a column.
    var debugToggles: [String] {
        views.compactMap { ($0 as? NSButton)?.accessibilityIdentifier() }.filter { $0.hasSuffix("-toggle") }
    }
    #endif

    @objc private func branchClicked() { onBranchClick?() }
    @objc private func treeClicked() { onToggleTree?() }
}
