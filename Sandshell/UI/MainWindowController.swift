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
    // The title bar: the focused session's name, the Sandbox group, the Files toggle.
    private let toolbarName = NSTextField(labelWithString: "")
    /// The single, persistent identity view (the session's name). Built once
    /// and handed ONLY to the inserted toolbar item (see the `flag` gate in the
    /// toolbar delegate) so NSToolbar's palette/measurement passes can't
    /// re-parent its shared subviews and leave the live item blank.
    private lazy var identityItemView: NSStackView = {
        toolbarName.setContentCompressionResistancePriority(.init(40), for: .horizontal)
        toolbarName.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [toolbarName])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        // 140–360 pt, as wide as it can be: a long session name truncates
        // instead of blowing the whole toolbar into the overflow menu.
        // Priorities sit under fittingSizeCompression (50), so the toolbar
        // measures the item at its 140 pt minimum, yet once laid out the label
        // (40) truncates before it spills past the stack's edge (45) over the
        // buttons beside it. Clipping is the last resort.
        stack.setHuggingPriority(.init(1), for: .horizontal)
        stack.distribution = .fill
        stack.setClippingResistancePriority(.init(45), for: .horizontal)
        stack.clipsToBounds = true
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            stack.heightAnchor.constraint(equalToConstant: 32),
        ])
        return stack
    }()
    /// Stop / Restart for the focused session's process in its sandbox.
    private lazy var sandboxActions: SandboxActionsView = {
        let view = SandboxActionsView(target: self, stop: #selector(stopFromToolbar), rebuild: #selector(rebuildFromToolbar))
        view.sandboxMenu = { [weak self] in self?.sandboxMenu() }
        return view
    }()
    /// The Files sidebar's toggle (pressed while it shows).
    private lazy var filesToggleButton = ChromeButton(
        "Files", symbol: "doc.text", symbolConfiguration: .role(.body),
        toolTip: "Show or hide Files (⇧⌥⌘0)", target: self, action: #selector(toggleFilesFromToolbar), id: "toolbar-files")
    /// The Files sidebar's own close button (an ×), at the end of its header.
    private lazy var filesCloseButton = NSButton.symbol(
        "xmark", label: "Close Files (⇧⌥⌘0)", pointSize: TypeRole.meta.symbolPointSize,
        size: NSSize(width: 28, height: 24), target: self, action: #selector(toggleFilesFromToolbar), id: "files-close")
    /// Follows the Files sidebar however it collapses (toggle, menu, a drag).
    private var filesCollapseObserver: NSKeyValueObservation?
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
        controller.undoManager = window.undoManager

        let split = NSSplitViewController()
        // Sidebar and inspector widths (and whether they're collapsed), per window.
        split.splitView.autosaveName = instanceIndex == 0 ? "MainSplit-\(root.path)" : "MainSplit-\(root.path)#\(instanceIndex)"
        let thisWindow = instanceIndex == 0 ? root.path : "\(root.path)#\(instanceIndex)"
        filesVisibleKey = "filesPaneVisible:" + thisWindow

        let sidebarVC = SidebarListController(controller: controller)
        self.sidebar = sidebarVC
        sidebarVC.onOpenWorkspace = { [weak self] r in self?.onOpenWorkspace?(r) }
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
        // Drive the toolbar identity (the session's name) from the focused
        // pane; nothing when it shows no session.
        detail.onChromeChange = { [weak self] chrome in
            guard let self else { return }
            // The window title feeds the Window menu (and Mission Control), where
            // several folders' windows sit side by side — so it always carries
            // the folder name. The visible titlebar is hidden; the toolbar shows
            // only the session (the sidebar header already names the folder).
            let folder = self.root.lastPathComponent
            // No status, timer or subtitle up here: the sidebar row carries those.
            if let chrome {
                self.toolbarName.stringValue = chrome.title
                self.window?.title = "\(folder) — \(chrome.title)"
            } else {
                self.toolbarName.stringValue = ""
                self.window?.title = folder
            }
            self.window?.toolbar?.validateVisibleItems()
        }
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 420
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
        // Files is the window's right sidebar: full height (its header sits in
        // the title bar, over its own background), never a pane. As wide as
        // you like; at least what its shown columns need.
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
                Task { @MainActor [weak self] in self?.updateSandboxGroup() }
            }

        window.contentViewController = split
        // Native window toolbar (identity, Sandbox group, Files); and, in
        // DEBUG, a construction-tape banner.
        installMainToolbar()
        filesCollapseObserver = filesItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.filesVisibilityChanged() }
        }
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
        // First open: configure mounts before bringing the container up
        // (scripted runs take the defaults: nobody's there to answer).
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
        sandboxActions.apply(colors)
        filesToggleButton.apply(colors)
        filesCloseButton.contentTintColor = colors.text2
        toolbarName.textColor = colors.text
        filesPane?.applyChrome(colors)
    }

    // MARK: - Toolbar + debug construction tape

    /// Attach the window toolbar (its items are built by the `NSToolbarDelegate`
    /// conformance below).
    private func installMainToolbar() {
        toolbarName.font = .role(.title)
        toolbarName.lineBreakMode = .byTruncatingTail
        toolbarName.setAccessibilityIdentifier("toolbar-identity")
        toolbarName.stringValue = ""   // no session yet: the sidebar header names the folder

        // A fixed set, not customizable (one home per action), so nothing is
        // autosaved. The identifier is versioned all the same, and what older
        // versions autosaved is dropped, so none of their items (status,
        // reveal, search…) lingers.
        Self.forgetOldToolbarConfigurations()
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
        // Center the traffic lights on the toolbar's identity item (AppKit's
        // default on the macOS 27 SDK toolbar sits low, crowding the sidebar header).
        (window as? TrafficLightInsetWindow)?.trafficLightAlignmentView = identityItemView
        filesVisibilityChanged()
    }

    nonisolated static let toolbarIdentifier = "MainWindowToolbar.v6"

    /// The arrangements earlier toolbars autosaved (v1–v5, when it was
    /// customizable): forgotten, so no stale item set stays in defaults.
    nonisolated static func forgetOldToolbarConfigurations(_ defaults: UserDefaults = .standard) {
        for version in ["", ".v2", ".v3", ".v4", ".v5"] {
            defaults.removeObject(forKey: "NSToolbar Configuration MainWindowToolbar" + version)
        }
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

    // The window's parts, for the app's menu commands (and the self-tests).
    var paneTree: PaneTreeController? { detail }
    var inspectorFiles: FilesPaneController? { filesPane }
    var workspaceController: WorkspaceController? { workspace }
    var sidebarList: SidebarListController? { sidebar }
    var searchWindowController: SearchWindowController? { searchWindow }

    #if DEBUG
    /// Self-test: the identity item's width, and how many of the toolbar's
    /// shown items fit (the rest would go to its overflow menu).
    var debugToolbarWidths: (identity: CGFloat, visible: Int, items: Int, missing: [String]) {
        // The title bar's own items (the separator and space past it are the
        // Files sidebar's, laid out only while it shows).
        let items = window?.toolbar?.items ?? []
        let main = items.prefix { $0.itemIdentifier != .inspectorTrackingSeparator }
            .filter { !$0.isHidden && $0.itemIdentifier != .flexibleSpace }
        let visible = Set((window?.toolbar?.visibleItems ?? []).map(\.itemIdentifier))
        let missing = main.filter { !visible.contains($0.itemIdentifier) }.map(\.itemIdentifier.rawValue)
        return (identityItemView.frame.width, main.count - missing.count, main.count, missing)
    }
    /// Self-test: the toolbar's items, by identifier, in order.
    var debugToolbarItems: [String] { window?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [] }
    /// Self-test: the toolbar's default items, by identifier, in order.
    var debugDefaultToolbarItems: [String] {
        window?.toolbar.map { toolbarDefaultItemIdentifiers($0).map(\.rawValue) } ?? []
    }
    /// Self-test: the title bar's session name.
    var debugIdentity: String { toolbarName.stringValue }
    /// Self-test: the Sandbox group — shown, and Stop / Restart enabled.
    var debugSandboxGroup: (shown: Bool, stop: Bool, rebuild: Bool) {
        window?.toolbar?.validateVisibleItems()
        let item = window?.toolbar?.items.first { $0.itemIdentifier == .sandbox }
        return (item.map { !$0.isHidden } ?? false, sandboxActions.stopButton.isEnabled,
                sandboxActions.rebuildButton.isEnabled)
    }
    /// Self-test: the sandbox menu's titles ("" for a separator).
    var debugSandboxMenuTitles: [String] { sandboxMenu()?.items.map { $0.isSeparatorItem ? "" : $0.title } ?? [] }
    /// Self-test: Inspect, as the sandbox menu does it.
    func debugInspectSandbox() { inspectSandboxFromMenu() }
    /// Self-test: the sandbox pill's tooltip (its state and access).
    var debugSandboxAccess: String { sandboxActions.toolTip ?? "" }
    func debugShowSandboxAccess() -> Bool { showSandboxAccessFromMenu(); return accessPopover?.isShown == true }
    func debugCloseSandboxAccess() { accessPopover?.close(); accessPopover = nil }
    /// Self-test: what the Sandbox group's label says.
    var debugSandboxLabel: String { sandboxActions.debugLabel }
    /// Self-test: the Files toggle shows pressed; the sidebar's header shows.
    var debugFilesToggle: (on: Bool, headerShown: Bool) {
        let header = window?.toolbar?.items.first { $0.itemIdentifier == .filesHeader }
        return (filesToggleButton.isOn, header.map { !$0.isHidden } ?? false)
    }
    /// Self-test: set the toolbar's session name, then the name label's width
    /// against the identity item's.
    var debugToolbarNameFits: Bool {
        toolbarName.alignmentRect(forFrame: toolbarName.frame).width >= toolbarName.intrinsicContentSize.width - 6
    }
    func debugToolbarName(_ name: String) -> (label: CGFloat, identity: CGFloat) {
        toolbarName.stringValue = name
        identityItemView.layoutSubtreeIfNeeded()
        // The alignment rect: a label's frame runs 2 pt past its text each side.
        let text = toolbarName.alignmentRect(forFrame: toolbarName.frame)
        let label = toolbarName.superview?.convert(text, to: identityItemView) ?? text
        return (label.maxX, identityItemView.bounds.width)
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
        filesToggleButton.isOn = shown
        // The Files sidebar's part of the title bar (its tracking separator,
        // header, space and close button) comes and goes with it. Removed,
        // not hidden: hidden items still take room at the bar's end.
        if let toolbar = window?.toolbar {
            let separator = toolbar.items.firstIndex { $0.itemIdentifier == .inspectorTrackingSeparator }
            if shown, separator == nil {
                for id in Self.filesToolbarItems { toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.count) }
            } else if !shown, let separator {
                while toolbar.items.count > separator { toolbar.removeItem(at: toolbar.items.count - 1) }
            }
        }
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

private extension NSToolbarItem.Identifier {
    static let sidebarToggle = NSToolbarItem.Identifier("sidebarToggle")
    static let identity      = NSToolbarItem.Identifier("identity")
    static let sandbox       = NSToolbarItem.Identifier("sandbox")
    static let filesToggle   = NSToolbarItem.Identifier("filesToggle")
    /// The Files sidebar's header ("Files · main · 6 changed") and close
    /// button: over the sidebar, past the inspector's tracking separator.
    static let filesHeader   = NSToolbarItem.Identifier("filesHeader")
    static let filesClose    = NSToolbarItem.Identifier("filesClose")
}

extension MainWindowController: NSToolbarDelegate {
    /// The title bar: sidebar toggle · the session's name · Sandbox (Stop,
    /// Restart) · Files. Reveal in Finder lives in the pane's folder crumb,
    /// Chat ⇄ Terminal in the pane strip, Search in the sidebar (and ⇧⌘F).
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Our own sidebar toggle, not `.toggleSidebar`: the system item is a
        // bezeled button that renders as a glass capsule (and can hold a focus
        // ring) on macOS 26+/SDK 27 builds.
        [.sidebarToggle, .identity, .flexibleSpace, .sandbox, .filesToggle]
    }

    /// Over the Files sidebar while it shows (`filesVisibilityChanged`): its
    /// header, and its close button at the far end.
    fileprivate static let filesToolbarItems: [NSToolbarItem.Identifier] =
        [.inspectorTrackingSeparator, .filesHeader, .flexibleSpace, .filesClose]

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + Self.filesToolbarItems
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // Custom-view items. `flag` (willBeInsertedIntoToolbar) is true for the
        // real item and false for a palette / sizing pass; hand the shared live
        // views ONLY to the real item so a copy can't steal them (which left
        // the toolbar identity blank — see the identityItemView note).
        // No bezels anywhere: on macOS 26+/SDK 27 a bordered item is wrapped
        // in a Liquid Glass capsule, which is not this app's look (xmas-sandshell-85c).
        func item(_ view: @autoclosure () -> NSView, label: String,
                  validate: (() -> Void)? = nil) -> SelfValidatingToolbarItem {
            let item = SelfValidatingToolbarItem(itemIdentifier: itemIdentifier)
            item.view = flag ? view() : NSTextField(labelWithString: label)
            item.label = label
            item.paletteLabel = label
            item.isBordered = false
            item.onValidate = validate
            return item
        }
        switch itemIdentifier {
        case .sidebarToggle:
            let item = item(Self.plainToolbarButton(symbol: "sidebar.left", label: "Toggle Sidebar",
                                                    target: self, action: #selector(toggleSidebarFromToolbar)),
                            label: "Sidebar")
            item.toolTip = "Toggle Sidebar"
            item.visibilityPriority = .high
            return item
        case .identity:
            // Revalidates the Sandbox group too: a hidden item isn't validated.
            let item = item(identityItemView, label: "Session") { [weak self] in self?.updateSandboxGroup() }
            item.visibilityPriority = .high
            return item
        case .sandbox:
            let item = item(sandboxActions, label: "Sandbox") { [weak self] in self?.updateSandboxGroup() }
            item.visibilityPriority = .high
            return item
        case .filesToggle:
            let item = item(filesToggleButton, label: "Files")
            item.toolTip = "Show or hide Files (⇧⌥⌘0)"
            item.visibilityPriority = .high
            return item
        case .filesHeader:
            guard let filesPane else { return nil }
            return item(filesPane.header, label: "Files")
        case .filesClose:
            let item = item(filesCloseButton, label: "Hide Files")
            item.toolTip = "Hide Files (⇧⌥⌘0)"
            return item
        default:
            return nil
        }
    }

    /// The Sandbox group: hidden while no pane shows a session; Stop and
    /// Restart enabled for what the focused pane shows.
    private func updateSandboxGroup() {
        guard let detail else { return }
        let anySession = detail.panes.contains { $0.shownSession != nil }
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == .sandbox }), item.isHidden == anySession {
            item.isHidden = !anySession
        }
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
        sandboxActions.setSandbox(name: box?.name, access: access?.mode, stateColor: color,
                                  tip: box.map { box in
            let folder = access.map { a in
                switch a.mode {
                case .readWrite: " · reads and writes the folder"
                case .readOnly: " · reads the folder"
                case .notShared: " · can’t see the folder"
                }
            } ?? ""
            return "Sandbox “\(box.name)” (\(state))\(folder)"
        })
        sandboxActions.setSandboxRunning(phase != .stopped)
        // Not while it's being made or acted on, or before it exists.
        let busy = box.map { workspace?.sandboxBusy.contains($0.name) ?? false } ?? true
        let ready = (phase == .running || phase == .stopped) && !busy
        sandboxActions.setEnabled(stop: ready, rebuild: ready)
    }

    /// A borderless, non-focusable symbol button for toolbar items — the
    /// Sequoia-style glyph, with no bezel, glass capsule, or focus ring.
    private static func plainToolbarButton(symbol: String, label: String,
                                           target: AnyObject?, action: Selector) -> NSButton {
        NSButton.symbol(symbol, label: label, pointSize: TypeRole.body.symbolPointSize, size: NSSize(width: 28, height: 24),
                        target: target, action: action)
    }

    @objc private func toggleSidebarFromToolbar() { toggleSidebar() }
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
            self.sandboxActions.setEnabled(stop: false, rebuild: false)   // while it looks
            let found: Result<SandboxChanges, Error>
            do { found = .success(try await SbxClient.shared.readChanges(inSandbox: box.name)) } catch { found = .failure(error) }
            self.updateSandboxGroup()
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
        accessPopover = sandboxActions.showAccess(access)
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

