import AppKit
import Combine
import QuartzCore
import SwiftUI

extension AgentKind {
    /// SF Symbol used for an agent's session row.
    var symbolName: String {
        switch self {
        case .claude, .dockerAgent: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "diamond"
        case .shell: return "terminal"
        default: return customSymbol ?? "cpu"
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

    /// Sessions in display order — the single source of truth for row↔session
    /// mapping. A row index is simply an index into this array; there is no
    /// per-row identity object (NSTableView addresses rows by integer index).
    private(set) var displayedSessionIDs: [UUID] = []
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
    private let emptyStateSpinner = NSProgressIndicator()
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
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        // Sessions drag onto the detail area's panes (split or replace there).
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.menuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
        outline.onDeleteKey = { [weak self] in self?.closeSelectedSession() }
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

        emptyStateSpinner.style = .spinning
        emptyStateSpinner.controlSize = .small
        emptyStateSpinner.isDisplayedWhenStopped = false
        emptyStateSpinner.translatesAutoresizingMaskIntoConstraints = false
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
            self.lastActiveSession = { if case let .session(id) = sel { return id } else { return nil } }()
            self.syncSelection(sel)
            // Bold the newly-active session immediately (and un-bold the previous
            // unless it's still live) — no wait for the terminal to launch.
            self.refreshActive(previous)
            self.refreshActive(self.lastActiveSession)
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
            self.backgroundCounts = tasks.mapValues { $0.filter(\.isRunning).count }
        }.store(in: &cancellables)
        controller.$runtimes.dropFirst().sink { [weak self] runtimes in
            self?.runtimesChanged(runtimes)
        }.store(in: &cancellables)
        // Tick the work timer label on working rows via the workspace clock.
        controller.$clockTick.dropFirst()
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
        for id in displayedSessionIDs where controller.runtime(id)?.lastActivityAt != nil {
            updateSessionRow(id)
        }
    }

    private var lastRuntimes: [UUID: SessionRuntime] = [:]

    private func runtimesChanged(_ new: [UUID: SessionRuntime]) {
        var needsReorder = false
        for id in Set(new.keys).union(lastRuntimes.keys) where new[id] != lastRuntimes[id] {
            if new[id]?.isLive != lastRuntimes[id]?.isLive {
                // isLive drives name weight — needs a full cell reconfigure.
                if !reloading, let row = displayedSessionIDs.firstIndex(of: id) {
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
        guard let id, let row = displayedSessionIDs.firstIndex(of: id),
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionCellView
        else { return }
        cell.setActive(isActive(id))
    }

    /// Update a session row's runtime bits *in place* (no cell rebuild), so the
    /// working sweep animates continuously instead of restarting each poll.
    private var backgroundCounts: [UUID: Int] = [:]

    private func updateSessionRow(_ id: UUID) {
        guard !reloading, let row = displayedSessionIDs.firstIndex(of: id),
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
        guard !searchQuery.isEmpty else { return true }
        let q = searchQuery.lowercased()
        if session.name.lowercased().contains(q) { return true }
        if session.agent.displayName.lowercased().contains(q) { return true }
        if let name = workdirName(for: session), name.lowercased().contains(q) { return true }
        return false
    }

    // MARK: Reload (preserving selection)

    private func reload() {
        guard !reloading else { return }
        reloading = true
        defer { reloading = false }

        displayedSessionIDs = controller.orderedSessions.filter(matchesSearch).map(\.id)
        outline.reloadData()
        applySelectionToOutline()
        updateEmptyState()
    }

    private func applySelectionToOutline() {
        if case let .session(id) = controller.selection, let row = displayedSessionIDs.firstIndex(of: id) {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
    }

    /// Move the outline highlight to match `sel` (programmatic selection), with
    /// a guard so the resulting `selectionDidChange` doesn't write back.
    private func syncSelection(_ sel: SidebarSelection?) {
        guard !reloading else { return }
        var targetRow = -1
        if case let .session(id) = sel, let row = displayedSessionIDs.firstIndex(of: id) {
            targetRow = row
            updateSessionRow(id)   // selecting a session marks it seen — clear the dot
        }
        guard targetRow != outline.selectedRow else { return }
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
    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, row < displayedSessionIDs.count else { return }
        controller.selection = .session(displayedSessionIDs[row])
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
        let here = NSMenuItem(title: controller.workspace.rootURL.lastPathComponent,
                              action: nil, keyEquivalent: "")
        here.image = controller.rootProfile.menuImage()
        here.state = .on
        here.isEnabled = false
        menu.addItem(here)

        // Most recently opened folders (all of them live in the Open Workspace
        // browser, reachable via "See More…").
        let others = RootFolderStore.byRecency().filter { $0.path != current }
        if !others.isEmpty {
            menu.addItem(.separator())
            for profile in others.prefix(RecentRootsMenu.shortListCount) {
                let item = NSMenuItem(title: profile.name,
                                      action: #selector(openRecentRoot(_:)), keyEquivalent: "")
                item.target = self
                item.image = profile.menuImage()
                item.toolTip = profile.path
                item.representedObject = profile.url
                menu.addItem(item)
            }
            let more = NSMenuItem(title: others.count > RecentRootsMenu.shortListCount
                                    ? "See More… (\(others.count))" : "See More…",
                                  action: #selector(seeMoreFromMenu), keyEquivalent: "o")
            more.target = self
            more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
            menu.addItem(more)
        }

        menu.addItem(.separator())
        let dup = NSMenuItem(title: "Duplicate Window", action: #selector(duplicateWindowFromMenu),
                             keyEquivalent: "n")
        dup.keyEquivalentModifierMask = [.command, .shift]
        dup.target = self
        dup.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
        menu.addItem(dup)
        let open = NSMenuItem(title: "Open Folder…", action: #selector(openFolderFromMenu),
                              keyEquivalent: "n")
        open.keyEquivalentModifierMask = [.command, .option]
        open.target = self
        open.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        menu.addItem(open)

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
        openInConsole(Log.fileURL)
    }

    private func openDaemonLog() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logURL = home.appendingPathComponent(
            "Library/Application Support/com.docker.sandboxes/sandboxes/sandboxd/daemon.log")
        openInConsole(logURL)
    }

    private func openInConsole(_ logURL: URL) {
        let consoleURL = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        if FileManager.default.fileExists(atPath: consoleURL.path) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([logURL], withApplicationAt: consoleURL, configuration: cfg) { _, error in
                if let error {
                    Log.error(.app, "open Console failed: \(error.localizedDescription)")
                    DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
                }
            }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        }
    }

    private var statusDebugWindow: StatusDebugWindowController?

    private func openStatusDebugWindow() {
        if statusDebugWindow == nil {
            statusDebugWindow = StatusDebugWindowController(controller: controller)
        }
        statusDebugWindow?.show()
    }

    /// Present the per-root settings inspector (gear next to Search, and ⌘,) as a
    /// native macOS sheet — a fixed-size SwiftUI view; Close or Esc dismisses it.
    /// No-op if a sheet is already up (so ⌘, doesn't stack inspectors).
    @objc func presentInspector() { presentInspector(pane: .general) }

    func presentInspector(pane: InspectorPane) {
        guard presentedViewControllers?.isEmpty != false else { return }
        var sheet: NSViewController?
        let inspector = InspectorView(controller: controller, initialPane: pane, onClose: { sheet?.dismiss(nil) })
        let hosting = NSHostingController(rootView: inspector)
        sheet = hosting
        presentAsSheet(hosting)
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
        let folders = NSMenuItem(title: "In Folder", action: nil, keyEquivalent: "")
        folders.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folders.submenu = folderSubmenu()
        items.append(folders)
        items.append(.separator())
        let search = NSMenuItem(title: "Search Sessions…", action: #selector(showSearchFromMenu(_:)), keyEquivalent: "")
        search.target = self
        search.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        search.representedObject = defaultFolder
        items.append(search)
        return items
    }

    /// New chats, "New <Agent>" for the builtins + custom agents, and shells attached to an
    /// agent's sandbox — all in `folderID`.
    private func newSessionActions(folderID: UUID) -> [NSMenuItem] {
        func action(_ title: String, _ icon: NSImage?, _ req: NewSessionRequest) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(addSessionFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.image = icon
            item.representedObject = req
            return item
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
        let terminal = NSMenuItem(title: "In Terminal", action: nil, keyEquivalent: "")
        terminal.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        let terminalMenu = NSMenu()
        for agent in SbxCommand.acpAgents {
            terminalMenu.addItem(action("New \(agent.displayName) in Terminal", agent.menuIcon,
                                        NewSessionRequest(folderID: folderID, agent: agent)))
        }
        terminal.submenu = terminalMenu
        items.append(terminal)
        let others = AgentKind.builtins.filter { !featured.contains($0) }
        if !others.isEmpty {
            let more = NSMenuItem(title: "Other Agents", action: nil, keyEquivalent: "")
            more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
            let sub = NSMenu()
            for agent in others {
                sub.addItem(action("New \(agent.displayName)", agent.menuIcon,
                                   NewSessionRequest(folderID: folderID, agent: agent)))
            }
            more.submenu = sub
            items.append(more)
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
    private func folderSubmenu() -> NSMenu {
        let menu = NSMenu()
        for folder in controller.folders {
            let item = NSMenuItem(title: controller.displayName(for: folder), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let sub = NSMenu()
            for action in newSessionActions(folderID: folder.id) { sub.addItem(action) }
            item.submenu = sub
            menu.addItem(item)
        }
        if !controller.folders.isEmpty { menu.addItem(.separator()) }
        menu.addItem(menuItem("Add Folder…", #selector(newFolderClicked)))
        menu.addItem(menuItem("Choose Existing Folder…", #selector(addExistingFolderClicked)))
        return menu
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

    func closeSelectedSession() {
        if case let .session(id) = controller.selection { controller.closeSession(id) }
    }

    // MARK: Context menu — Drops

    private func dropsSubmenuItem(for folderID: UUID) -> NSMenuItem {
        let parent = NSMenuItem(title: "Drops", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(menuItem("Show Changed Files in Finder",
                             #selector(contextShowChangedDrops), object: folderID))
        sub.addItem(menuItem("Open Terminal to Changed Files",
                             #selector(contextOpenTerminalToDrops), object: folderID))
        parent.submenu = sub
        return parent
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
        let sbx = controller.folderURL(for: folder).appendingPathComponent(".sbx", isDirectory: true)
        let drops = sbx.appendingPathComponent("drops", isDirectory: true)
        let staging = sbx.appendingPathComponent("drops-changed-\(Int(Date().timeIntervalSince1970))",
                                                  isDirectory: true)
        return (drops, staging)
    }

    // MARK: Context menu

    private func contextMenu(forRow row: Int) -> NSMenu? {
        let menu = NSMenu()
        guard row >= 0, row < displayedSessionIDs.count,
              let session = controller.session(id: displayedSessionIDs[row]) else {
            // Empty-area click: offer the same menu as the "+" button.
            for item in newSessionMenuItems() { menu.addItem(item) }
            return menu
        }
        menu.addItem(menuItem("Close Session", #selector(contextCloseSession), object: session.id))
        menu.addItem(menuItem("Open Files in Split", #selector(contextOpenFiles), object: session.id))
        if SbxCommand.supportsACP(session.agent) {
            menu.addItem(menuItem(session.isChat ? "Show as Terminal" : "Show as Chat",
                                  #selector(contextToggleChat), object: session.id))
        }
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

    private func menuItem(_ title: String, _ action: Selector, object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }

    @objc private func contextOpenFiles(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onOpenFilesInSplit?(id) }
    }

    @objc private func contextCloseSession(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { controller.closeSession(id) }
    }

    fileprivate func closeSessionFromRow(_ id: UUID) { controller.closeSession(id) }
}

// MARK: - Data source

extension SidebarListController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { displayedSessionIDs.count }

    /// A session row drags out as a session (onto a pane edge: split there).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row >= 0, row < displayedSessionIDs.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(displayedSessionIDs[row].uuidString, forType: .sandshellSession)
        return item
    }

    /// Files dragged onto a session row attach to that session (chat: as
    /// attachments; terminal: as sandbox-readable paths).
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard !displayedSessionIDs.isEmpty,
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) else { return [] }
        tableView.setDropRow(min(max(row, 0), displayedSessionIDs.count - 1), dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard row >= 0, row < displayedSessionIDs.count,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(displayedSessionIDs[row], urls)
        return true
    }
}

// MARK: - Delegate (cells, selection)

extension SidebarListController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarRowView(theme: sidebarTheme, drawsSelection: true)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 50 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayedSessionIDs.count else { return nil }
        let id = displayedSessionIDs[row]
        let cell = SessionCellView(owner: self)
        cell.sessionID = id
        if let session = controller.session(id: id) {
            cell.configure(
                session,
                runtime: controller.runtime(id),
                unread: controller.runtime(id)?.isUnread ?? false,
                active: isActive(id),
                theme: sidebarTheme,
                workdirName: workdirName(for: session),
                backgroundCount: controller.runningBackgroundTasks(id))
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, !settingSelection else { return }
        let row = outline.selectedRow
        let newSelection: SidebarSelection? = (row >= 0 && row < displayedSessionIDs.count)
            ? .session(displayedSessionIDs[row]) : nil
        if controller.selection != newSelection { controller.selection = newSelection }
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
            (theme.isDark ? NSColor.white(0.10) : theme.selection).setFill()
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
        field.target = self
        field.action = #selector(changed)

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

    @objc private func changed() { onChange?(field.stringValue) }

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

        let metaRow = NSStackView(views: [statusSlot, timeLabel, subLabel])
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

    func configure(_ session: Session, runtime: SessionRuntime?, unread: Bool, active: Bool,
                   theme: ThemeColors, workdirName: String?, backgroundCount: Int = 0) {
        agentLabel = session.agent.displayName
        self.workdirName = workdirName
        accent = theme.accent
        fg = theme.sidebarFg
        badge.configure(session.agent)
        nameLabel.stringValue = session.name
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
        nameLabel.textColor = active ? fg : fg.withAlphaComponent(0.55)
    }

    /// Update the runtime-driven bits (left-rail sweep/dot + time, subline) in
    /// place — no cell rebuild, so frequent polls don't churn the row.
    func updateRuntime(_ runtime: SessionRuntime?, unread: Bool) {
        var parts = [agentLabel]
        if let workdirName { parts.append(workdirName) }
        let work = runtime.flatMap { compactWorkTime($0.liveWorkSeconds()) }
        switch runtime?.stoppedReason == nil ? runtime?.status : nil {
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
            parts.append(runtime?.lastActivityAt.map { relativeActivity($0) } ?? "Ready")
        default:
            workingView.stopAnimating()
            workingView.isHidden = true
            statusDot.isHidden = true
            timeLabel.isHidden = true
        }
        if runtime?.stoppedReason != nil { parts.append("Stopped") }
        if backgroundRunning > 0 { parts.append("\(backgroundRunning) in background") }
        subLabel.stringValue = parts.joined(separator: " · ")
        subLabel.toolTip = runtime?.stoppedReason
    }

    private func syncHover() {
        let hovered = window?.isKeyWindow == true
            && bounds.contains(convert(window!.mouseLocationOutsideOfEventStream, from: nil))
        closeButton.isHidden = !hovered
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
}

/// Coarse relative time for the session subline: "just now" → "2m ago" → "3h ago".
func relativeActivity(_ date: Date, now: Date = Date()) -> String { Format.ago(date, now: now) }
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
