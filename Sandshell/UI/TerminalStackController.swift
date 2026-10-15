import AppKit
import Combine
import GhosttyTerminal
import SwiftUI

@MainActor
private final class TerminalRuntimeController {
    private struct AgentActivityWatch {
        var startedAt = Date()
        var containerName: String?
        var baselineExecIDs: Set<String>?
        var execID: String?
        var transcriptURL: URL?
        var transcriptMTime: Date?
        var transcriptReadOffset: Int = 0   // bytes consumed; avoids re-reading whole file each tick
        var cachedLastRole: String?         // Codex: last response_item role for quiet-state rechecks
        var latestPrompt: String?
    }

    private let controller: WorkspaceController
    private let isTerminalAlive: (UUID) -> Bool
    private let isSessionVisible: (UUID) -> Bool
    private let onTerminalDidExit: (UUID) -> Void

    private var activityWatches: [UUID: AgentActivityWatch] = [:]
    private var claimedTranscripts: Set<URL> = []
    private var watchTasks: [UUID: Task<Void, Never>] = [:]
    private var exited: Set<UUID> = []

    init(controller: WorkspaceController,
         isTerminalAlive: @escaping (UUID) -> Bool,
         isSessionVisible: @escaping (UUID) -> Bool,
         onTerminalDidExit: @escaping (UUID) -> Void) {
        self.controller = controller
        self.isTerminalAlive = isTerminalAlive
        self.isSessionVisible = isSessionVisible
        self.onTerminalDidExit = onTerminalDidExit
    }

    func isExited(_ id: UUID) -> Bool { exited.contains(id) }

    func resetExit(_ id: UUID) {
        exited.remove(id)
    }

    func prepareLaunch(_ id: UUID, containerName: String) async {
        let baselineExecIDs = await SbxClient.shared.activeExecIDs(containerName: containerName)
        updateActivityWatch(id) {
            $0.containerName = containerName
            $0.baselineExecIDs = baselineExecIDs
        }
    }

    func terminalStarted(_ id: UUID) {
        resetExit(id)
        controller.setLive(id, true)
    }

    func terminalRemoved(_ id: UUID) {
        controller.setLive(id, false)
        controller.clearClaudeStatus(id)
        releaseTranscript(id)
    }

    func terminalDidExit(_ id: UUID) {
        guard !exited.contains(id) else { return }
        exited.insert(id)
        controller.reportActivity(id, working: false, at: Date())
        onTerminalDidExit(id)
    }

    func startTracking(_ session: Session, resumeID: String?) {
        let id = session.id
        if let rid = resumeID, activityWatches[id]?.transcriptURL == nil,
           let url = TranscriptReader.transcriptURL(
                agent: session.agent, workdir: session.workdir,
                home: controller.home, id: rid) {
            updateActivityWatch(id) { $0.transcriptURL = url }
            claimedTranscripts.insert(url)
        }
        watchAgentActivity(session)
    }

    func stopTracking(_ id: UUID) {
        releaseTranscript(id)
    }

    func stopAll() {
        for id in Array(watchTasks.keys) { releaseTranscript(id) }
    }

    private func watchAgentActivity(_ session: Session) {
        let id = session.id
        watchTasks[id]?.cancel()
        let start = Date()
        updateActivityWatch(id) { $0.startedAt = start }
        watchTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isTerminalAlive(id),
                      let s = self.controller.session(id: id) else { return }
                let home = self.controller.home
                await self.pollExecLifecycle(id)
                if self.exited.contains(id) { continue }
                if self.activityWatches[id]?.transcriptURL == nil {
                    let agent = s.agent, workdir = s.workdir
                    let claimed = self.claimedTranscripts
                    let startedAt = self.activityWatches[id]?.startedAt ?? start
                    let url = await Task.detached(priority: .utility) {
                        TranscriptReader.transcriptURL(
                            agent: agent, workdir: workdir, home: home,
                            since: startedAt, excluding: claimed)
                    }.value
                    if let url {
                        self.updateActivityWatch(id) {
                            $0.transcriptURL = url
                            $0.transcriptReadOffset = 0
                            $0.cachedLastRole = nil
                        }
                        self.claimedTranscripts.insert(url)
                        if let transcriptID = TranscriptReader.transcriptID(at: url, agent: agent) {
                            self.controller.setTranscriptID(id, transcriptID)
                        }
                    }
                }
                guard let watch = self.activityWatches[id],
                      let url = watch.transcriptURL else { continue }
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                let mayChangeWithoutWrite = TranscriptReader.liveStateMayChangeWithoutFileWrite(agent: s.agent)
                let recheckQuietState = mayChangeWithoutWrite
                    && self.controller.runtime(id)?.status == .working

                if let mtime, watch.transcriptMTime == mtime {
                    // File unchanged. For Codex while working: re-evaluate the time-based window
                    // using the cached last role — no file read needed.
                    if recheckQuietState, let lastRole = watch.cachedLastRole {
                        let recentlyWritten = Date().timeIntervalSince(mtime) < 10
                        let working = lastRole == "user" || (lastRole != "assistant" && recentlyWritten)
                        let transition = self.controller.reportActivity(id, working: working,
                                                                        lastWrite: mtime, at: Date())
                        if transition.finishedWork,
                           let s = self.controller.session(id: id),
                           !self.isSessionVisible(id) {
                            NotificationManager.shared.sendWorkComplete(
                                sessionID: id,
                                agentName: s.agent.displayName,
                                sessionName: s.name,
                                lastPrompt: self.activityWatches[id]?.latestPrompt,
                                workSeconds: transition.workSeconds,
                                workdir: s.workdir)
                        }
                    }
                    continue
                }
                self.updateActivityWatch(id) { $0.transcriptMTime = mtime }

                // Incremental read: parse only bytes appended since the last tick.
                let readOffset = self.activityWatches[id]?.transcriptReadOffset ?? 0
                let urlCapture = url
                let incResult = await Task.detached(priority: .utility) {
                    TranscriptReader.incrementalLiveState(in: urlCapture, fromOffset: readOffset)
                }.value
                guard let result = incResult else { continue }
                self.updateActivityWatch(id) {
                    $0.transcriptReadOffset = result.newOffset
                    if let role = result.lastRole { $0.cachedLastRole = role }
                }
                let state = result.liveState
                let transition = self.controller.reportActivity(id, working: state.working,
                                                                lastWrite: mtime, at: Date())
                if let prompt = state.latestPrompt {
                    self.controller.autoName(id, from: prompt)
                    self.updateActivityWatch(id) { $0.latestPrompt = prompt }
                }
                if transition.finishedWork,
                   let s = self.controller.session(id: id),
                   !self.isSessionVisible(id) {
                    NotificationManager.shared.sendWorkComplete(
                        sessionID: id,
                        agentName: s.agent.displayName,
                        sessionName: s.name,
                        lastPrompt: self.activityWatches[id]?.latestPrompt,
                        workSeconds: transition.workSeconds,
                        workdir: s.workdir)
                }
            }
        }
    }

    private func pollExecLifecycle(_ id: UUID) async {
        guard let watch = activityWatches[id],
              let containerName = watch.containerName,
              !exited.contains(id) else { return }

        let execID: String?
        if let known = watch.execID {
            execID = known
        } else {
            guard let baseline = watch.baselineExecIDs,
                  let active = await SbxClient.shared.activeExecIDs(containerName: containerName)
            else { return }
            let candidates = active.subtracting(baseline).sorted()
            guard let claimed = candidates.first else { return }
            updateActivityWatch(id) { $0.execID = claimed }
            Log.info(.workspace, "session \(id) attached to sbx exec \(claimed)")
            execID = claimed
        }

        guard let execID,
              let state = await SbxClient.shared.inspectExecLifecycle(id: execID),
              !state.running else { return }
        Log.info(.workspace, "session \(id) sbx exec \(execID) exited with \(state.exitCode ?? 0)")
        terminalDidExit(id)
    }

    private func updateActivityWatch(_ id: UUID, _ apply: (inout AgentActivityWatch) -> Void) {
        var watch = activityWatches[id] ?? AgentActivityWatch()
        apply(&watch)
        activityWatches[id] = watch
    }

    private func releaseTranscript(_ id: UUID) {
        watchTasks[id]?.cancel()
        watchTasks[id] = nil
        if let url = activityWatches[id]?.transcriptURL { claimedTranscripts.remove(url) }
        activityWatches[id] = nil
    }
}

/// Hosts the live terminals for the workspace's sessions in the detail pane.
///
/// One `TerminalSession` per live session; its view is added to a stable host
/// **once** and shown/hidden by toggling `isHidden` + surface visibility — never
/// re-parented (re-adding blanked surfaces in the prior in-window attempt).
/// Selecting a session lazily brings its agent's container up, then creates and
/// shows the terminal; other sessions persist hidden in the background. While a
/// container builds/rebuilds, a centered spinner + status is shown instead.

/// A window's live session surfaces (terminals, chats, launches, drafts and
/// the activity watcher), shared by its panes — so a session keeps running
/// when it moves between panes, and each session runs once per window.
@MainActor
final class SessionSurfaces {
    let controller: WorkspaceController
    var terminals: [UUID: TerminalSession] = [:]
    var chats: [UUID: ChatSessionView] = [:]
    var drafts: [UUID: (text: String, urls: [URL], send: Bool)] = [:]
    var pending: Set<UUID> = []
    /// Sessions whose sandbox couldn't be brought up, with why: not retried
    /// until the user says so (a refresh used to relaunch — and fail — forever).
    var launchFailures: [UUID: String] = [:]
    var searchWindows: [UUID: TerminalSearchWindowController] = [:]
    /// Whether some pane is showing the session (set by the pane tree).
    var isShown: (UUID) -> Bool = { _ in false }
    /// A terminal's process exited (routed to the pane showing it).
    var onTerminalExit: (UUID) -> Void = { _ in }
    /// A chat's agent exited on its own (routed to the pane showing it).
    var onChatAgentExit: (UUID) -> Void = { _ in }
    /// A chat's usage or model changed (routed to the pane showing it).
    var onChatStatus: (UUID) -> Void = { _ in }
    /// When each chat was last reconnected without being asked (at most once a minute).
    var lastAutoReconnect: [UUID: Date] = [:]

    fileprivate lazy var runtime = TerminalRuntimeController(
        controller: controller,
        isTerminalAlive: { [unowned self] id in self.terminals[id] != nil },
        isSessionVisible: { [unowned self] id in NSApp.isActive && self.isShown(id) },
        onTerminalDidExit: { [unowned self] id in self.onTerminalExit(id) })

    /// Background tasks of every running Claude session in this window.
    lazy var backgroundTasks = BackgroundTaskMonitor(
        controller: controller,
        isAlive: { [unowned self] id in
            self.chats[id] != nil || (self.terminals[id] != nil && !self.runtime.isExited(id))
        },
        isVisible: { [unowned self] id in NSApp.isActive && self.isShown(id) })

    init(controller: WorkspaceController) {
        self.controller = controller
        backgroundTasks.start()
    }
}

/// One pane of the detail area: shows a single session (terminal or chat)
/// from the window's shared `SessionSurfaces`, with its status, restart and
/// kit banner. `PaneTreeController` arranges several of these in splits.
@MainActor
final class TerminalStackController: NSViewController {
    private static let terminalPasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .URL, .string, .tiff, .png
    ]

    private let controller: WorkspaceController
    let surfaces: SessionSurfaces
    private var runtime: TerminalRuntimeController { surfaces.runtime }
    private var terminals: [UUID: TerminalSession] {
        get { surfaces.terminals }
        set { surfaces.terminals = newValue }
    }
    /// Sessions shown as native chat (ACP) instead of a terminal.
    private var chats: [UUID: ChatSessionView] {
        get { surfaces.chats }
        set { surfaces.chats = newValue }
    }
    /// Drafts for chats still starting (Services, Shortcuts).
    private var drafts: [UUID: (text: String, urls: [URL], send: Bool)] {
        get { surfaces.drafts }
        set { surfaces.drafts = newValue }
    }
    private var pending: Set<UUID> {
        get { surfaces.pending }
        set { surfaces.pending = newValue }
    }
    private var cancellables: Set<AnyCancellable> = []

    /// The session this pane shows (the pane tree decides; nil = empty pane).
    private(set) var shownSession: UUID?
    /// Or the Files tree + editor for a session's folder (exclusive with a session).
    private(set) var shownFiles: FilesTarget?
    private(set) var filesPane: FilesPaneController?
    /// "Add to Chat" from this pane's Files tree.
    var onFilesAddToChat: (([URL], FilesTarget) -> Void)?
    /// Focused pane: the one the sidebar selection and toolbar act on.
    var isFocused = true { didSet { updateFocusRing() } }
    /// Draw the focus ring only when there's more than one pane.
    var showsFocusRing = false {
        didSet {
            updateFocusRing()
            closePaneButton.isHidden = !showsFocusRing
            emptyCloseButton.isHidden = !showsFocusRing
        }
    }
    /// Close this pane (title-strip ✕, shown when split).
    var onClosePane: (() -> Void)?
    /// Split this pane (title-strip buttons): a new empty pane on that side.
    var onSplit: ((PaneTreeController.Edge) -> Void)?
    /// Show this pane's session folder (or the workspace) as Files beside it.
    var onOpenFiles: ((_ changesOnly: Bool) -> Void)?
    /// Open a file (from a link in the chat) in the Files pane beside this one.
    var onOpenFileInFiles: ((URL, Int?) -> Void)?
    private let closePaneButton = NSButton()
    private let filesPaneButton = NSButton()
    /// Chat ⇄ Terminal for this pane's session (agents that can chat).
    private let chatModeButton = NSButton()
    private let splitRightButton = NSButton()
    private let splitDownButton = NSButton()
    /// Title-strip pane controls: Files, Split Right, Split Down, Close.
    private let paneControls = NSStackView()
    /// An empty pane's own way out: Show Files / Close Pane, under its hint.
    private let emptyActions = NSStackView()
    private let emptyFilesButton = NSButton(title: "Show Files", target: nil, action: nil)
    private let emptyCloseButton = NSButton(title: "Close Pane", target: nil, action: nil)
    /// A session that couldn't start: Try Again, and the settings that broke it.
    private let failureActions = NSStackView()
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let editSettingsButton = NSButton(title: "Edit Kits…", target: nil, action: nil)
    private var editSettingsPane: InspectorPane = .kits
    /// Zero-width the Claude readout while it's hidden so it doesn't squeeze
    /// the title in a narrow pane.
    private lazy var claudeStatsCollapsed = claudeStats.widthAnchor.constraint(equalToConstant: 0)

    private let host = NSView()
    // Session header bar
    private let headerBar = NSView()
    private let sidebarToggle = NSButton()
    private var headerLeadingConstraint: NSLayoutConstraint!
    /// Called when the sidebar-toggle button is clicked (wired by the window).
    var onToggleSidebar: (() -> Void)?
    /// The active session's identity, published to the window's native toolbar
    /// (agent badge + title/subtitle). `nil` when no session is shown.
    /// `agent` is nil for a Files pane that isn't any session's (no badge).
    struct Chrome { let agent: AgentKind?; let title: String; let subtitle: String }
    var onChromeChange: ((Chrome?) -> Void)?
    /// Live status for the toolbar: text ("Working  ◷ 39m 16s" / "Ready") and
    /// whether the agent is currently working (drives the green tint).
    var onStatusChange: ((String, Bool) -> Void)?
    private let headerBadge = AgentBadgeView(side: 30, fontSize: 12, radius: 9)
    private let headerName = NSTextField(labelWithString: "")
    private let headerSub = NSTextField(labelWithString: "")
    private let headerStatus = NSTextField(labelWithString: "")
    // Session action icons (right of the header): reveal in Finder, stop, restart.
    private let revealButton = NSButton()
    private let stopButton = NSButton()
    private let headerRestartButton = NSButton()
    private let headerActions = NSStackView()
    private let headerLine = NSView()
    private var activeSessionID: UUID?
    // Framed terminal
    private let frameView = NSView()
    private let titleStrip = LayoutReportingView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let titleLine = NSView()
    /// Claude model/effort choosers + context/tokens/cost, trailing edge of the title strip.
    private let claudeStats = ClaudeStatsView()
    /// Over an unfocused pane (when split): a translucent wash of the background.
    private let dimOverlay = PassThroughView()
    /// Sandbox · folder · branch chips (replaces the plain title for sessions).
    private let contextBar = SessionContextBar()
    /// "2 running" — the session's background tasks; opens their list.
    private let backgroundPill = CollapsingButton()
    private var backgroundPopover: NSPopover?
    // Kit startup banner (failed / warning / still installing), above the frame.
    private let kitBanner = KitStartupBannerView()
    private var frameTopNoBanner: NSLayoutConstraint?
    private var frameTopWithBanner: NSLayoutConstraint?
    /// Banner findings the user dismissed (by `Content.signature`), so
    /// a poll doesn't bring the same banner back but a rebuild's new findings do.
    private var dismissedKitBanners: Set<String> = []
    /// Whether the pane is showing a session (active or exited); the banner then
    /// reports that session's container. When false, `kitBannerFallbackAgent`
    /// (set in the no-selection state) reports the workspace's primary container
    /// instead, so a failing sandbox is visible before any session is opened.
    private var kitBannerContextActive = false
    private var kitBannerFallbackAgent: AgentKind?
    // Centered status (building / no selection)
    private let statusStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "Select a session")
    private let spinner = NSProgressIndicator()
    private let restartButton = NSButton()
    /// Local event monitor that intercepts Cmd+V (image paste) and Cmd+F (search).
    private var pasteEventMonitor: Any?
    /// One search window per session; opened by Cmd+F, closed when session ends.
    private var searchWindows: [UUID: TerminalSearchWindowController] {
        get { surfaces.searchWindows }
        set { surfaces.searchWindows = newValue }
    }

    private var theme: ThemeColors { controller.theme.colors }

    init(controller: WorkspaceController, surfaces: SessionSurfaces) {
        self.controller = controller
        self.surfaces = surfaces
        super.init(nibName: nil, bundle: nil)
    }

    // MARK: Pane

    /// Show `id` in this pane (nil = empty). Unsaved Files edits are the
    /// caller's to confirm first (`confirmLeavingFiles`).
    func show(_ id: UUID?) {
        dropFilesPane()
        shownSession = id
        refresh()
    }

    /// Show the Files tree + editor for `target` instead of a session.
    func showFiles(_ target: FilesTarget) {
        shownSession = nil
        shownFiles = target
        refresh()
    }

    /// Before replacing or closing a Files pane: save/discard edits (false = cancel).
    func confirmLeavingFiles() -> Bool { filesPane?.confirmClose() ?? true }

    private func dropFilesPane() {
        shownFiles = nil
        guard let filesPane else { return }
        filesPane.view.superview?.removeFromSuperview()
        filesPane.removeFromParent()
        self.filesPane = nil
    }

    private func presentFiles(_ target: FilesTarget) {
        let files: FilesPaneController
        if let existing = filesPane {
            files = existing
        } else {
            files = FilesPaneController(compact: true)
            files.onAddToChat = { [weak self] urls in
                guard let self, let target = self.shownFiles else { return }
                self.onFilesAddToChat?(urls, target)
            }
            addChild(files)
            // The editor paints the system text background, not the terminal's.
            let surface = FilesSurfaceView()
            files.view.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(files.view)
            NSLayoutConstraint.activate([
                files.view.topAnchor.constraint(equalTo: surface.topAnchor),
                files.view.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
                files.view.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                files.view.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            ])
            addTerminalView(surface)
            filesPane = files
        }
        guard let surface = files.view.superview else { return }
        let (url, _) = target.resolve(in: controller)
        let agent = target.session.flatMap { controller.session(id: $0)?.containerAgentKind } ?? controller.primaryAgent
        let access = controller.sandboxAccess(for: url, agent: agent)
        files.setRoot(url, access: access)
        hideHostContents(except: surface)
        surface.isHidden = false
        activeSessionID = nil
        // Where these files are and what they're shared with — not the session's name.
        titleLabel.stringValue = "\(shortHome(url.path)) — \(access.titleSummary)"
        titleLabel.isHidden = false
        contextBar.isHidden = true
        titleLabel.toolTip = "These files are shared with sandbox “\(access.sandbox)” — see the Sandbox line under the file list"
        backgroundPill.isHidden = true
        filesPaneButton.isHidden = true
        chatModeButton.isHidden = true
        claudeStats.isHidden = true
        claudeStatsCollapsed.isActive = true
        frameView.isHidden = false
        restartButton.isHidden = true
        spinner.stopAnimation(nil)
        statusStack.isHidden = true
        kitBannerContextActive = false
        kitBannerFallbackAgent = nil
        updateKitBanner()
        updateFocusRing()
        onChromeChange?(nil)
        onStatusChange?("", false)
    }

    /// Re-send this pane's identity/status to the window (it became focused).
    func reemitChrome() {
        if let id = activeSessionID, id == shownSession, let session = controller.session(id: id) {
            configureHeader(session)
            updateHeaderStatus(id)
        } else if let files = shownFiles {
            // A Files pane speaks for its session (or just its folder).
            let (url, title) = files.resolve(in: controller)
            if let id = files.session, let session = controller.session(id: id) {
                onChromeChange?(Chrome(agent: session.agent, title: session.name,
                                       subtitle: "Files · \(shortHome(url.path))"))
                updateHeaderStatus(id)
            } else {
                onChromeChange?(Chrome(agent: nil, title: "Files — \(title)", subtitle: shortHome(url.path)))
                onStatusChange?("", false)
            }
        } else {
            onChromeChange?(nil)
            onStatusChange?("", false)
        }
    }

    /// With several panes, the ones not in focus are dimmed slightly (no ring).
    private func updateFocusRing() {
        guard isViewLoaded else { return }
        let c = controller.theme.colors
        frameView.layer?.borderColor = c.border.cgColor
        frameView.layer?.borderWidth = 1
        view.layer?.borderWidth = 0
        dimOverlay.layer?.backgroundColor = c.termBg.withAlphaComponent(0.2).cgColor
        dimOverlay.isHidden = !(showsFocusRing && !isFocused)
    }

    /// Hide everything in this pane's host except `keep`.
    private func hideHostContents(except keep: NSView? = nil) {
        for v in host.subviews where v !== keep {
            v.isHidden = true
            (v as? AppTerminalView)?.setSurfaceVisible(false)
        }
    }

    /// Bring a session's view into this pane (it may have been in another).
    private func adopt(_ view: NSView) {
        guard view.superview !== host else { return }
        view.removeFromSuperview()
        addTerminalView(view)
        (view as? AppTerminalView)?.setSurfaceVisible(false)   // re-armed visible by the caller
    }

    /// The pane's views were re-attached to the window (split rebuild): a
    /// libghostty surface stops drawing until its visibility is re-asserted.
    func redrawSurface() {
        guard let id = shownSession, let terminal = terminals[id], terminal.view.superview === host,
              !terminal.view.isHidden else { return }
        terminal.view.setSurfaceVisible(false)
        terminal.view.setSurfaceVisible(true)
    }

    @objc private func closePaneClicked() { onClosePane?() }

    /// The sandbox wouldn't come up: say why, and offer to fix the settings or retry.
    private func showLaunchFailure(_ message: String) {
        showStatus("Couldn't start the sandbox\n\n" + message, busy: false)
        let lower = message.lowercased()
        editSettingsPane = lower.contains("kit") ? .kits : lower.contains("mount") ? .mounts : .sandboxes
        editSettingsButton.title = editSettingsPane == .kits ? "Edit Kits…"
            : editSettingsPane == .mounts ? "Edit Mounts…" : "Sandbox Settings…"
        failureActions.isHidden = false
    }

    @objc private func retryLaunch() {
        guard let id = shownSession else { return }
        surfaces.launchFailures[id] = nil
        refresh()
    }

    @objc private func editSettingsForFailure() {
        NotificationCenter.default.post(name: InspectorView.openRequest, object: controller,
                                        userInfo: ["pane": editSettingsPane.rawValue])
    }
    @objc private func splitRightClicked() { onSplit?(.trailing) }
    @objc private func splitDownClicked() { onSplit?(.bottom) }
    @objc private func openFilesClicked() { onOpenFiles?(false) }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = AppearanceReactiveView()
        // The window's appearance is authoritative; nudge the global appearance
        // source when it settles/changes (fixes the launch race in `.system` mode)
        // and repaint. `AppAppearance` re-resolving flips every window's palette.
        container.onAppearanceChange = { [weak self] appearance in
            AppAppearance.shared.systemAppearanceSettled(appearance)
            self?.applyTheme()
        }
        container.onPasteboardDrag = { [weak self] pasteboard in
            self?.canInsertPasteboard(pasteboard) == true
        }
        container.onPasteboardDrop = { [weak self] pasteboard in
            self?.insertPasteboard(pasteboard) == true
        }
        container.registerForDraggedTypes(Self.terminalPasteboardTypes)
        container.wantsLayer = true   // so the panel background actually paints
        for v in [headerBar, headerLine, frameView, titleStrip, titleLine, host] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.wantsLayer = true
        }

        // Header bar: agent badge + identity, with a hairline at the bottom.
        headerName.translatesAutoresizingMaskIntoConstraints = false
        headerName.font = .systemFont(ofSize: 14.5, weight: .semibold)
        headerName.lineBreakMode = .byTruncatingTail
        headerName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerSub.translatesAutoresizingMaskIntoConstraints = false
        headerSub.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        headerSub.textColor = .secondaryLabelColor
        headerSub.lineBreakMode = .byTruncatingMiddle
        headerSub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let headerText = NSStackView(views: [headerName, headerSub])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 1
        headerText.translatesAutoresizingMaskIntoConstraints = false
        headerStatus.translatesAutoresizingMaskIntoConstraints = false
        headerStatus.font = .systemFont(ofSize: 12, weight: .medium)
        headerStatus.textColor = .secondaryLabelColor
        sidebarToggle.translatesAutoresizingMaskIntoConstraints = false
        sidebarToggle.isBordered = false
        sidebarToggle.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
        sidebarToggle.imagePosition = .imageOnly
        sidebarToggle.target = self
        sidebarToggle.action = #selector(toggleSidebarClicked)

        for (button, symbol, action, tip) in [
            (revealButton, "folder", #selector(revealInFinderClicked), "Reveal folder in Finder"),
            (stopButton, "stop", #selector(stopClicked), "Stop the session"),
            (headerRestartButton, "arrow.clockwise", #selector(headerRestartClicked), "Restart the session"),
        ] {
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        headerActions.orientation = .horizontal
        headerActions.spacing = 10
        headerActions.translatesAutoresizingMaskIntoConstraints = false
        // The reveal/stop/restart actions now live in the window NSToolbar (see
        // MainWindowController). headerActions is kept as an empty trailing spacer
        // so the header-status layout constraints are unaffected.
        headerActions.setViews([], in: .leading)

        headerBar.addSubview(sidebarToggle)
        headerBar.addSubview(headerBadge)
        headerBar.addSubview(headerText)
        headerBar.addSubview(headerStatus)
        headerBar.addSubview(headerActions)
        headerBar.addSubview(headerLine)

        // Framed terminal: rounded border + title strip + the libghostty surface.
        frameView.layer?.cornerRadius = 12
        frameView.layer?.borderWidth = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleStrip.addSubview(titleLabel)
        titleStrip.addSubview(titleLine)
        claudeStats.translatesAutoresizingMaskIntoConstraints = false
        claudeStats.isHidden = true
        claudeStatsCollapsed.isActive = true
        claudeStats.onModelPicked = { [weak self] id in self?.modelPicked(id) }
        claudeStats.onEffortPicked = { [weak self] level in self?.effortPicked(level) }
        titleStrip.addSubview(claudeStats)
        contextBar.translatesAutoresizingMaskIntoConstraints = false
        contextBar.isHidden = true
        contextBar.onShowFiles = { [weak self] in self?.onOpenFiles?(false) }
        contextBar.onShowChanges = { [weak self] in self?.onOpenFiles?(true) }
        contextBar.onWidthChange = { [weak self] in self?.shareTitleStrip() }
        // Not from inside layout(): the readout's new constraints would wait a pass.
        titleStrip.onLayout = { [weak self] in DispatchQueue.main.async { self?.shareTitleStrip() } }
        titleStrip.addSubview(contextBar)
        backgroundPill.translatesAutoresizingMaskIntoConstraints = false
        backgroundPill.bezelStyle = .inline
        backgroundPill.controlSize = .small
        backgroundPill.font = .systemFont(ofSize: 11, weight: .medium)
        backgroundPill.image = NSImage(systemSymbolName: "square.stack.3d.up",
                                       accessibilityDescription: "Background tasks")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        backgroundPill.imagePosition = .imageLeading
        backgroundPill.target = self
        backgroundPill.action = #selector(showBackgroundTasks)
        backgroundPill.setAccessibilityIdentifier("background-tasks-pill")
        backgroundPill.isHidden = true
        titleStrip.addSubview(backgroundPill)
        for (button, symbol, tip, action, id) in [
            (chatModeButton, "terminal", "Show as Terminal", #selector(toggleChatClicked), "pane-chat-mode"),
            (filesPaneButton, "folder", "Show Files beside this pane (⇧⌥⌘0)", #selector(openFilesClicked), "pane-files"),
            (splitRightButton, "rectangle.split.2x1", "Split Right (⌘D)", #selector(splitRightClicked), "pane-split-right"),
            (splitDownButton, "rectangle.split.1x2", "Split Down (⇧⌘D)", #selector(splitDownClicked), "pane-split-down"),
            (closePaneButton, "xmark", "Close Pane (⌥⌘W)", #selector(closePaneClicked), "pane-close"),
        ] {
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            button.imagePosition = .imageOnly
            button.toolTip = tip
            button.target = self
            button.action = action
            button.setAccessibilityLabel(tip)
            button.setAccessibilityIdentifier(id)
        }
        closePaneButton.isHidden = true
        paneControls.orientation = .horizontal
        paneControls.spacing = 10
        paneControls.translatesAutoresizingMaskIntoConstraints = false
        chatModeButton.isHidden = true
        paneControls.setViews([chatModeButton, filesPaneButton, splitRightButton, splitDownButton, closePaneButton],
                              in: .leading)
        titleStrip.addSubview(paneControls)
        frameView.addSubview(titleStrip)
        frameView.addSubview(host)

        // Centered status.
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 15)
        // Selectable so errors (e.g. sbx create failures) can be copied out;
        // long ones wrap within the pane instead of running off both sides.
        statusLabel.isSelectable = true
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.cell?.wraps = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusStack.orientation = .vertical
        statusStack.alignment = .centerX
        statusStack.spacing = 12
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        restartButton.title = "Restart Session"
        restartButton.bezelStyle = .rounded
        restartButton.controlSize = .large
        restartButton.target = self
        restartButton.action = #selector(restartClicked)
        restartButton.isHidden = true
        statusStack.addArrangedSubview(spinner)
        statusStack.addArrangedSubview(statusLabel)
        statusStack.addArrangedSubview(restartButton)
        // An empty pane (just split, or its session closed): say how to fill
        // it, and offer Files / Close right there.
        emptyFilesButton.bezelStyle = .rounded
        emptyFilesButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        emptyFilesButton.imagePosition = .imageLeading
        emptyFilesButton.target = self
        emptyFilesButton.action = #selector(openFilesClicked)
        emptyFilesButton.setAccessibilityIdentifier("empty-pane-files")
        emptyCloseButton.bezelStyle = .rounded
        emptyCloseButton.target = self
        emptyCloseButton.action = #selector(closePaneClicked)
        emptyCloseButton.isHidden = true
        emptyCloseButton.setAccessibilityIdentifier("empty-pane-close")
        emptyActions.orientation = .horizontal
        emptyActions.spacing = 10
        emptyActions.setViews([emptyFilesButton, emptyCloseButton], in: .leading)
        emptyActions.isHidden = true
        statusStack.addArrangedSubview(emptyActions)
        for b in [retryButton, editSettingsButton] { b.bezelStyle = .rounded; b.target = self }
        retryButton.action = #selector(retryLaunch)
        retryButton.keyEquivalent = "\r"
        editSettingsButton.action = #selector(editSettingsForFailure)
        failureActions.orientation = .horizontal
        failureActions.spacing = 10
        failureActions.setViews([editSettingsButton, retryButton], in: .leading)
        failureActions.isHidden = true
        statusStack.addArrangedSubview(failureActions)

        // The session identity + actions now live in the window's native
        // NSToolbar (see MainWindowController); the detail pane is just the framed
        // terminal, anchored below the toolbar via the safe-area guide.
        container.addSubview(frameView)
        container.addSubview(statusStack)

        // Kit startup banner: sits between the toolbar and the framed terminal
        // when a kit failed/warned/is still installing; otherwise collapsed.
        kitBanner.translatesAutoresizingMaskIntoConstraints = false
        kitBanner.isHidden = true
        kitBanner.onShowLog = { [weak self] agent in self?.controller.openKitLog(for: agent) }
        kitBanner.onRebuild = { [weak self] agent in self?.confirmKitRebuild(for: agent) }
        kitBanner.onDismiss = { [weak self] signature in
            self?.dismissedKitBanners.insert(signature)
            self?.updateKitBanner()
        }
        kitBanner.onAdopt = { [weak self] agent in self?.controller.adoptKitDrift(for: agent) }
        kitBanner.onIgnoreDrift = { [weak self] agent in self?.controller.ignoreKitDrift(for: agent) }
        container.addSubview(kitBanner)
        let frameTopNoBanner = frameView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 14)
        let frameTopWithBanner = frameView.topAnchor.constraint(equalTo: kitBanner.bottomAnchor, constant: 12)
        self.frameTopNoBanner = frameTopNoBanner
        self.frameTopWithBanner = frameTopWithBanner

        NSLayoutConstraint.activate([
            kitBanner.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 12),
            kitBanner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            kitBanner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            frameTopNoBanner,
            frameView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            frameView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            frameView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            titleStrip.topAnchor.constraint(equalTo: frameView.topAnchor),
            titleStrip.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            titleStrip.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            titleStrip.heightAnchor.constraint(equalToConstant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: titleStrip.leadingAnchor, constant: 14),
            contextBar.leadingAnchor.constraint(equalTo: titleStrip.leadingAnchor, constant: 10),
            contextBar.centerYAnchor.constraint(equalTo: titleStrip.centerYAnchor),
            contextBar.trailingAnchor.constraint(lessThanOrEqualTo: backgroundPill.leadingAnchor, constant: -10),
            contextBar.trailingAnchor.constraint(lessThanOrEqualTo: claudeStats.leadingAnchor, constant: -10),
            contextBar.trailingAnchor.constraint(lessThanOrEqualTo: paneControls.leadingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: titleStrip.centerYAnchor),
            paneControls.trailingAnchor.constraint(equalTo: titleStrip.trailingAnchor, constant: -12),
            paneControls.centerYAnchor.constraint(equalTo: titleStrip.centerYAnchor),
            claudeStats.trailingAnchor.constraint(equalTo: paneControls.leadingAnchor, constant: -12),
            claudeStats.centerYAnchor.constraint(equalTo: titleStrip.centerYAnchor),
            claudeStats.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            backgroundPill.trailingAnchor.constraint(equalTo: claudeStats.leadingAnchor, constant: -8),
            backgroundPill.centerYAnchor.constraint(equalTo: titleStrip.centerYAnchor),
            backgroundPill.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            titleLine.leadingAnchor.constraint(equalTo: titleStrip.leadingAnchor),
            titleLine.trailingAnchor.constraint(equalTo: titleStrip.trailingAnchor),
            titleLine.bottomAnchor.constraint(equalTo: titleStrip.bottomAnchor),
            titleLine.heightAnchor.constraint(equalToConstant: 1),
            host.topAnchor.constraint(equalTo: titleStrip.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),

            statusStack.centerXAnchor.constraint(equalTo: frameView.centerXAnchor),
            statusStack.widthAnchor.constraint(lessThanOrEqualTo: frameView.widthAnchor, constant: -48),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            statusStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        // Topmost: dims the pane while another one has focus (clicks pass through).
        dimOverlay.wantsLayer = true
        dimOverlay.isHidden = true
        dimOverlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dimOverlay)
        NSLayoutConstraint.activate([
            dimOverlay.topAnchor.constraint(equalTo: container.topAnchor),
            dimOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            dimOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dimOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        self.view = container
        applyTheme()
    }

    /// Adjust the header for the sidebar's collapsed state (inset past the traffic
    /// lights) and reflect it in the toggle glyph.
    func setSidebarCollapsed(_ collapsed: Bool) {
        headerLeadingConstraint?.constant = collapsed ? 76 : 14
        sidebarToggle.image = NSImage(
            systemSymbolName: collapsed ? "sidebar.left" : "sidebar.left",
            accessibilityDescription: "Toggle Sidebar")
    }

    @objc private func toggleSidebarClicked() { onToggleSidebar?() }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(systemDidWake),
                                               name: SystemSleep.didWake, object: nil)
        // Intercept Cmd+V (image paste) and Cmd+F (search) before AppTerminalView
        // processes them. Both actions need a focused terminal view to activate.
        // Must not use `?? event` here: returning nil is how we consume the event;
        // falling back to `event` when nil is returned would pass it through to the
        // terminal, causing ghostty to type a stray "v" after injecting the path.
        pasteEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleTerminalKeyEquivalent(event)
        }
        controller.$revision.dropFirst().sink { [weak self] _ in
            self?.pruneClosed(); self?.refresh()
        }.store(in: &cancellables)
        controller.$activity.sink { [weak self] activity in
            // A rebuild recreates containers, so the affected terminals' exec
            // processes are dead — drop them so re-selecting relaunches.
            if activity?.hasPrefix("Rebuilding") == true { self?.dropAllTerminals() }
            self?.refresh()
        }.store(in: &cancellables)
        controller.theme.$colors.dropFirst().sink { [weak self] c in self?.applyTheme(c) }
            .store(in: &cancellables)
        // Kit startup findings arrive asynchronously after the container is up.
        // (`@Committed` publishes after the store, so reading the controller here
        // sees the new findings.)
        controller.$kitStartup.dropFirst().sink { [weak self] _ in self?.updateKitBanner() }
            .store(in: &cancellables)
        controller.$backgroundTasks.dropFirst().sink { [weak self] _ in self?.updateBackgroundPill() }
            .store(in: &cancellables)
        // The sandbox answered what it is: refresh a Files pane's title and line.
        controller.$sandboxSystems.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            if self.shownFiles != nil { return self.refresh() }
            if let id = self.activeSessionID, let session = self.controller.session(id: id) {
                self.configureHeader(session)
            }
        }.store(in: &cancellables)
        // A tapped "background task finished" notification opens the list.
        NotificationCenter.default.publisher(for: NotificationManager.showBackgroundTasks)
            .sink { [weak self] note in
                guard let self, let id = note.object as? UUID, id == self.activeSessionID else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showBackgroundTasks() }
            }
            .store(in: &cancellables)
        controller.$kitDrift.dropFirst().sink { [weak self] _ in self?.updateKitBanner() }
            .store(in: &cancellables)
        // Live-update the header when runtime state changes (status, name, etc.).
        controller.$runtimes.dropFirst().sink { [weak self] _ in
            guard let self, let id = self.activeSessionID else { return }
            self.updateClaudeStats(id)
            guard !self.headerBar.isHidden else { return }
            self.updateHeaderStatus(id)
        }.store(in: &cancellables)
        // Tick the work timer every second via the shared workspace clock.
        controller.$clockTick.dropFirst()
            .sink { [weak self] _ in
                guard let self, let id = self.activeSessionID,
                      self.controller.runtime(id)?.status == .working,
                      !self.headerBar.isHidden else { return }
                self.updateHeaderStatus(id)
            }
            .store(in: &cancellables)
    }

    private func applyTheme(_ c: ThemeColors? = nil) {
        let c = c ?? controller.theme.colors
        view.layer?.backgroundColor = c.panel.cgColor
        headerBar.layer?.backgroundColor = c.panel.cgColor
        headerLine.layer?.backgroundColor = c.border.cgColor
        titleLine.layer?.backgroundColor = c.border.cgColor
        titleStrip.layer?.backgroundColor = c.termBg.cgColor
        frameView.layer?.backgroundColor = c.termBg.cgColor
        frameView.layer?.borderColor = c.border.cgColor
        host.layer?.backgroundColor = c.termBg.cgColor
        titleLabel.textColor = c.termDim
        claudeStats.applyTheme(c)
        kitBanner.applyTheme(c)
        for b in [closePaneButton, filesPaneButton, splitRightButton, splitDownButton, chatModeButton] {
            b.contentTintColor = c.termDim
        }
        contextBar.applyTheme(c)
        updateFocusRing()
        headerName.textColor = c.text
        sidebarToggle.contentTintColor = c.text2
        for b in [revealButton, stopButton, headerRestartButton] { b.contentTintColor = c.text2 }
    }

    // MARK: Display

    /// Single source of truth for what the detail pane shows.
    /// `selection` may be passed by the `$selection` sink; other callers pass nil
    /// to use the current one.
    func refresh() {
        // Files don't wait on the container.
        if let files = shownFiles { return presentFiles(files) }
        if controller.isBuilding {
            showStatus(controller.activity ?? "Building…", busy: true)
            return
        }
        guard let id = shownSession, let session = controller.session(id: id) else {
            onChromeChange?(nil)   // no session → window title falls back to folder
            onStatusChange?("", false)
            showStatus("Pick a session in the sidebar, or drag one here", busy: false)
            emptyActions.isHidden = false
            // No session: still surface the primary container's kit problems.
            kitBannerFallbackAgent = controller.primaryAgent
            updateKitBanner()
            return
        }
        if session.isChat, let failure = surfaces.launchFailures[id], chats[id] == nil {
            return showLaunchFailure(failure)
        }
        if session.isChat {
            if terminals[id] != nil { dropTerminal(id) }   // switched terminal → chat
            if let chat = chats[id], chat.session.needsReconnect, !SystemSleep.isAsleep, autoReconnect(id) {
                return   // its agent died off screen (e.g. while the Mac slept): bring it back
            }
            if let chat = chats[id] { showChat(id, chat) } else { launchChat(session) }
            return
        }
        if let failure = surfaces.launchFailures[id], terminals[id] == nil, chats[id] == nil {
            return showLaunchFailure(failure)
        }
        if chats[id] != nil { closeChat(id) }   // switched chat → terminal
        if runtime.isExited(id) {
            showExited(session)
        } else if terminals[id] != nil {
            showActive(id)
        } else {
            launch(session)
        }
    }

    private func showStatus(_ text: String, busy: Bool) {
        hideHostContents()
        headerBar.isHidden = true
        frameView.isHidden = true
        restartButton.isHidden = true
        emptyActions.isHidden = true
        failureActions.isHidden = true
        statusLabel.stringValue = text
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        updateFocusRing()
        statusStack.isHidden = false
        kitBannerContextActive = false
        kitBannerFallbackAgent = nil
        updateKitBanner()
    }

    // MARK: Kit startup banner

    /// Rebuild from the kit banner: confirm (it ends the container's sessions),
    /// then force-recreate so the current kit contents are applied.
    private func confirmKitRebuild(for agent: AgentKind) {
        let name = controller.containerName(for: agent)
        let alert = NSAlert()
        alert.messageText = "Rebuild “\(name)”?"
        alert.informativeText = "The sandbox is recreated with the current kits and mounts, which reloads every "
            + "kit’s contents. Any session running in it will end. Workspace files are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller.rebuildContainer(for: agent, force: true)
    }

    /// Show/hide the kit startup banner for the active session's container.
    /// Findings come from `WorkspaceController.kitStartup` (polled from the
    /// sandbox's dispatcher log); a dismissed finding stays hidden until the
    /// findings change (e.g. after a rebuild).
    private func updateKitBanner() {
        var content: KitStartupBannerView.Content?
        var agent: AgentKind?
        if kitBannerContextActive, let id = activeSessionID, let session = controller.session(id: id) {
            agent = session.containerAgentKind
        } else if let fallback = kitBannerFallbackAgent {
            agent = fallback
        }
        if let agent, let status = controller.kitStartupStatus(for: agent), status.fetchError == nil {
            let candidate = KitStartupBannerView.Content(agent: agent, status: status)
            if candidate.isVisible, !dismissedKitBanners.contains(candidate.signature) { content = candidate }
        }
        // Startup problems take the slot first; kit drift shows when there are none.
        if content == nil, let agent, let drift = controller.kitDrift[agent] {
            let candidate = KitStartupBannerView.Content(agent: agent, drift: drift)
            if candidate.isVisible, !dismissedKitBanners.contains(candidate.signature) { content = candidate }
        }
        let show = content != nil
        if let content { kitBanner.configure(content) }
        kitBanner.isHidden = !show
        frameTopNoBanner?.isActive = !show
        frameTopWithBanner?.isActive = show
    }

    /// Runtime controller reported a deduped terminal/process exit.
    func terminalRuntimeDidExit(_ id: UUID) {
        if shownSession == id, let session = controller.session(id: id) {
            showExited(session)
        }
    }

    /// In-pane "process ended → restart" prompt (keeps the rest of the app usable,
    /// unlike a window-blocking modal that could fire for a background session).
    private func showExited(_ session: Session) {
        activeSessionID = session.id
        hideHostContents()
        headerBar.isHidden = false
        configureHeader(session)
        updateHeaderStatus(session.id)
        frameView.isHidden = true
        spinner.stopAnimation(nil)
        statusLabel.stringValue = "\(session.agent.displayName) exited."
        restartButton.isHidden = false
        statusStack.isHidden = false
        kitBannerContextActive = true
        updateKitBanner()
    }

    @objc private func restartClicked() {
        guard let id = activeSessionID, let session = controller.session(id: id) else { return }
        if session.isChat {
            closeChat(id)
            launchChat(session)
            return
        }
        runtime.resetExit(id)
        // Drop the dead terminal so launch() builds a fresh one.
        if let terminal = terminals[id] {
            terminal.view.removeFromSuperview()
            terminal.cleanup()
            terminals[id] = nil
            runtime.terminalRemoved(id)
        }
        restartButton.isHidden = true
        launch(session)
    }

    // MARK: Header session actions

    /// Open the active session's working directory in Finder (its own window,
    /// showing the project's contents — not the parent with the folder selected).
    @objc func revealInFinderClicked() {
        if activeSessionID == nil, let files = shownFiles {
            NSWorkspace.shared.open(files.resolve(in: controller).url)
            return
        }
        guard let id = activeSessionID, let s = controller.session(id: id) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: s.workdir))
    }

    /// Stop the active session's agent (terminate the terminal) → restart prompt.
    @objc func stopClicked() {
        if let id = activeSessionID, let chat = chats[id] {
            chat.session.cancel()   // stop the running turn; the chat stays open
            return
        }
        guard let id = activeSessionID, terminals[id] != nil else { return }
        terminals[id]?.view.removeFromSuperview()
        terminals[id]?.cleanup()
        terminals[id] = nil
        runtime.terminalRemoved(id)
        runtime.terminalDidExit(id)
    }

    /// Restart the active session from the header/toolbar.
    @objc func headerRestartClicked() { restartClicked() }

    /// Toolbar: show the active Claude session as a native chat, or back as a
    /// terminal. Same conversation either way (resumed in the new surface).
    @objc func toggleChatClicked() {
        guard let id = activeSessionID, let session = controller.session(id: id),
              SbxCommand.supportsACP(session.agent) else { return }
        controller.setChat(id, !session.isChat)
    }

    /// Show the terminal for `id` in this pane (moving it here if it was in
    /// another), hiding the rest and the status.
    private func showActive(_ id: UUID) {
        guard let terminal = terminals[id], let session = controller.session(id: id) else { return }
        adopt(terminal.view)
        hideHostContents(except: terminal.view)
        terminal.view.isHidden = false
        terminal.view.setSurfaceVisible(true)
        activeSessionID = id
        configureHeader(session)
        updateHeaderStatus(id)
        headerBar.isHidden = false
        frameView.isHidden = false
        spinner.stopAnimation(nil)
        statusStack.isHidden = true
        kitBannerContextActive = true
        updateKitBanner()
        updateFocusRing()
        if isFocused { view.window?.makeFirstResponder(terminals[id]?.view) }
    }

    private func configureHeader(_ session: Session) {
        let container = controller.containerName(for: session.containerAgentKind)
        headerBadge.configure(session.agent)
        headerName.stringValue = session.name
        headerSub.stringValue = "\(container) · \(shortHome(session.workdir))"
        let program = session.agent == .shell ? "bash" : session.agent.rawValue
        titleLabel.stringValue = "\(program) — \(container)" + (session.isChat ? " · chat (ACP)" : "")
        // The strip shows where the session runs: sandbox, folder, branch.
        let folder = URL(fileURLWithPath: session.workdir)
        contextBar.update(folder: folder,
                          access: controller.sandboxAccess(for: folder, agent: session.containerAgentKind))
        contextBar.toolTip = titleLabel.stringValue
        contextBar.isHidden = false
        titleLabel.isHidden = true
        updateClaudeStats(session.id)
        updateBackgroundPill()
        filesPaneButton.isHidden = false
        let canChat = SbxCommand.supportsACP(session.agent) && session.containerAgent == nil
        chatModeButton.isHidden = !canChat
        let modeTip = session.isChat ? "Show as Terminal" : "Show as Chat"
        chatModeButton.image = NSImage(systemSymbolName: session.isChat ? "terminal" : "bubble.left.and.text.bubble.right",
                                       accessibilityDescription: modeTip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        chatModeButton.toolTip = modeTip
        chatModeButton.setAccessibilityLabel(modeTip)
        onChromeChange?(Chrome(agent: session.agent, title: session.name,
                               subtitle: "\(container) · \(shortHome(session.workdir))"))
    }

    /// Split the strip between the context chips and the Claude readout: the
    /// readout sheds its optional pieces before the chips are squeezed.
    private func shareTitleStrip() {
        guard !claudeStats.isHidden else { return }
        var room = titleStrip.bounds.width - 10 - 12 - paneControls.fittingSize.width - 12
        if !backgroundPill.isHidden { room -= backgroundPill.fittingSize.width + 8 }
        if !contextBar.isHidden { room -= contextBar.preferredMinWidth + 10 }
        claudeStats.maxWidth = max(room, 0)
    }

    /// Title-strip readout: shown for Claude sessions only; numbers fill in as
    /// status reports arrive, the model falls back to the workspace's choice.
    func updateClaudeStats(_ id: UUID) {
        guard let session = controller.session(id: id) else { return }
        // A chat reports through ACP (usage updates, the model it answered
        // with); a terminal through Claude Code's status line. Same readout.
        let chat = session.isChat ? chats[id]?.session : nil
        claudeStats.isHidden = session.agent != .claude || (session.isChat && chat == nil)
        claudeStatsCollapsed.isActive = claudeStats.isHidden
        guard session.agent == .claude else { return }
        if let chat {
            claudeStats.update(status: Self.chatStatus(chat), defaultModel: chat.launchModel,
                               defaultEffort: chat.launchEffort)
        } else if !session.isChat {
            claudeStats.update(status: controller.claudeStatus(id), defaultModel: controller.claudeModel,
                               defaultEffort: controller.claudeEffort)
        }
        shareTitleStrip()
    }

    /// A chat's readout, in the status line's terms.
    private static func chatStatus(_ chat: ChatSession) -> ClaudeSessionStatus {
        var status = ClaudeSessionStatus()
        status.sessionID = chat.sessionID
        if let model = chat.liveModel ?? chat.launchModel {
            status.model = .init(id: model, displayName: ClaudeModelChoice.title(forID: ClaudePriceBook.normalize(model)))
        }
        if let effort = chat.launchEffort { status.effort = .init(level: effort) }
        if let usage = chat.usage, usage.size > 0 {
            status.contextWindow = .init(contextWindowSize: usage.size,
                                         usedPercentage: Double(usage.used) / Double(usage.size) * 100)
        }
        if let cost = chat.usage?.cost { status.cost = .init(totalCostUSD: cost) }
        return status
    }

    /// Shown while the session has background tasks running, or finished ones
    /// from the last half hour; green while anything runs.
    private func updateBackgroundPill() {
        guard let id = activeSessionID else { backgroundPill.isHidden = true; return }
        let tasks = controller.backgroundTasks(id)
        let running = tasks.filter(\.isRunning).count
        let recent = tasks.filter {
            !$0.isRunning && !$0.orphaned && Date().timeIntervalSince($0.finishedAt ?? $0.startedAt) < 1800
        }.count
        backgroundPill.isHidden = running == 0 && recent == 0
        defer { shareTitleStrip() }
        let color: NSColor = running > 0 ? .hex("16a34a") : .secondaryLabelColor
        backgroundPill.attributedTitle = NSAttributedString(
            string: running > 0 ? "\(running) running" : "\(recent) done",
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 11, weight: .medium)])
        backgroundPill.contentTintColor = color
        backgroundPill.toolTip = running > 0
            ? "\(running) background task\(running == 1 ? "" : "s") running — click for details"
            : "Background tasks finished recently — click for details"
    }

    @objc func showBackgroundTasks() {
        guard let id = activeSessionID, view.window != nil else { return }
        if let open = backgroundPopover, open.isShown { open.close(); return }
        let list = BackgroundTasksView(controller: controller, sessionIDs: { [id] },
                                       loadOutput: { [controller] sid, task in await controller.backgroundOutput(sid, task) })
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: list.frame(width: 420, height: 380))
        let anchor: NSView = backgroundPill.isHidden ? titleStrip : backgroundPill
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor is NSButton ? .maxY : .minY)   // below (buttons are flipped)
        backgroundPopover = popover
    }

    /// Model chooser: persist for the workspace; offer to restart a live Claude
    /// session so it picks the model up (Claude Code fixes its model at launch —
    /// we never type `/model` into the PTY).
    private func modelPicked(_ modelID: String?) {
        controller.setClaudeModel(modelID)
        // A chat takes its model at launch too: relaunch it (resuming the
        // conversation) — now, or when the current turn ends.
        if let id = activeSessionID, let chat = chats[id]?.session {
            defer { updateClaudeStats(id) }
            guard ClaudePriceBook.normalize(modelID ?? "") != ClaudePriceBook.normalize(chat.launchModel ?? "") else { return }
            if case .running = chat.phase {
                chat.afterTurn = { [weak self] in self?.reconnectChat(id) }
            } else {
                reconnectChat(id)
            }
            return
        }
        offerClaudeRestart(changed: modelID != liveClaudeStatus?.model?.id,
                           title: "Restart with \(ClaudeModelChoice.title(forID: modelID))?",
                           what: "model")
    }

    /// Effort chooser: same deal as the model — fixed at launch via `--effort`.
    private func effortPicked(_ level: String?) {
        controller.setClaudeEffort(level)
        // A chat changes effort live.
        if let id = activeSessionID, let chat = chats[id]?.session {
            chat.setEffort(level)
            updateClaudeStats(id)
            return
        }
        offerClaudeRestart(changed: level != liveClaudeStatus?.effort?.level,
                           title: "Restart with \(ClaudeEffortChoice.title(forID: level)) effort?",
                           what: "effort level")
    }

    private var liveClaudeStatus: ClaudeSessionStatus? {
        activeSessionID.flatMap { controller.claudeStatus($0) }
    }

    /// After a model/effort change, offer to restart the live Claude session so
    /// it relaunches (resuming the conversation) with the new flags.
    private func offerClaudeRestart(changed: Bool, title: String, what: String) {
        defer { if let id = activeSessionID { updateClaudeStats(id) } }
        guard changed, let id = activeSessionID, let session = controller.session(id: id),
              session.agent == .claude, terminals[id] != nil, !runtime.isExited(id) else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Claude Code chooses its \(what) at launch. Restarting resumes this "
            + "conversation with the new \(what). New sessions in this workspace use it either way."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        restartClicked()
    }

    private func updateHeaderStatus(_ id: UUID) {
        guard let rt = controller.runtime(id) else {
            headerStatus.stringValue = ""
            onStatusChange?("", false)
            return
        }
        let label = rt.stoppedReason != nil ? "Stopped" : rt.status == .working ? "Working" : "Ready"
        let live = rt.liveWorkSeconds()
        let time = live > 0 ? "  ◷ \(formatWorkTime(live))" : ""
        headerStatus.stringValue = label + time
        headerStatus.textColor = rt.status == .working ? .hex("16a34a") : .secondaryLabelColor
        onStatusChange?(label + time, rt.status == .working)
    }

    private func shortHome(_ path: String) -> String {
        let h = FileManager.default.homeDirectoryForCurrentUser.path
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    // MARK: Launch

    /// Bring the session's container up (async), then create + show its terminal.
    private func launch(_ session: Session) {
        let id = session.id
        guard !pending.contains(id), terminals[id] == nil else { return }

        // Restore prior history: if this session ran before, resume that
        // conversation when its transcript still exists; if it's gone, ask
        // whether to start a new session instead.
        var resumeID: String? = nil
        if let tid = session.transcriptID {
            if TranscriptReader.transcriptExists(agent: session.agent, workdir: session.workdir,
                                                 home: controller.home, id: tid) {
                resumeID = tid
            } else if confirmStartFresh(session) {
                controller.clearTranscriptID(id)
            } else {
                return   // user declined; leave the session unopened
            }
        }

        pending.insert(id)
        showStatus(resumeID == nil ? "Starting \(session.agent.displayName)…"
                                   : "Restoring \(session.agent.displayName)…", busy: true)

        // Holds the pane until the terminal is up (its exit handler holds it weakly).
        Task { [self] in
            let containerName = await controller.ensureContainerReady(for: session.containerAgentKind)
            pending.remove(id)
            guard let containerName else {
                let message = controller.lastError ?? "Failed to start the sandbox."
                surfaces.launchFailures[id] = message
                if shownSession == id { showLaunchFailure(message) }
                return
            }
            // The session may have been closed while the container came up.
            guard controller.session(id: id) != nil, terminals[id] == nil else { return }
            // Leftovers from a crash/kill would share this conversation.
            await SbxClient.reapSessionProcessesAndWait(container: containerName,
                                                        match: "SANDSHELL_SESSION=\(id.uuidString)")

            await runtime.prepareLaunch(id, containerName: containerName)

            Log.info(.workspace, "launching \(session.agent.rawValue) terminal in “\(containerName)” at \(session.workdir)\(resumeID == nil ? "" : " (resume \(resumeID!))")")
            // Claude: model/effort choice + the status feed (model/context/cost readout).
            var claudeOptions: SbxCommand.ClaudeOptions? = nil
            if session.agent == .claude {
                let root = controller.rootURL
                let script = ClaudeStatusFeed.prepare(root: root)
                claudeOptions = SbxCommand.ClaudeOptions(
                    model: controller.claudeModel,
                    effort: controller.claudeEffort,
                    statusScriptPath: script?.path,
                    statusDir: script == nil ? nil : ClaudeStatusFeed.statusDir(root: root).path,
                    sessionID: id.uuidString,
                    sbxProxyAuth: await SbxClient.shared.hasAnthropicSecret(sandbox: containerName))
            }
            let terminal = TerminalSession(
                sessionID: id, containerName: containerName, agent: session.agent,
                workdir: session.workdir,
                mcpURL: controller.workspace.mcpURL,
                theme: controller.theme,
                resumeID: resumeID,
                claude: claudeOptions)
            terminal.onProcessExit = { [weak self] in self?.runtime.terminalDidExit(id) }
            addTerminalView(terminal.view)
            terminals[id] = terminal
            runtime.terminalStarted(id)
            runtime.startTracking(session, resumeID: resumeID)

            if shownSession == id { showActive(id) }
        }
    }

    /// The session's prior history is gone — ask whether to start fresh.
    private func confirmStartFresh(_ session: Session) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Couldn’t restore “\(session.name)”."
        alert.informativeText = "This session’s \(session.agent.displayName) history "
            + "is no longer available. Start a new session in its place?"
        alert.addButton(withTitle: "New Session")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func addTerminalView(_ tv: NSView) {
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isHidden = true
        host.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: host.topAnchor),
            tv.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    @discardableResult
    func insertExternalItems(_ urls: [URL]) -> Bool {
        if let id = activeSessionID, let chat = chats[id], !chat.isHidden {
            chat.addAttachments(urls: urls)
            return true
        }
        guard let context = activeTerminalContext(),
              let text = terminalInput(for: urls, workdir: context.session.workdir),
              !text.isEmpty else { return false }
        context.view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    // MARK: Chat sessions

    /// Whether an agent's transcripts land on the host (mounted config dir), so
    /// a resume id can be checked before it's tried.
    private static func transcriptsOnHost(_ agent: AgentKind, home: URL) -> Bool {
        switch agent {
        case .claude: return true
        case .codex: return FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path)
        default: return false
        }
    }

    /// Why a chat for `agent` can't work in `container` before launching it —
    /// no credential sbx's proxy could inject — or nil to go ahead. Claude keeps
    /// its own fallbacks (host login, inference gateway), so it's never blocked.
    private static func missingCredential(for agent: AgentKind, container: String, home: URL) async -> String? {
        guard agent != .claude, let service = ChatSession.credentialService(for: agent) else { return nil }
        if await SbxClient.shared.hasServiceSecret(service, sandbox: container) { return nil }
        // Codex also signs in from a host ~/.codex/auth.json (mounted when present).
        if agent == .codex,
           FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/auth.json").path) { return nil }
        return ChatSession.credentialHelp(for: agent)
    }

    /// Bring the container up, then start the session's ACP agent and show its
    /// chat. Resumes the prior conversation when its transcript still exists.
    private func launchChat(_ session: Session) {
        let id = session.id
        guard !pending.contains(id), chats[id] == nil else { return }
        pending.insert(id)
        showStatus("Starting \(session.agent.displayName) chat…", busy: true)
        Task { [weak self] in
            guard let self else { return }
            // Pending until the chat is registered: a second launch while this
            // one awaits would start another agent (and orphan one of them).
            defer { pending.remove(id) }
            let containerName = await controller.ensureContainerReady(for: session.containerAgentKind)
            guard let containerName else {
                let message = controller.lastError ?? "Failed to start the sandbox."
                surfaces.launchFailures[id] = message
                if shownSession == id { showLaunchFailure(message) }
                return
            }
            guard let current = controller.session(id: id), current.isChat, chats[id] == nil else { return }
            var resumeID: String?
            if let tid = current.transcriptID,
               !Self.transcriptsOnHost(current.agent, home: controller.home)
                || TranscriptReader.transcriptExists(agent: current.agent, workdir: current.workdir,
                                                     home: controller.home, id: tid) {
                // An agent whose history stays in the sandbox (Gemini; Codex without
                // a host ~/.codex) can't be checked from here: try, and session/load
                // falls back to a fresh conversation if it's gone.
                resumeID = tid
            }
            Log.info(.workspace, "launching \(current.agent.rawValue) chat in “\(containerName)” at \(current.workdir)\(resumeID.map { " (resume \($0))" } ?? "")")
            await SbxClient.reapSessionProcessesAndWait(container: containerName,
                                                        match: "SANDSHELL_SESSION=\(id.uuidString)")
            let proxyAuth = await SbxClient.shared.hasAnthropicSecret(sandbox: containerName)
            let unavailable = await Self.missingCredential(for: current.agent, container: containerName,
                                                           home: controller.home)
            let chat = ChatSession(title: current.agent.displayName, agent: current.agent,
                                   containerName: containerName,
                                   workdir: current.workdir, home: controller.home.path,
                                   mcpURL: controller.mcpURL, resumeID: resumeID, sbxProxyAuth: proxyAuth,
                                   sessionID: id, unavailable: unavailable,
                                   model: current.agent == .claude ? controller.claudeModel : nil,
                                   effort: current.agent == .claude ? controller.claudeEffort : nil)
            chat.onSessionID = { [controller] sid in controller.setTranscriptID(id, sid) }
            chat.onClosed = { [controller] why in controller.setStopped(id, why) }
            chat.onUnexpectedExit = { [surfaces] in surfaces.onChatAgentExit(id) }
            chat.onUsage = { [surfaces] in surfaces.onChatStatus(id) }
            controller.setStopped(id, nil)
            var lastPrompt: String?
            chat.onPrompt = { [controller] prompt in
                lastPrompt = prompt
                controller.autoName(id, from: prompt)
            }
            chat.onWorkingChange = { [controller, surfaces] working in
                let now = Date()
                let transition = controller.reportActivity(id, working: working, lastWrite: now, at: now)
                // Same "finished" notification terminals send, when you're elsewhere.
                if transition.finishedWork, let s = controller.session(id: id),
                   !(NSApp.isActive && surfaces.isShown(id)) {
                    NotificationManager.shared.sendWorkComplete(
                        sessionID: id, agentName: s.agent.displayName, sessionName: s.name,
                        lastPrompt: lastPrompt, workSeconds: transition.workSeconds, workdir: s.workdir)
                }
            }
            let view = ChatSessionView(session: chat)
            view.onReconnect = { [weak self] in self?.reconnectChat(id) }
            view.onOpenFile = { [weak self] url, line in self?.onOpenFileInFiles?(url, line) }
            view.onFork = { [weak self] reply in
                guard let self else { return }
                if self.controller.forkChat(id, upTo: reply) == nil { NSSound.beep() }
            }
            view.resolveFileURLs = { [weak self] urls in
                self?.materializeDroppedURLs(urls, workdir: current.workdir).map { URL(fileURLWithPath: $0) } ?? urls
            }
            addTerminalView(view)
            chats[id] = view
            controller.setLive(id, true)
            chat.start()
            if shownSession == id { showChat(id, view) }
            if let draft = drafts.removeValue(forKey: id) {
                view.applyDraft(text: draft.text, urls: draft.urls, send: draft.send)
            }
        }
    }

    /// Files dropped on a session's sidebar row: a chat gets them as
    /// attachments (now, or once it starts); a live terminal gets their paths.
    func dropFiles(_ urls: [URL], on id: UUID) {
        guard let session = controller.session(id: id) else { return }
        if session.isChat {
            queueDraft("", urls: urls, send: false, for: id)
        } else if activeSessionID == id {
            insertExternalItems(urls)
        }
    }

    /// Put a draft into the session's chat — now if it's open, else when it starts.
    func queueDraft(_ text: String, urls: [URL], send: Bool, for id: UUID) {
        if let chat = chats[id] { chat.applyDraft(text: text, urls: urls, send: send) }
        else { drafts[id] = (text, urls, send) }
    }

    private func showChat(_ id: UUID, _ chat: ChatSessionView) {
        adopt(chat)
        hideHostContents(except: chat)
        chat.isHidden = false
        guard let session = controller.session(id: id) else { return }
        activeSessionID = id
        configureHeader(session)
        updateHeaderStatus(id)
        headerBar.isHidden = false
        frameView.isHidden = false
        restartButton.isHidden = true
        spinner.stopAnimation(nil)
        statusStack.isHidden = true
        kitBannerContextActive = true
        updateKitBanner()
        updateFocusRing()
        if isFocused { chat.focusComposer() }
    }

    // MARK: Reconnecting chats

    /// A shown chat's agent exited on its own. While the Mac sleeps, wait for
    /// the wake; otherwise relaunch it (sandbox up, conversation resumed).
    func chatAgentExited(_ id: UUID) {
        guard !SystemSleep.isAsleep, shownSession == id else { return }
        _ = autoReconnect(id)
    }

    /// After a wake: the shown chat, if its agent died meanwhile.
    @objc private func systemDidWake() {
        guard let id = shownSession, chats[id]?.session.needsReconnect == true else { return }
        _ = autoReconnect(id)
    }

    /// Reconnect without being asked, at most once a minute per chat (a chat
    /// whose agent keeps dying waits for the Reconnect button instead).
    private func autoReconnect(_ id: UUID) -> Bool {
        if let last = surfaces.lastAutoReconnect[id], Date().timeIntervalSince(last) < 60 { return false }
        surfaces.lastAutoReconnect[id] = Date()
        reconnectChat(id)
        return true
    }

    /// What switching to Terminal and back did by hand: drop the dead chat and
    /// launch it again, resuming its conversation.
    func reconnectChat(_ id: UUID) {
        guard let session = controller.session(id: id), session.isChat, !pending.contains(id) else { return }
        Log.info(.workspace, "reconnecting chat “\(session.name)”")
        closeChat(id)
        surfaces.launchFailures[id] = nil
        launchChat(session)
    }

    private func closeChat(_ id: UUID) {
        guard let chat = chats.removeValue(forKey: id) else { return }
        chat.session.close()
        chat.removeFromSuperview()
        controller.setLive(id, false)
        controller.setStopped(id, nil)   // a stopped chat's reason doesn't follow it to Terminal
    }

    /// Tear down a session's terminal (e.g. when it switches to chat).
    private func dropTerminal(_ id: UUID) {
        guard let terminal = terminals.removeValue(forKey: id) else { return }
        terminal.view.removeFromSuperview()
        terminal.cleanup()
        runtime.terminalRemoved(id)
        searchWindows[id]?.close()
        searchWindows[id] = nil
    }

    // MARK: Teardown

    private func pruneClosed() {
        let existing = Set(controller.orderedSessions.map(\.id))
        for id in chats.keys where !existing.contains(id) { closeChat(id) }
        for (id, terminal) in terminals where !existing.contains(id) {
            terminal.view.removeFromSuperview()
            terminal.cleanup()
            terminals[id] = nil
            runtime.terminalRemoved(id)
            searchWindows[id]?.close()
            searchWindows[id] = nil
        }
    }

    /// Tear down every terminal when the window closes — kills each session's
    /// `sbx exec` (libghostty closes the PTY on surface teardown) and removes its
    /// temp launch script. Without this, closing a window leaks the scripts.
    func teardown() {
        contextBar.stop()
        if let m = pasteEventMonitor { NSEvent.removeMonitor(m); pasteEventMonitor = nil }
        for wc in searchWindows.values { wc.close() }
        searchWindows.removeAll()
        dropAllTerminals()
    }

    private func dropAllTerminals() {
        for id in Array(chats.keys) { closeChat(id) }
        for (id, terminal) in terminals {
            terminal.view.removeFromSuperview()
            terminal.cleanup()
            runtime.terminalRemoved(id)
        }
        terminals.removeAll()
    }
}

// MARK: - Terminal Key Equivalents

extension TerminalStackController {
    /// Central dispatch for Cmd+key intercepts. Returns nil to consume the event,
    /// or the original event to pass it through to the focused terminal view.
    private func handleTerminalKeyEquivalent(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers,
              let id = activeSessionID,
              let tv = terminals[id]?.view,
              tv.window?.isKeyWindow == true,
              tv.window?.firstResponder === tv else { return event }
        switch key {
        case "v": return handlePaste(event, id: id, tv: tv)
        case "f": openSearch(for: id, tv: tv); return nil
        default:  return event
        }
    }

    // MARK: Pasteboard / Drag Input

    private struct TerminalContext {
        var id: UUID
        var session: Session
        var view: AppTerminalView
    }

    private func activeTerminalContext() -> TerminalContext? {
        guard let id = activeSessionID,
              let session = controller.session(id: id),
              let view = terminals[id]?.view else { return nil }
        return TerminalContext(id: id, session: session, view: view)
    }

    private func handlePaste(_ event: NSEvent, id: UUID, tv: AppTerminalView) -> NSEvent? {
        guard let session = controller.session(id: id),
              shouldInterceptPasteboard(NSPasteboard.general),
              let text = terminalInput(from: NSPasteboard.general, workdir: session.workdir),
              !text.isEmpty else { return event }
        tv.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return nil
    }

    private func canInsertPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        if let id = activeSessionID, chats[id] != nil {
            return pasteboard.availableType(from: [.fileURL, .tiff, .png]) != nil
        }
        return activeTerminalContext() != nil && pasteboard.availableType(from: Self.terminalPasteboardTypes) != nil
    }

    @discardableResult
    private func insertPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        if let id = activeSessionID, let chat = chats[id] { return chat.addAttachments(from: pasteboard) }
        guard let context = activeTerminalContext(),
              let text = terminalInput(from: pasteboard, workdir: context.session.workdir),
              !text.isEmpty else { return false }
        context.view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    private func shouldInterceptPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.availableType(from: [.fileURL, .URL, .tiff, .png]) != nil { return true }
        return false
    }

    private func terminalInput(from pasteboard: NSPasteboard, workdir: String) -> String? {
        if let urls = pasteboardFileURLs(pasteboard), !urls.isEmpty {
            return terminalInput(for: urls, workdir: workdir)
        }
        if let urlString = pasteboard.string(forType: .URL), !urlString.isEmpty {
            return urlString
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           !images.isEmpty {
            let paths = images.compactMap { saveClipboardImage($0, workdir: workdir) }
            return paths.isEmpty ? nil : paths.map(SbxCommand.shellQuote).joined(separator: " ")
        }
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return string
        }
        return nil
    }

    private func pasteboardFileURLs(_ pasteboard: NSPasteboard) -> [URL]? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls
        }
        guard let raw = pasteboard.string(forType: .fileURL),
              let url = URL(string: raw), url.isFileURL else { return nil }
        return [url]
    }

    private func terminalInput(for urls: [URL], workdir: String) -> String? {
        let paths = materializeDroppedURLs(urls, workdir: workdir)
        guard !paths.isEmpty else { return nil }
        return paths.map(SbxCommand.shellQuote).joined(separator: " ")
    }

    private func saveClipboardImage(_ image: NSImage, workdir: String) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let sbxDir = URL(fileURLWithPath: workdir, isDirectory: true).appendingPathComponent(".sbx")
        do {
            try FileManager.default.createDirectory(at: sbxDir, withIntermediateDirectories: true)
        } catch {
            Log.error(.app, "image paste: failed to create .sbx dir: \(error)")
            return nil
        }
        pruneStalePastes(in: sbxDir)
        let name = "paste-\(Int(Date().timeIntervalSince1970)).png"
        let url = sbxDir.appendingPathComponent(name)
        do {
            try png.write(to: url)
            return url.path
        } catch {
            Log.error(.app, "image paste: failed to write \(url.path): \(error)")
            return nil
        }
    }

    private func materializeDroppedURLs(_ urls: [URL], workdir: String) -> [String] {
        let dropDir = URL(fileURLWithPath: workdir, isDirectory: true)
            .appendingPathComponent(".sbx/drops", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dropDir, withIntermediateDirectories: true)
        } catch {
            Log.error(.app, "drop: failed to create \(dropDir.path): \(error)")
            return []
        }
        return urls.compactMap { url in
            guard FileManager.default.fileExists(atPath: url.path) else {
                return url.path
            }
            let destination = uniqueDestination(for: url.lastPathComponent, in: dropDir)
            do {
                if url.standardizedFileURL.path != destination.standardizedFileURL.path {
                    try FileManager.default.copyItem(at: url, to: destination)
                    recordProvenance(source: url, destination: destination, in: dropDir)
                }
                return destination.path
            } catch {
                Log.error(.app, "drop: failed to copy \(url.path) to \(destination.path): \(error)")
                return url.path
            }
        }
    }

    // Append an entry to .sbx/drops/.provenance so tools can trace each file back
    // to the path it was dragged from. The file is a JSON object keyed by the
    // destination filename; existing entries are preserved across drops.
    private func recordProvenance(source: URL, destination: URL, in dropDir: URL) {
        let provenanceURL = dropDir.appendingPathComponent(".provenance")
        var entries: [String: [String: String]] = [:]
        if let data = try? Data(contentsOf: provenanceURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
            entries = existing
        }
        entries[destination.lastPathComponent] = [
            "source": source.path,
            "droppedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: provenanceURL)
    }

    private func uniqueDestination(for filename: String, in directory: URL) -> URL {
        let base = filename.isEmpty ? "item" : filename
        let original = directory.appendingPathComponent(base)
        if !FileManager.default.fileExists(atPath: original.path) { return original }
        let ext = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        for index in 1..<10_000 {
            let name = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(base)")
    }

    /// Delete paste-*.png files in `.sbx/` that are older than 7 days so the
    /// folder doesn't grow unbounded across sessions.
    private func pruneStalePastes(in dir: URL) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("paste-")
                                && entry.pathExtension == "png" {
            guard let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate, created < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: Terminal Search (Cmd+F)

    /// Open (or bring to front and refresh) a search window for this session.
    /// Extracts the full terminal scrollback via select-all + copy, then restores
    /// the clipboard so the user's prior contents are unaffected.
    private func openSearch(for id: UUID, tv: AppTerminalView) {
        guard let session = controller.session(id: id) else { return }

        // select_all is synchronous through the ghostty C library; give the run
        // loop one tick before reading back the selection via copy.
        tv.selectAll(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let text = self.extractAndRestoreClipboard(from: tv)

            if let wc = self.searchWindows[id] {
                if let text { wc.loadText(text) }
                wc.window?.makeKeyAndOrderFront(nil)
                return
            }
            let wc = TerminalSearchWindowController(sessionName: session.name)
            wc.onClose = { [weak self] in self?.searchWindows[id] = nil }
            if let text { wc.loadText(text) }
            wc.showWindow(nil)
            self.searchWindows[id] = wc
        }
    }

    /// Copy the terminal's current selection to the clipboard, read the text,
    /// then restore the clipboard to its prior contents. Returns the text, or
    /// nil if the terminal has no selection or the copy fails.
    private func extractAndRestoreClipboard(from tv: AppTerminalView) -> String? {
        let pb = NSPasteboard.general

        // Capture all clipboard data before we clobber it.
        let saved: [(NSPasteboard.PasteboardType, Data)] = (pb.pasteboardItems ?? [])
            .flatMap { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }

        _ = tv.copySelectedTextToPasteboard()
        let text = pb.string(forType: .string)

        // Restore.
        pb.clearContents()
        if !saved.isEmpty {
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            pb.writeObjects([item])
        }

        return text
    }
}

/// A layer-backed container that reports when its effective appearance changes,
/// so the detail pane can re-resolve theme colors against the authoritative
/// window appearance (rather than racing the launch-time resolution).
private final class AppearanceReactiveView: NSView {
    var onAppearanceChange: ((NSAppearance) -> Void)?
    var onPasteboardDrag: ((NSPasteboard) -> Bool)?
    var onPasteboardDrop: ((NSPasteboard) -> Bool)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?(effectiveAppearance)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onPasteboardDrag?(sender.draggingPasteboard) == true ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onPasteboardDrag?(sender.draggingPasteboard) == true ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPasteboardDrop?(sender.draggingPasteboard) == true
    }
}

extension TerminalStackController: NSToolbarItemValidation {
    /// Reveal/stop/restart are actionable only when a session is active; the
    /// Chat/Terminal toggle only for Claude sessions, and it shows the mode you'd
    /// switch *to*.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.action == #selector(revealInFinderClicked) { return activeSessionID != nil || shownFiles != nil }
        guard item.action == #selector(toggleChatClicked) else { return activeSessionID != nil }
        let session = activeSessionID.flatMap { controller.session(id: $0) }
        let isChat = session?.isChat ?? false
        let label = isChat ? "Show as Terminal" : "Show as Chat"
        if item.label != label {
            item.label = label
            item.paletteLabel = "Chat / Terminal"
            item.toolTip = label
            item.image = NSImage(systemSymbolName: isChat ? "terminal" : "bubble.left.and.text.bubble.right",
                                 accessibilityDescription: label)
        }
        return session.map { SbxCommand.supportsACP($0.agent) } ?? false
    }
}

/// Background for a Files surface in a pane: the system text background,
/// following light/dark (CALayer colors don't track appearance on their own).
private final class FilesSurfaceView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.textBackgroundColor.cgColor }
}

/// Draws but never takes clicks (the pane's dimming wash).
/// Takes no width while hidden, so a hidden pill doesn't hold space in the strip.
private final class CollapsingButton: NSButton {
    override var isHidden: Bool { didSet { if isHidden != oldValue { invalidateIntrinsicContentSize() } } }
    override var intrinsicContentSize: NSSize {
        isHidden ? NSSize(width: 0, height: super.intrinsicContentSize.height) : super.intrinsicContentSize
    }
}

/// Tells its owner when it lays out (its width changed).
private final class LayoutReportingView: NSView {
    var onLayout: (() -> Void)?
    private var lastWidth: CGFloat = -1

    override func layout() {
        super.layout()
        guard bounds.width != lastWidth else { return }
        lastWidth = bounds.width
        onLayout?()
    }
}

private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

#if DEBUG
extension TerminalStackController {
    /// Self-test: show the Claude readout with `status`, whatever the session is.
    func debugShowClaudeReadout(_ status: ClaudeSessionStatus?) {
        claudeStats.isHidden = false
        claudeStatsCollapsed.isActive = false
        claudeStats.update(status: status, defaultModel: nil, defaultEffort: nil)
        shareTitleStrip()
    }

    var debugReadoutFitting: String { claudeStats.debugFitting }
    var debugReadoutShown: Bool { !claudeStats.isHidden }
    func debugShowLaunchFailure(_ message: String) { showLaunchFailure(message) }
    /// Self-test: pick a model in the readout, as its menu would.
    func debugPickModel(_ id: String?) { modelPicked(id) }

    /// Self-test: the strip's width, the folder chip's, and the readout's.
    var debugTitleStripWidths: (strip: CGFloat, folder: CGFloat, folderWanted: CGFloat, readout: CGFloat, budget: CGFloat) {
        view.layoutSubtreeIfNeeded()
        return (titleStrip.bounds.width, contextBar.debugFolderChip.frame.width,
                min(contextBar.debugFolderChip.intrinsicContentSize.width, 140), claudeStats.frame.width,
                claudeStats.maxWidth)
    }
}
#endif
