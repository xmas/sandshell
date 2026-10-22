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

/// The workspace sidebar: a header (workspace switcher, +, search field), a
/// flat list of sessions — whatever needs you, then what's working, then the
/// rest by recency, forks under their source — and a footer with a terminal
/// on this Mac and Status Debug. Every row reads `<glyph> Status · detail`
/// (`SessionRowStatus`); its views are in SidebarRows.swift.
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

    /// What each row shows: a session, its one subagents row (the count of
    /// its subagents, workflows and background tasks), or — opened from that
    /// row — one of its subagents or workflows.
    enum Row: Equatable, Identifiable {
        case session(UUID), summary(UUID), subagent(SubagentInfo), workflow(UUID, WorkflowRun)

        /// Which row it is, whatever it shows now (a subagent's state, a run's progress).
        enum ID: Hashable { case session(UUID), summary(UUID), subagent(UUID, String), workflow(UUID, String) }
        var id: ID {
            switch self {
            case .session(let id): .session(id)
            case .summary(let id): .summary(id)
            case .subagent(let info): .subagent(info.sessionID, info.id)
            case .workflow(let session, let run): .workflow(session, run.id)
            }
        }
        /// The session it is, or sits under.
        var sessionID: UUID {
            switch self {
            case .session(let id), .summary(let id): id
            case .subagent(let info): info.sessionID
            case .workflow(let session, _): session
            }
        }
    }
    private(set) var rows: [Row] = []
    /// Sessions whose subagent rows the person opened (from the subagents row).
    private var openedParents: Set<UUID> = []

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
    /// The session whose subagents row this is.
    func summarySession(atRow row: Int) -> UUID? {
        guard rows.indices.contains(row), case .summary(let id) = rows[row] else { return nil }
        return id
    }
    /// The session a child row (subagents row, subagent or workflow) sits under; nil for a session row.
    func parentSession(ofRow row: Int) -> UUID? {
        summarySession(atRow: row) ?? subagent(atRow: row)?.sessionID ?? workflow(atRow: row)?.session
    }

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
        rows.contains { row in
            switch row {
            case .subagent(let info): info.sessionID == id
            case .workflow(let session, _): session == id
            default: false
            }
        }
    }

    /// Its subagent and workflow rows show: the person opened them (they're
    /// summed up in one row otherwise).
    func showsSubagents(of id: UUID) -> Bool {
        openedParents.contains(id) && childCount(of: id) > 0
    }

    /// What a session's subagents row says (empty: no row).
    func summary(of id: UUID) -> SubagentSummary {
        SubagentSummary(subagents: controller.subagents[id] ?? [], workflows: controller.workflows[id] ?? [],
                        tasks: controller.backgroundTasks[id] ?? [])
    }

    /// A session's child rows: its subagents and workflows, oldest first.
    private func childRows(of id: UUID) -> [Row] {
        let subs = (controller.subagents[id] ?? []).map { (date: $0.startedAt, row: Row.subagent($0)) }
        let runs = (controller.workflows[id] ?? []).map { (date: $0.startedAt ?? .distantPast, row: Row.workflow(id, $0)) }
        return (subs + runs).sorted { $0.date < $1.date }.map(\.row)
    }
    private func childCount(of id: UUID) -> Int { (controller.subagents[id]?.count ?? 0) + (controller.workflows[id]?.count ?? 0) }

    func setShowsSubagents(_ show: Bool, of id: UUID) {
        if show { openedParents.insert(id) } else { openedParents.remove(id) }
        reload()
    }

    /// The subagents row was clicked: show or hide its rows — or, with only
    /// background tasks to count, open Background Tasks.
    private func summaryClicked(_ id: UUID) {
        if childCount(of: id) > 0 {
            setShowsSubagents(!childRowsShown(of: id), of: id)
        } else {
            controller.selection = .session(id)
            (view.window?.windowController as? MainWindowController)?.showBackgroundTasks()
        }
    }
    /// Live filter over `displayedSessionIDs` (session name / agent / folder).
    private var searchQuery: String = ""

    /// The shortcut that focuses the search field (Edit ▸ Find ▸ Filter
    /// Sessions), shown at its end. ⌘F stays Find in a pane.
    static let filterShortcut = "⌥⌘F"
    private let searchField = SidebarSearchField(shortcutHint: SidebarListController.filterShortcut)
    private let newSessionButton = SidebarIconButton(
        symbolName: "plus", configuration: .role(.meta, weight: .semibold), accessibilityDescription: "New Session")

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
    /// `● Sandbox · read-write  main`: opens the sandbox access popover.
    /// The footer: a terminal on this Mac, and the Status Debug window. (What
    /// the sandbox can see of the folder is the title bar's sandbox pill.)
    private let footer = NSStackView()
    private lazy var terminalButton = NSButton.symbol(
        "apple.terminal", label: "Open a Terminal on This Mac", pointSize: TypeRole.body.symbolPointSize,
        size: NSSize(width: 32, height: 30), target: self, action: #selector(openHostTerminal), id: "sidebar-terminal")
    private lazy var debugButton = NSButton.symbol(
        "ladybug", label: "Status Debug", pointSize: TypeRole.body.symbolPointSize,
        size: NSSize(width: 32, height: 30), target: self, action: #selector(statusDebugClicked), id: "sidebar-debug")
    private let footerBorder = NSView()
    /// A host (Mac) shell terminal window, kept open across re-clicks.
    private var hostTerminal: HostTerminalWindowController?
    /// Terminal opened to the most-recent changed-drops staging directory.
    private var dropsTerminal: HostTerminalWindowController?

    /// Open another workspace folder in its own window (Obsidian-vault style).
    /// Set by `MainWindowController`; routed to `AppDelegate.openWorkspace`.
    var onOpenWorkspace: ((URL) -> Void)?
    /// Files dropped on a session row (the window routes them to that session).
    var onDropFiles: ((UUID, [URL]) -> Void)?

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
        // Full width: the rows draw their own 6 pt inset and fills (SidebarRows.swift).
        outline.style = .fullWidth
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
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
        outline.doubleAction = #selector(rowDoubleClicked)
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

        // ── Header, row 1: the folder's mark and name with a ▾ (the workspace
        //    switcher), then the one + (New Session). Below the traffic lights.
        brandBox.translatesAutoresizingMaskIntoConstraints = false
        brandBox.wantsLayer = true
        brandBox.layer?.cornerRadius = 5
        appMark.translatesAutoresizingMaskIntoConstraints = false
        appMark.imageScaling = .scaleProportionallyUpOrDown
        appMark.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        brandBox.addSubview(appMark)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .role(.title)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateHeaderIdentity()   // icon/color/title from the folder profile

        headerChevron.translatesAutoresizingMaskIntoConstraints = false
        headerChevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Workspace")
        headerChevron.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        headerChevron.setContentHuggingPriority(.required, for: .horizontal)
        headerChevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = SidebarHeaderView(views: [brandBox, titleLabel, headerChevron])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.setCustomSpacing(5, after: titleLabel)
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.onClick = { [weak self] in self?.headerClicked() }

        newSessionButton.translatesAutoresizingMaskIntoConstraints = false
        newSessionButton.target = self
        newSessionButton.action = #selector(newSessionButtonClicked)
        newSessionButton.toolTip = "New Session"

        // ── Row 2: the search field — the sidebar's one search.
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
        searchField.toolTip = "Search sessions (\(Self.filterShortcut))"

        rightBorder.translatesAutoresizingMaskIntoConstraints = false
        rightBorder.wantsLayer = true
        // ── Footer: its buttons, roomy.
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.spacing = 6
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        footer.setViews([terminalButton, debugButton], in: .leading)
        footer.setAccessibilityIdentifier("sidebar-footer")
        footerBorder.translatesAutoresizingMaskIntoConstraints = false
        footerBorder.wantsLayer = true

        emptyStateLabel.alignment = .center
        emptyStateLabel.font = .role(.body)
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

        for v in [header, newSessionButton, searchField, scroll, emptyStateStack, footer, footerBorder, rightBorder] as [NSView] {
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            brandBox.widthAnchor.constraint(equalToConstant: 20),
            brandBox.heightAnchor.constraint(equalToConstant: 20),
            appMark.centerXAnchor.constraint(equalTo: brandBox.centerXAnchor),
            appMark.centerYAnchor.constraint(equalTo: brandBox.centerYAnchor),
            appMark.widthAnchor.constraint(equalToConstant: 12),
            appMark.heightAnchor.constraint(equalToConstant: 12),

            // Its own line below the window's traffic-light controls.
            newSessionButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            newSessionButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            newSessionButton.widthAnchor.constraint(equalToConstant: 26),
            newSessionButton.heightAnchor.constraint(equalToConstant: 26),
            header.centerYAnchor.constraint(equalTo: newSessionButton.centerYAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(lessThanOrEqualTo: newSessionButton.leadingAnchor, constant: -8),

            searchField.topAnchor.constraint(equalTo: newSessionButton.bottomAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerBorder.topAnchor),

            emptyStateStack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyStateStack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -20),
            emptyStateStack.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 20),
            emptyStateStack.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -20),
            emptyStateLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 170),

            footerBorder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerBorder.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerBorder.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footerBorder.heightAnchor.constraint(equalToConstant: 1),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 40),

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

    /// The sidebar's colours (derived from its theme's background and foreground).
    private var palette: SidebarPalette { SidebarPalette(sidebarTheme) }

    private func applyTheme(_ c: ThemeColors) {
        // Force the sidebar's own appearance so its text and controls render
        // in the chosen scheme regardless of the app's overall mode (enables
        // "Sidebar always dark"), then paint the explicit background on top.
        let p = SidebarPalette(c)
        view.appearance = NSAppearance(named: c.isDark ? .darkAqua : .aqua)
        view.layer?.backgroundColor = c.sidebar.cgColor
        rightBorder.layer?.backgroundColor = c.border.cgColor
        footerBorder.layer?.backgroundColor = p.separator.cgColor
        terminalButton.contentTintColor = p.muted
        debugButton.contentTintColor = p.muted
        titleLabel.textColor = p.foreground
        headerChevron.contentTintColor = p.muted
        searchField.style(p)
        emptyStateLabel.textColor = p.muted
        newSessionButton.contentTintColor = p.foreground
        newSessionButton.restingBackgroundColor = p.selectedFill
        newSessionButton.hoverBackgroundColor = p.background.mixed(with: p.foreground, 0.16)
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
            // The newly-shown title at full strength at once (and the previous
            // one dimmed unless it's live) — no wait for the terminal to launch.
            self.refreshActive(previous)
            self.refreshActive(self.lastActiveSession)
            // Which rows are open in another pane follows the focused pane.
            self.refreshRowFills()
        }.store(in: &cancellables)
        // The subagents row counts running background tasks: reload when that
        // count changes (not on every write their output gets).
        controller.$backgroundTasks.dropFirst()
            .map { $0.mapValues { $0.count { $0.isRunning && ($0.kind == .shell || $0.kind == .monitor) } } }
            .removeDuplicates()
            .sink { [weak self] _ in self?.reloadAfterEvent() }
            .store(in: &cancellables)
        // View ▸ Comfortable / Compact.
        NotificationCenter.default.publisher(for: SidebarDensity.didChange)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
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
        // Tick the relative "3m" labels on idle rows. Cheap and low-frequency.
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

    /// Working rows' elapsed time, every second (the workspace clock).
    private func tickWorkingTimers() {
        guard !reloading else { return }
        for id in displayedSessionIDs where SessionRowStatus.state(of: controller.runtime(id)) == .working {
            guard let row = row(of: id),
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionCellView else { continue }
            cell.setTime(timeText(id))
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
            updateSessionRow(id)
            // Rank changes (it needs you, starts or stops working) and finished
            // turns are structural: resort. Every other field (the timer,
            // activity while it works) updates the row in place, above, so
            // nothing jumps around while a timer ticks.
            if SessionRowStatus.rank(new[id]) != SessionRowStatus.rank(lastRuntimes[id])
                || new[id]?.status != lastRuntimes[id]?.status { needsReorder = true }
        }
        lastRuntimes = new
        if needsReorder { reload() }
    }

    private var lastActiveSession: UUID?

    /// The row stands out (its title at full strength) while it's shown in the
    /// focused pane — or picked in the list.
    private func isSelected(_ id: UUID) -> Bool {
        controller.selection == .session(id)
    }

    /// Update a session row's emphasis in place (no rebuild).
    private func refreshActive(_ id: UUID?) {
        guard let id, let row = row(of: id),
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionCellView
        else { return }
        cell.setSelected(isSelected(id))
    }

    /// A session row's status line, as its runtime says now.
    private func status(_ id: UUID) -> SessionRowStatus {
        SessionRowStatus.of(controller.runtime(id), agent: controller.session(id: id)?.agent ?? .claude)
    }

    private func timeText(_ id: UUID) -> String? {
        SessionRowStatus.time(controller.runtime(id), lastActivity: controller.lastActivity(id))
    }

    /// Update a session row's state-driven bits *in place* (no cell rebuild),
    /// so its spinner turns on instead of restarting each poll.
    private func updateSessionRow(_ id: UUID) {
        guard !reloading, let row = row(of: id),
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionCellView
        else { return }   // off-screen rows reconfigure fresh when they reappear
        cell.update(status: status(id), time: timeText(id), selected: isSelected(id),
                    live: controller.runtime(id)?.isLive == true)
    }

    /// The sessions shown in panes other than the focused one, when the window has more than one.
    private var sessionsOpenElsewhere: Set<UUID> {
        guard let tree = (view.window?.windowController as? MainWindowController)?.paneTree, tree.panes.count > 1
        else { return [] }
        return Set(tree.panes.filter { $0 !== tree.focused }.compactMap(\.shownSession))
    }

    /// Redraw the rows' fills: the selection, and which sessions another pane shows.
    private func refreshRowFills() {
        let elsewhere = sessionsOpenElsewhere
        outline.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? SidebarRowView else { return }
            rowView.isOpenElsewhere = sessionID(atRow: row).map(elsewhere.contains) ?? false
            rowView.needsDisplay = true
        }
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
            [.session(id)] + (summary(of: id).isEmpty ? [] : [.summary(id)])
                + (showsSubagents(of: id) ? childRows(of: id) : [])
        }
        outline.reloadData()
        applySelectionToOutline(keeping: picked)
        updateEmptyState()
        refreshRowFills()
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
    /// Double-click: rename a session in place (a subagent opens its window).
    @objc private func rowDoubleClicked() { doubleClicked(row: outline.clickedRow) }

    private func doubleClicked(row: Int) {
        guard row >= 0 else { return }
        if let info = subagent(atRow: row) { return SubagentWindowController.show(info, workspace: controller) }
        guard let id = sessionID(atRow: row) else { return }
        Self.afterEvent { [weak self] in self?.beginRename(id) }
    }

    @objc private func rowClicked() {
        let row = outline.clickedRow
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        // The subagents row isn't picked: a click shows or hides its rows.
        if let id = summarySession(atRow: row) {
            guard modifiers.isDisjoint(with: [.command, .shift]) else { return }
            return Self.afterEvent { [weak self] in self?.summaryClicked(id) }
        }
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

    // Help ▸ Show Sandshell Log / Show sbx Daemon Log / Status Debug Window.

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

    @objc private func statusDebugClicked() { openStatusDebugWindow() }
    #if DEBUG
    /// Self-test: the buttons beside the footer that show, left to right.
    var debugFooterButtons: [String] {
        let shown: [NSButton] = [terminalButton, debugButton].filter { !$0.isHidden && $0.frame.width > 0 }
        return shown.sorted { $0.frame.minX < $1.frame.minX }.map { $0.accessibilityIdentifier() }
    }
    #endif

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

    /// Present the per-root settings inspector (⌘, and the app menu) as a
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
    /// (or adding) another working directory. (Search is the sidebar's field.)
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
    /// A session's subagents row, when it has one.
    func debugSummaryCell(_ id: UUID) -> SubagentSummaryCellView? {
        rows.firstIndex(of: .summary(id)).flatMap { outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? SubagentSummaryCellView }
    }
    /// Self-test: what dragging `id`'s row carries, on a pasteboard of its own.
    func debugDragPasteboard(_ id: UUID) -> NSPasteboard? {
        guard let row = row(of: id), let item = tableView(outline, pasteboardWriterForRow: row) else { return nil }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sandshell-selftest-drag-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        return pasteboard
    }
    func debugRowView(_ id: UUID) -> SidebarRowView? {
        row(of: id).flatMap { outline.rowView(atRow: $0, makeIfNecessary: true) as? SidebarRowView }
    }
    /// A row's height, without the 1 pt between rows.
    func debugRowHeight(_ id: UUID) -> CGFloat? {
        row(of: id).map { outline.rect(ofRow: $0).height - outline.intercellSpacing.height }
    }
    /// Click the subagents row (as a click would, once the event is over).
    func debugClickSummary(_ id: UUID) { summaryClicked(id) }
    var debugPalette: SidebarPalette { palette }
    func debugDoubleClick(_ id: UUID) { row(of: id).map { doubleClicked(row: $0) } }
    var debugSearchHint: String? { searchField.hintText }
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

    /// A row's close button.
    func closeSessionFromRow(_ id: UUID) { controller.closeSession(id) }
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
        let view = SidebarRowView(palette: palette)
        let id = rows.indices.contains(row) ? rows[row].sessionID : nil
        if sessionID(atRow: row) != nil {
            // A fork listed under its source: on the rail, indented.
            let nested = id.map(nestedForkIDs.contains) ?? false
            view.indent = nested ? SidebarMetrics.childIndent : 0
            view.drawsRail = nested
            view.isOpenElsewhere = id.map(sessionsOpenElsewhere.contains) ?? false
        } else {
            // The subagents row and the rows it opens hang from the rail too.
            view.indent = SidebarMetrics.childIndent
            view.drawsRail = true
        }
        return view
    }

    /// The density, read once per reload's worth of rows.
    private var density: SidebarDensity { SidebarDensity.current }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if summarySession(atRow: row) != nil { return SidebarMetrics.summaryRowHeight }
        guard let id = sessionID(atRow: row) else { return SidebarMetrics.childRowHeight }
        return density.sessionRowHeight(showsInstruction: instruction(id) != nil && density == .comfortable)
    }

    /// A row's first instruction, when its title isn't it.
    private func instruction(_ id: UUID) -> String? {
        guard let s = controller.session(id: id) else { return nil }
        return SessionRowStatus.instruction(displayName: controller.displayName(of: s), firstPrompt: s.firstPrompt)
    }

    /// The subagents row isn't picked (a click toggles what it sums up).
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { summarySession(atRow: row) == nil }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let palette = self.palette
        if let id = summarySession(atRow: row) {
            return SubagentSummaryCellView(summary(of: id), expanded: childRowsShown(of: id), palette: palette)
        }
        if let info = subagent(atRow: row) { return SubagentCellView(info, palette: palette) }
        if let wf = workflow(atRow: row) {
            let task = controller.backgroundTasks[wf.session]?.first { $0.runID == wf.run.id }
            return SubagentCellView(workflow: wf.run, task: task, palette: palette)
        }
        guard let id = sessionID(atRow: row), let session = controller.session(id: id) else { return nil }
        let cell = SessionCellView(owner: self, palette: palette)
        cell.sessionID = id
        cell.configure(session, name: controller.displayName(of: session), instruction: instruction(id),
                       density: density, nested: nestedForkIDs.contains(id), status: status(id), time: timeText(id),
                       selected: isSelected(id), live: controller.runtime(id)?.isLive == true)
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


/// Coarse relative time for the session subline: "just now" → "2m ago" → "3h ago".
func relativeActivity(_ date: Date, now: Date = .now) -> String { Format.ago(date, now: now) }
func compactWorkTime(_ seconds: TimeInterval) -> String? { Format.compactWorkTime(seconds) }
func formatWorkTime(_ seconds: TimeInterval) -> String { Format.workTime(seconds) }


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


