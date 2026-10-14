import AppKit
import SwiftUI

/// Where a session runs, at a glance, in its pane's title strip: the sandbox
/// (what kind of machine), the folder, and its git branch — each a small chip
/// with the obvious actions behind it.
@MainActor
final class SessionContextBar: NSStackView {
    var onShowFiles: (() -> Void)?

    private let sandboxChip = ContextChip(symbol: "shippingbox")
    private let folderChip = ContextChip(symbol: "folder")
    private let branchChip = ContextChip(symbol: "arrow.triangle.branch")
    private var access: SandboxAccess?
    private var folder: URL?
    private var git = GitStatus.empty
    private var gitTask: Task<Void, Never>?
    private var popover: NSPopover?

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        setViews([sandboxChip, folderChip, branchChip], in: .leading)
        setHuggingPriority(.defaultLow, for: .horizontal)
        sandboxChip.target = self
        sandboxChip.action = #selector(sandboxClicked)
        sandboxChip.setAccessibilityIdentifier("context-sandbox")
        folderChip.target = self
        folderChip.action = #selector(folderClicked)
        folderChip.setAccessibilityIdentifier("context-folder")
        branchChip.target = self
        branchChip.action = #selector(branchClicked)
        branchChip.setAccessibilityIdentifier("context-branch")
        // The branch chip gives way first in a narrow pane, then the sandbox's.
        branchChip.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        sandboxChip.setContentCompressionResistancePriority(.init(245), for: .horizontal)
        folderChip.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        // Commits and edits happen behind our back: re-read the branch now and then.
        gitTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return }
                self.refreshGit()
            }
        }
    }

    private var gitTimer: Timer?

    func stop() { gitTimer?.invalidate(); gitTimer = nil }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ c: ThemeColors) {
        for chip in [sandboxChip, folderChip, branchChip] { chip.tint = c.termDim; chip.border = c.border }
    }

    /// Show `folder` as seen by its sandbox; the branch follows on its own.
    func update(folder: URL, access: SandboxAccess) {
        self.access = access
        sandboxChip.set(title: access.system.map { "\($0.shortDistribution ?? "Linux") VM · \(access.sandbox)" }
                        ?? access.sandbox,
                        tip: "Runs in sandbox “\(access.sandbox)”, a Linux VM — click for what it can access")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = folder.path == home ? "~" : folder.path.hasPrefix(home + "/") ? "~" + folder.path.dropFirst(home.count) : folder.path
        folderChip.set(title: folder.lastPathComponent, tip: "\(path) — \(access.summary)")
        guard folder != self.folder else { return }
        self.folder = folder
        branchChip.isHidden = true
        refreshGit()
    }

    /// Re-read the branch and changed count (cheap; called on a slow tick).
    func refreshGit() {
        guard let folder, gitTask == nil else { return }
        gitTask = Task { [weak self] in
            let status = await GitStatus.load(for: folder)
            // Lines added/removed vs HEAD (tracked files), like a PR's +/- count.
            let numstat = status.repoRoot == nil ? nil : await Task.detached(priority: .utility) {
                GitStatus.git(["-C", folder.path, "diff", "--numstat", "HEAD"])
            }.value
            guard let self else { return }
            self.gitTask = nil
            self.git = status
            if status.repoRoot == nil {
                self.branchChip.set(title: "No git", tip: "\(folder.lastPathComponent) isn't a git repository")
            } else {
                let n = status.changes.count
                var added = 0, removed = 0
                for line in (numstat ?? "").split(separator: "\n") {
                    let cols = line.split(separator: "\t")
                    if cols.count >= 2 { added += Int(cols[0]) ?? 0; removed += Int(cols[1]) ?? 0 }
                }
                self.branchChip.set(title: status.branch ?? "detached",
                                    added: added, removed: removed,
                                    tip: "Branch \(status.branch ?? "(detached HEAD)") in \(status.repoRoot ?? "")"
                                        + (n > 0 ? " — \(n) changed file\(n == 1 ? "" : "s"), +\(added) −\(removed) lines" : " — no changes"))
            }
            self.branchChip.isHidden = false
        }
    }

    // MARK: Actions

    @objc private func sandboxClicked() {
        guard let access else { return }
        if let open = popover, open.isShown { open.close(); return }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = NSHostingController(rootView: SandboxAccessView(access: access))
        p.show(relativeTo: sandboxChip.bounds, of: sandboxChip, preferredEdge: .maxY)
        popover = p
    }

    @objc private func folderClicked() {
        guard let folder else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Files", action: #selector(showFiles), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(reveal), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let info = menu.addItem(withTitle: folder.path, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: folderChip.bounds.maxY + 4), in: folderChip)
    }

    @objc private func branchClicked() {
        let menu = NSMenu()
        if git.repoRoot != nil {
            let changes = menu.addItem(withTitle: git.changes.isEmpty ? "Show Files" : "Show \(git.changes.count) Changed File\(git.changes.count == 1 ? "" : "s")",
                                       action: #selector(showFiles), keyEquivalent: "")
            changes.target = self
            if git.branch != nil {
                menu.addItem(withTitle: "Copy Branch Name", action: #selector(copyBranch), keyEquivalent: "").target = self
            }
        } else {
            let none = menu.addItem(withTitle: "Not a git repository", action: nil, keyEquivalent: "")
            none.isEnabled = false
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: branchChip.bounds.maxY + 4), in: branchChip)
    }

    @objc private func showFiles() { onShowFiles?() }
    @objc private func reveal() { if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) } }
    @objc private func copyPath() { copy(folder?.path) }
    @objc private func copyBranch() { copy(git.branch) }

    private func copy(_ s: String?) {
        guard let s else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// A small outlined chip: symbol + label, like a breadcrumb you can click.
final class ContextChip: NSButton {
    var tint: NSColor = .secondaryLabelColor { didSet { restyle() } }
    var border: NSColor = .separatorColor { didSet { restyle() } }
    private let symbol: String
    private var text = ""

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        imagePosition = .imageLeading
        lineBreakMode = .byTruncatingTail
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var added = 0, removed = 0

    func set(title: String, added: Int = 0, removed: Int = 0, tip: String) {
        text = title
        self.added = added
        self.removed = removed
        toolTip = tip
        setAccessibilityLabel(added + removed > 0 ? "\(title), \(added) lines added, \(removed) removed" : title)
        restyle()
    }

    private func restyle() {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        contentTintColor = tint
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let title = NSMutableAttributedString(string: " " + text, attributes: [.font: font, .foregroundColor: tint])
        if added + removed > 0 {
            let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            title.append(NSAttributedString(string: "  +\(added)", attributes: [.font: mono, .foregroundColor: NSColor.systemGreen]))
            title.append(NSAttributedString(string: " −\(removed)", attributes: [.font: mono, .foregroundColor: NSColor.systemRed]))
        }
        attributedTitle = title
        layer?.borderColor = border.cgColor
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 14, height: 20)
    }
}
