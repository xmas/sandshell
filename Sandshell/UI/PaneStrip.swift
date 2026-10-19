import AppKit
import SwiftUI

/// What a pane strip of a given width spells out. The crumbs give way from the
/// least specific inward — the sandbox's name, then the folder's, then all
/// three (sandbox, folder, branch) fold into one ⋯ menu — while the controls
/// never shrink or move. Widths are the strip's own, not the window's.
struct PaneStripCondensing: Equatable, Sendable {
    /// The sandbox crumb shows its name (else just its icon; the name is its tooltip).
    var sandboxLabel = true
    /// The folder crumb shows its name (else just its icon).
    var folderLabel = true
    /// Sandbox, folder and branch are folded into the ⋯ menu.
    var folded = false

    static let sandboxLabelBelow: CGFloat = 560
    static let folderLabelBelow: CGFloat = 480
    static let foldBelow: CGFloat = 410

    init(sandboxLabel: Bool = true, folderLabel: Bool = true, folded: Bool = false) {
        self.sandboxLabel = sandboxLabel
        self.folderLabel = folderLabel
        self.folded = folded
    }

    init(width: CGFloat) {
        self.init(sandboxLabel: width >= Self.sandboxLabelBelow,
                  folderLabel: width >= Self.folderLabelBelow,
                  folded: width < Self.foldBelow)
    }
}

/// How a pane shows its session, for the strip's two-segment switch.
enum PaneViewMode: Equatable, Sendable {
    case chat, terminal

    /// The switch for `session`: its current view, or nil when it has none —
    /// an agent that can't chat (no ACP), or a terminal-only session (an agent
    /// run in another agent's sandbox).
    static func current(for session: Session) -> PaneViewMode? {
        guard SbxCommand.supportsACP(session.agent), session.containerAgent == nil else { return nil }
        return session.isChat ? .chat : .terminal
    }
}

/// The strip's colours, from the terminal's: the strip is the top of the
/// terminal's frame, and a terminal can be dark in a light app. The default
/// light theme lands near the design's #F0EAE3 fill, #5C524B crumbs and
/// #BDB2A8 separators; a dark terminal gets the same steps toward its text.
extension ThemeColors {
    fileprivate var termIsDark: Bool {
        guard let c = termBg.usingColorSpace(.sRGB) else { return isDark }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.5
    }
    fileprivate func termMix(_ fraction: CGFloat) -> NSColor {
        termBg.blended(withFraction: fraction, of: termText) ?? termText
    }
    /// The focused pane's strip.
    var stripFill: NSColor { termMix(termIsDark ? 0.06 : 0.04) }
    var stripCrumb: NSColor { termMix(0.7) }
    var stripName: NSColor { termText }
    var stripSeparator: NSColor { termMix(0.38) }
    var stripHover: NSColor { termText.withAlphaComponent(0.07) }
    /// The view switch's track and its selected segment.
    var stripTrack: NSColor { termText.withAlphaComponent(termIsDark ? 0.1 : 0.07) }
    var stripSegment: NSColor { termIsDark ? NSColor.white.withAlphaComponent(0.16) : .white }
    var stripSegmentShadow: NSColor { NSColor.black.withAlphaComponent(termIsDark ? 0.35 : 0.1) }
}

/// A pane's title strip: one line, 34 pt, that never wraps. On the left the
/// session's crumbs — sandbox › folder › branch › name — which condense by
/// the strip's width (`PaneStripCondensing`); on the right the fixed
/// controls: Chat | Terminal, Split Right, Split Down, Close.
@MainActor
final class PaneStripView: NSView {
    static let height: CGFloat = 34
    private static let sidePadding: CGFloat = 10
    private static let controlSize: CGFloat = 24
    private static let controlGap: CGFloat = 2
    /// Between the crumbs and the controls.
    private static let crumbsGap: CGFloat = 8
    /// Between crumbs and separators.
    private static let crumbGap: CGFloat = 2
    /// The name crumb never gets narrower.
    static let nameMinWidth: CGFloat = 72
    /// The controls' symbols (larger than meta's: they're the strip's targets).
    private static let controlSymbol: CGFloat = 14

    // Actions (the pane's).
    var onShowFiles: ((_ changesOnly: Bool) -> Void)?
    var onPickView: ((PaneViewMode) -> Void)?
    var onSplitRight: (() -> Void)?
    var onSplitDown: (() -> Void)?
    var onClose: (() -> Void)?

    private let content = NSView()
    private let crumbs = NSView()
    private let sandboxCrumb = StripCrumb(symbol: "cube")
    private let folderCrumb = StripCrumb(symbol: "folder")
    private let branchCrumb = StripCrumb(symbol: nil, role: .code)
    private let moreCrumb = StripCrumb(symbol: "ellipsis", iconSize: 14, padding: 5)
    private let nameCrumb = StripCrumb(symbol: nil)
    private var separators: [NSTextField] = []
    private let viewSwitch = ViewModeSwitch()
    private let splitRightButton = StripIconButton()
    private let splitDownButton = StripIconButton()
    private let closeButton = StripIconButton()

    private var colors = ThemeColors.lightBase
    private var access: SandboxAccess?
    private var folder: URL?
    private var git = GitStatus.empty
    private var diff = (added: 0, removed: 0)
    private var hasBranch = false
    private var gitTask: Task<Void, Never>?
    private var gitTimer: Timer?
    private var popover: NSPopover?
    private var name: String?
    private var hovering = false
    private(set) var condensing = PaneStripCondensing()

    /// The pane has focus: the strip takes its fill.
    var isFocusedPane = true { didSet { updateEmphasis() } }
    /// Split windows dim the strips of the panes without focus.
    var dimsUnfocused = false { didSet { updateEmphasis() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        clipsToBounds = true
        addSubview(content)
        crumbs.clipsToBounds = true
        content.addSubview(crumbs)
        for crumb in [sandboxCrumb, folderCrumb, branchCrumb, moreCrumb, nameCrumb] { crumbs.addSubview(crumb) }
        sandboxCrumb.onPress = { [weak self] crumb in self?.showSandbox(below: crumb) }
        sandboxCrumb.setAccessibilityIdentifier("context-sandbox")
        folderCrumb.onPress = { [weak self] _ in self?.revealFolder() }
        folderCrumb.setAccessibilityIdentifier("context-folder")
        branchCrumb.onPress = { [weak self] crumb in self?.branchMenu().popUp(below: crumb) }
        branchCrumb.setAccessibilityIdentifier("context-branch")
        moreCrumb.onPress = { [weak self] crumb in self?.moreMenu().popUp(below: crumb) }
        moreCrumb.setAccessibilityIdentifier("pane-more")
        moreCrumb.setAccessibilityLabel("Sandbox, folder and branch")
        moreCrumb.toolTip = "Sandbox, folder and branch"
        nameCrumb.setAccessibilityIdentifier("pane-name")
        nameCrumb.label.font = .role(.meta, weight: .semibold)
        content.addSubview(viewSwitch)
        viewSwitch.onPick = { [weak self] mode in self?.onPickView?(mode) }
        viewSwitch.isHidden = true
        for (button, symbol, tip, action, id) in [
            (splitRightButton, "rectangle.split.2x1", "Split Right (⌘D)", #selector(splitRightClicked), "pane-split-right"),
            (splitDownButton, "rectangle.split.1x2", "Split Down (⇧⌘D)", #selector(splitDownClicked), "pane-split-down"),
            (closeButton, "xmark", "Close Pane (⌥⌘W)", #selector(closeClicked), "pane-close"),
        ] {
            button.configureSymbol(symbol, label: tip, pointSize: Self.controlSymbol, weight: .regular, tint: nil,
                                   target: self, action: action, id: id)
            content.addSubview(button)
        }
        // Commits and edits happen behind our back: re-read the branch now and then.
        gitTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return }
                self.refreshGit()
            }
        }
        applyTheme(colors)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func stop() { gitTimer?.invalidate(); gitTimer = nil }

    // MARK: Content

    /// Show `folder` as seen by its sandbox; the branch follows on its own.
    func update(folder: URL, access: SandboxAccess) {
        self.access = access
        let system = access.system.map { "\($0.shortDistribution ?? "Linux") VM" }
        sandboxCrumb.set(title: access.sandbox,
                         tip: "Runs in sandbox “\(access.sandbox)”" + (system.map { ", a \($0)" } ?? "")
                            + " — click for what it can access")
        folderCrumb.set(title: folder.lastPathComponent,
                        tip: "\(folder.path.tildeAbbreviated) — \(access.summary). Click to open in Finder")
        guard folder != self.folder else { return needsLayout = true }
        self.folder = folder
        hasBranch = false
        needsLayout = true
        refreshGit()
    }

    /// The session's name, shown only when the window has more than one pane (nil: hidden).
    func setName(_ name: String?) {
        guard name != self.name else { return }
        self.name = name
        nameCrumb.set(title: name ?? "", tip: name ?? "")
        restyleName()
        needsLayout = true
    }

    /// The view switch shows the session's current view (nil: no switch).
    func setViewMode(_ mode: PaneViewMode?) {
        viewSwitch.isHidden = mode == nil
        if let mode { viewSwitch.mode = mode }
        needsLayout = true
    }

    /// Close only does something with more than one pane.
    var canClose = false { didSet { closeButton.isEnabled = canClose } }

    /// Re-read the branch and its line counts (cheap; also on a slow tick).
    func refreshGit() {
        guard let folder, gitTask == nil else { return }
        gitTask = Task(priority: .utility) { [weak self] in
            let status = await GitStatus.load(for: folder)
            let numstat = status.repoRoot == nil ? nil : await GitStatus.numstat(for: folder)
            guard let self else { return }
            self.gitTask = nil
            // Moved to another folder meanwhile: this is old news; read that one.
            guard self.folder == folder else { self.refreshGit(); return }
            self.git = status
            var added = 0, removed = 0
            for line in (numstat ?? "").split(separator: "\n") {
                let cols = line.split(separator: "\t")
                if cols.count >= 2 { added += Int(cols[0]) ?? 0; removed += Int(cols[1]) ?? 0 }
            }
            self.diff = (added, removed)
            self.hasBranch = status.repoRoot != nil
            self.restyleBranch()
            self.needsLayout = true
        }
    }

    private var branchName: String { git.branch ?? "detached" }

    private func restyleBranch() {
        let title = NSMutableAttributedString(string: branchName, attributes: [
            .font: NSFont.role(.code), .foregroundColor: colors.stripCrumb])
        if diff.added + diff.removed > 0 {
            title.append(NSAttributedString(string: " ", attributes: [.font: NSFont.role(.code)]))
            title.append(.diffCounts(added: diff.added, removed: diff.removed))
        }
        let n = git.changes.count
        branchCrumb.set(attributedTitle: title,
                        tip: "Branch \(git.branch ?? "(detached HEAD)") in \(git.repoRoot ?? "")"
                            + (n > 0 ? " — \(n) changed file\(n == 1 ? "" : "s"), +\(diff.added) −\(diff.removed) lines"
                                     : " — no changes"))
        branchCrumb.setAccessibilityLabel(Self.branchAccessibilityLabel(branchName, added: diff.added, removed: diff.removed))
    }

    private func restyleName() {
        nameCrumb.label.textColor = colors.stripName
    }

    /// What VoiceOver hears for the branch crumb: its name, and the lines
    /// changed (with "line" agreeing with the count).
    static func branchAccessibilityLabel(_ branch: String, added: Int, removed: Int) -> String {
        guard added + removed > 0 else { return branch }
        let counts = String(AttributedString(localized: "^[\(added) line](inflect: true) added, \(removed) removed").characters)
        return "\(branch), \(counts)"
    }

    // MARK: Theme and focus

    func applyTheme(_ c: ThemeColors) {
        colors = c
        for crumb in [sandboxCrumb, folderCrumb, branchCrumb, moreCrumb, nameCrumb] {
            crumb.tint = c.stripCrumb
            crumb.hoverColor = c.stripHover
        }
        for sep in separators { sep.textColor = c.stripSeparator }
        for b in [splitRightButton, splitDownButton, closeButton] {
            b.contentTintColor = c.stripCrumb
            b.hoverColor = c.stripHover
        }
        viewSwitch.applyTheme(c)
        restyleName()
        if hasBranch { restyleBranch() }
        updateEmphasis()
    }

    private func updateEmphasis() {
        layer?.backgroundColor = (isFocusedPane ? colors.stripFill : colors.termBg).cgColor
        content.alphaValue = dimsUnfocused && !isFocusedPane && !hovering ? 0.4 : 1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateEmphasis() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateEmphasis() }

    // MARK: Layout

    override func layout() {
        super.layout()
        content.frame = bounds
        let width = bounds.width, height = bounds.height
        condensing = PaneStripCondensing(width: width)

        // Controls, right to left: fixed, whatever the crumbs need.
        let y = ((height - Self.controlSize) / 2).rounded()
        var x = width - Self.sidePadding
        for button in [closeButton, splitDownButton, splitRightButton] {
            x -= Self.controlSize
            button.frame = NSRect(x: x, y: y, width: Self.controlSize, height: Self.controlSize)
            x -= Self.controlGap
        }
        x += Self.controlGap
        if !viewSwitch.isHidden {
            x -= 6 + ViewModeSwitch.size.width
            viewSwitch.frame = NSRect(origin: NSPoint(x: x, y: ((height - ViewModeSwitch.size.height) / 2).rounded()),
                                      size: ViewModeSwitch.size)
        }

        // Crumbs: what fits by the rule, left to right; the name takes what's left.
        let crumbsWidth = max(x - Self.crumbsGap - Self.sidePadding, 0)
        crumbs.frame = NSRect(x: Self.sidePadding, y: 0, width: crumbsWidth, height: height)
        sandboxCrumb.showsLabel = condensing.sandboxLabel
        folderCrumb.showsLabel = condensing.folderLabel
        var items: [StripCrumb] = condensing.folded ? [moreCrumb] : [sandboxCrumb, folderCrumb] + (hasBranch ? [branchCrumb] : [])
        if name != nil { items.append(nameCrumb) }
        if condensing.folded, access == nil { items.removeAll { $0 === moreCrumb } }
        for crumb in [sandboxCrumb, folderCrumb, branchCrumb, moreCrumb, nameCrumb] {
            crumb.isHidden = !items.contains { $0 === crumb }
        }
        while separators.count < items.count - 1 { separators.append(makeSeparator()) }
        let separatorWidth = separators.first.map { ceil($0.intrinsicContentSize.width) } ?? 0
        let natural = items.map { $0 === nameCrumb ? max($0.naturalWidth, Self.nameMinWidth) : $0.naturalWidth }
        let widths = Self.crumbWidths(natural: natural,
                                      minimum: items.map { minimumWidth(of: $0) },
                                      room: crumbsWidth - CGFloat(max(items.count - 1, 0)) * (separatorWidth + 2 * Self.crumbGap))
        let crumbY = ((height - StripCrumb.height) / 2).rounded()
        var cx: CGFloat = 0
        for (i, crumb) in items.enumerated() {
            if i > 0 {
                let sep = separators[i - 1]
                cx += Self.crumbGap
                sep.frame = NSRect(x: cx, y: ((height - sep.intrinsicContentSize.height) / 2).rounded(),
                                   width: separatorWidth, height: sep.intrinsicContentSize.height)
                sep.isHidden = false
                cx += separatorWidth + Self.crumbGap
            }
            crumb.frame = NSRect(x: cx, y: crumbY, width: widths[i], height: StripCrumb.height)
            cx += widths[i]
        }
        for sep in separators.dropFirst(max(items.count - 1, 0)) { sep.isHidden = true }
    }

    /// How narrow a crumb may get when the rule's crumbs still don't fit:
    /// sandbox and folder down to their icons, the branch to a few letters,
    /// the name never below 72 pt (a short one is that wide anyway).
    private func minimumWidth(of crumb: StripCrumb) -> CGFloat {
        switch crumb {
        case sandboxCrumb, folderCrumb: crumb.iconOnlyWidth
        case branchCrumb: min(crumb.naturalWidth, 48)
        case nameCrumb: Self.nameMinWidth
        default: crumb.naturalWidth
        }
    }

    /// The crumbs' widths in `room`: each its natural width while they fit;
    /// when they don't, the least specific gives way first (the crumbs are in
    /// priority order, lowest first), each down to its minimum. Whatever still
    /// doesn't fit is clipped at the controls.
    static func crumbWidths(natural: [CGFloat], minimum: [CGFloat], room: CGFloat) -> [CGFloat] {
        var widths = natural
        var excess = natural.reduce(0, +) - room
        for i in widths.indices where excess > 0 {
            let give = min(excess, max(widths[i] - minimum[i], 0))
            widths[i] -= give
            excess -= give
        }
        return widths
    }

    private func makeSeparator() -> NSTextField {
        let sep = NSTextField(labelWithString: "›")
        sep.font = .role(.meta)
        sep.textColor = colors.stripSeparator
        sep.setAccessibilityElement(false)
        crumbs.addSubview(sep)
        return sep
    }

    // MARK: Actions

    @objc private func splitRightClicked() { onSplitRight?() }
    @objc private func splitDownClicked() { onSplitDown?() }
    @objc private func closeClicked() { onClose?() }

    private func showSandbox(below anchor: NSView) {
        guard let access else { return }
        NSPopover.toggle(&popover, below: anchor) { .hosting(SandboxAccessPopover(access: access)) }
    }

    /// Its own Finder window, showing the folder's contents.
    private func revealFolder() {
        guard let folder else { return }
        NSWorkspace.shared.open(folder)
    }

    private func branchMenuItems() -> [NSMenuItem] {
        guard git.repoRoot != nil else { return [] }
        let n = git.changes.count
        var items = [n == 0 ? NSMenuItem("Show Files") { [weak self] in self?.onShowFiles?(false) }
                     : NSMenuItem("Show \(n) Changed File\(n == 1 ? "" : "s")") { [weak self] in self?.onShowFiles?(true) }]
        if let branch = git.branch {
            items.append(NSMenuItem("Copy Branch Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(branch, forType: .string)
            })
        }
        return items
    }

    private func branchMenu() -> NSMenu {
        let menu = NSMenu()
        menu.items = branchMenuItems()
        return menu
    }

    /// The folded crumbs, as menu items with their actions.
    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        if let access {
            menu.addItem(NSMenuItem("Sandbox “\(access.sandbox)”…") { [weak self] in
                guard let self else { return }
                self.showSandbox(below: self.moreCrumb)
            })
            menu.items.last?.image = NSImage(systemSymbolName: "cube", accessibilityDescription: nil)
        }
        if let folder {
            menu.addItem(NSMenuItem("Open “\(folder.lastPathComponent)” in Finder") { [weak self] in self?.revealFolder() })
            menu.items.last?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        }
        if hasBranch {
            let counts = diff.added + diff.removed > 0 ? "  +\(diff.added) −\(diff.removed)" : ""
            menu.addItem(NSMenuItem(branchName + counts, symbol: "arrow.triangle.branch", submenu: branchMenuItems()))
        }
        return menu
    }
}

private extension NSMenu {
    @MainActor func popUp(below view: NSView) {
        popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }
}

private extension GitStatus {
    /// Lines added/removed vs HEAD (tracked files), like a PR's +/- count; off
    /// the main actor.
    @concurrent static func numstat(for folder: URL) async -> String? {
        git(["-C", folder.path, "diff", "--numstat", "HEAD"])
    }
}

// MARK: - Pieces

/// One crumb: an optional 12 pt symbol and a label, 24 pt high, with a hover
/// wash when it does something. Laid out by hand so the strip knows its width.
@MainActor
final class StripCrumb: NSView {
    static let height: CGFloat = 24
    private let padding: CGFloat
    private let iconGap: CGFloat = 5
    private let iconSize: CGFloat
    private let icon: NSImageView?
    let label = NSTextField(labelWithString: "")
    var onPress: ((StripCrumb) -> Void)?
    var tint: NSColor = .secondaryLabelColor {
        didSet { icon?.contentTintColor = tint; if !hasAttributedTitle { label.textColor = tint } }
    }
    var hoverColor: NSColor = .clear { didSet { updateHover() } }
    var showsLabel = true {
        didSet { if showsLabel != oldValue { label.isHidden = !showsLabel; needsLayout = true } }
    }
    private var hasAttributedTitle = false
    private var hovering = false { didSet { updateHover() } }
    private var pressed = false

    init(symbol: String?, role: TypeRole = .meta, iconSize: CGFloat = TypeRole.meta.symbolPointSize, padding: CGFloat = 7) {
        self.iconSize = iconSize
        self.padding = padding
        icon = symbol.map {
            NSImageView(image: NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular)) ?? NSImage())
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        icon?.setAccessibilityElement(false)   // the crumb says what it is
        if let icon { addSubview(icon) }
        label.font = .role(role)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.setAccessibilityElement(false)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(title: String, tip: String) {
        hasAttributedTitle = false
        label.stringValue = title
        label.textColor = tint
        toolTip = tip
        setAccessibilityLabel(title)
        needsLayout = true
    }

    func set(attributedTitle: NSAttributedString, tip: String) {
        hasAttributedTitle = true
        label.attributedStringValue = attributedTitle
        toolTip = tip
        needsLayout = true
    }

    /// A text field's cell draws its text this far in from either side.
    private static let cellMargin: CGFloat = 2
    /// The text's own width (the cell's, less its margins; the intrinsic
    /// width is short of what the cell needs and would truncate).
    private var labelWidth: CGFloat { ceil((label.cell?.cellSize.width ?? label.intrinsicContentSize.width) - 2 * Self.cellMargin) }

    /// Just its icon (and padding).
    var iconOnlyWidth: CGFloat { padding * 2 + (icon != nil ? iconSize : 0) }

    /// Its whole width: padding, icon, label (when shown), padding.
    var naturalWidth: CGFloat {
        var w = padding * 2
        if icon != nil { w += iconSize }
        if showsLabel, !label.stringValue.isEmpty { w += (icon != nil ? iconGap : 0) + labelWidth }
        return w
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    // The strip sets frames by hand: lay out with every new size, not on the next pass.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }

    private func layoutContent() {
        var x = padding
        if let icon {
            icon.frame = NSRect(x: x, y: ((bounds.height - iconSize) / 2).rounded(), width: iconSize, height: iconSize)
            x += iconSize + iconGap
        }
        // The field draws its text inset by its cell's margin: the frame
        // reaches into the padding by that much, so the text sits where
        // `naturalWidth` measured it.
        let h = ceil(label.intrinsicContentSize.height)
        let textX = icon == nil ? padding : x
        label.frame = NSRect(x: textX - Self.cellMargin, y: ((bounds.height - h) / 2).rounded(),
                             width: max(bounds.width - textX - padding, 0) + 2 * Self.cellMargin, height: h)
    }

    // A button for VoiceOver when it does something; static text otherwise.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { onPress == nil ? .staticText : .button }
    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress(self)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = onPress != nil }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = onPress != nil }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?(self)
    }
    // Clicks on the label or icon are the crumb's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    private func updateHover() { layer?.backgroundColor = hovering ? hoverColor.cgColor : nil }
}

/// A 24 pt symbol control with a hover wash (the strip's right-hand controls).
@MainActor
final class StripIconButton: NSButton {
    var hoverColor: NSColor = .clear
    private var hovering = false { didSet { updateHover() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.45; if !isEnabled { hovering = false } } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isEnabled }
    override func mouseExited(with event: NSEvent) { hovering = false }
    private func updateHover() { layer?.backgroundColor = hovering ? hoverColor.cgColor : nil }
}

/// Chat | Terminal: two 26×20 segments on a track, the selected one raised.
/// It shows the session's current view; picking the other switches to it.
@MainActor
final class ViewModeSwitch: NSView {
    static let size = NSSize(width: 2 + 26 + 1 + 26 + 2, height: 24)
    var mode: PaneViewMode = .chat { didSet { restyle() } }
    var onPick: ((PaneViewMode) -> Void)?
    private let chatSegment = NSButton()
    private let terminalSegment = NSButton()
    private var colors = ThemeColors.lightBase

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        for (segment, symbol, label, action, id) in [
            (chatSegment, "bubble.left", "Chat", #selector(chatPicked), "pane-view-chat"),
            (terminalSegment, "terminal", "Terminal", #selector(terminalPicked), "pane-view-terminal"),
        ] {
            segment.configureSymbol(symbol, label: "Show as \(label)", pointSize: 13, weight: .regular, tint: nil,
                                    target: self, action: action, id: id)
            segment.setButtonType(.pushOnPushOff)
            segment.wantsLayer = true
            segment.layer?.cornerRadius = 4
            segment.layer?.masksToBounds = false
            segment.layer?.shadowOffset = NSSize(width: 0, height: -1)
            segment.layer?.shadowRadius = 0.5
            addSubview(segment)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("View as")
        setAccessibilityIdentifier("pane-view-switch")
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        chatSegment.frame = NSRect(x: 2, y: 2, width: 26, height: 20)
        terminalSegment.frame = NSRect(x: 2 + 26 + 1, y: 2, width: 26, height: 20)
    }

    func applyTheme(_ c: ThemeColors) {
        colors = c
        restyle()
    }

    private func restyle() {
        layer?.backgroundColor = colors.stripTrack.cgColor
        for (segment, selected) in [(chatSegment, mode == .chat), (terminalSegment, mode == .terminal)] {
            segment.state = selected ? .on : .off
            segment.layer?.backgroundColor = selected ? colors.stripSegment.cgColor : nil
            segment.layer?.shadowColor = colors.stripSegmentShadow.cgColor
            segment.layer?.shadowOpacity = selected ? 1 : 0
            segment.contentTintColor = selected ? colors.stripName : colors.stripCrumb
            segment.setAccessibilityValue(selected)
        }
    }

    @objc private func chatPicked() { pick(.chat) }
    @objc private func terminalPicked() { pick(.terminal) }

    private func pick(_ picked: PaneViewMode) {
        defer { restyle() }   // (the button toggled itself; the session decides)
        guard picked != mode else { return }
        onPick?(picked)
    }
}

#if DEBUG
extension PaneStripView {
    /// Self-test: what the strip shows at its current width.
    struct DebugState {
        var height: CGFloat
        var condensing: PaneStripCondensing
        var sandboxShown, sandboxLabelShown, folderShown, folderLabelShown, branchShown, moreShown, nameShown: Bool
        var nameWidth: CGFloat
        var viewMode: PaneViewMode?
        /// Drawn at 40 % (an unfocused pane's strip, the pointer elsewhere).
        var dimmed: Bool
        /// The controls' frames in `view`'s coordinates.
        var controlFrames: [NSRect]
    }

    func debugState(in view: NSView) -> DebugState {
        layoutSubtreeIfNeeded()
        func shown(_ v: NSView) -> Bool { !v.isHiddenOrHasHiddenAncestor && v.frame.maxX <= crumbs.bounds.maxX + 0.5 }
        let controls = [viewSwitch.isHidden ? nil : viewSwitch as NSView, splitRightButton, splitDownButton, closeButton]
            .compactMap { $0 }
        return DebugState(
            height: bounds.height, condensing: condensing,
            sandboxShown: shown(sandboxCrumb), sandboxLabelShown: shown(sandboxCrumb) && !sandboxCrumb.label.isHidden,
            folderShown: shown(folderCrumb), folderLabelShown: shown(folderCrumb) && !folderCrumb.label.isHidden,
            branchShown: shown(branchCrumb), moreShown: !moreCrumb.isHiddenOrHasHiddenAncestor,
            nameShown: !nameCrumb.isHiddenOrHasHiddenAncestor, nameWidth: nameCrumb.isHidden ? 0 : nameCrumb.frame.width,
            viewMode: viewSwitch.isHidden ? nil : viewSwitch.mode, dimmed: content.alphaValue < 1,
            controlFrames: controls.map { $0.convert($0.bounds, to: view) })
    }

    /// Self-test: the folded crumbs' menu, as ⋯ would open it.
    var debugMoreMenuTitles: [String] { moreMenu().items.map(\.title) }
}
#endif
