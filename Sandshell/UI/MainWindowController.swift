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
    /// The Sandbox group follows its sandbox (running, stopped, busy).
    private var sandboxObserver: AnyCancellable?
    /// Sandbox ▸ Folder Access…'s popover.
    private var accessPopover: NSPopover?
    /// Whether this window's Files inspector is open (per folder and window).
    private var filesVisibleKey = "filesPaneVisible"
    private var detail: PaneTreeController?
    /// This workspace's Search window (⇧⌘F), created on first use.
    private var searchWindow: SearchWindowController?
    /// The focused session's sandbox, in the sidebar's header (there's no
    /// toolbar: the panes' strips are the title bar).
    private lazy var sandboxStatus: SandboxStatusButton = {
        let view = SandboxStatusButton()
        view.sandboxMenu = { [weak self] in self?.sandboxMenu() }
        return view
    }()
    /// Follows the Files sidebar however it collapses (toggle, menu, a drag).
    private var filesCollapseObserver: NSKeyValueObservation?
    /// Follows the sidebar however it collapses: the top-left strip makes room
    /// for the traffic lights while it's hidden.
    private var sidebarCollapseObserver: NSKeyValueObservation?
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
    /// Called when this window becomes key (the app's menus follow it).
    var onBecomeKey: (() -> Void)?

    /// Distinguishes duplicate windows on the same root so their frame-autosave
    /// names don't collide (index 0 keeps the legacy per-root name).
    let instanceIndex: Int

    /// The index for a new window on a root whose open windows hold `used`:
    /// the lowest free one, so it never shares a live window's autosave names.
    nonisolated static func freeInstanceIndex(used: [Int]) -> Int {
        let taken = Set(used)
        return (0...taken.count).first { !taken.contains($0) } ?? taken.count
    }

    /// The index for a new window on a root whose open windows hold `used`:
    /// `requested` (the one it had when the app quit) while no open window
    /// holds it, else the lowest free one.
    nonisolated static func instanceIndex(requested: Int?, used: [Int]) -> Int {
        if let requested, requested >= 0, !used.contains(requested) { return requested }
        return freeInstanceIndex(used: used)
    }

    /// `restoresLayout: false` opens one fresh pane instead of the window's
    /// saved layout (Duplicate Window).
    init(root: URL, instanceIndex: Int = 0, restoresLayout: Bool = true) {
        self.root = root
        self.instanceIndex = instanceIndex
        let window = TrafficLightInsetWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // No toolbar: the panes' strips are the title bar, and the traffic
        // lights center in their band (the sidebar's top row matches it).
        window.trafficLightCenterFromTop = PaneStripView.height / 2
        window.title = root.lastPathComponent
        // We restore windows ourselves (AppDelegate + OpenWindows); opt out of
        // macOS's automatic state restoration so it never re-presents a sheet
        // (e.g. the per-root inspector) that was open at quit.
        window.isRestorable = false
        // Merge the title bar into the content: the panes' strips are the title
        // bar (each names what it shows), so the native title stays hidden.
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
        controller.undoManager = window.undoManager

        let split = NSSplitViewController()
        // Sidebar and inspector widths (and whether they're collapsed), per window.
        split.splitView.autosaveName = instanceIndex == 0 ? "MainSplit-\(root.path)" : "MainSplit-\(root.path)#\(instanceIndex)"
        let thisWindow = instanceIndex == 0 ? root.path : "\(root.path)#\(instanceIndex)"
        filesVisibleKey = "filesPaneVisible:" + thisWindow

        let sidebarVC = SidebarListController(controller: controller)
        self.sidebar = sidebarVC
        sidebarVC.onOpenWorkspace = { [weak self] r in self?.onOpenWorkspace?(r) }
        sidebarVC.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        sidebarVC.onStopTask = { [weak self] sid, task in await self?.detail?.surfaces.chats[sid]?.session.stopBackgroundTask(task) ?? false }
        sidebarVC.onDropFiles = { [weak self] id, urls in
            self?.workspace?.selection = .session(id)
            self?.detail?.dropFiles(urls, on: id)
        }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        // Resizable within a range; collapses (auto-collapses when dragged below
        // the minimum, since it's a sidebar item with canCollapse).
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 460
        sidebarItem.canCollapse = true
        self.sidebarItem = sidebarItem
        split.addSplitViewItem(sidebarItem)

        let detail = PaneTreeController(controller: controller, instanceIndex: instanceIndex,
                                        restoresLayout: restoresLayout)
        self.detail = detail
        detail.newSessionMenu = { [weak self] in self?.sidebar?.newSessionMenu() }
        detail.onShowFiles = { [weak self] changesOnly in self?.showInFiles(changesOnly: changesOnly) }
        detail.onOpenFile = { [weak self] url, line in self?.showInFiles(url, line: line) }
        detail.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        detail.onToggleFiles = { [weak self] in self?.toggleFiles() }
        // The focused pane's session names the window (its strip shows it).
        detail.onChromeChange = { [weak self] chrome in
            guard let self else { return }
            // The window title feeds the Window menu (and Mission Control), where
            // several folders' windows sit side by side — so it always carries
            // the folder name. The native title bar is hidden.
            let folder = self.root.lastPathComponent
            self.window?.title = chrome.map { "\(folder) — \($0.title)" } ?? folder
            self.updateSandboxStatus()
        }
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 420
        // To the window's top: the panes' strips are its title bar.
        detailItem.allowsFullHeightLayout = true
        detailItem.titlebarSeparatorStyle = .none
        split.addSplitViewItem(detailItem)

        // Its tabs are this window's, whichever session's folder it shows
        // (not shared with a split Files pane on the same folder).
        let files = FilesPaneController(tabsKey: "filesTabs:inspector:" + thisWindow, layoutKey: thisWindow)
        self.filesPane = files
        files.onAddToChat = { [weak self] urls in
            guard let self, case .session(let id)? = self.workspace?.selection else { return }
            self.detail?.dropFiles(urls, on: id)
        }
        files.onAskAgent = { [weak self] text in
            guard let self, case .session(let id)? = self.workspace?.selection else { return NSSound.beep() }
            self.detail?.askAgent(text, on: id)
        }
        // Files is the window's right sidebar: full height (its header is its
        // top band, beside the strips), never a pane. As wide as you like; at
        // least what its shown columns need.
        let filesItem = NSSplitViewItem(inspectorWithViewController: files)
        filesItem.minimumThickness = files.minimumWidth
        filesItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        files.onMinimumWidthChange = { [weak self] width in self?.filesMinimumWidthChanged(width) }
        filesItem.canCollapse = true
        filesItem.allowsFullHeightLayout = true
        filesItem.titlebarSeparatorStyle = .none
        filesItem.isCollapsed = !UserDefaults.standard.bool(forKey: filesVisibleKey)
        self.filesItem = filesItem
        split.addSplitViewItem(filesItem)
        // Follow the active session's folder (the workspace root otherwise).
        selectionObserver = controller.$selection.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncFilesRoot() }
        }
        sandboxObserver = controller.$containerPhases.map { _ in () }
            .merge(with: controller.$sandboxBusy.map { _ in () })
            .sink { [weak self] in
                Task { @MainActor [weak self] in self?.updateSandboxStatus() }
            }

        window.contentViewController = split
        // No toolbar: the panes' strips are the title bar, the sandbox's state
        // is in the sidebar's header; and, in DEBUG, a construction-tape banner.
        Self.forgetOldToolbarConfigurations()
        sidebarVC.setHeaderAccessory(sandboxStatus)
        filesCollapseObserver = filesItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.filesVisibilityChanged() }
        }
        sidebarCollapseObserver = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] _, change in
            let collapsed = change.newValue ?? false
            MainActor.assumeIsolated { self?.detail?.sidebarHidden = collapsed }
        }
        filesVisibilityChanged()
        updateSandboxStatus()
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

        // Container phases, subagents and the work timers stay current in
        // every window, a folder still being set up included.
        controller.startMonitoring()
        // Its config.json or state.json couldn't be read: it runs on defaults
        // or a fresh session list, so say so first.
        if let warning = UnreadableWorkspaceFile.warning(for: controller.takeOpenProblems()) {
            Alerts.inform(warning.title, warning.message, style: .warning, in: window)
        }
        // First open: configure mounts first (scripted runs take the defaults:
        // nobody's there to answer). Either way an existing sandbox is
        // attached to, and a missing one waits for the first session.
        if controller.needsConfiguration, AutomatedRun.isActive {
            controller.applyConfiguration(policy: controller.policy)
        } else if controller.needsConfiguration {
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
        filesPane?.applyChrome(colors)
    }

    // MARK: - Old toolbars + debug construction tape

    /// The arrangements the toolbars before autosaved (v1–v6; there's no
    /// toolbar now): forgotten, so no stale item set stays in defaults.
    nonisolated static func forgetOldToolbarConfigurations(_ defaults: UserDefaults = .standard) {
        for version in ["", ".v2", ".v3", ".v4", ".v5", ".v6"] {
            defaults.removeObject(forKey: "NSToolbar Configuration MainWindowToolbar" + version)
        }
    }

    /// DEBUG-only: a faint construction-tape watermark inserted **behind** the
    /// title bar's controls (into the titlebar view), so a debug build is
    /// unmistakable without adding a separate band. It's chrome.
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

    // The window's parts, for the app's menu commands (and the self-tests).
    var paneTree: PaneTreeController? { detail }
    var inspectorFiles: FilesPaneController? { filesPane }
    var workspaceController: WorkspaceController? { workspace }
    var sidebarList: SidebarListController? { sidebar }
    var searchWindowController: SearchWindowController? { searchWindow }

    #if DEBUG
    /// Self-test: the sidebar's sandbox status — shown, which sandbox, what it says.
    var debugSandboxStatus: (shown: Bool, name: String?, tip: String) {
        updateSandboxStatus()
        return (!sandboxStatus.isHidden, sandboxStatus.sandboxName, sandboxStatus.toolTip ?? "")
    }
    /// Self-test: the sandbox menu's titles ("" for a separator).
    var debugSandboxMenuTitles: [String] { sandboxMenu()?.items.map { $0.isSeparatorItem ? "" : $0.title } ?? [] }
    /// Self-test: Inspect, as the sandbox menu does it.
    func debugInspectSandbox() { inspectSandboxFromMenu() }
    /// Self-test: the sandbox status's tooltip (its state and access).
    var debugSandboxAccess: String { sandboxStatus.toolTip ?? "" }
    func debugShowSandboxAccess() -> Bool { showSandboxAccessFromMenu(); return accessPopover?.isShown == true }
    func debugCloseSandboxAccess() { accessPopover?.close(); accessPopover = nil }
    /// Self-test: the access popover's content and its anchor, on screen.
    var debugAccessPopoverFrames: (popover: NSRect, anchor: NSRect)? {
        guard let view = accessPopover?.contentViewController?.view, let pop = view.window else { return nil }
        return (pop.convertToScreen(view.convert(view.bounds, to: nil)), sandboxStatus.debugScreenRect)
    }
    /// Self-test: collapse or expand Files as a person's click does (animated).
    func debugSetFilesShownAnimated(_ show: Bool) {
        guard let item = filesItem, item.isCollapsed == show else { return }
        NSAnimationContext.runAnimationGroup { _ in item.animator().isCollapsed = !show }
        filesVisibilityChanged()
    }
    /// Self-test: the window has no toolbar.
    var debugHasToolbar: Bool { window?.toolbar != nil }
    /// Self-test: the traffic lights' vertical center, from the window's top.
    var debugTrafficLightsCenterFromTop: CGFloat? {
        guard let window, let close = window.standardWindowButton(.closeButton), let frameView = window.contentView?.superview
        else { return nil }
        let r = close.convert(close.bounds, to: frameView)
        return frameView.bounds.height - r.midY
    }
    /// Self-test: the strips carrying the window's toggles — which pane's has
    /// the sidebar's (sidebar hidden) and which the Files toggle, and whether
    /// that's pressed; and whether Files' header shows.
    var debugWindowCorners: (sidebarToggles: Int, filesToggles: Int, filesOn: Bool, filesHeader: Bool) {
        let strips = (detail?.panes ?? []).compactMap { $0.debugStripView as? PaneStripView }.map(\.debugWindowToggles)
        let header = filesPane.map { isFilesShown && $0.header.window != nil && !$0.header.isHiddenOrHasHiddenAncestor } ?? false
        return (strips.filter(\.sidebar).count, strips.filter(\.files).count, strips.contains { $0.files && $0.filesOn }, header)
    }
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
                },
                canStop: { [weak self] sid, _ in self?.detail?.surfaces.chats[sid] != nil },
                stopTask: { [weak self] sid, task in await self?.detail?.surfaces.chats[sid]?.session.stopBackgroundTask(task.id) ?? false })
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

    /// View ▸ Show / Hide Files (⇧⌥⌘0), the title bar's Files button, the
    /// sidebar's own close button: the window's Files sidebar, which follows
    /// the selected session's folder.
    func toggleFiles() { setFilesShown(!isFilesShown) }

    func setFilesShown(_ show: Bool) {
        guard let item = filesItem, item.isCollapsed == show else { return }
        // Scripted runs (an offscreen window) don't animate: the split there
        // never gets past the first frame of the expansion.
        if AutomatedRun.isActive { item.isCollapsed = !show } else {
            NSAnimationContext.runAnimationGroup { _ in item.animator().isCollapsed = !show }
        }
        filesVisibilityChanged()
    }

    /// Panes that can't shrink enough leave no room for Files: the split lays
    /// it out past the window's edge. Widen the window by what's missing (as
    /// far as the screen allows) so the sidebar shows.
    private func fitFilesInWindow() {
        guard isFilesShown, let window, let files = filesPane?.view else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let overflow = files.convert(files.bounds, to: nil).maxX - window.frame.width
        guard overflow > 0.5 else { return }
        var frame = window.frame
        frame.size.width += ceil(overflow)
        if let screen = window.screen?.visibleFrame {
            frame.size.width = min(frame.width, screen.width)
            if frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - frame.width) }
        }
        window.setFrame(frame, display: true, animate: !AutomatedRun.isActive)
    }

    @objc func toggleFilesFromToolbar() { toggleFiles() }

    /// View ▸ File Tree / Diff Column: that column of the Files sidebar,
    /// showing the sidebar too if it's hidden.
    func toggleFileTree() {
        guard let files = filesPane else { return }
        if !isFilesShown { files.setTreeShown(true); return setFilesShown(true) }
        files.toggleTree()
    }
    func toggleDiffColumn() {
        guard let files = filesPane else { return }
        if !isFilesShown { files.setDiffColumnShown(true); return setFilesShown(true) }
        files.toggleDiffColumn()
    }
    var isFileTreeShown: Bool { isFilesShown && filesPane?.isTreeShown == true }
    var isDiffColumnShown: Bool { isFilesShown && filesPane?.isDiffColumnShown == true }

    /// A Files column showed or hid: the sidebar needs at least this much now
    /// (growing into the panes, and the window, if it's narrower).
    private func filesMinimumWidthChanged(_ width: CGFloat) {
        guard let filesItem else { return }
        filesItem.minimumThickness = width
        guard isFilesShown, let files = filesPane?.view, files.frame.width < width - 0.5,
              let split = window?.contentViewController as? NSSplitViewController else { return }
        let view = split.splitView
        view.setPosition(view.bounds.width - width - view.dividerThickness, ofDividerAt: split.splitViewItems.count - 2)
        fitFilesInWindow()
    }

    /// The Files sidebar showed or hid (however it happened): the toggle's
    /// pressed state, its header in the title bar, the window's saved state,
    /// and the folder it shows.
    private func filesVisibilityChanged() {
        let shown = isFilesShown
        // The top-right strip's Files toggle shows it pressed.
        detail?.filesShown = shown
        UserDefaults.standard.set(shown, forKey: filesVisibleKey)
        syncFilesRoot()
        // Once it has expanded (and been laid out), make sure it's in the window.
        if shown {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                self?.fitFilesInWindow()
            }
        }
    }

    /// A pane's branch crumb or a chat's file link: the Files sidebar (shown
    /// if it isn't) with just the changes, or `url` open (at `line`).
    func showInFiles(_ url: URL? = nil, line: Int? = nil, changesOnly: Bool = false) {
        setFilesShown(true)
        guard let files = filesPane else { return }
        if changesOnly { files.showChanges() }
        guard let url else { return }
        if let line { files.editor.open(url, line: line, highlight: "") } else { files.open(url) }
    }

    /// File ▸ Open Quickly (⇧⌘O) when no Files surface has focus: the Files
    /// sidebar, shown if needed.
    func openQuickly() {
        if let item = filesItem, !item.isCollapsed, let files = filesPane { return files.openQuickly(nil) }
        setFilesShown(true)
        // After the inspector's expand animation, so the popover anchors in place.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.filesPane?.openQuickly(nil)
        }
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

    /// ⇧⌘F / the sidebar: search this workspace's open sessions and
    /// the past conversations that can be restored into it.
    func showSearch(preferredFolder: UUID? = nil) {
        guard let workspace else { return }
        let search = searchWindow ?? SearchWindowController(workspace: workspace, mainWindow: window)
        searchWindow = search
        search.preferredFolder = preferredFolder
        search.show()
    }


    /// ⌘, — open the per-root settings inspector sheet (all settings live there).
    func showSettings() {
        sidebar?.presentInspector()
    }

    /// Cycle the selected session (`+1` next / `-1` previous) through the ones
    /// the sidebar lists: filtered, and in the order it shows them.
    func cycleSession(_ delta: Int) {
        workspace?.selectAdjacentSession(delta, in: sidebar?.displayedSessionIDs ?? [])
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

    /// Whether the session runs in this window (its terminal or chat is up or
    /// starting); another window on the folder only shows it's open elsewhere.
    func isRunning(_ id: UUID) -> Bool { detail?.surfaces.isRunning(id) ?? false }

    /// Whether `window` is this window or one opened for it — its Settings,
    /// Search or Background Tasks window, or a sheet or popover on one —
    /// so the app's menus act on this workspace while it is key.
    func owns(_ window: NSWindow) -> Bool {
        guard let main = self.window else { return false }
        var window = window
        while let parent = window.sheetParent ?? window.parent { window = parent }
        return window === main || window === searchWindow?.window || window === backgroundTasksPanel?.window
            || window === SettingsWindowController.window(for: main)
    }

    var sidebarController: SidebarListController? { sidebar }

    func reopenClosedSession() {
        if workspace?.reopenLastClosed() == nil { NSSound.beep() }
    }
    var canReopenClosedSession: Bool { !(workspace?.recentlyClosed.isEmpty ?? true) }
    var isSidebarCollapsed: Bool { sidebarItem?.isCollapsed ?? false }
    var isFilesShown: Bool { !(filesItem?.isCollapsed ?? true) }
    /// What ⌘W would close here: a session, or the window.
    var closesSession: Bool {
        if case .session? = workspace?.selection { true } else { false }
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
        let selection: String? = switch workspace?.selection {
        case .session(let id)?: "session:\(id.uuidString)"
        case nil: nil
        }
        let sessions = workspace?.orderedSessions.map { session -> SessionScriptStatus in
            let rt = workspace?.runtime(session.id)
            return SessionScriptStatus(
                id: session.id.uuidString,
                name: workspace?.displayName(of: session) ?? session.displayName,
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

/// A window whose traffic-light buttons center at a given depth from its top
/// (the panes' strips' band: there's no toolbar to set it). AppKit re-lays out
/// the standard buttons on every layout pass, so we re-apply it after each.
final class TrafficLightInsetWindow: NSWindow {
    /// The buttons' vertical center, in points from the window's top (nil: AppKit's own).
    var trafficLightCenterFromTop: CGFloat? { didSet { layoutTrafficLights() } }

    private static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private var positioning = false

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutTrafficLights()
    }

    private func layoutTrafficLights() {
        guard let depth = trafficLightCenterFromTop, !positioning,
              let titlebar = standardWindowButton(.closeButton)?.superview else { return }
        positioning = true
        defer { positioning = false }
        // The titlebar view is non-flipped (origin at bottom-left) and runs to
        // the window's top; a button deeper than it would be clipped.
        let midY = titlebar.bounds.height - depth
        for type in Self.buttonTypes {
            guard let button = standardWindowButton(type) else { continue }
            let y = max(0, (midY - button.frame.height / 2).rounded())
            if button.frame.origin.y != y { button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y)) }
        }
    }
}

extension MainWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmUnsavedFiles() }

    func windowDidBecomeKey(_ notification: Notification) { onBecomeKey?() }

    /// Unsaved edits in the Files inspector: Save / Discard /
    /// Cancel for each (false = the person cancelled).
    func confirmUnsavedFiles() -> Bool {
        filesPane?.confirmClose() ?? true
    }

    /// Tear down this window's terminals (kills their `sbx exec` + removes temp
    /// scripts), close its Settings, Search and status windows, and let
    /// `AppDelegate` forget it.
    /// (Not called at quit: the windows and their layouts come back at launch.)
    func windowWillClose(_ notification: Notification) {
        workspace?.windowClosed()
        detail?.teardown()
        // An extra window's layout goes with it, so a later window taking its
        // index starts fresh; the folder's first window keeps its layout for
        // the next time the folder opens.
        if instanceIndex > 0 { detail?.forgetLayout() }
        searchWindow?.close()
        sidebar?.closeAuxiliaryWindows()
        if let window { SettingsWindowController.close(for: window) }
        backgroundTasksPanel?.close()   // it shows (and stops) this window's sessions
        backgroundTasksPanel = nil
        onClose?()
    }
}

// MARK: - The sandbox (its state in the sidebar's header, its menu)

extension MainWindowController {
    /// The sidebar's sandbox status: hidden while the focused pane shows no
    /// session; else its sandbox, tinted by its state.
    func updateSandboxStatus() {
        guard detail != nil else { return }
        let box = focusedSandbox
        let phase = box.flatMap { workspace?.containerPhases[$0.agent] }
        let access = focusedSandboxAccess
        let (color, state): (NSColor?, String) = switch phase {
        case .running?: (.systemBlue, "running")
        case .creating?, .rebuilding?: (.sessionWorking, "being built")
        case .failed?: (.systemRed, "failed")
        case .stopped?: (nil, "stopped")
        case .absent?, nil: (nil, "not created yet")
        }
        sandboxStatus.setSandbox(name: box?.name, stateColor: color, tip: box.map { box in
            let folder = access.map { a in
                switch a.mode {
                case .readWrite: " · reads and writes the folder"
                case .readOnly: " · reads the folder"
                case .notShared: " · can’t see the folder"
                }
            } ?? ""
            return "Sandbox “\(box.name)” (\(state))\(folder)"
        })
    }

    /// Sandbox ▸ Stop: the focused session's process in its sandbox.
    @objc private func stopFromToolbar() {
        guard let workspace, let box = focusedSandbox else { return }
        if workspace.containerPhases[box.agent] == .stopped {
            return workspace.startSandbox(box.name) { [weak self] in self?.restartSessions(inSandboxOf: box.agent) }
        }
        let live = workspace.liveSessionCount(inSandboxOf: box.agent)
        guard live == 0 || Alerts.confirm("Stop the sandbox “\(box.name)”?",
                                          "\(live == 1 ? "The session" : "All \(live) sessions") running in it will stop.",
                                          confirm: "Stop Sandbox", destructive: true) else { return }
        workspace.stopSandbox(box.name)
    }
    /// Sandbox ▸ Restart: the sandbox stopped and started again, then the
    /// sessions this window shows in it.
    @objc private func restartSandboxFromMenu() {
        guard let workspace, let box = focusedSandbox else { return }
        let live = workspace.liveSessionCount(inSandboxOf: box.agent)
        guard live == 0 || Alerts.confirm("Restart the sandbox “\(box.name)”?",
                                          "\(live == 1 ? "The session" : "All \(live) sessions") running in it will stop; "
                                          + "the ones in this window start again.",
                                          confirm: "Restart Sandbox") else { return }
        workspace.restartSandbox(box.name) { [weak self] in self?.restartSessions(inSandboxOf: box.agent) }
    }

    /// Sandbox ▸ Rebuild: the sandbox made again from its image and the
    /// workspace's kits. First looks for what was added in it since it was
    /// made, and offers to keep that as a kit (installed again on the new one).
    @objc private func rebuildFromToolbar() {
        guard let workspace, let box = focusedSandbox else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let found: Result<SandboxChanges, Error>
            do { found = .success(try await SbxClient.shared.readChanges(inSandbox: box.name)) } catch { found = .failure(error) }
            self.updateSandboxStatus()
            let live = workspace.liveSessionCount(inSandboxOf: box.agent)
            var info = "It’s made again from its image and the workspace’s kits"
                + (live == 0 ? "." : "; \(live == 1 ? "the session" : "all \(live) sessions") running in it stop.")
            var buttons = ["Rebuild", "Cancel"]
            switch found {
            case .success(let changes) where !changes.isEmpty:
                info += "\n\nAdded since it was made: \(changes.summary). Keep them as a kit, so the new sandbox "
                    + "(and any later rebuild) installs them again?"
                if !changes.notes.isEmpty { info += "\n\nNot capturable: \(changes.notes.prefix(4).joined(separator: "; "))" }
                buttons = ["Keep as Kit & Rebuild", "Rebuild Without", "Cancel"]
            case .success:
                info += "\n\nNothing was installed in it since it was made."
            case .failure(let error):
                info += "\n\nCouldn’t check what was added in it: \(error.localizedDescription)"
            }
            let answer = await Alerts.choose("Rebuild the sandbox “\(box.name)”?", info, buttons: buttons, in: self.window)
            guard buttons.indices.contains(answer), buttons[answer] != "Cancel" else { return }
            if buttons[answer] == "Keep as Kit & Rebuild", case .success(let changes) = found {
                do { try workspace.captureChangesAsKit(changes, for: box.agent) } catch {
                    return Alerts.inform("Couldn’t save the kit", error.localizedDescription, style: .warning, in: self.window)
                }
            }
            workspace.rebuildContainer(for: box.agent, force: true)
        }
    }

    /// The sandbox's details, and what was added in it (with Keep as Kit).
    @objc private func inspectSandboxFromMenu() {
        guard let workspace, let box = focusedSandbox else { return }
        SandboxInspectWindowController.show(sandbox: box.name, agent: box.agent, workspace: workspace, near: window)
    }

    /// The menu under the sandbox's name in the title bar.
    private func sandboxMenu() -> NSMenu? {
        guard let workspace, let box = focusedSandbox else { return nil }
        let stopped = workspace.containerPhases[box.agent] == .stopped
        let busy = workspace.sandboxBusy.contains(box.name)
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, symbol: String, enabled: Bool = true) {
            let item = NSMenuItem(title, action: action, target: self, symbol: symbol)
            item.isEnabled = enabled && !busy
            menu.addItem(item)
        }
        add("Inspect…", #selector(inspectSandboxFromMenu), symbol: "info.circle")
        add("Folder Access…", #selector(showSandboxAccessFromMenu), symbol: "lock.open")
        add("Keep What Was Added as a Kit…", #selector(inspectSandboxFromMenu), symbol: "shippingbox")
        menu.addItem(.separator())
        add(stopped ? "Start" : "Stop", #selector(stopFromToolbar), symbol: stopped ? "play.fill" : "stop.fill")
        add("Restart", #selector(restartSandboxFromMenu), symbol: "arrow.clockwise", enabled: !stopped)
        add("Rebuild…", #selector(rebuildFromToolbar), symbol: "hammer")
        return menu
    }

    /// What the focused session's sandbox can do with its folder.
    private var focusedSandboxAccess: SandboxAccess? {
        guard let workspace, let id = detail?.focused?.shownSession, let session = workspace.session(id: id) else { return nil }
        return workspace.sandboxAccess(for: URL(filePath: session.workdir, directoryHint: .isDirectory),
                                       agent: session.containerAgentKind)
    }
    /// Sandbox ▸ Folder Access…: what it can do with the folder, under the pill.
    @objc private func showSandboxAccessFromMenu() {
        guard let access = focusedSandboxAccess else { return }
        accessPopover?.close()
        accessPopover = sandboxStatus.showAccess(access)
    }

    /// The focused session's sandbox (its container name and agent).
    private var focusedSandbox: (name: String, agent: AgentKind)? {
        guard let workspace, let id = detail?.focused?.shownSession, let session = workspace.session(id: id) else { return nil }
        return (workspace.containerName(for: session.containerAgentKind), session.containerAgentKind)
    }

    /// Start again the sessions this window's panes show in `agent`'s sandbox.
    private func restartSessions(inSandboxOf agent: AgentKind) {
        guard let workspace, let detail else { return }
        for pane in detail.panes {
            guard let id = pane.shownSession, workspace.session(id: id)?.containerAgentKind == agent else { continue }
            pane.headerRestartClicked()
        }
    }
}

