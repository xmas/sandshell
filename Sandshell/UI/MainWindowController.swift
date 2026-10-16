import AppKit
import Combine
import SwiftUI

/// The main Finder-style window: a source-list sidebar of the workspace's
/// projects/sessions plus a detail pane, driven by `WorkspaceController`.
@MainActor
final class MainWindowController: NSWindowController {
    private var workspace: WorkspaceController?
    private var sidebar: SidebarListController?
    private var themeObserver: AnyCancellable?
    private var sidebarItem: NSSplitViewItem?
    /// Files pane (tree + editor) on the trailing edge; follows the active session.
    private var filesPane: FilesPaneController?
    private var filesItem: NSSplitViewItem?
    private var selectionObserver: AnyCancellable?
    private static let filesVisibleKey = "filesPaneVisible"
    private var detail: PaneTreeController?
    /// This workspace's Search window (⇧⌘F), created on first use.
    private var searchWindow: SearchWindowController?
    private var collapseObservation: NSKeyValueObservation?
    // Native-toolbar identity + live status, updated from the detail controller.
    private let toolbarBadge = AgentBadgeView(side: 26, fontSize: 11, radius: 8)
    private let toolbarName = NSTextField(labelWithString: "")
    private let toolbarSubtitle = NSTextField(labelWithString: "")
    private let toolbarStatus = NSTextField(labelWithString: "")
    /// The single, persistent identity view (badge + name/subtitle). Built once
    /// and handed ONLY to the inserted toolbar item (see the `flag` gate in the
    /// toolbar delegate) so NSToolbar's palette/measurement passes can't
    /// re-parent its shared subviews and leave the live item blank.
    private lazy var identityItemView: NSStackView = {
        for label in [toolbarName, toolbarSubtitle] {
            label.setContentCompressionResistancePriority(.init(40), for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [toolbarName, toolbarSubtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let stack = NSStackView(views: [toolbarBadge, text])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        // 200–360 pt, as wide as it can be: a long session name truncates
        // instead of blowing the whole toolbar into the overflow menu.
        // Priorities sit under fittingSizeCompression (50), so the toolbar
        // measures the item at its 200 pt minimum, yet once laid out the labels
        // (40) truncate before they spill past the stack's edge (45) over the
        // status and buttons beside it. Clipping is the last resort.
        stack.setHuggingPriority(.init(1), for: .horizontal)
        // The name column takes all the room after the badge; hugging its
        // content, it shrank to the subtitle's width and cut a name that fit.
        stack.distribution = .fill
        text.setHuggingPriority(.init(1), for: .horizontal)
        stack.setClippingResistancePriority(.init(45), for: .horizontal)
        text.setClippingResistancePriority(.init(45), for: .horizontal)
        stack.clipsToBounds = true
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            stack.heightAnchor.constraint(equalToConstant: 32),
        ])
        return stack
    }()
    /// The workspace root this window is bound to (window-per-folder).
    let root: URL
    /// This window's theme controller (for chrome that opens its own windows,
    /// e.g. the host/debug terminals).
    var theme: ThemeController? { workspace?.theme }
    /// Top-left seed for cascading brand-new workspace windows (those without a
    /// remembered frame), so they don't open exactly on top of one another.
    private static var lastCascadePoint: NSPoint?
    /// Open another folder in its own window (set by `AppDelegate`).
    var onOpenWorkspace: ((URL) -> Void)?
    /// Called when this window closes so `AppDelegate` can drop it from its
    /// per-folder registry (lets the folder reopen later).
    var onClose: (() -> Void)?

    /// Distinguishes duplicate windows on the same root so their frame-autosave
    /// names don't collide (index 0 keeps the legacy per-root name).
    let instanceIndex: Int

    init(root: URL, instanceIndex: Int = 0) {
        self.root = root
        self.instanceIndex = instanceIndex
        let window = TrafficLightInsetWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // With the native toolbar, let AppKit place the traffic lights itself
        // (the custom inset fought the toolbar and dragged them into the sidebar).
        window.trafficLightInset = .zero
        window.title = root.lastPathComponent
        // We restore windows ourselves (AppDelegate + OpenWindows); opt out of
        // macOS's automatic state restoration so it never re-presents a sheet
        // (e.g. the per-root inspector) that was open at quit.
        window.isRestorable = false
        // Merge the title bar into the content so the sidebar header reads as the
        // window's title area (window controls float over the sidebar top).
        // Identity lives in a custom toolbar item (badge + name/subtitle), so the
        // native window title stays hidden.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Per-root frame autosave so each folder's window remembers its own size.
        // Duplicate windows on the same root use a suffixed name so they don't
        // fight over one stored frame (and instead cascade — see below).
        window.setFrameAutosaveName(
            instanceIndex == 0 ? "MainWindow-\(root.path)" : "MainWindow-\(root.path)#\(instanceIndex)")
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        // Open this folder's workspace before building the views that bind to it.
        guard let controller = try? WorkspaceController.open(root: root) else {
            fatalError("Sandshell: could not open the workspace at \(root.path)")
        }
        workspace = controller

        let split = NSSplitViewController()

        let sidebarVC = SidebarListController(controller: controller)
        self.sidebar = sidebarVC
        sidebarVC.onOpenWorkspace = { [weak self] r in self?.onOpenWorkspace?(r) }
        sidebarVC.onOpenFilesInSplit = { [weak self] id in
            guard let s = self?.workspace?.session(id: id) else { return }
            self?.detail?.openFiles(FilesTarget(session: id, folder: s.workdir))
        }
        sidebarVC.onShowSearch = { [weak self] folder in self?.showSearch(preferredFolder: folder) }
        sidebarVC.onDropFiles = { [weak self] id, urls in
            self?.workspace?.selection = .session(id)
            self?.detail?.dropFiles(urls, on: id)
        }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        // Resizable within a range; collapses (auto-collapses when dragged below
        // the minimum, since it's a sidebar item with canCollapse).
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 460
        sidebarItem.canCollapse = true
        self.sidebarItem = sidebarItem
        split.addSplitViewItem(sidebarItem)

        let detail = PaneTreeController(controller: controller)
        self.detail = detail
        detail.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        detail.newSessionMenu = { [weak self] in self?.sidebar?.newSessionMenu() }
        // Drive the toolbar identity (badge + name/subtitle) from the active
        // session; fall back to the folder name when nothing is selected.
        detail.onChromeChange = { [weak self] chrome in
            guard let self else { return }
            // The window title feeds the Window menu (and Mission Control), where
            // several folders' windows sit side by side — so it always carries
            // the folder name. The visible titlebar is hidden; the toolbar shows
            // only the session (the sidebar header already names the folder).
            let folder = self.root.lastPathComponent
            if let chrome {
                self.toolbarBadge.isHidden = chrome.agent == nil
                if let agent = chrome.agent { self.toolbarBadge.configure(agent) }
                self.toolbarName.stringValue = chrome.title
                self.toolbarSubtitle.stringValue = chrome.subtitle
                self.window?.title = "\(folder) — \(chrome.title)"
            } else {
                self.toolbarBadge.isHidden = true
                self.toolbarName.stringValue = ""
                self.toolbarSubtitle.stringValue = ""
                self.window?.title = folder
            }
        }
        // Live "Working ◷ …" / "Ready" status in the toolbar (green while working).
        detail.onStatusChange = { [weak self] text, working in
            guard let self else { return }
            self.toolbarStatus.stringValue = text
            self.toolbarStatus.textColor = working ? .hex("16a34a") : .secondaryLabelColor
        }
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 420
        split.addSplitViewItem(detailItem)

        let files = FilesPaneController()
        self.filesPane = files
        files.onAddToChat = { [weak self] urls in
            guard let self, case .session(let id)? = self.workspace?.selection else { return }
            self.detail?.dropFiles(urls, on: id)
        }
        files.onAskAgent = { [weak self] text in
            guard let self, case .session(let id)? = self.workspace?.selection else { return NSSound.beep() }
            self.detail?.askAgent(text, on: id)
        }
        let filesItem = NSSplitViewItem(inspectorWithViewController: files)
        filesItem.minimumThickness = 480
        filesItem.maximumThickness = 1600
        filesItem.canCollapse = true
        filesItem.isCollapsed = !UserDefaults.standard.bool(forKey: Self.filesVisibleKey)
        self.filesItem = filesItem
        split.addSplitViewItem(filesItem)
        // Follow the active session's folder (the workspace root otherwise).
        selectionObserver = controller.$selection.sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncFilesRoot() }
        }

        // Keep the detail header's toggle (icon + leading inset for the traffic
        // lights) in sync however the sidebar collapses — button, ⌥1/⌥2, or drag.
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak detail] item, _ in
            let collapsed = item.isCollapsed
            Task { @MainActor in detail?.setSidebarCollapsed(collapsed) }
        }

        window.contentViewController = split
        // Native window toolbar for the session actions (reveal/stop/restart),
        // reorderable + customizable; and, in DEBUG, a construction-tape banner.
        installMainToolbar()
        installDebugTapeIfNeeded()
        window.setContentSize(NSSize(width: 1000, height: 640))
        // Restore this folder's remembered frame; for a folder opened for the
        // first time, center the first window and cascade subsequent ones so
        // multiple workspaces don't stack exactly on top of each other.
        if !window.setFrameUsingName(window.frameAutosaveName) {
            if let last = Self.lastCascadePoint {
                Self.lastCascadePoint = window.cascadeTopLeft(from: last)
            } else {
                window.center()
                Self.lastCascadePoint = window.cascadeTopLeft(from: .zero)
            }
        }

        // Light/Dark/System is global (`AppAppearance` sets `NSApp.appearance`),
        // so the window inherits it automatically — we only theme the chrome
        // colors (titlebar continuous with the detail background) and repaint when
        // the resolved palette changes.
        applyWindowTheme(controller.theme.colors)
        themeObserver = controller.theme.$colors.dropFirst().sink { [weak self] c in
            self?.applyWindowTheme(c)
        }

        // First open: configure mounts before bringing the container up.
        if controller.needsConfiguration {
            presentMountConfig(for: controller)
        } else {
            controller.openPrimaryContainer()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Tint the window background to the detail background color so the
    /// transparent titlebar reads as the same color as the chrome below it.
    private func applyWindowTheme(_ colors: ThemeColors) {
        // The transparent titlebar shows the window background; use the title-bar
        // color (== panel normally, the selected Main color when matching terminal).
        window?.backgroundColor = colors.titleBar
    }

    // MARK: - Toolbar + debug construction tape

    /// Attach the native, user-customizable window toolbar (its items are built by
    /// the `NSToolbarDelegate` conformance below).
    private func installMainToolbar() {
        toolbarName.font = .systemFont(ofSize: 13.5, weight: .semibold)
        toolbarName.lineBreakMode = .byTruncatingTail
        toolbarSubtitle.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        toolbarSubtitle.textColor = .secondaryLabelColor
        toolbarSubtitle.lineBreakMode = .byTruncatingMiddle
        toolbarStatus.font = .systemFont(ofSize: 12, weight: .medium)
        toolbarStatus.textColor = .secondaryLabelColor
        toolbarStatus.setContentHuggingPriority(.init(1), for: .horizontal)
        NSLayoutConstraint.activate([
            toolbarStatus.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            toolbarStatus.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
        ])
        toolbarName.stringValue = ""   // no session yet: the sidebar header names the folder
        toolbarBadge.isHidden = true

        // Identifier is versioned so an item-set change discards the stale
        // autosaved arrangement (which otherwise pins items to old positions).
        // Bump the version when default items change: autosaved configurations
        // would otherwise hide new items (v3 added the Chat/Terminal toggle, v5
        // Search).
        let toolbar = NSToolbar(identifier: "MainWindowToolbar.v5")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
        // Center the traffic lights on the toolbar's identity item (AppKit's
        // default on the macOS 27 SDK toolbar sits low, crowding the sidebar header).
        (window as? TrafficLightInsetWindow)?.trafficLightAlignmentView = identityItemView
    }

    /// DEBUG-only: a faint construction-tape watermark inserted **behind** the
    /// toolbar (into the titlebar view), so a debug build is unmistakable without
    /// adding a separate band. Shown regardless of session state — it's chrome.
    private func installDebugTapeIfNeeded() {
#if DEBUG
        // The titlebar view is the superview of the standard window buttons; with
        // `titlebarAppearsTransparent` a subview at the back shows through behind
        // the toolbar items. autoresizes to track the titlebar+toolbar height.
        guard let titlebar = window?.standardWindowButton(.closeButton)?.superview else { return }
        // A 5pt-tall hazard stripe pinned to the very top of the titlebar
        // (full width), behind the toolbar items. Auto Layout so "top" is
        // unambiguous regardless of the titlebar view's coordinate flip.
        let stripe = ConstructionTapeView(frame: .zero)
        stripe.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(stripe, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            stripe.topAnchor.constraint(equalTo: titlebar.topAnchor),
            stripe.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor),
            stripe.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor),
            stripe.heightAnchor.constraint(equalToConstant: 5),
        ])
#endif
    }

    /// Present the mount-config sheet for first-time workspace setup.
    private func presentMountConfig(for controller: WorkspaceController) {
        guard let host = window?.contentViewController else { return }
        let model = MountConfigModel(
            home: controller.home, root: controller.workspace.rootURL, policy: controller.policy)
        var sheet: NSViewController?
        let view = MountConfigView(
            model: model,
            confirmTitle: "Create Workspace",
            confirmInfo: "Creates this workspace’s sandbox container with the selected mounts. "
                + "You can change mounts later in Settings ▸ Mounts.",
            onConfirm: { policy in
                sheet?.dismiss(nil)
                controller.applyConfiguration(policy: policy)
            },
            onCancel: { sheet?.dismiss(nil) }
        )
        let hosting = NSHostingController(rootView: view)
        sheet = hosting
        host.presentAsSheet(hosting)
    }

    /// ⌘N — create a new session in the current context (same folder + agent).
    func newSession() {
        workspace?.newSessionInCurrentContext()
    }

    /// App quit: kill this window's session processes (no windowWillClose then).
    func prepareForQuit() { detail?.teardown() }

    func newChat(agent: AgentKind = .claude) {
        workspace?.newChatInCurrentContext(agent: agent)
    }

    #if DEBUG
    /// Self-test access (see SelfTest).
    var paneTree: PaneTreeController? { detail }

    #if DEBUG
    /// Self-test: the toolbar's identity and status views' widths.
    var debugToolbarWidths: (identity: CGFloat, status: CGFloat, visible: Int, items: Int) {
        (identityItemView.frame.width, toolbarStatus.frame.width,
         window?.toolbar?.visibleItems?.count ?? -1, window?.toolbar?.items.count ?? -1)
    }
    /// Self-test: set the toolbar's session name, then the name label's width
    /// against the identity item's.
    var debugToolbarNameFits: Bool {
        toolbarName.alignmentRect(forFrame: toolbarName.frame).width >= toolbarName.intrinsicContentSize.width - 6
    }
    func debugToolbarName(_ name: String, subtitle: String? = nil) -> (label: CGFloat, identity: CGFloat) {
        toolbarName.stringValue = name
        if let subtitle { toolbarSubtitle.stringValue = subtitle }
        identityItemView.layoutSubtreeIfNeeded()
        // The alignment rect: a label's frame runs 2 pt past its text each side.
        let text = toolbarName.alignmentRect(forFrame: toolbarName.frame)
        let label = toolbarName.superview?.convert(text, to: identityItemView) ?? text
        return (label.maxX, identityItemView.bounds.width)
    }
    #endif
    var inspectorFiles: FilesPaneController? { filesPane }
    var workspaceController: WorkspaceController? { workspace }
    var sidebarList: SidebarListController? { sidebar }
    var searchWindowController: SearchWindowController? { searchWindow }
    #endif

    // MARK: Panes (View ▸ Split Right / Split Down / Close Pane …)

    func splitRight() { detail?.splitFocused(.trailing) }
    func splitDown() { detail?.splitFocused(.bottom) }
    func closePane() { detail?.closeFocused() }
    func focusNextPane() { detail?.focusAdjacent(1) }
    func focusPreviousPane() { detail?.focusAdjacent(-1) }
    func equalizePanes() { detail?.equalize() }

    private var backgroundTasksPanel: BackgroundTasksWindowController?

    /// Window ▸ Background Tasks: every session's background work in this window.
    func showBackgroundTasks() {
        guard let workspace else { return }
        if backgroundTasksPanel == nil {
            backgroundTasksPanel = BackgroundTasksWindowController(
                controller: workspace, title: root.lastPathComponent,
                loadOutput: { [workspace] sid, task in await workspace.backgroundOutput(sid, task) },
                onSelectSession: { [weak self] id in
                    self?.workspace?.selection = .session(id)
                    self?.window?.makeKeyAndOrderFront(nil)
                })
        }
        backgroundTasksPanel?.showWindow(nil)
    }

    /// New Claude chat seeded with text/files (Services, Shortcuts); `send`
    /// submits it as soon as the agent is ready.
    func newChat(draft: String, urls: [URL], send: Bool) {
        guard let session = workspace?.newChatInCurrentContext() else { return }
        detail?.queueDraft(draft, urls: urls, send: send, for: session.id)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Adopt `prefs` as this window's appearance ("Apply to All" from the
    /// per-root inspector). Persists to this root's config and re-themes live.
    func applyTheme(_ prefs: ThemePreferences) {
        workspace?.theme.prefs = prefs
    }

    /// Sidebar show/hide (⌥1 hides → terminal only, ⌥2 shows; header button toggles).
    func setSidebarCollapsed(_ collapsed: Bool) {
        guard let item = sidebarItem, item.isCollapsed != collapsed else { return }
        item.animator().isCollapsed = collapsed
    }
    func toggleSidebar() { setSidebarCollapsed(!(sidebarItem?.isCollapsed ?? false)) }

    /// View ▸ Show Files (⌥⌘0) / toolbar: the session folder's tree + editor.
    func toggleFiles() {
        guard let item = filesItem else { return }
        let show = item.isCollapsed
        NSAnimationContext.runAnimationGroup { _ in item.animator().isCollapsed = !show }
        UserDefaults.standard.set(show, forKey: Self.filesVisibleKey)
        syncFilesRoot()
    }

    /// Toolbar Files button: click toggles the trailing Files pane;
    /// ⌥-click opens Files in a split beside the focused pane instead.
    @objc func toggleFilesFromToolbar() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true { openFilesInSplit() } else { toggleFiles() }
    }

    /// View ▸ Open Files in Split (⇧⌥⌘0): the focused session's folder as a pane.
    func openFilesInSplit() {
        guard let detail else { return }
        detail.openFiles(detail.defaultFilesTarget())
    }

    /// File ▸ Open Quickly (⇧⌘O) when no Files surface has focus: the focused
    /// Files pane, else the trailing Files pane (shown if needed), else any.
    func openQuickly() {
        if let files = detail?.focusedFiles { return files.openQuickly(nil) }
        if let item = filesItem, !item.isCollapsed, let files = filesPane { return files.openQuickly(nil) }
        if let files = detail?.anyFiles { return files.openQuickly(nil) }
        toggleFiles()
        // After the inspector's expand animation, so the popover anchors in place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.filesPane?.openQuickly(nil) }
    }

    private func syncFilesRoot() {
        guard let workspace, let filesItem, !filesItem.isCollapsed else { return }
        var folder = workspace.rootURL
        var agent = workspace.primaryAgent
        if case .session(let id) = workspace.selection, let s = workspace.session(id: id) {
            folder = URL(fileURLWithPath: s.workdir)
            agent = s.containerAgentKind
        }
        filesPane?.setRoot(folder, access: workspace.sandboxAccess(for: folder, agent: agent))
    }

    /// ⇧⌘F / sidebar footer / toolbar: search this workspace's open sessions and
    /// the past conversations that can be restored into it.
    func showSearch(preferredFolder: UUID? = nil) {
        guard let workspace else { return }
        let search = searchWindow ?? SearchWindowController(workspace: workspace, mainWindow: window)
        searchWindow = search
        search.preferredFolder = preferredFolder
        search.show()
    }

    @objc func showSearchFromToolbar() { showSearch() }

    /// ⌘, — open the per-root settings inspector sheet (all settings live there).
    func showSettings() {
        sidebar?.presentInspector()
    }

    /// Cycle the selected session (`+1` next / `-1` previous).
    func cycleSession(_ delta: Int) {
        workspace?.selectAdjacentSession(delta)
    }

    /// Navigate to a session by ID. Returns true if this window owns the session.
    /// Used by notification taps to jump back to the finished session.
    @discardableResult
    func selectSession(_ id: UUID) -> Bool {
        guard workspace?.session(id: id) != nil else { return false }
        workspace?.selection = .session(id)
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    /// ⌘W closes the selected session, falling back to closing the window.
    func closeSessionOrWindow() {
        if let workspace, case let .session(id) = workspace.selection {
            workspace.closeSession(id)
        } else {
            window?.performClose(nil)
        }
    }

    @discardableResult
    func insertExternalItems(_ urls: [URL]) -> Bool {
        detail?.insertExternalItems(urls) ?? false
    }

    func scriptingStatus() -> WindowScriptStatus {
        let selection: String?
        if let workspace {
            switch workspace.selection {
            case .session(let id): selection = "session:\(id.uuidString)"
            case nil: selection = nil
            }
        } else {
            selection = nil
        }
        let sessions = workspace?.orderedSessions.map { session -> SessionScriptStatus in
            let rt = workspace?.runtime(session.id)
            return SessionScriptStatus(
                id: session.id.uuidString,
                name: session.name,
                agent: session.agent.rawValue,
                workdir: session.workdir,
                status: rt?.status == .working ? "working" : "ready",
                isLive: rt?.isLive ?? false,
                isUnread: rt?.isUnread ?? false,
                workSeconds: rt?.liveWorkSeconds() ?? 0,
                transcriptID: session.transcriptID,
                backgroundRunning: workspace?.runningBackgroundTasks(session.id) ?? 0)
        } ?? []
        return WindowScriptStatus(
            root: root.path,
            title: window?.title ?? "",
            isKey: window?.isKeyWindow ?? false,
            selection: selection,
            sessions: sessions,
            sidebarSessionIDs: sidebar?.displayedSessionIDs.map(\.uuidString) ?? [],
            isBuilding: workspace?.isBuilding ?? false,
            activity: workspace?.activity,
            emptyState: sidebar?.emptyStateText)
    }
}

/// A window that insets its traffic-light buttons from the native top-left
/// corner. AppKit re-lays out the standard buttons on every layout pass, so we
/// capture their native origins once and re-apply our offset after each pass.
final class TrafficLightInsetWindow: NSWindow {
    /// Extra padding added to the native button position (points right + down).
    var trafficLightInset: NSSize = .zero { didSet { layoutTrafficLights() } }
    /// When set, the traffic lights are re-centered vertically on this view
    /// (e.g. the toolbar's identity item) instead of AppKit's default, which on
    /// the macOS 27 SDK toolbar sits noticeably below the toolbar items and
    /// crowds the sidebar header. `trafficLightInset` still applies on top.
    weak var trafficLightAlignmentView: NSView? { didSet { layoutTrafficLights() } }

    private static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private var nativeOrigins: [NSWindow.ButtonType: NSPoint] = [:]
    private var positioning = false

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutTrafficLights()
    }

    private func layoutTrafficLights() {
        guard trafficLightInset != .zero || trafficLightAlignmentView != nil, !positioning else { return }
        positioning = true
        defer { positioning = false }
        // Target center (in the buttons' superview coordinates) from the
        // alignment view, if it is laid out and in this window.
        var targetMidY: CGFloat?
        if let align = trafficLightAlignmentView, align.window === self, !align.bounds.isEmpty,
           let titlebar = standardWindowButton(.closeButton)?.superview {
            let r = align.convert(align.bounds, to: titlebar)
            if r.height > 0 { targetMidY = r.midY }
        }
        for type in Self.buttonTypes {
            guard let button = standardWindowButton(type) else { continue }
            // First sight of each button is its native (AppKit-assigned) origin.
            let native = nativeOrigins[type] ?? button.frame.origin
            nativeOrigins[type] = native
            // Superview is non-flipped (origin at bottom-left), so move down by
            // subtracting from y.
            let baseY = targetMidY.map { $0 - button.frame.height / 2 } ?? native.y
            button.setFrameOrigin(NSPoint(x: native.x + trafficLightInset.width,
                                          y: baseY - trafficLightInset.height))
        }
    }
}

extension MainWindowController: NSWindowDelegate {
    /// Tear down this window's terminals (kills their `sbx exec` + removes temp
    /// scripts), close its Settings window, and let `AppDelegate` forget it.
    func windowWillClose(_ notification: Notification) {
        detail?.teardown()
        searchWindow?.close()
        onClose?()
    }
}

private extension NSToolbarItem.Identifier {
    static let sidebarToggle  = NSToolbarItem.Identifier("sidebarToggle")
    static let identity       = NSToolbarItem.Identifier("identity")
    static let sessionStatus  = NSToolbarItem.Identifier("sessionStatus")
    static let revealFolder   = NSToolbarItem.Identifier("revealFolder")
    static let stopSession    = NSToolbarItem.Identifier("stopSession")
    static let restartSession = NSToolbarItem.Identifier("restartSession")
    static let chatToggle     = NSToolbarItem.Identifier("chatToggle")
    static let filesToggle    = NSToolbarItem.Identifier("filesToggle")
    static let search         = NSToolbarItem.Identifier("search")
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Our own sidebar toggle, not `.toggleSidebar`: the system item is a
        // bezeled button that renders as a glass capsule (and can hold a focus
        // ring) on macOS 26+/SDK 27 builds.
        // Chat ⇄ Terminal lives on each pane (title strip), not here.
        [.sidebarToggle, .identity, .flexibleSpace, .sessionStatus,
         .revealFolder, .stopSession, .restartSession, .search, .filesToggle]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarToggle, .identity, .sessionStatus, .filesToggle, .search,
         .revealFolder, .stopSession, .restartSession, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // Custom-view items: session identity (badge + name/subtitle) and status.
        // `flag` (willBeInsertedIntoToolbar) is true for the real item and false
        // for the customization palette / sizing pass; hand the shared live views
        // ONLY to the real item so the palette copy can't steal them (which left
        // the toolbar identity blank — see the identityItemView note).
        if itemIdentifier == .identity {
            let item = NSToolbarItem(itemIdentifier: .identity)
            item.view = flag ? identityItemView : NSTextField(labelWithString: "Session")   // width: see identityItemView
            item.visibilityPriority = .high
            // No bezel: on macOS 26+/SDK 27 a bordered item is wrapped in a Liquid
            // Glass capsule, which is not this app's look (xmas-sandshell-85c).
            item.isBordered = false
            return item
        }
        if itemIdentifier == .sessionStatus {
            toolbarStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let item = NSToolbarItem(itemIdentifier: .sessionStatus)
            item.view = flag ? toolbarStatus : NSTextField(labelWithString: "Status")
            item.isBordered = false
            return item
        }

        if itemIdentifier == .filesToggle {
            let item = NSToolbarItem(itemIdentifier: .filesToggle)
            item.label = "Files"
            item.paletteLabel = "Show Files"
            item.toolTip = "Show Files (⌥⌘0) — ⌥-click to open Files in a split"
            item.view = Self.plainToolbarButton(symbol: "sidebar.right", label: "Show Files",
                                                target: self, action: #selector(toggleFilesFromToolbar))
            return item
        }
        if itemIdentifier == .search {
            let item = NSToolbarItem(itemIdentifier: .search)
            item.label = "Search"
            item.paletteLabel = "Search Sessions"
            item.toolTip = "Search Sessions (⇧⌘F)"
            item.view = Self.plainToolbarButton(symbol: "magnifyingglass", label: "Search Sessions",
                                                target: self, action: #selector(showSearchFromToolbar))
            return item
        }
        if itemIdentifier == .sidebarToggle {
            let item = NSToolbarItem(itemIdentifier: .sidebarToggle)
            item.label = "Sidebar"
            item.paletteLabel = "Toggle Sidebar"
            item.toolTip = "Toggle Sidebar"
            item.view = Self.plainToolbarButton(symbol: "sidebar.left", label: "Toggle Sidebar",
                                                target: self, action: #selector(toggleSidebarFromToolbar))
            item.visibilityPriority = .high
            return item
        }

        let spec: (symbol: String, label: String, action: Selector)?
        switch itemIdentifier {
        case .revealFolder:
            spec = ("folder", "Reveal Folder", #selector(TerminalStackController.revealInFinderClicked))
        case .stopSession:
            spec = ("stop", "Stop", #selector(TerminalStackController.stopClicked))
        case .restartSession:
            spec = ("arrow.clockwise", "Restart", #selector(TerminalStackController.headerRestartClicked))
        case .chatToggle:
            // Icon/label flip with the active session (see validateToolbarItem).
            spec = ("bubble.left.and.text.bubble.right", "Show as Chat",
                    #selector(TerminalStackController.toggleChatClicked))
        default:
            spec = nil
        }
        guard let spec, let detail else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        item.label = spec.label
        item.paletteLabel = spec.label
        item.toolTip = spec.label
        // Plain glyphs, not bezeled buttons: bordered items get Liquid Glass
        // capsules (grouped into one pill) on macOS 26+/SDK 27 builds. These
        // stay image items (no custom view) so NSToolbarItemValidation keeps
        // enabling/disabling them with the active session.
        item.isBordered = false
        // Actions route to the detail controller's active session; it also
        // supplies enable/disable via NSToolbarItemValidation.
        item.target = detail
        item.action = spec.action
        return item
    }

    /// A borderless, non-focusable symbol button for toolbar items — the
    /// Sequoia-style glyph, with no bezel, glass capsule, or focus ring.
    private static func plainToolbarButton(symbol: String, label: String,
                                           target: AnyObject?, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        let button = NSButton(image: image ?? NSImage(), target: target, action: action)
        button.isBordered = false
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.setButtonType(.momentaryChange)
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    @objc private func toggleSidebarFromToolbar() { toggleSidebar() }
}
