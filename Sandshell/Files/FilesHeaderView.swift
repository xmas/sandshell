import AppKit

/// The Files sidebar's header, in the title bar above it: "Files", then the
/// folder's branch and how many files changed ("main · 6 changed"; click for
/// the changed files). The sidebar's close button sits at the bar's far end.
@MainActor
final class FilesHeaderView: NSStackView {
    private let title = NSTextField(labelWithString: "Files")
    let branch = NSTextField(labelWithString: "")
    /// The branch line was clicked.
    var onBranchClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = 8
        title.font = .role(.title)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        branch.font = .role(.code)
        branch.lineBreakMode = .byTruncatingMiddle
        branch.setContentCompressionResistancePriority(.init(40), for: .horizontal)
        branch.setAccessibilityIdentifier("files-header-branch")
        branch.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(branchClicked)))
        setViews([title, branch], in: .leading)
        edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
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
    }

    @objc private func branchClicked() { onBranchClick?() }
}
