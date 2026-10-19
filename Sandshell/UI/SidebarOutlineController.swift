import AppKit
import Combine
import QuartzCore
import SwiftUI

extension AgentKind {
    /// SF Symbol used for an agent's session row.
    var symbolName: String {
        switch self {
        case .claude, .dockerAgent: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .gemini: "diamond"
        case .shell: "terminal"
        default: customSymbol ?? "cpu"
        }
    }

    /// Menu icon used in agent pickers. Prefer actual agent brand assets when
    /// available, and fall back to the same SF Symbol used by session rows.
    var menuIcon: NSImage? {
        if let name = badgeImageName, let image = NSImage(named: name) {
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            return image
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }
}

/// NSTableView subclass that delegates context-menu and key handling back to
/// the `SidebarListController`.
final class SidebarTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?
    var onDeleteKey: (() -> Void)?
    var onReturnKey: (() -> Void)?
    /// ← / → (true): collapse / expand; false = not handled.
    var onArrow: ((Bool) -> Bool)?
    private var keyObservers: [NSObjectProtocol] = []

    // The selection is drawn muted when the window isn't key or the list isn't
    // focused (like native lists): redraw rows when either changes.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.redrawRows() }
            })
        }
    }
    override func becomeFirstResponder() -> Bool { defer { redrawRows() }; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { defer { redrawRows() }; return super.resignFirstResponder() }
    private func redrawRows() {
        enumerateAvailableRowViews { row, _ in row.needsDisplay = true }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return menuProvider?(row)
    }

    override func keyDown(with event: NSEvent) {
        // Delete / Backspace closes the selected session.
        if event.keyCode == 51 || event.keyCode == 117 {
            onDeleteKey?()
            return
        }
        if (event.keyCode == 123 || event.keyCode == 124), event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           onArrow?(event.keyCode == 124) == true { return }
        // Return renames (Finder's convention).
        if event.keyCode == 36, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            onReturnKey?()
            return
        }
        super.keyDown(with: event)
    }
}

/// The workspace sidebar: a flat, chronologically-ordered list of sessions
/// (most recently active first) — every agent kind sits together as a peer,
/// with no folder grouping. A folder is still each session's working
/// directory (shown as a subtitle segment when it isn't the root), managed
/// from the "Folders" inspector pane rather than as sidebar rows.
/// Mutations route through `WorkspaceController`; the view reloads on changes.
@MainActor
final class SidebarListController: NSViewController {
    private let controller: WorkspaceController
    private let outline = SidebarTableView()
    private var cancellables: Set<AnyCancellable> = []
    private var reloading = false
    private var settingSelection = false

    /// Sessions in display order, after the search filter. Table rows map
    /// through `rows`, which also holds each open session's subagent and
    /// workflow rows, so an index here is not a row index: use `row(of:)` /
    /// `sessionID(atRow:)`.
    private(set) var displayedSessionIDs: [UUID] = []
    /// The displayed forks listed under their group's top session (shown
    /// too): they're the indented rows (`SessionOrder`).
    private(set) var nestedForkIDs: Set<UUID> = []

    /// What each row shows: a session, or one of its subagents beneath it.
    enum Row: Equatable, Identifiable {
        case session(UUID), subagent(SubagentInfo), workflow(UUID, WorkflowRun)

        /// Which row it is, whatever it shows now (a subagent's state, a run's progress).
        enum ID: Hashable { case session(UUID), subagent(UUID, String), workflow(UUID, String) }
        var id: ID {
            switch self {
            case .session(let id): .session(id)
            case .subagent(let info): .subagent(info.sessionID, info.id)
            case .workflow(let session, let run): .workflow(session, run.id)
            }
        }
        /// The session it is, or sits under.
        var sessionID: UUID {
            switch self {
            case .session(let id): id
            case .subagent(let info): info.sessionID
            case .workflow(let session, _): session
            }
        }
    }
    private(set) var rows: [Row] = []
    /// Subagent lists opened / closed by the person (else: open while one runs,
    /// or for the selected session).
    private var openedParents: Set<UUID> = []
    private var closedParents: Set<UUID> = []

    func sessionID(atRow row: Int) -> UUID? {
        guard rows.indices.contains(row), case .session(let id) = rows[row] else { return nil }
        return id
    }
    func subagent(atRow row: Int) -> SubagentInfo? {
        guard rows.indices.contains(row), case .subagent(let info) = rows[row] else { return nil }
        return info
    }
    func workflow(atRow row: Int) -> (session: UUID, run: WorkflowRun)? {
        guard rows.indices.contains(row), case .workflow(let session, let run) = rows[row] else { return nil }
        return (session, run)
    }
    /// The session a child row (subagent or workflow) sits under; nil for a session row.
    func parentSession(ofRow row: Int) -> UUID? { subagent(atRow: row)?.sessionID ?? workflow(atRow: row)?.session }

    private func openWorkflow(_ run: WorkflowRun, in session: UUID) {
        controller.selection = .session(session)
        let taskID = controller.backgroundTasks[session]?.first { $0.runID == run.id }?.id
        let stop: (() async -> Bool)? = taskID.map { tid in { [weak self] in await self?.onStopTask?(session, tid) ?? false } }
        WorkflowWindowController.show(run, sessionID: session, workspace: controller, stop: stop)
    }
    /// Stops a session's background task (the pane that runs its chat does it).
    var onStopTask: ((UUID, String) async -> Bool)?
    func row(of id: UUID) -> Int? { rows.firstIndex(of: .session(id)) }

    /// Whether a session's subagent and workflow rows are in the list now.
    private func childRowsShown(of id: UUID) -> Bool {
        row(of: id).map { parentSession(ofRow: $0 + 1) == id } ?? false
    }
    /// A listed session whose child rows should show, or go, by now (they follow the selection).
    private func childRowsStale(_ id: UUID?) -> Bool {
        guard let id, row(of: id) != nil else { return false }
        return showsSubagents(of: id) != childRowsShown(of: id)
    }

    func showsSubagents(of id: UUID) -> Bool {
        let list = controller.subagents[id] ?? [], runs = controller.workflows[id] ?? []
        guard !list.isEmpty || !runs.isEmpty else { return false }
        if closedParents.contains(id) { return false }
        if openedParents.contains(id) { return true }
        return list.contains(where: \.isRunning) || runs.contains { !$0.agentsSettled } || controller.selection == .session(id)
    }

    /// A session's child rows: its subagents and workflows, oldest first.
    private func childRows(of id: UUID) -> [Row] {
        let subs = (controller.subagents[id] ?? []).map { (date: $0.startedAt, row: Row.subagent($0)) }
        let runs = (controller.workflows[id] ?? []).map { (date: $0.startedAt ?? .distantPast, row: Row.workflow(id, $0)) }
        return (subs + runs).sorted { $0.date < $1.date }.map(\.row)
    }
    private func childCount(of id: UUID) -> Int { (controller.subagents[id]?.count ?? 0) + (controller.workflows[id]?.count ?? 0) }

    func setShowsSubagents(_ show: Bool, of id: UUID) {
        if show { openedParents.insert(id); closedParents.remove(id) } else { closedParents.insert(id); openedParents.remove(id) }
        reload()
    }
    /// Live filter over `displayedSessionIDs` (session name / agent / folder).
    private var searchQuery: String = ""

    private let searchField = SidebarSearchField()
    private let newSessionButton = SidebarIconButton(
        symbolName: "plus", pointSize: 14, accessibilityDescription: "New Session")

    /// Overlay shown in place of the (empty) list: the container's build
    /// status while one is coming up, else "No sessions yet"/"No matches".
    /// Without this the list was just blank during a first-time build, which
    /// read as broken rather than in progress.
    private let emptyStateStack = NSStackView()
    private let emptyStateSpinner = NSProgressIndicator.spinner()
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "")

    private let appMark = NSImageView()
    private let brandBox = NSView()
    private let titleLabel = NSTextField(labelWithString: "Sandshell")
    private let headerChevron = NSImageView()
    private let rightBorder = NSView()
    private let footer = NSView()
    private let footerBorder = NSView()
    private let searchButton = HoverButton()
    private let settingsButton = SidebarIconButton(
        symbolName: "gearshape",
        pointSize: 13,
        accessibilityDescription: "Folder settings")
    private let terminalButton = SidebarIconButton(
        symbolName: "terminal",
        pointSize: 13,
        accessibilityDescription: "Open a terminal to the Mac host")
    private let consoleButton = SidebarIconButton(
        symbolName: "ladybug",
        pointSize: 13,
        accessibilityDescription: "Open the Sandshell log in Console")
    /// A host (Mac) shell terminal window, kept open across re-clicks.
    private var hostTerminal: HostTerminalWindowController?
    /// Terminal opened to the most-recent changed-drops staging directory.
    private var dropsTerminal: HostTerminalWindowController?

    /// Open another workspace folder in its own window (Obsidian-vault style).
    /// Set by `MainWindowController`; routed to `AppDelegate.openWorkspace`.
    var onOpenWorkspace: ((URL) -> Void)?
    /// Files dropped on a session row (the window routes them to that session).
    var onDropFiles: ((UUID, [URL]) -> Void)?
    /// "Open Files in Split" from a session row's context menu.
    var onOpenFilesInSplit: ((UUID) -> Void)?
    /// Open the window's Search (footer button / "Search…" menu item); the
    /// folder is where a restored conversation lands if its cwd has none.
    var onShowSearch: ((UUID?) -> Void)?

    /// True while a container is building/rebuilding (drives the empty-state
    /// placeholder — session creation itself is never gated on this).
    var isBuilding: Bool { controller.isBuilding }
    private var theme: ThemeColors { controller.theme.colors }
    /// The sidebar is themed independently (it can be forced dark).
    /// The sidebar palette is driven by this folder's chosen background + color
    /// (independent of the detail theme): text adapts to the bg's luminance, and
    /// the brand color tints the selection.
    private var sidebarTheme: ThemeColors { sidebarTheme(for: controller.rootProfile) }

    private func sidebarTheme(for p: RootProfile) -> ThemeColors {
        let dark = NSColor.hex(p.sidebarHex).perceivedIsDark
        var c = ThemeColors.base(dark: dark)
        c.sidebar = .hex(p.sidebarHex)
        c.accent = .hex(p.colorHex)
        // Derive muted text from the foreground as a translucent tint rather than a
        // fixed slate-gray — a flat gray reads as washed-out over a vivid sidebar,
        // while a faded foreground lets the background color show through.
        c.sidebarMuted = c.sidebarFg.withAlphaComponent(0.6)
        return c
    }

    init(controller: WorkspaceController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: View

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true   // explicit sidebar background (see applyTheme)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.headerView = nil
        outline.style = .sourceList
        outline.selectionHighlightStyle = .none
        outline.backgroundColor = .clear   // let the explicit container color show
        outline.rowSizeStyle = .default
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = true
        outline.setAccessibilityLabel("Sessions")
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        // Sessions drag onto the detail area's panes (split or replace there).
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.menuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
        outline.onDeleteKey = { [weak self] in self?.closeSelectedSession() }
        outline.onReturnKey = { [weak self] in
            guard let self else { return }
            if let info = self.subagent(atRow: self.outline.selectedRow) {
                return SubagentWindowController.show(info, workspace: self.controller)
            }
            if let wf = self.workflow(atRow: self.outline.selectedRow) { return self.openWorkflow(wf.run, in: wf.session) }
            self.beginRenameSelected()
        }
        outline.onArrow = { [weak self] right in
            guard let self else { return false }
            let row = self.outline.selectedRow
            if let id = self.sessionID(atRow: row), self.childCount(of: id) > 0 {
                guard self.childRowsShown(of: id) != right else { return false }
                self.setShowsSubagents(right, of: id)
                return true
            }
            // ← on a subagent: up to its session.
            if !right, let session = self.parentSession(ofRow: row), let parent = self.row(of: session) {
                self.outline.selectRowIndexes([parent], byExtendingSelection: false)
                return true
            }
            return false
        }
        // Reduce Motion / Increase Contrast changed: redraw the rows. (NSWorkspace
        // posts it on its own center, not the default one.)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
        scroll.documentView = outline

        // ── Header: the folder's chosen icon/color + its name (last path
        //    component), on its own line below the window's traffic lights.
        brandBox.translatesAutoresizingMaskIntoConstraints = false
        brandBox.wantsLayer = true
        brandBox.layer?.cornerRadius = 7
        appMark.translatesAutoresizingMaskIntoConstraints = false
        appMark.image?.isTemplate = true
        appMark.contentTintColor = .white
        appMark.imageScaling = .scaleProportionallyUpOrDown
        appMark.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        brandBox.addSubview(appMark)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 19, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        updateHeaderIdentity()   // icon/color/title from the folder profile

        // Disclosure affordance: clicking the header pops a menu to switch or
        // duplicate the workspace.
        headerChevron.translatesAutoresizingMaskIntoConstraints = false
        headerChevron.image = NSImage(systemSymbolName: "chevron.down",
                                      accessibilityDescription: "Workspace")
        headerChevron.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        headerChevron.setContentHuggingPriority(.required, for: .horizontal)

        let header = SidebarHeaderView(views: [brandBox, titleLabel, headerChevron])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.onClick = { [weak self] in self?.headerClicked() }

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.onChange = { [weak self] text in
            self?.searchQuery = text
            self?.reload()
        }
        searchField.onMoveDown = { [weak self] in
            guard let self, !self.displayedSessionIDs.isEmpty else { return }
            self.view.window?.makeFirstResponder(self.outline)
            if self.outline.selectedRow < 0 { self.controller.selection = .session(self.displayedSessionIDs[0]) }
        }
        newSessionButton.translatesAutoresizingMaskIntoConstraints = false
        newSessionButton.target = self
        newSessionButton.action = #selector(newSessionButtonClicked)

        searchButton.title = "Search"
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchButton.isBordered = false
        searchButton.wantsLayer = true
        searchButton.layer?.cornerRadius = 9
        searchButton.layer?.masksToBounds = true
        searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchButton.imagePosition = .imageLeading
        searchButton.imageHugsTitle = true        // keep icon + text together, centered
        searchButton.alignment = .center
        searchButton.font = .systemFont(ofSize: 12, weight: .regular)
        searchButton.target = self
        searchButton.action = #selector(searchClicked)
        searchButton.toolTip = "Search sessions and past conversations (⇧⌘F)"

        // Per-root settings inspector lives behind a square gear next to Search.
        // This custom control avoids NSButtonCell's image-only metrics so the
        // visible background and centered glyph stay optically square.
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        settingsButton.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        settingsButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        settingsButton.setContentHuggingPriority(.defaultLow, for: .vertical)
        settingsButton.target = self
        settingsButton.action = #selector(presentInspector as () -> Void)

        terminalButton.translatesAutoresizingMaskIntoConstraints = false
        terminalButton.target = self
        terminalButton.action = #selector(openHostTerminal)

        consoleButton.translatesAutoresizingMaskIntoConstraints = false
        consoleButton.target = self
        consoleButton.action = #selector(openConsole)

        rightBorder.translatesAutoresizingMaskIntoConstraints = false
        rightBorder.wantsLayer = true
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.wantsLayer = true
        footerBorder.translatesAutoresizingMaskIntoConstraints = false
        footerBorder.wantsLayer = true

        emptyStateLabel.alignment = .center
        emptyStateLabel.font = .systemFont(ofSize: 12)
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateStack.orientation = .vertical
        emptyStateStack.alignment = .centerX
        emptyStateStack.spacing = 8
        emptyStateStack.translatesAutoresizingMaskIntoConstraints = false
        emptyStateStack.isHidden = true
        emptyStateStack.setAccessibilityIdentifier("sidebar-empty-state")
        emptyStateLabel.setAccessibilityIdentifier("sidebar-empty-state-label")
        emptyStateStack.addArrangedSubview(emptyStateSpinner)
        emptyStateStack.addArrangedSubview(emptyStateLabel)

        container.addSubview(header)
        container.addSubview(searchField)
        container.addSubview(newSessionButton)
        container.addSubview(scroll)
        container.addSubview(emptyStateStack)
        container.addSubview(footer)
        container.addSubview(rightBorder)
        footer.addSubview(footerBorder)
        footer.addSubview(settingsButton)
        footer.addSubview(terminalButton)
        footer.addSubview(consoleButton)
        footer.addSubview(searchButton)
        NSLayoutConstraint.activate([
            brandBox.widthAnchor.constraint(equalToConstant: 28),
            brandBox.heightAnchor.constraint(equalToConstant: 28),
            appMark.leadingAnchor.constraint(equalTo: brandBox.leadingAnchor, constant: 6),
            appMark.trailingAnchor.constraint(equalTo: brandBox.trailingAnchor, constant: -6),
            appMark.topAnchor.constraint(equalTo: brandBox.topAnchor, constant: 6),
            appMark.bottomAnchor.constraint(equalTo: brandBox.bottomAnchor, constant: -6),

            // Sits on its own line below the window's traffic-light controls.
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            // Search field + persistent "New Session" button, replacing the old
            // per-folder trailing row now that there are no folder rows.
            searchField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: newSessionButton.leadingAnchor, constant: -8),
            newSessionButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            newSessionButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            newSessionButton.widthAnchor.constraint(equalToConstant: 32),
            newSessionButton.heightAnchor.constraint(equalToConstant: 32),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            emptyStateStack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyStateStack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -20),
            emptyStateStack.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 20),
            emptyStateStack.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -20),
            emptyStateLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 170),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 54),
            footerBorder.topAnchor.constraint(equalTo: footer.topAnchor),
            footerBorder.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerBorder.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerBorder.heightAnchor.constraint(equalToConstant: 1),
            // Footer: a square gear (per-root settings) + a Search button that
            // fills the remaining width to the right edge. Both 34pt tall,
            // vertically centered in the footer.
            settingsButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            settingsButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 34),
            settingsButton.heightAnchor.constraint(equalToConstant: 34),
            terminalButton.leadingAnchor.constraint(equalTo: settingsButton.trailingAnchor, constant: 8),
            terminalButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
            terminalButton.widthAnchor.constraint(equalToConstant: 34),
            terminalButton.heightAnchor.constraint(equalToConstant: 34),
            consoleButton.leadingAnchor.constraint(equalTo: terminalButton.trailingAnchor, constant: 8),
            consoleButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
            consoleButton.widthAnchor.constraint(equalToConstant: 34),
            consoleButton.heightAnchor.constraint(equalToConstant: 34),
            searchButton.leadingAnchor.constraint(equalTo: consoleButton.trailingAnchor, constant: 8),
            searchButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            searchButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
            searchButton.heightAnchor.constraint(equalToConstant: 34),

            rightBorder.topAnchor.constraint(equalTo: container.topAnchor),
            rightBorder.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rightBorder.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rightBorder.widthAnchor.constraint(equalToConstant: 1),
        ])
        self.view = container
    }

    /// Refresh the header mark + title from this folder's profile.
    private func updateHeaderIdentity(_ profile: RootProfile? = nil) {
        let p = profile ?? controller.rootProfile
        titleLabel.stringValue = controller.workspace.rootURL.lastPathComponent
        brandBox.layer?.backgroundColor = NSColor.hex(p.colorHex).cgColor
        let img = NSImage(systemSymbolName: p.icon, accessibilityDescription: nil)
        img?.isTemplate = true
        appMark.image = img
        appMark.contentTintColor = .white
    }

    private func applyTheme(_ c: ThemeColors) {
        // Force the sidebar's own appearance so its native source-list material,
        // text and selection render in the chosen scheme regardless of the app's
        // overall mode (enables "Sidebar always dark"), then paint the explicit
        // background and brand mark on top.
        view.appearance = NSAppearance(named: c.isDark ? .darkAqua : .aqua)
        view.layer?.backgroundColor = c.sidebar.cgColor
        rightBorder.layer?.backgroundColor = c.border.cgColor
        footer.layer?.backgroundColor = c.sidebar.cgColor
        footerBorder.layer?.backgroundColor = c.border.cgColor
        titleLabel.textColor = c.sidebarFg
        headerChevron.contentTintColor = c.sidebarMuted
        searchField.style(bg: c.sidebarHover, fg: c.sidebarFg, muted: c.sidebarMuted)
        emptyStateLabel.textColor = c.sidebarMuted

        // Footer buttons + the new-session button: a subtle resting fill that
        // brightens on hover.
        let resting = c.sidebarHover
        let hover = c.sidebarFg.withAlphaComponent(c.isDark ? 0.16 : 0.10)
        for b in [settingsButton, terminalButton, consoleButton, newSessionButton] {
            b.contentTintColor = c.sidebarFg
            b.restingBackgroundColor = resting
            b.hoverBackgroundColor = hover
        }
        searchButton.contentTintColor = c.sidebarFg
        searchButton.restingBackgroundColor = resting
        searchButton.hoverBackgroundColor = hover
        // Leading space widens the gap between the magnifying-glass icon and the label.
        searchButton.attributedTitle = NSAttributedString(
            string: "  Search",
            attributes: [
                .foregroundColor: c.sidebarFg,
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyTheme(sidebarTheme)
        // The sidebar is driven by the folder's profile (icon/color/background);
        // re-theme + re-render the header when it's edited in General.
        // A pane's "Edit Kits…" / "Edit Mounts…" opens this workspace's settings there.
        NotificationCenter.default.publisher(for: InspectorView.openRequest)
            .sink { [weak self] note in
                guard let self, note.object as? WorkspaceController === self.controller,
                      let raw = note.userInfo?["pane"] as? String, let pane = InspectorPane(rawValue: raw) else { return }
                self.presentInspector(pane: pane)
            }
            .store(in: &cancellables)
        controller.$rootProfile.dropFirst().sink { [weak self] profile in
            guard let self else { return }
            self.updateHeaderIdentity(profile)
            self.applyTheme(self.sidebarTheme(for: profile))
            self.reload()
        }.store(in: &cancellables)
        reload()
        // Reload only on structural changes (revision), not on selection/busy —
        // otherwise selecting a row or opening an inline editor would tear the
        // outline down. `dropFirst` skips the value emitted on subscribe.
        controller.$revision.dropFirst().sink { [weak self] _ in
            self?.reload()
        }.store(in: &cancellables)
        // Reflect programmatic selection changes (e.g. ⌘⇧[/] cycling) in the
        // outline highlight without reloading.
        controller.$selection.sink { [weak self] sel in
            guard let self else { return }
            let previous = self.lastActiveSession
            self.lastActiveSession = if case let .session(id) = sel { id } else { nil }
            self.syncSelection(sel)
            // Bold the newly-active session immediately (and un-bold the previous
            // unless it's still live) — no wait for the terminal to launch.
            self.refreshActive(previous)
            self.refreshActive(self.lastActiveSession)
            // Subagents show for the selected session: list (or unlist) them —
            // once the click (or key) that changed it is handled, and once for
            // the selectionDidChange + rowClicked pair. Rows above it may go,
            // so bring it back into view.
            if [previous, self.lastActiveSession].contains(where: { self.childRowsStale($0) }) {
                self.reloadAfterEvent(revealingShown: true)
            }
        }.store(in: &cancellables)
        // Update only the affected session rows (status dot + work-time + live-ness
        // + unread) — all session state is now in one `runtimes` publisher. A
        // working↔ready transition (session started/finished work) is the one
        // case that re-sorts the list; every other tick updates rows in place so
        // nothing jumps around while it's just ticking a timer or clearing a dot.
        // Rows say how many background tasks their session has running.
        controller.$backgroundTasks.dropFirst().sink { [weak self] tasks in
            guard let self else { return }
            for id in Set(tasks.keys).union(self.backgroundCounts.keys) { self.updateSessionRow(id) }
            self.backgroundCounts = tasks.mapValues { $0.count(where: \.isRunning) }
        }.store(in: &cancellables)
        // Only when a row would change: a running subagent's or workflow's
        // transcripts are written all the time, and every poll would rebuild
        // the list. (One reload for a poll that changes both.)
        controller.$subagents.dropFirst().map { $0.mapValues { $0.map(\.asShown) } }.removeDuplicates().sink { [weak self] _ in
            self?.reloadAfterEvent()
        }.store(in: &cancellables)
        controller.$workflows.dropFirst().map { $0.mapValues { $0.map(\.asShown) } }.removeDuplicates().sink { [weak self] _ in
            self?.reloadAfterEvent()
        }.store(in: &cancellables)
        controller.$runtimes.dropFirst().sink { [weak self] runtimes in
            self?.runtimesChanged(runtimes)
        }.store(in: &cancellables)
        // Tick the work timer label on working rows via the workspace clock.
        controller.clockTick.dropFirst()
            .sink { [weak self] _ in self?.tickWorkingTimers() }
            .store(in: &cancellables)
        // Tick the relative "Xm ago" labels on idle rows. Cheap and low-frequency.
        Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshRelativeTimes() }
            .store(in: &cancellables)
        // The build-status placeholder tracks activity text directly — it must
        // update the moment a build starts/finishes, not wait for a `revision`
        // bump (creating the first session's container doesn't touch folders/
        // sessions at all, so revision never fires for it).
        controller.$activity.dropFirst().sink { [weak self] _ in
            self?.updateEmptyState()
        }.store(in: &cancellables)
    }

    /// Shown in place of the (empty) session list: the container's build
    /// status while one is coming up, else a "no sessions"/"no matches" hint.
    /// The empty-state placeholder's text while it's showing (scripting status).
    var emptyStateText: String? { emptyStateStack.isHidden ? nil : emptyStateLabel.stringValue }

    private func updateEmptyState() {
        // Only ever in place of an empty list: with rows showing, the build
        // status belongs to the pane (it says "Building …" there), and the
        // placeholder would sit on top of the rows.
        if !displayedSessionIDs.isEmpty {
            emptyStateSpinner.stopAnimation(nil)
            emptyStateStack.isHidden = true
        } else if controller.isBuilding, let activity = controller.activity {
            emptyStateSpinner.isHidden = false
            emptyStateSpinner.startAnimation(nil)
            emptyStateLabel.stringValue = activity
            emptyStateStack.isHidden = false
        } else {
            emptyStateSpinner.stopAnimation(nil)
            emptyStateSpinner.isHidden = true
            emptyStateLabel.stringValue = searchQuery.isEmpty ? "No sessions yet" : "No matches"
            emptyStateStack.isHidden = false
        }
    }

    private func tickWorkingTimers() {
        guard !reloading else { return }
        for id in displayedSessionIDs where controller.runtime(id)?.status == .working {
            updateSessionRow(id)
        }
    }

    private func refreshRelativeTimes() {
        guard !reloading else { return }
        for id in displayedSessionIDs where controller.lastActivity(id) != nil {
            updateSessionRow(id)
        }
        // Finished subagents and workflows say when they finished.
        let finished = (Range(outline.rows(in: outline.visibleRect)) ?? 0..<0).filter {
            subagent(atRow: $0).map { !$0.isRunning } ?? (workflow(atRow: $0) != nil)
        }
        if !finished.isEmpty { outline.reloadData(forRowIndexes: IndexSet(finished), columnIndexes: [0]) }
    }

    private var lastRuntimes: [UUID: SessionRuntime] = [:]

    private func runtimesChanged(_ new: [UUID: SessionRuntime]) {
        var needsReorder = false
        for id in Set(new.keys).union(lastRuntimes.keys) where new[id] != lastRuntimes[id] {
            if new[id]?.isLive != lastRuntimes[id]?.isLive {
                // isLive drives name weight — needs a full cell reconfigure
                // (once a rename in it ends: that would throw its editor away).
                if id == renamingID {
                    pendingReload = true
                    updateSessionRow(id)
                } else if !reloading, let row = row(of: id) {
                    outline.reloadData(forRowIndexes: IndexSet([row]), columnIndexes: IndexSet([0]))
                }
            } else {
                updateSessionRow(id)
            }
            // A working↔ready transition is a structural event: resort so the
            // list reflects recency. Every other field (timer, lastActivityAt
            // while still working, etc.) updates the row in place, above.
            if new[id]?.status != lastRuntimes[id]?.status { needsReorder = true }
        }
        lastRuntimes = new
        if needsReorder { reload() }
    }

    private var lastActiveSession: UUID?

    /// A session is emphasized when it's selected (active) or has a live terminal.
    private func isActive(_ id: UUID) -> Bool {
        controller.runtime(id)?.isLive == true || controller.selection == .session(id)
    }

    /// Update a session row's emphasis in place (no rebuild).
    private func refreshActive(_ id: UUID?) {
        guard let id, let row = row(of: id),
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionCellView
        else { return }
        cell.setActive(isActive(id))
    }

    /// Update a session row's runtime bits *in place* (no cell rebuild), so the
    /// working sweep animates continuously instead of restarting each poll.
    private var backgroundCounts: [UUID: Int] = [:]

    private func updateSessionRow(_ id: UUID) {
        guard !reloading, let row = row(of: id),
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionCellView
        else { return }   // off-screen rows reconfigure fresh when they reappear
        cell.backgroundRunning = controller.runningBackgroundTasks(id)
        cell.updateRuntime(controller.runtime(id), unread: controller.runtime(id)?.isUnread ?? false)
    }

    /// The folder-name segment for a session's subtitle (nil for the root
    /// folder, which needs no extra label since it's the common case).
    private func workdirName(for session: Session) -> String? {
        guard let folder = controller.folder(id: session.folderID), !folder.isRoot else { return nil }
        return (folder.relativePath as NSString).lastPathComponent
    }

    /// Whether `session` matches the live search filter (name / agent / folder).
    private func matchesSearch(_ session: Session) -> Bool {
        Self.matches(searchQuery, in: [controller.displayName(of: session), session.agent.displayName, workdirName(for: session)])
    }

    /// Whether any of `fields` contains `query`, as Finder matches (ignoring
    /// case and accents: "cafe" finds "Café"). An empty query matches all.
    nonisolated static func matches(_ query: String, in fields: [String?]) -> Bool {
        query.isEmpty || fields.contains { $0?.localizedStandardContains(query) == true }
    }

    // MARK: Reload (preserving selection)

    /// A reload asked for while a row was being renamed (run when it ends).
    private var pendingReload = false
    /// A rename just ended: reloads wait for the rest of the event that ended it.
    private var endingRename = false
    /// A reload is on its way (`reloadAfterEvent`), and whether it then brings
    /// the shown session's row into view.
    private var reloadScheduled = false
    private var revealShownAfterReload = false

    /// Run `body` once the event being handled is over — a click's mouse-up
    /// included. (The main queue is also served in the table's tracking loop
    /// between mouse-down and -up, where the table still goes by the row index
    /// it pressed: a reload there moves another row under the click.)
    private static func afterEvent(_ body: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.default, .modalPanel]) { MainActor.assumeIsolated(body) }
    }

    /// Reload once the event being handled is over, however often it's asked
    /// for meanwhile.
    private func reloadAfterEvent(revealingShown: Bool = false) {
        if revealingShown { revealShownAfterReload = true }
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Self.afterEvent { [weak self] in
            guard let self else { return }
            let reveal = self.revealShownAfterReload
            self.revealShownAfterReload = false
            if self.reloadScheduled { self.reload() }
            if reveal, !self.pendingReload { self.revealShown() }
        }
    }

    /// Keep the shown session's row (or the picked row under it) in view: rows
    /// above it come and go with the selection.
    private func revealShown() {
        guard let id = shownSession else { return }
        let last = outline.selectedRow
        let target = rows.indices.contains(last) && rows[last].sessionID == id ? last : row(of: id)
        if let target { outline.scrollRowToVisible(target) }
    }

    private func reload() {
        guard !reloading else { return }
        reloadScheduled = false
        // Rebuilding the rows would throw the rename's editor away mid-typing
        // (and, as it ends, move rows under the click that ended it).
        if renamingID != nil || endingRename { pendingReload = true; return }
        pendingReload = false
        reloading = true
        defer { reloading = false }

        // What's picked, by identity: rows come, go and move with every reload.
        let picked = Set(outline.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        let order = controller.sessionOrder
        displayedSessionIDs = order.compactMap { controller.session(id: $0.id) }.filter(matchesSearch).map(\.id)
        let displayed = Set(displayedSessionIDs)
        nestedForkIDs = Set(order.filter { $0.nestedUnder.map(displayed.contains) == true && displayed.contains($0.id) }.map(\.id))
        rows = displayedSessionIDs.flatMap { id -> [Row] in
            [.session(id)] + (showsSubagents(of: id) ? childRows(of: id) : [])
        }
        outline.reloadData()
        applySelectionToOutline(keeping: picked)
        updateEmptyState()
    }

    /// The session the detail shows (the controller's selection).
    private var shownSession: UUID? {
        if case let .session(id) = controller.selection { return id }
        return nil
    }

    private func applySelectionToOutline(keeping picked: Set<Row.ID> = []) {
        let select = Self.rowsToSelect(keeping: picked, shown: shownSession, in: rows)
        if select.isEmpty { outline.deselectAll(nil) } else { outline.selectRowIndexes(select, byExtendingSelection: false) }
    }

    /// The rows to pick after a reload: those picked before, wherever they are
    /// now — when the shown session (or a row under it) is still among them —
    /// else the shown session's row.
    nonisolated static func rowsToSelect(keeping picked: Set<Row.ID>, shown: UUID?, in rows: [Row]) -> IndexSet {
        guard let shown else { return [] }
        let kept = IndexSet(rows.indices.filter { picked.contains(rows[$0].id) })
        if kept.contains(where: { rows[$0].sessionID == shown }) { return kept }
        return rows.firstIndex(of: .session(shown)).map { IndexSet(integer: $0) } ?? []
    }

    /// Move the outline highlight to match `sel` (programmatic selection), with
    /// a guard so the resulting `selectionDidChange` doesn't write back.
    private func syncSelection(_ sel: SidebarSelection?) {
        guard !reloading else { return }
        var targetRow = -1
        if case let .session(id) = sel, let row = row(of: id) {
            targetRow = row
            updateSessionRow(id)   // selecting a session marks it seen — clear the dot
            // One of its subagents is the picked row: leave it.
            if parentSession(ofRow: outline.selectedRow) == id { return }
        }
        guard targetRow != outline.selectedRow else { return }
        // Part of a multi-selection the person made: keep it.
        if targetRow >= 0, outline.selectedRowIndexes.count > 1, outline.selectedRowIndexes.contains(targetRow) { return }
        let previousRow = outline.selectedRow
        settingSelection = true
        defer { settingSelection = false }
        if targetRow >= 0 {
            outline.selectRowIndexes([targetRow], byExtendingSelection: false)
            outline.scrollRowToVisible(targetRow)
        } else {
            outline.deselectAll(nil)
        }
        // selectionHighlightStyle = .none means AppKit won't automatically
        // redraw row views on programmatic selection changes — force it.
        if previousRow >= 0 { outline.rowView(atRow: previousRow, makeIfNecessary: false)?.needsDisplay = true }
        if targetRow >= 0 { outline.rowView(atRow: targetRow, makeIfNecessary: false)?.needsDisplay = true }
    }

    // MARK: Actions

    /// Single click: (re)publish the selection — even if unchanged — so the
    /// detail pane re-launches a session whose terminal hasn't started yet
    /// (re-clicking an already-selected row doesn't fire selectionDidChange).
    /// A ⌘- or ⇧-click only changes what's picked (selectionDidChange did that):
    /// republishing its row would undo a ⌘-click that unpicked it.
    @objc private func rowClicked() {
        let row = outline.clickedRow
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        guard modifiers.isDisjoint(with: [.command, .shift]), outline.selectedRowIndexes.contains(row) else { return }
        if let info = subagent(atRow: row) {
            controller.selection = .session(info.sessionID)
            return SubagentWindowController.show(info, workspace: controller)
        }
        if let wf = workflow(atRow: row) { return openWorkflow(wf.run, in: wf.session) }
        guard let id = sessionID(atRow: row) else { return }
        controller.selection = .session(id)
    }

    /// Create a blank folder (its look/rename lives in the Folders inspector
    /// pane now — there's no sidebar row to rename inline).
    @objc private func newFolderClicked() {
        controller.addFolder(name: "New Folder")
    }

    /// "Add Folder…" / "Choose Existing Folder…" — register an existing
    /// (possibly nested) subfolder via a picker.
    @objc private func addExistingFolderClicked() {
        controller.chooseExistingFolder()
    }

    private struct NewSessionRequest {
        let folderID: UUID
        let agent: AgentKind
        /// When set (and different from `agent`), attach to that agent's sandbox
        /// — e.g. a shell opened inside the claude/codex container.
        var containerAgent: AgentKind? = nil
        /// Native chat (ACP) instead of a terminal.
        var chat = false
    }

    @objc private func addSessionFromMenu(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? NewSessionRequest else { return }
        addSession(folderID: req.folderID, agent: req.agent, containerAgent: req.containerAgent, chat: req.chat)
    }

    /// Header click: Option-click duplicates this window; a plain click pops the
    /// workspace-folder switcher menu.
    private func headerClicked() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            (NSApp.delegate as? AppDelegate)?.duplicateWindow(nil)
        } else {
            presentWorkspaceMenu()
        }
    }

    /// Pop a menu of other workspace folders (recent roots) below the header
    /// mark — picking one opens it in its own window (Obsidian-vault style).
    private func presentWorkspaceMenu() {
        let menu = NSMenu()
        let current = controller.workspace.rootURL.standardizedFileURL.path

        // The current folder first, checked, as a header for context.
        let here = NSMenuItem(controller.workspace.rootURL.lastPathComponent, image: controller.rootProfile.menuImage())
        here.state = .on
        here.isEnabled = false
        menu.addItem(here)

        // Most recently opened folders (all of them live in the Open Workspace
        // browser, reachable via "See More…").
        let others = RootFolderStore.byRecency().filter { $0.path != current }
        if !others.isEmpty {
            menu.addItem(.separator())
            for profile in others.prefix(RecentRootsMenu.shortListCount) {
                menu.addItem(profile.menuItem(action: #selector(openRecentRoot(_:)), target: self))
            }
            menu.addItem(NSMenuItem(others.count > RecentRootsMenu.shortListCount
                                        ? "See More… (\(others.count))" : "See More…",
                                    action: #selector(seeMoreFromMenu), target: self, symbol: "ellipsis.circle", key: "o"))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem("Duplicate Window", action: #selector(duplicateWindowFromMenu), target: self,
                                symbol: "plus.square.on.square", key: "n", modifiers: [.command, .shift]))
        menu.addItem(NSMenuItem("Open Folder…", action: #selector(openFolderFromMenu), target: self,
                                symbol: "plus", key: "n", modifiers: [.command, .option]))

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 36), in: appMark)
    }

    @objc private func openRecentRoot(_ sender: NSMenuItem) {
        guard let root = sender.representedObject as? URL else { return }
        (NSApp.delegate as? AppDelegate)?.openWorkspace(root)
    }

    @objc private func openFolderFromMenu() {
        (NSApp.delegate as? AppDelegate)?.openFolder(nil)
    }

    @objc private func seeMoreFromMenu() {
        (NSApp.delegate as? AppDelegate)?.openWorkspaceBrowser(nil)
    }

    @objc private func duplicateWindowFromMenu() {
        (NSApp.delegate as? AppDelegate)?.duplicateWindow(nil)
    }

    /// Open (or focus) a terminal to the Mac host, rooted at the workspace
    /// folder. Kept open across re-clicks — one window per workspace.
    @objc func openHostTerminal() {
        if let existing = hostTerminal, existing.window != nil {
            existing.focus()
            return
        }
        let host = HostTerminalWindowController(root: controller.workspace.rootURL, theme: controller.theme)
        host.onClose = { [weak self] in self?.hostTerminal = nil }
        hostTerminal = host
        host.focus()
    }

    /// Open the Sandshell log in Console.app (normal click), the sbx daemon log
    /// in Console.app (⌃ click), or the live status debug window (⌥ click).
    @objc func openConsole() {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.option) { openStatusDebugWindow(); return }
        if flags.contains(.control) { openDaemonLog(); return }
        openSandshellLog()
    }

    func openSandshellLog() { openInConsole(Log.fileURL) }

    func openDaemonLog() {
        let logURL = URL.homeDirectory.appending(
            path: "Library/Application Support/com.docker.sandboxes/sandboxes/sandboxd/daemon.log")
        openInConsole(logURL)
    }

    private func openInConsole(_ logURL: URL) {
        let consoleURL = URL(filePath: "/System/Applications/Utilities/Console.app", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: consoleURL.path(percentEncoded: false)) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            Task {
                do { _ = try await NSWorkspace.shared.open([logURL], withApplicationAt: consoleURL, configuration: cfg) }
                catch {
                    Log.error(.app, "open Console failed: \(error.localizedDescription)")
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                }
            }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        }
    }

    private var statusDebugWindow: StatusDebugWindowController?

    func openStatusDebugWindow() {
        if statusDebugWindow == nil {
            statusDebugWindow = StatusDebugWindowController(controller: controller)
        }
        statusDebugWindow?.show()
    }

    /// The workspace window closed: its status window goes with it (it holds
    /// the workspace, whose `sbx` polling would otherwise outlive the window).
    func closeAuxiliaryWindows() {
        statusDebugWindow?.close()
        statusDebugWindow = nil
    }

    /// Present the per-root settings inspector (gear next to Search, and ⌘,) as a
    /// native macOS sheet — a fixed-size SwiftUI view; Close or Esc dismisses it.
    /// No-op if a sheet is already up (so ⌘, doesn't stack inspectors).
    @objc func presentInspector() { presentInspector(pane: nil) }

    func presentInspector(pane: InspectorPane?) {
        SettingsWindowController.show(for: controller, pane: pane, owner: view.window)
    }

    // MARK: New Session menu

    /// The folder a new session should default into: the current selection's
    /// folder, else the workspace root.
    private func currentContextFolderID() -> UUID? {
        if case let .session(id) = controller.selection, let s = controller.session(id: id) { return s.folderID }
        return controller.rootFolder?.id ?? controller.folders.first?.id
    }

    @objc private func newSessionButtonClicked() {
        // No isBuilding gate: adding a Session record is app-level state,
        // independent of whether the container has finished coming up (⌘N/
        // newSessionInCurrentContext() already does this safely) — the button
        // used to disable itself during a build and silently swallow clicks,
        // which read as "the button doesn't work."
        newSessionMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: newSessionButton.bounds.height + 4),
                               in: newSessionButton)
    }

    /// The "+ New Session" menu, also popped by an empty pane's New Session.
    func newSessionMenu() -> NSMenu {
        let menu = NSMenu()
        for item in newSessionMenuItems() { menu.addItem(item) }
        return menu
    }

    /// Shared "+ New Session" menu content. The top items are actions —
    /// New Claude / New Codex / New Shell in the current context's folder,
    /// plus shells joining an agent's sandbox — then "In Folder ▸" for picking
    /// (or adding) another working directory, then Search.
    private func newSessionMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let defaultFolder = currentContextFolderID()
        if let defaultFolder {
            // Say where "New …" lands only when there's a choice of folders.
            if controller.folders.count > 1, let folder = controller.folders.first(where: { $0.id == defaultFolder }) {
                items.append(.sectionHeader(title: "In \(controller.displayName(for: folder))"))
            }
            items.append(contentsOf: newSessionActions(folderID: defaultFolder))
            items.append(.separator())
        }
        items.append(NSMenuItem("In Folder", symbol: "folder", submenu: folderSubmenuItems()))
        items.append(.separator())
        items.append(NSMenuItem("Search Sessions…", action: #selector(showSearchFromMenu(_:)), target: self,
                                symbol: "magnifyingglass", object: defaultFolder))
        return items
    }

    /// New chats, "New <Agent>" for the builtins + custom agents, and shells attached to an
    /// agent's sandbox — all in `folderID`.
    private func newSessionActions(folderID: UUID) -> [NSMenuItem] {
        func action(_ title: String, _ icon: NSImage?, _ req: NewSessionRequest) -> NSMenuItem {
            NSMenuItem(title, action: #selector(addSessionFromMenu(_:)), target: self, image: icon, object: req)
        }
        var items: [NSMenuItem] = []
        let custom = controller.customAgents
        var featured: [AgentKind] = [.claude, .codex, .gemini, .shell]
        if !featured.contains(controller.primaryAgent), controller.primaryAgent.isBuiltin {
            featured.insert(controller.primaryAgent, at: 0)
        }
        // Agents that can chat start as a chat (the default); each runs in its
        // own sandbox. The pane's Chat/Terminal switch flips it later.
        for agent in featured + custom {
            items.append(action("New \(agent.displayName)", agent.menuIcon,
                                NewSessionRequest(folderID: folderID, agent: agent,
                                                  chat: SbxCommand.supportsACP(agent))))
        }
        items.append(NSMenuItem("In Terminal", symbol: "terminal", submenu: SbxCommand.acpAgents.map { agent in
            action("New \(agent.displayName) in Terminal", agent.menuIcon,
                   NewSessionRequest(folderID: folderID, agent: agent))
        }))
        let others = AgentKind.builtins.filter { !featured.contains($0) }
        if !others.isEmpty {
            items.append(NSMenuItem("Other Agents", symbol: "ellipsis.circle", submenu: others.map { agent in
                action("New \(agent.displayName)", agent.menuIcon, NewSessionRequest(folderID: folderID, agent: agent))
            }))
        }
        items.append(.separator())
        for host in [AgentKind.claude, .codex] + custom {
            items.append(action("Shell in \(host.displayName) Sandbox", host.menuIcon,
                                NewSessionRequest(folderID: folderID, agent: .shell, containerAgent: host)))
        }
        return items
    }

    #if DEBUG
    /// Self-test access: the "+ New Session" menu's titles, submenu items as
    /// "Parent ▸ Child".
    func newSessionMenuTitles() -> [String] {
        func titles(_ items: [NSMenuItem], prefix: String) -> [String] {
            items.flatMap { item -> [String] in
                guard !item.isSeparatorItem else { return [] }
                let own = prefix + item.title
                return [own] + titles(item.submenu?.items ?? [], prefix: own + " ▸ ")
            }
        }
        return titles(newSessionMenuItems(), prefix: "")
    }
    #endif

    /// "In Folder ▸": each known folder opens the same New … actions there,
    /// plus ways to add another folder.
    private func folderSubmenuItems() -> [NSMenuItem] {
        var items = controller.folders.map { folder in
            NSMenuItem(controller.displayName(for: folder), symbol: "folder",
                       submenu: newSessionActions(folderID: folder.id))
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(menuItem("Add Folder…", #selector(newFolderClicked)))
        items.append(menuItem("Choose Existing Folder…", #selector(addExistingFolderClicked)))
        return items
    }

    private func addSession(folderID: UUID, agent: AgentKind, containerAgent: AgentKind? = nil,
                            chat: Bool = false) {
        if let session = controller.addSession(folderID: folderID, agent: agent,
                                               containerAgent: containerAgent, chat: chat) {
            controller.selection = .session(session.id)
            applySelectionToOutline()
        }
    }

    /// Open the Search window (open sessions + restorable past conversations).
    @objc private func showSearchFromMenu(_ sender: NSMenuItem) {
        onShowSearch?(sender.representedObject as? UUID)
    }

    /// Search from the footer button (restores route purely by the conversation's cwd).
    @objc private func searchClicked() { onShowSearch?(nil) }

    /// Delete in the list closes the session rows picked there, and only those.
    /// Nothing picked (the filter hides the shown session) or only subagent
    /// or workflow rows: a beep — no session closes that the list doesn't
    /// show picked (⌘W closes the shown one).
    func closeSelectedSession() {
        let ids = selectedSessionIDs
        guard !ids.isEmpty else { return NSSound.beep() }
        controller.closeSessions(ids)
    }

    /// The selected sessions, in list order.
    var selectedSessionIDs: [UUID] {
        outline.selectedRowIndexes.compactMap { sessionID(atRow: $0) }
    }

    /// What a context menu at `row` acts on: the whole selection when the row
    /// is part of it, else just that row (Finder's rule).
    private func menuTargets(row: Int) -> [UUID] {
        guard let id = sessionID(atRow: row) else { return [] }
        return outline.selectedRowIndexes.contains(row) ? selectedSessionIDs : [id]
    }

    // MARK: Rename (Return, Session ▸ Rename…, the context menu)

    func beginRenameSelected() {
        guard case let .session(id) = controller.selection else { return }
        beginRename(id)
    }

    /// The row being renamed; reloads wait for it (see `reload`).
    private weak var renamingCell: SessionCellView?
    private var renamingID: UUID? { renamingCell.flatMap { $0.isRenaming ? $0.sessionID : nil } }

    func beginRename(_ id: UUID) {
        // Session ▸ Rename… with the sidebar hidden: show it, and edit once it's back.
        if let window = view.window?.windowController as? MainWindowController, window.isSidebarCollapsed {
            window.setSidebarCollapsed(false)
            return Self.afterEvent { [weak self] in self?.renameInRow(id) }
        }
        renameInRow(id)
    }

    private func renameInRow(_ id: UUID) {
        // The filter hides its row: clear it.
        if row(of: id) == nil, !searchQuery.isEmpty { searchField.clear() }
        guard let row = row(of: id) else { return }
        outline.scrollRowToVisible(row)
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionCellView else { return }
        let editing = cell.beginRenaming { [weak self] name in
            guard let self else { return }
            self.renamingCell = nil
            // A rename usually ends with a click on another row: reloads put
            // off till now (and the rename's own) wait until that click is
            // handled, so it picks the row the person saw.
            self.endingRename = true
            if let name { self.controller.renameSession(id, to: name) }
            self.view.window?.makeFirstResponder(self.outline)
            Self.afterEvent { [weak self] in
                guard let self else { return }
                self.endingRename = false
                if self.pendingReload { self.reload() }
            }
        }
        if editing { renamingCell = cell }
    }

    // MARK: Copy

    /// ⌘C: each selected session as "name — folder path", one per line (a drag
    /// carries the folder path alone).
    @objc func copy(_ sender: Any?) {
        guard !selectedSessionIDs.isEmpty else { return NSSound.beep() }
        writeSelection(to: .general)
    }

    func writeSelection(to pb: NSPasteboard) {
        pb.clearContents()
        pb.setString(pasteboardText(selectedSessionIDs), forType: .string)
    }

    #if DEBUG
    func debugSelect(_ ids: [UUID]) {
        outline.selectRowIndexes(IndexSet(ids.compactMap { row(of: $0) }), byExtendingSelection: false)
    }
    func debugFilter(_ text: String) { searchField.debugSetText(text) }
    func debugCell(_ id: UUID) -> SessionCellView? {
        row(of: id).flatMap { outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? SessionCellView }
    }
    #endif

    private func pasteboardText(_ ids: [UUID]) -> String {
        ids.compactMap { controller.session(id: $0) }
            .map { "\(controller.displayName(of: $0)) — \($0.workdir)" }
            .joined(separator: "\n")
    }

    /// Edit ▸ Find ▸ Filter Sessions (⌥⌘F): the sidebar's filter field.
    func focusFilter() {
        if let item = (view.window?.windowController as? MainWindowController), item.isSidebarCollapsed {
            item.setSidebarCollapsed(false)
        }
        searchField.focus()
    }

    // MARK: Context menu — Drops

    private func dropsSubmenuItem(for folderID: UUID) -> NSMenuItem {
        NSMenuItem("Drops", submenu: [
            menuItem("Show Changed Files in Finder", #selector(contextShowChangedDrops), object: folderID),
            menuItem("Open Terminal to Changed Files", #selector(contextOpenTerminalToDrops), object: folderID),
        ])
    }

    @objc private func contextShowChangedDrops(_ sender: NSMenuItem) {
        guard let stagingDir = exportChangedDrops(sender) else { return }
        NSWorkspace.shared.open(stagingDir)
    }

    /// Copy the folder's changed drops out to its staging folder (saying so
    /// when there are none or it fails); the staging folder, or nil.
    private func exportChangedDrops(_ sender: NSMenuItem) -> URL? {
        guard let folderID = sender.representedObject as? UUID,
              let folder = controller.folder(id: folderID) else { return nil }
        let (dropDir, stagingDir) = dropsPaths(for: folder)
        let changed = DropsScanner.scan(dropDir: dropDir)
        guard !changed.isEmpty else {
            Alerts.inform("No Modified Files", "All files in .sbx/drops are unchanged since they were dropped.")
            return nil
        }
        do {
            try DropsScanner.export(changed, from: dropDir, to: stagingDir)
            return stagingDir
        } catch {
            Alerts.inform("Export Failed", error.localizedDescription, style: .warning)
            return nil
        }
    }

    @objc private func contextOpenTerminalToDrops(_ sender: NSMenuItem) {
        guard let stagingDir = exportChangedDrops(sender) else { return }
        let term = HostTerminalWindowController(root: stagingDir, theme: controller.theme)
        term.onClose = { [weak self] in self?.dropsTerminal = nil }
        dropsTerminal = term
        term.focus()
    }

    /// Returns (.sbx/drops, .sbx/drops-changed-<timestamp>) for a folder.
    private func dropsPaths(for folder: Folder) -> (URL, URL) {
        let sbx = controller.folderURL(for: folder).appending(path: ".sbx", directoryHint: .isDirectory)
        let drops = sbx.appending(path: "drops", directoryHint: .isDirectory)
        let staging = sbx.appending(path: "drops-changed-\(Int(Date.now.timeIntervalSince1970))",
                                    directoryHint: .isDirectory)
        return (drops, staging)
    }

    // MARK: Context menu

    private func contextMenu(forRow row: Int) -> NSMenu? {
        let menu = NSMenu()
        if let info = subagent(atRow: row) { return subagentMenu(info) }
        if let wf = workflow(atRow: row) { return workflowMenu(wf.run, in: wf.session) }
        guard let id = sessionID(atRow: row), let session = controller.session(id: id) else {
            // Empty-area click: offer the same menu as the "+" button.
            for item in newSessionMenuItems() { menu.addItem(item) }
            return menu
        }
        let targets = menuTargets(row: row)
        if targets.count > 1 {
            menu.addItem(menuItem("Close \(targets.count) Sessions", #selector(contextCloseSessions), object: targets))
            menu.addItem(menuItem("Copy \(targets.count) Sessions", #selector(contextCopy), object: targets))
            return menu
        }
        menu.addItem(menuItem("Rename…", #selector(contextRename), object: session.id))
        menu.addItem(menuItem("Close Session", #selector(contextCloseSession), object: session.id))
        menu.addItem(.separator())
        menu.addItem(menuItem("Open Files in Split", #selector(contextOpenFiles), object: session.id))
        if SbxCommand.supportsACP(session.agent) {
            menu.addItem(menuItem(session.isChat ? "Show as Terminal" : "Show as Chat",
                                  #selector(contextToggleChat), object: session.id))
        }
        menu.addItem(menuItem("Reveal in Finder", #selector(contextReveal), object: session.id))
        menu.addItem(menuItem("Copy", #selector(contextCopy), object: [session.id]))
        menu.addItem(.separator())
        menu.addItem(dropsSubmenuItem(for: session.folderID))
        return menu
    }

    /// Same conversation, other surface: the detail pane swaps terminal ⇄ chat
    /// and resumes the transcript in the new one.
    @objc private func contextToggleChat(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let session = controller.session(id: id) else { return }
        controller.setChat(id, !session.isChat)
        controller.selection = .session(id)
    }

    /// A workflow row's menu.
    private func workflowMenu(_ run: WorkflowRun, in session: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem("Open Workflow") { [weak self] in self?.openWorkflow(run, in: session) })
        menu.addItem(NSMenuItem("Reveal Run in Finder") { NSWorkspace.shared.activateFileViewerSelecting([run.dir]) })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem("Hide Subagents and Workflows") { [weak self] in self?.setShowsSubagents(false, of: session) })
        return menu
    }

    /// A subagent row's menu.
    private func subagentMenu(_ info: SubagentInfo) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem("Open Transcript") { [weak self] in
            guard let self else { return }
            SubagentWindowController.show(info, workspace: self.controller)
        })
        menu.addItem(NSMenuItem("Reveal Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([info.transcript]) })
        menu.addItem(NSMenuItem("Copy Description") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(info.title, forType: .string)
        })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem("Hide Subagents") { [weak self] in self?.setShowsSubagents(false, of: info.sessionID) })
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, object: Any? = nil) -> NSMenuItem {
        NSMenuItem(title, action: action, target: self, object: object)
    }

    @objc private func contextOpenFiles(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onOpenFilesInSplit?(id) }
    }

    @objc private func contextCloseSession(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { controller.closeSession(id) }
    }

    @objc private func contextCloseSessions(_ sender: NSMenuItem) {
        if let ids = sender.representedObject as? [UUID] { controller.closeSessions(ids) }
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { beginRename(id) }
    }

    @objc private func contextReveal(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let s = controller.session(id: id) else { return }
        if !NSWorkspace.shared.open(URL(filePath: s.workdir, directoryHint: .isDirectory)) {
            Alerts.inform("Folder Not Found", "\(s.workdir.tildeAbbreviated) no longer exists.", style: .warning)
        }
    }

    @objc private func contextCopy(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [UUID] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pasteboardText(ids), forType: .string)
    }

    fileprivate func closeSessionFromRow(_ id: UUID) { controller.closeSession(id) }
}

// MARK: - Data source

extension SidebarListController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// A session row drags out as a session (onto a pane edge: split there).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        if let info = subagent(atRow: row) { return info.transcript as NSURL }   // its transcript, as a file
        if workflow(atRow: row) != nil { return nil }
        guard let id = sessionID(atRow: row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: .sandshellSession)
        // Out of the app: its folder's path as text (Terminal, TextEdit…). Not
        // a file URL, which a Finder drop would take as "copy the project".
        if let s = controller.session(id: id) { item.setString(s.workdir, forType: .string) }
        return item
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        subagent(atRow: row)?.title ?? workflow(atRow: row)?.run.name ?? sessionID(atRow: row).flatMap { controller.displayName($0) }
    }

    /// Files dragged onto a session row attach to that session (chat: as
    /// attachments; terminal: as sandbox-readable paths).
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard !displayedSessionIDs.isEmpty, info.draggingSource as? NSTableView !== tableView,
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) else { return [] }
        let pointer = tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
        tableView.setDropRow(Self.dropRow(proposed: row, between: dropOperation == .above, pointer: pointer, in: rows),
                             dropOperation: .on)
        return .copy
    }

    /// The session row a file drop lands on. Near a row's edge the table
    /// proposes the gap ("above" the next row): that's the row under the
    /// pointer (else the one above the gap). A subagent or workflow row's drop
    /// goes to its session.
    nonisolated static func dropRow(proposed row: Int, between: Bool, pointer: Int, in rows: [Row]) -> Int {
        let target = min(max(between ? (pointer >= 0 ? pointer : row - 1) : row, 0), rows.count - 1)
        guard rows.indices.contains(target) else { return target }
        return rows.firstIndex(of: .session(rows[target].sessionID)) ?? target
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let id = sessionID(atRow: row),
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(id, urls)
        return true
    }
}

// MARK: - Delegate (cells, selection)

extension SidebarListController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarRowView(theme: sidebarTheme, drawsSelection: true)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { parentSession(ofRow: row) == nil ? 50 : 34 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let parent = parentSession(ofRow: row) {
            let last = parentSession(ofRow: row + 1) != parent
            if let info = subagent(atRow: row) { return SubagentCellView(info, isLast: last, theme: sidebarTheme) }
            if let wf = workflow(atRow: row) {
                let task = controller.backgroundTasks[wf.session]?.first { $0.runID == wf.run.id }
                return SubagentCellView(workflow: wf.run, task: task, isLast: last, theme: sidebarTheme)
            }
        }
        guard let id = sessionID(atRow: row) else { return nil }
        let cell = SessionCellView(owner: self)
        cell.sessionID = id
        if let session = controller.session(id: id) {
            cell.configure(
                session,
                name: controller.displayName(of: session),
                runtime: controller.runtime(id),
                unread: controller.runtime(id)?.isUnread ?? false,
                active: isActive(id),
                theme: sidebarTheme,
                workdirName: workdirName(for: session),
                backgroundCount: controller.runningBackgroundTasks(id))
            if childCount(of: id) > 0 {
                // What the list shows now (whether they should show changes with the selection).
                cell.showDisclosure(expanded: childRowsShown(of: id), count: childCount(of: id)) { [weak self] in
                    guard let self else { return }
                    self.setShowsSubagents(!self.childRowsShown(of: id), of: id)
                }
            }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, !settingSelection else { return }
        let picked = outline.selectedRowIndexes
        // Nothing picked (a click below the rows): the shown session stays
        // picked. The app reads no selection as "no session" (⌘W would close
        // the window while a pane still shows it).
        if picked.isEmpty {
            guard let id = shownSession, let row = row(of: id) else { return }
            settingSelection = true
            defer { settingSelection = false }
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
            return
        }
        let shown = Self.shownSession(picked: picked, last: outline.selectedRow, clicked: rowClickedNow,
                                      shown: shownSession, in: rows)
        let newSelection = shown.map { SidebarSelection.session($0) }
        if controller.selection != newSelection { controller.selection = newSelection }
    }

    /// The row a plain or ⌘-click in the list is on, while the selection
    /// changes for it; nil for keys (⌘A, arrows) and ⇧-clicks.
    private var rowClickedNow: Int? {
        guard let event = NSApp.currentEvent, event.window === outline.window,
              event.type == .leftMouseDown || event.type == .leftMouseUp,
              !event.modifierFlags.contains(.shift) else { return nil }
        let row = outline.row(at: outline.convert(event.locationInWindow, from: nil))
        return row >= 0 ? row : nil
    }

    /// The session the detail shows for what's picked (a subagent or workflow
    /// row stands for its session). A click that picks a row shows it. Else —
    /// ⇧-extension, ⌘A, a ⌘-click that unpicks another row — the one already
    /// shown stays while it (or a row under it) is still picked; failing
    /// that, the last row picked.
    nonisolated static func shownSession(picked: IndexSet, last: Int, clicked: Int?, shown: UUID?,
                                         in rows: [Row]) -> UUID? {
        func session(_ row: Int) -> UUID? { rows.indices.contains(row) ? rows[row].sessionID : nil }
        if let clicked, picked.contains(clicked) { return session(clicked) }
        if picked.count > 1, let shown, picked.contains(where: { session($0) == shown }) { return shown }
        return session(last)
    }
}

extension SidebarSearchField: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { onMoveDown?() } else { clear() }
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            onMoveDown?()
            return true
        default: return false
        }
    }
}

// MARK: - Cell views

final class SidebarRowView: NSTableRowView {
    private var theme: ThemeColors
    private let drawsSelection: Bool
    private var tracking: NSTrackingArea?

    init(theme: ThemeColors, drawsSelection: Bool) {
        self.theme = theme
        self.drawsSelection = drawsSelection
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // All row fills are drawn here so a hover tint can layer on top of the
    // selection. Hover is computed live from the real pointer location (state
    // tracked via enter/exit goes stale across the frequent in-place row
    // updates, which left several rows looking hovered at once).
    override func drawSelection(in dirtyRect: NSRect) {}

    private var isHovered: Bool {
        guard let window, window.isKeyWindow else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 9, yRadius: 9)
        let selected = drawsSelection && isSelected
        if selected {
            // Vivid in the focused list of the key window, muted otherwise.
            let focused = window?.isKeyWindow == true && (superview as? NSTableView).map { window?.firstResponder === $0 } ?? false
            let fill = theme.isDark ? NSColor.white(focused ? 0.10 : 0.06) : theme.selection
            (focused || theme.isDark ? fill : fill.withAlphaComponent(0.55)).setFill()
            path.fill()
        }
        if isHovered {
            if selected {
                (theme.isDark ? NSColor.white(0.06) : NSColor.black.withAlphaComponent(0.045)).setFill()
            } else {
                theme.sidebarHover.setFill()
            }
            path.fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved,
                                                          .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        needsDisplay = true
    }

    // Enter/exit/move just trigger a redraw; drawBackground decides hover live.
    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { needsDisplay = true }
}

/// A rounded search field with a leading magnifier, built from a borderless
/// text field so its padding and vertical centering are fully under our control
/// (NSSearchField's bezel renders inconsistently when unstyled).
final class SidebarSearchField: NSView {
    private let field = NSTextField()
    private let icon = NSImageView()
    var onChange: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.setAccessibilityLabel("Filter sessions")

        addSubview(icon)
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// ↓ / Return from the field: into the list.
    var onMoveDown: (() -> Void)?

    func focus() { window?.makeFirstResponder(field) }

    /// Empty it: every session shows again.
    func clear() {
        field.stringValue = ""
        onChange?("")
    }

    #if DEBUG
    /// As if typed (one keystroke's change).
    func debugSetText(_ text: String) {
        field.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    #endif

    func style(bg: NSColor, fg: NSColor, muted: NSColor) {
        layer?.backgroundColor = bg.cgColor
        icon.contentTintColor = muted
        field.textColor = fg
        field.placeholderAttributedString = NSAttributedString(
            string: "Search sessions",
            attributes: [.foregroundColor: muted, .font: NSFont.systemFont(ofSize: 12.5)])
    }
}

final class WorkingSweepView: NSView {
    private let trackLayer = CALayer()
    private let pillLayer = CALayer()
    private static let green = NSColor.sessionWorking

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        trackLayer.addSublayer(pillLayer)
        applyColors()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        trackLayer.frame = bounds
        trackLayer.cornerRadius = bounds.height / 2
        pillLayer.frame = CGRect(x: 0, y: 0, width: 7, height: bounds.height)
        pillLayer.cornerRadius = bounds.height / 2
        if !isHidden { startAnimating() }
    }

    // Re-color layers and restart the animation when the sidebar switches
    // between light and dark. Without this the 22%-alpha green track becomes
    // invisible on a white sidebar background (light mode), and any in-flight
    // CABasicAnimation that was paused during the appearance transition stays dead.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        if !isHidden {
            pillLayer.removeAnimation(forKey: "sweep")
            startAnimating()
        }
    }

    private func applyColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.trackLayer.backgroundColor = Self.green.withAlphaComponent(dark ? 0.22 : 0.35).cgColor
            self.pillLayer.backgroundColor = Self.green.cgColor
        }
    }

    func startAnimating() {
        guard window != nil, bounds.width > 7 else { return }
        // Reduce Motion: a still pill in the middle of the track.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            pillLayer.removeAnimation(forKey: "sweep")
            pillLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            return
        }
        if pillLayer.animation(forKey: "sweep") != nil { return }
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = 3.5
        animation.toValue = bounds.width - 3.5
        animation.duration = 0.85
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pillLayer.position = CGPoint(x: 3.5, y: bounds.midY)
        pillLayer.add(animation, forKey: "sweep")
    }

    func stopAnimating() {
        pillLayer.removeAnimation(forKey: "sweep")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stopAnimating() : startAnimating()
    }
}

final class SessionCellView: NSTableCellView {
    var sessionID: UUID?
    private weak var owner: SidebarListController?
    // Smaller icon and no separate leading rail — reclaims width for text
    // (title on its own line, metadata line below it). The working/ready
    // indicator lives inline at the start of that metadata line instead of a
    // dedicated column, so it reads as "below the title" rather than beside it.
    private let badge = AgentBadgeView(side: 22, fontSize: 10, radius: 6)
    private let statusSlot = NSView()
    private let workingView = WorkingSweepView()
    private let statusDot = NSView()
    private let timeLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?
    private var agentLabel = ""
    private var workdirName: String?
    /// The session's last turn before this run (`Session.lastActiveAt`).
    private var lastActive: Date?
    private var accent: NSColor = .controlAccentColor

    init(owner: SidebarListController) {
        self.owner = owner
        super.init(frame: .zero)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.font = .systemFont(ofSize: 11)
        subLabel.textColor = .secondaryLabelColor
        subLabel.lineBreakMode = .byTruncatingTail

        // Working sweep OR an accent ready-dot, plus the live work-time —
        // shown inline before the rest of the metadata, not in their own column.
        statusSlot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        workingView.isHidden = true
        statusSlot.addSubview(workingView)
        statusSlot.addSubview(statusDot)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor

        disclosure.isBordered = false
        disclosure.imagePosition = .imageLeading
        disclosure.font = .systemFont(ofSize: 11, weight: .medium)
        disclosure.target = self
        disclosure.action = #selector(disclosureClicked)
        disclosure.isHidden = true
        disclosure.setContentHuggingPriority(.required, for: .horizontal)
        disclosure.setContentCompressionResistancePriority(.required, for: .horizontal)
        subLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let metaRow = NSStackView(views: [statusSlot, timeLabel, subLabel, disclosure])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 5
        metaRow.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [nameLabel, metaRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true

        addSubview(badge)
        addSubview(text)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            statusSlot.widthAnchor.constraint(equalToConstant: 12),
            statusSlot.heightAnchor.constraint(equalToConstant: 10),
            workingView.centerXAnchor.constraint(equalTo: statusSlot.centerXAnchor),
            workingView.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
            workingView.widthAnchor.constraint(equalToConstant: 12),
            workingView.heightAnchor.constraint(equalToConstant: 4),
            statusDot.centerXAnchor.constraint(equalTo: statusSlot.centerXAnchor),
            statusDot.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),

            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Name/meta span the full width (just a little trailing padding).
            text.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 9),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var fg: NSColor = .labelColor

    /// Full (re)configure — identity + colors + active-ness, then the runtime bits.
    /// `active` (selected or has a running terminal) drives the emphasized name.
    /// `workdirName` (nil for the root folder) shows as a subtitle segment so
    /// sessions still read their working directory now that there are no
    /// folder rows to group them under.
    /// Background tasks (subagents, background commands) the session has running.
    var backgroundRunning = 0

    func configure(_ session: Session, name: String, runtime: SessionRuntime?, unread: Bool, active: Bool,
                   theme: ThemeColors, workdirName: String?, backgroundCount: Int = 0) {
        agentLabel = session.agent.displayName
        self.workdirName = workdirName
        lastActive = session.lastActiveAt
        accent = theme.accent
        fg = theme.sidebarFg
        badge.configure(session.agent)
        nameLabel.stringValue = name
        backgroundRunning = backgroundCount
        setActive(active)
        subLabel.textColor = theme.sidebarMuted
        timeLabel.textColor = theme.sidebarMuted
        closeButton.contentTintColor = theme.sidebarMuted.withAlphaComponent(0.75)
        updateRuntime(runtime, unread: unread)
    }

    /// Active (selected/live) sessions are emphasized; inactive ones are regular
    /// weight and dimmed so they clearly read as not-running. Applied in place so
    /// clicking a session bolds it immediately (before its terminal launches).
    func setActive(_ active: Bool) {
        nameLabel.font = .systemFont(ofSize: 13.5, weight: active ? .semibold : .regular)
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        nameLabel.textColor = active || contrast ? fg : fg.withAlphaComponent(0.55)
    }

    /// Update the runtime-driven bits (left-rail sweep/dot + time, subline) in
    /// place — no cell rebuild, so frequent polls don't churn the row.
    func updateRuntime(_ runtime: SessionRuntime?, unread: Bool) {
        var parts = [agentLabel]
        if let workdirName { parts.append(workdirName) }
        let work = runtime.flatMap { compactWorkTime($0.liveWorkSeconds()) }
        switch runtime?.stoppedReason == nil ? runtime?.status : nil {
        case .working where runtime?.isWaiting == true:
            // Waiting on you (a question or a permission): no sweep, an orange dot.
            workingView.stopAnimating()
            workingView.isHidden = true
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            statusDot.isHidden = false
            timeLabel.isHidden = true
            parts.append("Waiting for you")
        case .working:
            workingView.isHidden = false
            workingView.startAnimating()
            statusDot.isHidden = true
            timeLabel.stringValue = work ?? ""
            timeLabel.isHidden = (work == nil)
            parts.append("Working")
        case .ready:
            workingView.stopAnimating()
            workingView.isHidden = true
            statusDot.layer?.backgroundColor = accent.cgColor
            statusDot.isHidden = !unread       // accent dot only when ready + unseen
            timeLabel.isHidden = true
            parts.append((runtime?.lastActivityAt ?? lastActive).map { relativeActivity($0) } ?? "Ready")
            if unread { parts.append("New") }   // not just the dot's colour
        default:
            workingView.stopAnimating()
            workingView.isHidden = true
            statusDot.isHidden = true
            timeLabel.isHidden = true
            // Not run since the app opened: when it last was.
            if runtime == nil, let lastActive { parts.append(relativeActivity(lastActive)) }
        }
        if runtime?.stoppedReason != nil { parts.append("Stopped") }
        if backgroundRunning > 0 { parts.append("\(backgroundRunning) in background") }
        subLabel.stringValue = parts.joined(separator: " · ")
        subLabel.toolTip = runtime?.stoppedReason
    }

    private func syncHover() {
        guard let window, window.isKeyWindow else { closeButton.isHidden = true; return }
        closeButton.isHidden = !bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved,
                                                          .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        syncHover()   // recompute from the real pointer; never leaves it stale
    }
    override func mouseEntered(with event: NSEvent) { syncHover() }
    override func mouseExited(with event: NSEvent) { syncHover() }
    override func mouseMoved(with event: NSEvent) { syncHover() }

    @objc private func closeClicked() { if let sessionID { owner?.closeSessionFromRow(sessionID) } }

    // MARK: Subagents

    private let disclosure = NSButton()
    private var onDisclosure: (() -> Void)?

    /// "▸ 3 subagents": shows or hides them under the row.
    func showDisclosure(expanded: Bool, count: Int, toggle: @escaping () -> Void) {
        onDisclosure = toggle
        disclosure.isHidden = false
        disclosure.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        // Just the count: the status beside it keeps its room.
        let words = "\(count) subagent\(count == 1 ? "" : "s")"
        disclosure.contentTintColor = subLabel.textColor
        disclosure.attributedTitle = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: subLabel.textColor ?? .secondaryLabelColor])
        disclosure.toolTip = "\(expanded ? "Hide" : "Show") \(words)"
        disclosure.setAccessibilityLabel(disclosure.toolTip)
    }

    @objc private func disclosureClicked() { onDisclosure?() }

    // MARK: Inline rename

    private var renameDone: ((String?) -> Void)?
    private var nameBeforeRename = ""

    /// Its name is being edited.
    var isRenaming: Bool { renameDone != nil && nameLabel.currentEditor() != nil }

    /// Edit the name in place: Return keeps it, Esc puts the old one back.
    /// False when it can't take focus (not on screen): nothing is left editable.
    func beginRenaming(_ done: @escaping (String?) -> Void) -> Bool {
        renameDone = done
        nameBeforeRename = nameLabel.stringValue
        nameLabel.isEditable = true
        nameLabel.isSelectable = true
        nameLabel.delegate = self
        guard window?.makeFirstResponder(nameLabel) == true else {
            renameDone = nil
            nameLabel.isEditable = false
            nameLabel.isSelectable = false
            return false
        }
        nameLabel.currentEditor()?.selectAll(nil)
        return true
    }

    /// `name` nil: cancelled. Committing it unchanged counts as cancelling (it
    /// would pin the automatic name and add an Undo step).
    private func finishRenaming(_ name: String?) {
        guard let done = renameDone else { return }
        renameDone = nil
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        if name == nil { nameLabel.stringValue = nameBeforeRename }
        done(name == nameBeforeRename ? nil : name)
    }

    #if DEBUG
    var debugName: String { nameLabel.stringValue }
    func debugFinishRenaming(_ name: String?) {
        if let name { nameLabel.stringValue = name }
        finishRenaming(name)
    }
    #endif
}

extension SessionCellView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finishRenaming(nil)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) { finishRenaming(nameLabel.stringValue) }
}

/// Coarse relative time for the session subline: "just now" → "2m ago" → "3h ago".
func relativeActivity(_ date: Date, now: Date = .now) -> String { Format.ago(date, now: now) }
func compactWorkTime(_ seconds: TimeInterval) -> String? { Format.compactWorkTime(seconds) }
func formatWorkTime(_ seconds: TimeInterval) -> String { Format.workTime(seconds) }

final class SidebarIconButton: NSControl {
    private let imageView = NSImageView()

    var contentTintColor: NSColor = .labelColor {
        didSet { imageView.contentTintColor = contentTintColor }
    }

    /// Resting + hover fills, set by the theme. Swapped on mouse enter/exit.
    var restingBackgroundColor: NSColor = .clear {
        didSet { if !hovering { layer?.backgroundColor = restingBackgroundColor.cgColor } }
    }
    var hoverBackgroundColor: NSColor = .clear {
        didSet { if hovering { layer?.backgroundColor = hoverBackgroundColor.cgColor } }
    }
    private var hovering = false

    init(symbolName: String, pointSize: CGFloat, accessibilityDescription: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        setAccessibilityElement(true)   // a custom NSControl isn't one by default
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityDescription)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        imageView.image?.isTemplate = true
        imageView.imageScaling = .scaleNone
        imageView.contentTintColor = contentTintColor
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1.0 : 0.4 }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        hovering = true
        layer?.backgroundColor = hoverBackgroundColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = restingBackgroundColor.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
    }
}

/// An `NSButton` with a resting/hover background swap (the footer Search pill).
final class HoverButton: NSButton {
    var restingBackgroundColor: NSColor = .clear {
        didSet { if !hovering { layer?.backgroundColor = restingBackgroundColor.cgColor } }
    }
    var hoverBackgroundColor: NSColor = .clear {
        didSet { if hovering { layer?.backgroundColor = hoverBackgroundColor.cgColor } }
    }
    private var hovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        hovering = true
        layer?.backgroundColor = hoverBackgroundColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = restingBackgroundColor.cgColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// The sidebar header (app mark + workspace identity + chevron). A click
/// anywhere pops the workspace-folder switcher menu.
final class SidebarHeaderView: NSStackView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }

    // A button to VoiceOver and Full Keyboard Access: it opens the workspace menu.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityLabel() -> String? {
        "Workspace: " + (arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.first ?? "")
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func accessibilityPerformShowMenu() -> Bool { onClick?(); return true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

extension SidebarListController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedSessionIDs.isEmpty }
        return true
    }
}

extension SubagentInfo {
    /// As its sidebar row shows it: a running one just says "Working", so the
    /// writes its transcript gets all the time don't change it.
    var asShown: SubagentInfo {
        var shown = self
        if isRunning { shown.lastWrite = .distantPast }
        return shown
    }
}

extension WorkflowRun {
    /// As its sidebar row shows it: name, phases with how many of their agents
    /// are done, agent count — and when it last wrote, once its agents have
    /// settled. Its agents' tokens, models and writes, which change all the
    /// time while it runs, don't show.
    var asShown: WorkflowRun {
        WorkflowRun(id: id, dir: dir, name: name, summary: summary, phases: phases,
                    agents: agents.map { agent in
                        var shown = agent
                        shown.model = nil
                        shown.tokens = 0
                        shown.lastWrite = nil
                        return shown
                    },
                    startedAt: startedAt, lastWrite: agentsSettled ? lastWrite : nil)
    }
}

/// A subagent under its session: tree line, what it's doing, its state.
final class SubagentCellView: NSTableCellView {
    private let isLast: Bool
    private let lineColor: NSColor

    convenience init(_ info: SubagentInfo, isLast: Bool, theme: ThemeColors) {
        let state = switch info.state {
        case .running: "Working"
        case .done: Format.ago(info.lastWrite)
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
        self.init(title: info.title, subtitle: [info.agentType, state].compactMap { $0 }.joined(separator: " · "),
                  running: info.isRunning, failed: info.state == .failed, isLast: isLast, theme: theme,
                  accessibility: "Subagent: \(info.title), \(state)")
    }

    /// A workflow under its session: its name, and where it's got to.
    convenience init(workflow run: WorkflowRun, task: BackgroundTask?, isLast: Bool, theme: ThemeColors) {
        let running = task.map(\.isRunning) ?? !run.agentsSettled
        var parts = ["Workflow"]
        if running, let phase = run.phases.last(where: { run.progress(of: $0).total > 0 }) {
            let p = run.progress(of: phase)
            parts.append("\(phase.title) \(p.done)/\(p.total)")
        } else if let last = run.lastWrite {
            parts.append(task?.state == .failed ? "Failed" : Format.ago(last))
        }
        parts.append("\(run.agents.count) agents")
        self.init(title: run.name, subtitle: parts.joined(separator: " · "), running: running,
                  failed: task?.state == .failed, isLast: isLast, theme: theme,
                  accessibility: "Workflow: \(run.name), \(parts.dropFirst().joined(separator: ", "))",
                  symbol: "point.3.connected.trianglepath.dotted")
        toolTip = run.summary ?? run.name
    }

    init(title: String, subtitle: String, running: Bool, failed: Bool, isLast: Bool, theme: ThemeColors,
         accessibility: String, symbol: String? = nil) {
        self.isLast = isLast
        lineColor = theme.sidebarMuted.withAlphaComponent(0.45)
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: running ? .medium : .regular)
        titleLabel.textColor = theme.sidebarFg.withAlphaComponent(running ? 1 : 0.8)
        titleLabel.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .systemFont(ofSize: 10.5)
        sub.textColor = theme.sidebarMuted
        sub.lineBreakMode = .byTruncatingTail
        let mark: NSView
        if let symbol {
            let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            image.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            image.contentTintColor = running ? .sessionWorking : failed ? .systemRed : theme.sidebarMuted
            mark = image
        } else {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = (running ? NSColor.sessionWorking
                : failed ? .systemRed : theme.sidebarMuted.withAlphaComponent(0.5)).cgColor
            mark = dot
        }
        let text = NSStackView(views: [titleLabel, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for v in [mark, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let markSize: CGFloat = symbol == nil ? 6 : 12
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 43),
            mark.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: markSize),
            mark.heightAnchor.constraint(equalToConstant: markSize),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 53),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(accessibility)
        toolTip = title
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The tree: a line down from the session, an elbow into this row.
    override func draw(_ dirtyRect: NSRect) {
        lineColor.setStroke()
        let x: CGFloat = 19, mid = bounds.midY
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: x, y: isFlipped ? 0 : bounds.maxY))
        path.line(to: NSPoint(x: x, y: isLast ? mid : (isFlipped ? bounds.maxY : 0)))
        path.move(to: NSPoint(x: x, y: mid))
        path.line(to: NSPoint(x: 34, y: mid))
        path.stroke()
    }
}

