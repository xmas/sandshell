import AppKit
import SwiftUI

/// What a pane strip of a given width spells out: its name always, the
/// branch chip beside it while there's room (under 360 pt it's in ⋯ only).
/// The controls never shrink or move. Widths are the strip's own.
struct PaneStripCondensing: Equatable, Sendable {
    /// The branch chip shows.
    var branch = true

    static let branchBelow: CGFloat = 360

    init(branch: Bool = true) { self.branch = branch }

    init(width: CGFloat) { self.init(branch: width >= Self.branchBelow) }
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

/// A pane's title strip, the window's title bar: one 38 pt line that never
/// wraps. On the left what the pane shows — its name, then the branch as a
/// chip (it gives way first); on the right Chat | Terminal, Remote Control's
/// antenna while it's on, ⋯ (everything else: the board, Remote Control,
/// Stop / Restart, the sandbox, the folder, the branch, the splits, Close),
/// Close itself while the window has several panes, and at the window's
/// top-right corner the Files toggle.
@MainActor
final class PaneStripView: NSView {
    /// Also the window's title bar (there's no toolbar): the traffic lights
    /// center in it.
    static let height: CGFloat = 38
    /// Room for the traffic lights, for a strip at the window's top-left
    /// while the sidebar is hidden.
    static let trafficLightsWidth: CGFloat = 72
    private static let sidePadding: CGFloat = 10
    private static let controlSize: CGFloat = 24
    private static let controlGap: CGFloat = 2
    /// Between the crumbs and the controls.
    private static let crumbsGap: CGFloat = 8
    /// Between the name and the branch chip.
    private static let chipGap: CGFloat = 6
    /// The name never gets narrower.
    static let nameMinWidth: CGFloat = 72
    /// The controls' symbols (larger than meta's: they're the strip's targets).
    private static let controlSymbol: CGFloat = 14

    // Actions (the pane's).
    var onShowFiles: ((_ changesOnly: Bool) -> Void)?
    var onPickView: ((PaneViewMode) -> Void)?
    var onSplitRight: (() -> Void)?
    var onSplitDown: (() -> Void)?
    var onClose: (() -> Void)?
    /// The session's own controls: stop its process, start it again.
    var onStopSession: (() -> Void)?
    var onRestartSession: (() -> Void)?
    /// Remote Control (its popover goes below the view passed).
    var onRemote: ((NSView) -> Void)?
    /// A board pane's "Open in Full Screen Window".
    var onBoardWindow: (() -> Void)?
    /// A session's Show Board.
    var onShowBoard: (() -> Void)?
    /// The window's sidebar and Files toggles, on the strips at its corners.
    var onToggleSidebar: (() -> Void)?
    var onToggleFiles: (() -> Void)?

    private let content = NSView()
    private let crumbs = NSView()
    private let nameCrumb = StripCrumb(symbol: nil, role: .title)
    private let branchCrumb = StripCrumb(symbol: "arrow.triangle.branch", role: .code, padding: 6)
    private let viewSwitch = ViewModeSwitch()
    /// Everything that isn't on the bar.
    private let moreButton = StripIconButton()
    private let closeButton = StripIconButton()
    /// A chat's Remote Control, on the bar only while it's on.
    private let remoteButton = StripIconButton()
    /// The window's: the sidebar's toggle (top-left strip, sidebar hidden)
    /// and Files' (top-right strip).
    private let sidebarButton = StripIconButton()
    private let filesButton = StripIconButton()
    /// Remote Control's state (nil: not a chat).
    private(set) var remoteState: Bool?
    /// The session's Stop / Restart (nil: none — no session, or a chat's,
    /// whose turn stops in its composer), enabled or not.
    private var stopSession: Bool?
    private var restartSession: Bool?

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
    /// At the window's top-left with the sidebar hidden: room for the
    /// traffic lights, then the sidebar's toggle.
    var isWindowLeading = false {
        didSet { if isWindowLeading != oldValue { sidebarButton.isHidden = !isWindowLeading; needsLayout = true } }
    }
    /// At the window's top-right: the Files toggle.
    var isWindowTrailing = false {
        didSet { if isWindowTrailing != oldValue { filesButton.isHidden = !isWindowTrailing; needsLayout = true } }
    }
    /// Files shows: its toggle is tinted.
    var filesShown = false { didSet { restyleFiles() } }
    /// Close only with more than one pane (and only then on the bar).
    var canClose = false {
        didSet { if canClose != oldValue { closeButton.isHidden = !canClose; needsLayout = true } }
    }
    /// Whether the pane shows a session, so ⋯ offers the session's board.
    var showsBoardButton = false
    /// Whether the pane shows a board, so ⋯ offers the board's own window.
    var showsBoardWindowButton = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        addSubview(content)
        crumbs.clipsToBounds = true
        content.addSubview(crumbs)
        for crumb in [nameCrumb, branchCrumb] { crumbs.addSubview(crumb) }
        nameCrumb.setAccessibilityIdentifier("pane-name")
        branchCrumb.onPress = { [weak self] crumb in self?.branchMenu().popUp(below: crumb) }
        branchCrumb.setAccessibilityIdentifier("context-branch")
        branchCrumb.isHidden = true
        content.addSubview(viewSwitch)
        viewSwitch.onPick = { [weak self] mode in self?.onPickView?(mode) }
        viewSwitch.isHidden = true
        for (button, symbol, tip, action, id) in [
            (moreButton, "ellipsis", "More: the board, Remote Control, the sandbox and folder, splits",
             #selector(moreClicked), "pane-more"),
            (closeButton, "xmark", "Close Pane (⌥⌘W)", #selector(closeClicked), "pane-close"),
            (sidebarButton, "sidebar.left", "Show Sidebar (⌃⌘S)", #selector(sidebarClicked), "window-show-sidebar"),
            (filesButton, "sidebar.right", "Show or Hide Files (⇧⌥⌘0)", #selector(filesClicked), "window-files"),
        ] {
            button.configureSymbol(symbol, label: tip, pointSize: Self.controlSymbol, weight: .regular, tint: nil,
                                   target: self, action: action, id: id)
            content.addSubview(button)
        }
        closeButton.isHidden = true
        sidebarButton.isHidden = true
        filesButton.isHidden = true
        content.addSubview(remoteButton)
        remoteButton.isHidden = true
        restyleRemote()
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

    /// The strip is the window's title bar: its background moves the window,
    /// and a double-click there does what the title bar's does.
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return super.mouseDown(with: event) }
        if event.clickCount == 2 { return Self.titleBarDoubleClick(window) }
        window.performDrag(with: event)
    }

    /// System Settings ▸ Desktop & Dock ▸ "Double-click a window's title bar to".
    static func titleBarDoubleClick(_ window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }

    func stop() { gitTimer?.invalidate(); gitTimer = nil }

    // MARK: Content

    /// Show `folder` as seen by its sandbox; the branch follows on its own.
    func update(folder: URL, access: SandboxAccess) {
        self.access = access
        guard folder != self.folder else { return needsLayout = true }
        self.folder = folder
        hasBranch = false
        needsLayout = true
        refreshGit()
    }

    /// What the pane shows, by name (nil: nothing).
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
        for crumb in [nameCrumb, branchCrumb] {
            crumb.tint = c.stripCrumb
            crumb.hoverColor = c.stripHover
        }
        branchCrumb.restingColor = c.stripTrack
        for b in [moreButton, closeButton, remoteButton, sidebarButton, filesButton] {
            b.contentTintColor = c.stripCrumb
            b.hoverColor = c.stripHover
        }
        restyleRemote()
        restyleFiles()
        viewSwitch.applyTheme(c)
        restyleName()
        if hasBranch { restyleBranch() }
        updateEmphasis()
    }

    private func updateEmphasis() {
        layer?.backgroundColor = (isFocusedPane ? colors.stripFill : colors.termBg).cgColor
        content.alphaValue = dimsUnfocused && !isFocusedPane && !hovering ? 0.4 : 1
    }

    /// Only our own area: AppKit keeps the tooltip's among `trackingAreas` too.
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
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
        func place(_ button: NSView) {
            x -= Self.controlSize
            button.frame = NSRect(x: x, y: y, width: Self.controlSize, height: Self.controlSize)
            x -= Self.controlGap
        }
        // The window's Files toggle, at its far end.
        if !filesButton.isHidden { place(filesButton); x -= 4 }
        if !closeButton.isHidden { place(closeButton) }
        place(moreButton)
        if !remoteButton.isHidden { place(remoteButton) }
        x += Self.controlGap
        if !viewSwitch.isHidden {
            x -= 6 + ViewModeSwitch.size.width
            viewSwitch.frame = NSRect(origin: NSPoint(x: x, y: ((height - ViewModeSwitch.size.height) / 2).rounded()),
                                      size: ViewModeSwitch.size)
        }

        // The traffic lights and the sidebar's toggle, at the window's top-left.
        var leading = Self.sidePadding
        if isWindowLeading {
            sidebarButton.frame = NSRect(x: Self.trafficLightsWidth, y: y, width: Self.controlSize, height: Self.controlSize)
            leading = Self.trafficLightsWidth + Self.controlSize + 6
        }
        // The name, then the branch chip while there's room; the chip gives way first.
        let crumbsWidth = max(x - Self.crumbsGap - leading, 0)
        crumbs.frame = NSRect(x: leading, y: 0, width: crumbsWidth, height: height)
        let showsBranch = hasBranch && condensing.branch
        branchCrumb.isHidden = !showsBranch
        nameCrumb.isHidden = name == nil
        let items = [showsBranch ? branchCrumb : nil, name == nil ? nil : nameCrumb].compactMap { $0 }
        let natural = items.map { $0 === nameCrumb ? max($0.naturalWidth, Self.nameMinWidth) : $0.naturalWidth }
        let minimum = items.map { $0 === nameCrumb ? Self.nameMinWidth : min($0.naturalWidth, 48) }
        let gaps = items.count > 1 ? Self.chipGap : 0
        let widths = Self.crumbWidths(natural: natural, minimum: minimum, room: crumbsWidth - gaps)
        let crumbY = ((height - StripCrumb.height) / 2).rounded()
        // Laid out left to right: the name first.
        var cx: CGFloat = 0
        for (crumb, w) in zip(items, widths).reversed() {
            crumb.frame = NSRect(x: cx, y: crumbY, width: w, height: StripCrumb.height)
            cx += w + Self.chipGap
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

    // MARK: Actions

    @objc private func moreClicked() { moreMenu().popUp(below: moreButton) }
    @objc private func closeClicked() { onClose?() }
    @objc private func remoteClicked() { onRemote?(remoteButton) }
    @objc private func sidebarClicked() { onToggleSidebar?() }
    @objc private func filesClicked() { onToggleFiles?() }

    /// The Files toggle: tinted while Files shows.
    private func restyleFiles() {
        filesButton.contentTintColor = filesShown ? .controlAccentColor : colors.stripCrumb
        filesButton.setAccessibilityValue(filesShown ? "on" : "off")
    }

    /// A chat's Remote Control: on or off (nil: not a chat). The bar shows its
    /// antenna only while it's on; ⋯ has it either way.
    func setRemote(_ on: Bool?) {
        guard on != remoteState else { return }
        remoteState = on
        let shown = on == true
        if remoteButton.isHidden == shown { remoteButton.isHidden = !shown; needsLayout = true }
        restyleRemote()
    }

    private func restyleRemote() {
        remoteButton.configureSymbol("antenna.radiowaves.left.and.right",
                                     label: "Remote Control is on — click for this chat's address",
                                     pointSize: Self.controlSymbol, weight: .regular, tint: .controlAccentColor,
                                     target: self, action: #selector(remoteClicked), id: "pane-remote")
        remoteButton.setAccessibilityValue(remoteState == true ? "on" : "off")
    }

    /// The session's controls (in ⋯): nil leaves one out (no session; a
    /// chat's Stop is its composer's), else enabled or not.
    func setSessionControls(stop: Bool?, restart: Bool?) {
        stopSession = stop
        restartSession = restart
    }

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

    /// ⋯: the session's things, then where it runs, then the pane's.
    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, symbol: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                 enabled: Bool = true, _ handler: @escaping () -> Void) {
            let item = NSMenuItem(title, handler: handler)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if !key.isEmpty { item.keyEquivalent = key; item.keyEquivalentModifierMask = modifiers }
            item.isEnabled = enabled
            menu.addItem(item)
        }
        func separate() { if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) } }
        // The session's.
        if showsBoardButton { add("Show Board", symbol: "paintpalette") { [weak self] in self?.onShowBoard?() } }
        if showsBoardWindowButton {
            add("Open in Full Screen Window", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in self?.onBoardWindow?() }
        }
        if let on = remoteState {
            add(on ? "Remote Control…" : "Turn On Remote Control…", symbol: "antenna.radiowaves.left.and.right") { [weak self] in
                guard let self else { return }
                self.onRemote?(self.remoteButton.isHidden ? self.moreButton : self.remoteButton)
            }
        }
        if let stop = stopSession {
            add("Stop the Session", symbol: "stop.fill", key: ".", enabled: stop) { [weak self] in self?.onStopSession?() }
        }
        if let restart = restartSession {
            add("Restart the Session", symbol: "arrow.clockwise", key: "r", enabled: restart) { [weak self] in
                self?.onRestartSession?()
            }
        }
        // Where it runs.
        separate()
        if let access {
            add("Sandbox “\(access.sandbox)”…", symbol: "cube") { [weak self] in
                guard let self else { return }
                self.showSandbox(below: self.moreButton)
            }
        }
        if let folder {
            add("Open “\(folder.lastPathComponent)” in Finder", symbol: "folder") { [weak self] in self?.revealFolder() }
        }
        if hasBranch {
            let counts = diff.added + diff.removed > 0 ? "  +\(diff.added) −\(diff.removed)" : ""
            menu.addItem(NSMenuItem(branchName + counts, symbol: "arrow.triangle.branch", submenu: branchMenuItems()))
        }
        // The pane's.
        separate()
        add("Split Right", symbol: "rectangle.split.2x1", key: "d") { [weak self] in self?.onSplitRight?() }
        add("Split Down", symbol: "rectangle.split.1x2", key: "d", modifiers: [.command, .shift]) { [weak self] in
            self?.onSplitDown?()
        }
        add("Close Pane", symbol: "xmark", key: "w", modifiers: [.command, .option], enabled: canClose) { [weak self] in
            self?.onClose?()
        }
        return menu
    }

    #if DEBUG
    /// Self-test: which of the window's toggles this strip has, and Files' state.
    var debugWindowToggles: (sidebar: Bool, files: Bool, filesOn: Bool, crumbsX: CGFloat) {
        layoutSubtreeIfNeeded()
        return (!sidebarButton.isHidden, !filesButton.isHidden, filesShown, crumbs.frame.minX)
    }
    #endif
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
    /// Its fill when the pointer isn't over it (a chip's).
    var restingColor: NSColor = .clear { didSet { updateHover() } }
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

    /// Only our own area: AppKit keeps the tooltip's among `trackingAreas` too.
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
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

    private func updateHover() { layer?.backgroundColor = (hovering ? hoverColor : restingColor).cgColor }
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

    /// Only our own area: AppKit keeps the tooltip's among `trackingAreas` too.
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
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
        var branchShown, nameShown: Bool
        var nameWidth: CGFloat
        var viewMode: PaneViewMode?
        /// Remote Control's antenna and Close are on the bar.
        var remoteShown, closeShown: Bool
        /// Drawn at 40 % (an unfocused pane's strip, the pointer elsewhere).
        var dimmed: Bool
        /// The controls' frames in `view`'s coordinates.
        var controlFrames: [NSRect]
        /// The session's Stop / Restart (in ⋯): offered (and enabled), or nil.
        var stopSession: Bool?, restartSession: Bool?
    }

    func debugState(in view: NSView) -> DebugState {
        layoutSubtreeIfNeeded()
        let controls = [viewSwitch, remoteButton, moreButton, closeButton, filesButton].filter { !$0.isHidden } as [NSView]
        return DebugState(
            height: bounds.height, condensing: condensing,
            branchShown: !branchCrumb.isHiddenOrHasHiddenAncestor && branchCrumb.frame.maxX <= crumbs.bounds.maxX + 0.5,
            nameShown: !nameCrumb.isHiddenOrHasHiddenAncestor, nameWidth: nameCrumb.isHidden ? 0 : nameCrumb.frame.width,
            viewMode: viewSwitch.isHidden ? nil : viewSwitch.mode,
            remoteShown: !remoteButton.isHidden, closeShown: !closeButton.isHidden, dimmed: content.alphaValue < 1,
            controlFrames: controls.map { $0.convert($0.bounds, to: view) },
            stopSession: stopSession, restartSession: restartSession)
    }

    /// Self-test: ⋯'s items ("" for a separator).
    var debugMoreMenuTitles: [String] { moreMenu().items.map { $0.isSeparatorItem ? "" : $0.title } }
}
#endif
