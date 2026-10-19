import AppKit
import Combine
import GhosttyTerminal
import SwiftUI

@MainActor
private final class TerminalRuntimeController {
    private struct AgentActivityWatch {
        var startedAt = Date.now
        var containerName: String?
        var baselineExecIDs: Set<String>?
        /// Finds the terminal's own exec among the sandbox's (nil: they
        /// couldn't be listed before the launch).
        var execFinder: LaunchExecFinder?
        var execID: String?
        /// The log says the terminal's exec wasn't found (once).
        var loggedExecNotFound = false
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

    /// Closed sessions' exits are forgotten: one reopened (undo) starts anew.
    func forgetExits(except existing: Set<UUID>) {
        exited.formIntersection(existing)
    }

    /// The sandbox's execs right before a launch: its own is among the new ones.
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
        SbxClient.launchSettled(id)
        guard !exited.contains(id) else { return }
        exited.insert(id)
        controller.reportActivity(id, working: false, at: .now)
        onTerminalDidExit(id)
    }

    func startTracking(_ session: Session, resumeID: String?, launchTag: String) {
        let id = session.id
        // Its own exec carries the launch's tag; any there before it isn't it.
        updateActivityWatch(id) { watch in
            watch.execFinder = watch.baselineExecIDs.map { LaunchExecFinder(tag: launchTag, baseline: $0) }
        }
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
        let start = Date.now
        updateActivityWatch(id) { $0.startedAt = start }
        // Released (or the window closed) during an await: stop there, before
        // touching the watch or the window's surfaces again.
        watchTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isTerminalAlive(id),
                      let s = self.controller.session(id: id) else { return }
                let home = self.controller.home
                await self.pollExecLifecycle(id)
                guard !Task.isCancelled else { return }
                if self.exited.contains(id) { continue }
                if self.activityWatches[id]?.transcriptURL == nil {
                    // (Its folder may have moved since it started: the agent files under the old cwd.)
                    let agent = s.agent, workdir = s.conversationWorkdir
                    let claimed = self.claimedTranscripts
                    let startedAt = self.activityWatches[id]?.startedAt ?? start
                    let url = await Task.detached(priority: .utility) {
                        TranscriptReader.transcriptURL(
                            agent: agent, workdir: workdir, home: home,
                            since: startedAt, excluding: claimed)
                    }.value
                    guard !Task.isCancelled else { return }
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
                        let recentlyWritten = Date.now.timeIntervalSince(mtime) < 10
                        let working = lastRole == "user" || (lastRole != "assistant" && recentlyWritten)
                        let transition = self.controller.reportActivity(id, working: working,
                                                                        lastWrite: mtime, at: .now)
                        if transition.finishedWork,
                           let s = self.controller.session(id: id),
                           !self.isSessionVisible(id) {
                            NotificationManager.shared.sendWorkComplete(
                                sessionID: id,
                                agentName: s.agent.displayName,
                                sessionName: self.controller.displayName(of: s),
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
                guard !Task.isCancelled else { return }
                guard let result = incResult else { continue }
                self.updateActivityWatch(id) {
                    $0.transcriptReadOffset = result.newOffset
                    if let role = result.lastRole { $0.cachedLastRole = role }
                }
                let state = result.liveState
                let transition = self.controller.reportActivity(id, working: state.working,
                                                                lastWrite: mtime, at: .now)
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
                        sessionName: self.controller.displayName(of: s),
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

        if let execID = watch.execID {
            guard let state = await SbxClient.shared.inspectExecLifecycle(id: execID),
                  !state.running, !Task.isCancelled else { return }
            return execExited(id, execID: execID, state: state)
        }

        guard var finder = watch.execFinder,
              let active = await SbxClient.shared.activeExecIDs(containerName: containerName),
              !Task.isCancelled else { return }
        // Not another terminal's: the sandbox's other sessions, reaps and log
        // reads start execs too.
        let others = Set(activityWatches.filter { $0.key != id }.compactMap(\.value.execID))
        var inspections: [String: SbxClient.ExecLifecycleState] = [:]
        for candidate in finder.toInspect(active: active, others: others) {
            inspections[candidate] = await SbxClient.shared.inspectExecLifecycle(id: candidate)
        }
        guard !Task.isCancelled else { return }
        let claim = finder.claim(active: active, others: others, inspections: inspections)
        updateActivityWatch(id) {
            $0.execFinder = finder
            $0.execID = claim?.id
        }
        guard let claim else {
            // Its exit then shows only when its PTY closes: say why, once.
            if !watch.loggedExecNotFound, Date.now.timeIntervalSince(watch.startedAt) > 15 {
                updateActivityWatch(id) { $0.loggedExecNotFound = true }
                let left = finder.candidates(active: active, others: others).count
                let why = finder.sawCommands ? "none of the sandbox's new execs carries its launch tag"
                    : "sbx doesn't say what execs run, and \(left) new one(s) may be it"
                Log.info(.workspace, "session \(id): its sbx exec isn't found after 15 s: \(why)")
            }
            return
        }
        Log.info(.workspace, "session \(id) attached to sbx exec \(claim.id)")
        SbxClient.launchSettled(id)
        if !claim.state.running { execExited(id, execID: claim.id, state: claim.state) }
    }

    private func execExited(_ id: UUID, execID: String, state: SbxClient.ExecLifecycleState) {
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

/// What's waiting for a session's chat to open, in two parts that never mix:
/// a message to send, and text and files for the composer, where they wait
/// for the person to look them over (nothing there goes on its own).
struct ChatDraft {
    /// Text and files gathered from every draft that came in.
    struct Part: Equatable {
        var text = ""
        var urls: [URL] = []
        /// Pasted images and the like, which a message queued in an earlier
        /// chat can carry.
        var attachments: [ChatAttachment] = []

        var isEmpty: Bool { text.isEmpty && urls.isEmpty && attachments.isEmpty }

        /// The texts are joined, a paragraph apart; the files are added.
        mutating func add(text more: String, urls moreURLs: [URL] = [], attachments moreAttachments: [ChatAttachment] = []) {
            text = [text, more].filter { !$0.isEmpty }.joined(separator: "\n\n")
            urls += moreURLs
            attachments += moreAttachments
        }
    }

    /// Sent as one message as soon as the chat is up: asks, "send now"
    /// requests, a message queued in the session's last chat.
    var message = Part()
    /// Put in the composer: files dropped on the session, text to edit first.
    var composer = Part()

    /// Another draft while the chat starts: a message joins the message, the
    /// rest the composer.
    mutating func add(text: String, urls: [URL], send: Bool) {
        if send { message.add(text: text, urls: urls) } else { composer.add(text: text, urls: urls) }
    }

    /// The message a closing chat had queued behind its turn: it goes first,
    /// ahead of anything asked since.
    mutating func putFirst(text: String, attachments: [ChatAttachment]) {
        var first = Part(text: text, attachments: attachments)
        first.add(text: message.text, urls: message.urls, attachments: message.attachments)
        message = first
    }
}

/// A window's live session surfaces (terminals, chats, launches, drafts and
/// the activity watcher), shared by its panes — so a session keeps running
/// when it moves between panes, and each session runs once per window.
@MainActor
final class SessionSurfaces {
    let controller: WorkspaceController
    var terminals: [UUID: TerminalSession] = [:]
    var chats: [UUID: ChatSessionView] = [:]
    var drafts: [UUID: ChatDraft] = [:]
    /// Sessions starting. That's using them, for every window on the folder:
    /// "+ New …" there mustn't hand one out as unused.
    var pending: Set<UUID> = [] {
        didSet { for id in pending.subtracting(oldValue) { controller.markLaunched(id) } }
    }
    /// A closed chat's process tag, when it isn't the session's own (a warm
    /// spare's): reaped before the session launches again.
    var leftoverProcesses: [UUID: String] = [:]
    /// Sessions whose sandbox couldn't be brought up, with why: not retried
    /// until the user says so (a refresh used to relaunch — and fail — forever).
    var launchFailures: [UUID: String] = [:]
    /// Sessions whose history is gone and the person chose not to start anew
    /// (asked once; Try Again asks again).
    var declinedRestores: Set<UUID> = []
    /// The window closed: launches still waiting on a sandbox start nothing.
    var isTornDown = false
    var searchWindows: [UUID: TerminalSearchWindowController] = [:]
    /// The pane showing the session, if any (set by the pane tree): a session's
    /// own buttons and links act there, whichever pane launched it.
    var paneShowing: (UUID) -> TerminalStackController? = { _ in nil }
    /// Whether some pane is showing the session.
    func isShown(_ id: UUID) -> Bool { paneShowing(id) != nil }
    /// Whether the person can see the session now: the app is active, a pane
    /// shows it, and its window is on screen — not minimized, on another Space
    /// or covered by another window. Otherwise news of it is a notification.
    func isVisible(_ id: UUID) -> Bool {
        guard NSApp.isActive, let window = paneShowing(id)?.viewIfLoaded?.window else { return false }
        return window.isKeyWindow
            || (window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
    }
    /// A terminal's process exited (routed to the pane showing it).
    var onTerminalExit: (UUID) -> Void = { _ in }
    /// A chat's agent exited on its own (routed to the pane showing it).
    var onChatAgentExit: (UUID) -> Void = { _ in }
    /// A chat's usage or model changed (routed to the pane showing it).
    var onChatStatus: (UUID) -> Void = { _ in }
    /// A session's terminal or chat is up (or failed to start): every pane
    /// showing it shows it now.
    var onLaunched: (UUID) -> Void = { _ in }
    /// When each chat was last reconnected without being asked (at most once a minute).
    var lastAutoReconnect: [UUID: Date] = [:]

    // Weak: a watch or monitor task still in an await can outlive the window.
    fileprivate lazy var runtime = TerminalRuntimeController(
        controller: controller,
        isTerminalAlive: { [weak self] id in self?.terminals[id] != nil },
        isSessionVisible: { [weak self] id in self?.isVisible(id) ?? false },
        onTerminalDidExit: { [weak self] id in self?.onTerminalExit(id) })

    /// Background tasks of every running Claude session in this window.
    lazy var backgroundTasks = BackgroundTaskMonitor(
        controller: controller,
        isAlive: { [weak self] id in
            guard let self else { return false }
            return self.chats[id] != nil || (self.terminals[id] != nil && !self.runtime.isExited(id))
        },
        isVisible: { [weak self] id in self?.isVisible(id) ?? false })

    init(controller: WorkspaceController) {
        self.controller = controller
        backgroundTasks.start()
        Self.all.add(self)
    }

    /// End a session's chat, wherever it's shown (or with no pane showing it).
    func closeChat(_ id: UUID) {
        guard let chat = chats.removeValue(forKey: id) else { return }
        // A message queued behind its turn is kept for the session's next chat
        // (a reconnect sends it) instead of vanishing.
        if let waiting = chat.session.takeQueued() {
            drafts[id, default: ChatDraft()].putFirst(text: waiting.text, attachments: waiting.attachments)
        }
        let wasWorking = chat.session.phase == .running
        chat.session.close()
        // It won't say it stopped (closed sessions don't report): say so here.
        if wasWorking { _ = controller.reportActivity(id, working: false, at: .now) }
        // Its processes may not carry this session's tag (a warm spare's):
        // the next launch for this session reaps them by theirs too.
        leftoverProcesses[id] = chat.session.processMatch
        chat.removeFromSuperview()
        controller.setLive(id, false)
        controller.setWaiting(id, false)   // its question went with it
        NotificationManager.shared.withdrawNeedsInput(sessionID: id)
        controller.setStopped(id, nil)   // a stopped chat's reason doesn't follow it to Terminal
    }

    /// Relaunch a chat, resuming its conversation (to take a new model): the
    /// pane showing it does it now; one off screen is closed, and starts
    /// again, taking the change, when a pane next shows it.
    func reconnectChat(_ id: UUID) {
        guard !isTornDown else { return }
        if let pane = paneShowing(id) { return pane.reconnectChat(id) }
        guard let session = controller.session(id: id), session.isChat, !pending.contains(id),
              chats[id] != nil else { return }
        Log.info(.workspace, "closing chat “\(session.name)” (off screen) to relaunch it when it's shown")
        closeChat(id)
    }

    /// Every window's surfaces: a session runs in one window at a time.
    private static let all = NSHashTable<SessionSurfaces>.weakObjects()

    /// This window has the session's terminal or chat up, or starting.
    func isRunning(_ id: UUID) -> Bool { terminals[id] != nil || chats[id] != nil || pending.contains(id) }

    /// Another window (on the same folder) has this session running or
    /// starting. Launching here too would reap that one's agent.
    func isRunningElsewhere(_ id: UUID) -> Bool {
        Self.all.allObjects.contains { other in other !== self && !other.isTornDown && other.isRunning(id) }
    }

    /// This window closed and let go of `ids`: panes in the other windows that
    /// showed them as open here start them now (after the close is done).
    func releasedToOthers(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for other in Self.all.allObjects where other !== self && !other.isTornDown {
                for id in ids where other.isShown(id) { other.onLaunched(id) }
            }
        }
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
    private var drafts: [UUID: ChatDraft] {
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
    /// A diff line's "change this" from this pane's Files surface.
    var onFilesAsk: ((String, FilesTarget) -> Void)?
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
    /// The sidebar's "+ New Session" menu (an empty pane's New Session).
    var newSessionMenu: (() -> NSMenu?)?
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
    private let emptyNewButton = NSButton(title: "New Session", target: nil, action: nil)
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
    /// The active session's identity, published to the window's native toolbar
    /// (agent badge + title/subtitle). `nil` when no session is shown.
    /// `agent` is nil for a Files pane that isn't any session's (no badge).
    struct Chrome { let agent: AgentKind?; let title: String; let subtitle: String }
    var onChromeChange: ((Chrome?) -> Void)?
    /// Live status for the toolbar: text ("Working  ◷ 39m 16s" / "Ready") and
    /// whether the agent is currently working (drives the green tint).
    var onStatusChange: ((String, Bool) -> Void)?
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
    private let spinner = NSProgressIndicator.spinner(.regular)
    private let restartButton = NSButton()
    /// sbx's output while a sandbox is made (and beside a build that failed).
    private let buildLogView = BuildLogView()
    /// Whose build `buildLogView` shows (nil: it's hidden).
    private var buildLogAgent: AgentKind?
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
            files.onAskAgent = { [weak self] text in
                guard let self, let target = self.shownFiles else { return }
                self.onFilesAsk?(text, target)
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
        titleLabel.stringValue = "\(url.path.tildeAbbreviated) — \(access.titleSummary)"
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
                onChromeChange?(Chrome(agent: session.agent, title: controller.displayName(of: session),
                                       subtitle: "Files · \(url.path.tildeAbbreviated)"))
                updateHeaderStatus(id)
            } else {
                onChromeChange?(Chrome(agent: nil, title: "Files — \(title)", subtitle: url.path.tildeAbbreviated))
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
    /// Show `agent`'s build log under the status (hidden while it has none).
    private func showBuildLog(_ agent: AgentKind?) {
        buildLogAgent = agent
        updateBuildLog(controller.buildLogs)
    }

    private func updateBuildLog(_ logs: [AgentKind: BuildLog]) {
        guard let agent = buildLogAgent, let log = logs[agent], !log.isEmpty else {
            buildLogView.isHidden = true
            return
        }
        buildLogView.show(log)
        buildLogView.isHidden = false
    }

    private func showLaunchFailure(_ message: String) {
        showStatus("Couldn't start the sandbox\n\n" + message, busy: false)
        // Its sandbox's build failed: what sbx printed up to then.
        if let agent = shownSession.flatMap({ controller.session(id: $0) })?.containerAgentKind,
           case .failed = controller.containerPhases[agent] {
            showBuildLog(agent)
        }
        let lower = message.lowercased()
        editSettingsPane = lower.contains("kit") ? .kits : lower.contains("mount") ? .mounts : .sandboxes
        editSettingsButton.title = editSettingsPane == .kits ? "Edit Kits…"
            : editSettingsPane == .mounts ? "Edit Mounts…" : "Sandbox Settings…"
        editSettingsButton.isHidden = false
        failureActions.isHidden = false
    }

    @objc private func retryLaunch() {
        guard let id = shownSession else { return }
        surfaces.launchFailures[id] = nil
        surfaces.declinedRestores.remove(id)
        refresh()
    }

    @objc private func editSettingsForFailure() {
        NotificationCenter.default.post(name: InspectorView.openRequest, object: controller,
                                        userInfo: ["pane": editSettingsPane.rawValue])
    }
    @objc private func splitRightClicked() { onSplit?(.trailing) }
    @objc private func splitDownClicked() { onSplit?(.bottom) }
    @objc private func openFilesClicked() { onOpenFiles?(false) }
    /// The sidebar's "+ New Session" menu, under the button; what's picked opens
    /// here (this pane has focus from the click).
    @objc private func newSessionClicked() {
        newSessionMenu?()?.popUp(positioning: nil, at: NSPoint(x: 0, y: emptyNewButton.bounds.height + 4),
                                 in: emptyNewButton)
    }

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
        for v in [frameView, titleStrip, titleLine, host] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.wantsLayer = true
        }

        // Framed terminal: rounded border + title strip + the libghostty surface.
        frameView.layer?.cornerRadius = 12
        frameView.layer?.borderWidth = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .role(.code)
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
        titleStrip.onLayout = { [weak self] in Task { self?.shareTitleStrip() } }
        titleStrip.addSubview(contextBar)
        backgroundPill.translatesAutoresizingMaskIntoConstraints = false
        backgroundPill.bezelStyle = .inline
        backgroundPill.controlSize = .small
        backgroundPill.font = .role(.meta)
        backgroundPill.image = NSImage(systemSymbolName: "square.stack.3d.up",
                                       accessibilityDescription: "Background tasks")?
            .withSymbolConfiguration(.role(.meta))
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
            // Tinted by the theme (applyTheme).
            button.configureSymbol(symbol, label: tip, tint: nil, target: self, action: action, id: id)
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
        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .role(.body)
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
        buildLogView.isHidden = true
        statusStack.addArrangedSubview(buildLogView)
        statusStack.addArrangedSubview(restartButton)
        // An empty pane (just split, or its session closed): say how to fill
        // it, and offer Files / Close right there.
        emptyNewButton.bezelStyle = .rounded
        emptyNewButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        emptyNewButton.imagePosition = .imageLeading
        emptyNewButton.target = self
        emptyNewButton.action = #selector(newSessionClicked)
        emptyNewButton.setAccessibilityIdentifier("empty-pane-new")
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
        emptyActions.setViews([emptyNewButton, emptyFilesButton, emptyCloseButton], in: .leading)
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
            // As big as the pane allows, up to 640×260 (the stack keeps it inside).
            buildLogView.heightAnchor.constraint(lessThanOrEqualTo: frameView.heightAnchor, multiplier: 0.5),
        ])
        for size in [buildLogView.widthAnchor.constraint(equalToConstant: 640),
                     buildLogView.heightAnchor.constraint(equalToConstant: 260)] {
            size.priority = .defaultHigh
            size.isActive = true
        }
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
            // A rebuild recreates a container, so the exec processes of the
            // sessions in it are dead — drop those so re-selecting relaunches.
            if activity?.hasPrefix("Rebuilding") == true { self?.dropRebuildingSessions() }
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
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    self.showBackgroundTasks()
                }
            }
            .store(in: &cancellables)
        controller.$buildLogs.dropFirst().sink { [weak self] logs in self?.updateBuildLog(logs) }
            .store(in: &cancellables)
        controller.$kitDrift.dropFirst().sink { [weak self] _ in self?.updateKitBanner() }
            .store(in: &cancellables)
        // Live-update the toolbar status when runtime state changes (status, name, etc.).
        controller.$runtimes.dropFirst().sink { [weak self] _ in
            guard let self, let id = self.activeSessionID else { return }
            self.updateClaudeStats(id)
            self.updateHeaderStatus(id)
        }.store(in: &cancellables)
        // Tick the work timer every second via the shared workspace clock.
        controller.clockTick.dropFirst()
            .sink { [weak self] _ in
                guard let self, let id = self.activeSessionID,
                      self.controller.runtime(id)?.status == .working else { return }
                self.updateHeaderStatus(id)
            }
            .store(in: &cancellables)
    }

    private func applyTheme(_ c: ThemeColors? = nil) {
        let c = c ?? controller.theme.colors
        view.layer?.backgroundColor = c.panel.cgColor
        titleLine.layer?.backgroundColor = c.border.cgColor
        titleStrip.layer?.backgroundColor = c.termBg.cgColor
        frameView.layer?.backgroundColor = c.termBg.cgColor
        frameView.layer?.borderColor = c.border.cgColor
        host.layer?.backgroundColor = c.termBg.cgColor
        titleLabel.textColor = c.termDim
        claudeStats.applyTheme(c)
        kitBanner.applyTheme(c)
        buildLogView.applyTheme(c)
        for b in [closePaneButton, filesPaneButton, splitRightButton, splitDownButton, chatModeButton] {
            b.contentTintColor = c.termDim
        }
        contextBar.applyTheme(c)
        updateFocusRing()
    }

    // MARK: Display

    /// Single source of truth for what the detail pane shows.
    func refresh() {
        // Files don't wait on the container.
        if let files = shownFiles { return presentFiles(files) }
        // Another sandbox building doesn't hide a session that's already up —
        // its own being rebuilt does (what's on screen is about to go).
        let live = shownSession.map { terminals[$0] != nil || chats[$0] != nil } ?? false
        let ownRebuilding = shownSession.flatMap { controller.session(id: $0) }
            .map { controller.containerPhases[$0.containerAgentKind] == .rebuilding } ?? false
        if controller.isBuilding, !live || ownRebuilding {
            showStatus(controller.activity ?? "Building…", busy: true)
            // The shown session's sandbox when it's the one building, else the one that is.
            let own = shownSession.flatMap { controller.session(id: $0) }?.containerAgentKind
            showBuildLog(own.flatMap { controller.containerPhases[$0]?.isBuilding == true ? $0 : nil }
                         ?? controller.containerPhases.first { $0.value.isBuilding }?.key)
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
            dropTerminal(id)   // switched terminal → chat (a stopped one's exit goes too)
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
        // Nothing live here now: toolbar Stop/Restart mustn't reach a session
        // this pane no longer shows.
        activeSessionID = nil
        hideHostContents()
        frameView.isHidden = true
        restartButton.isHidden = true
        emptyActions.isHidden = true
        failureActions.isHidden = true
        buildLogAgent = nil
        buildLogView.isHidden = true
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
        guard Alerts.confirm("Rebuild “\(name)”?",
                             "The sandbox is recreated with the current kits and mounts, which reloads every "
                             + "kit’s contents. Any session running in it will end. Workspace files are kept.",
                             confirm: "Rebuild", destructive: true) else { return }
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
        configureHeader(session)
        updateHeaderStatus(session.id)
        frameView.isHidden = true
        spinner.stopAnimation(nil)
        statusLabel.stringValue = "\(session.agent.displayName) exited."
        restartButton.isHidden = false
        // Whatever the stack last offered (an empty pane's, a failed launch's) isn't for this.
        emptyActions.isHidden = true
        failureActions.isHidden = true
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
        NSWorkspace.shared.open(URL(filePath: s.workdir, directoryHint: .isDirectory))
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

    /// Toolbar: show the active session as a native chat, or back as a
    /// terminal, for agents that can chat (`SbxCommand.supportsACP`). Same
    /// conversation either way (resumed in the new surface).
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
        let program = session.agent == .shell ? "bash" : session.agent.rawValue
        titleLabel.stringValue = "\(program) — \(container)" + (session.isChat ? " · chat (ACP)" : "")
        // The strip shows where the session runs: sandbox, folder, branch.
        let folder = URL(filePath: session.workdir, directoryHint: .checkFileSystem)
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
            .withSymbolConfiguration(.role(.meta, weight: .medium))
        chatModeButton.toolTip = modeTip
        chatModeButton.setAccessibilityLabel(modeTip)
        onChromeChange?(Chrome(agent: session.agent, title: controller.displayName(of: session),
                               subtitle: "\(container) · \(session.workdir.tildeAbbreviated)"))
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
        let running = tasks.count(where: \.isRunning)
        let recent = tasks.count(where: {
            !$0.isRunning && !$0.orphaned && Date.now.timeIntervalSince($0.finishedAt ?? $0.startedAt) < 1800
        })
        backgroundPill.isHidden = running == 0 && recent == 0
        defer { shareTitleStrip() }
        let color: NSColor = running > 0 ? .sessionWorking : .secondaryLabelColor
        backgroundPill.attributedTitle = NSAttributedString(
            string: running > 0 ? "\(running) running" : "\(recent) done",
            attributes: [.foregroundColor: color, .font: NSFont.role(.meta)])

        backgroundPill.contentTintColor = color
        backgroundPill.toolTip = running > 0
            ? "\(running) background task\(running == 1 ? "" : "s") running — click for details"
            : "Background tasks finished recently — click for details"
    }

    @objc func showBackgroundTasks() {
        guard let id = activeSessionID, view.window != nil else { return }
        let list = BackgroundTasksView(controller: controller, sessionIDs: { [id] },
                                       loadOutput: { [controller] sid, task in await controller.backgroundOutput(sid, task) },
                                       stopTask: { [weak self] sid, task in await self?.chats[sid]?.session.stopBackgroundTask(task.id) ?? false },
                                       canStop: { [weak self] sid, _ in self?.chats[sid] != nil })
        NSPopover.toggle(&backgroundPopover, below: backgroundPill.isHidden ? titleStrip : backgroundPill) {
            .hosting(list.frame(width: 420, height: 380))
        }
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
                // Whichever pane shows the chat then (if any), not this one.
                chat.afterTurn = { [weak surfaces] in surfaces?.reconnectChat(id) }
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
        guard Alerts.confirm(title, "Claude Code chooses its \(what) at launch. Restarting resumes this "
                             + "conversation with the new \(what). New sessions in this workspace use it either way.",
                             confirm: "Restart", cancel: "Not Now", style: .informational) else { return }
        restartClicked()
    }

    private func updateHeaderStatus(_ id: UUID) {
        guard let rt = controller.runtime(id) else {
            onStatusChange?("", false)
            return
        }
        let label = rt.stoppedReason != nil ? "Stopped" : rt.status == .working ? "Working" : "Ready"
        let live = rt.liveWorkSeconds()
        let time = live > 0 ? "  ◷ \(formatWorkTime(live))" : ""
        onStatusChange?(label + time, rt.status == .working)
    }


    // MARK: Launch

    /// Bring the session's container up (async), then create + show its terminal.
    private func launch(_ session: Session) {
        let id = session.id
        // Already starting (from another pane): say so here; it shows in
        // every pane showing it once it's up (`surfaces.onLaunched`).
        if pending.contains(id) { return showStatus("Starting \(session.agent.displayName)…", busy: true) }
        guard terminals[id] == nil else { return }
        if surfaces.isRunningElsewhere(id) { return showOpenElsewhere(session) }

        // Restore prior history: if this session ran before, resume that
        // conversation when its transcript still exists; if it's gone, ask
        // whether to start a new session instead.
        var resumeID: String? = nil
        // Pending from here: the question below runs a modal loop, and a
        // refresh during it (clearing the transcript id publishes) mustn't
        // start a second launch.
        pending.insert(id)
        // Its folder moved while it last ran: its conversation comes along now.
        controller.settleConversation(id)
        if let tid = session.transcriptID {
            if TranscriptReader.transcriptExists(agent: session.agent, workdir: session.workdir,
                                                 home: controller.home, id: tid) {
                resumeID = tid
            } else if !surfaces.declinedRestores.contains(id), confirmStartFresh(session) {
                controller.clearTranscriptID(id)
            } else {
                // Declined: say so here (not ask on every refresh); Try Again asks again.
                pending.remove(id)
                surfaces.declinedRestores.insert(id)
                showStatus("“\(controller.displayName(of: session))”’s \(session.agent.displayName) history is no longer available.", busy: false)
                editSettingsButton.isHidden = true
                failureActions.isHidden = false
                return
            }
        }

        showStatus(resumeID == nil ? "Starting \(session.agent.displayName)…"
                                   : "Restoring \(session.agent.displayName)…", busy: true)
        // Its `sbx exec` goes first: the window's background reads wait for it.
        SbxClient.launchBegan(id)

        // Holds the pane until the terminal is up (its exit handler holds it weakly).
        Task { [self] in
            let containerName = await controller.ensureContainerReady(for: session.containerAgentKind)
            // The hold is for the launch itself, however long the sandbox took;
            // once the terminal's there, finding its exec ends it.
            SbxClient.launchBegan(id)
            defer {
                pending.remove(id)
                if terminals[id] == nil { SbxClient.launchSettled(id) }
            }
            guard !surfaces.isTornDown else { return }
            guard let containerName else {
                let message = controller.lastError ?? "Failed to start the sandbox."
                surfaces.launchFailures[id] = message
                surfaces.onLaunched(id)
                return
            }
            // The session may have been closed while the container came up.
            guard controller.session(id: id) != nil, terminals[id] == nil else { return }
            // Leftovers from a crash/kill would share this conversation.
            await reapLeftovers(id, in: containerName)

            Log.info(.workspace, "launching \(session.agent.rawValue) terminal in “\(containerName)” at \(session.workdir)\(resumeID.map { " (resume \($0))" } ?? "")")
            // Claude: model/effort choice + the status feed (model/context/cost readout).
            var claudeOptions: SbxCommand.ClaudeOptions? = nil
            if session.agent == .claude {
                let root = controller.rootURL
                let script = ClaudeStatusFeed.prepare(root: root)
                claudeOptions = SbxCommand.ClaudeOptions(
                    model: controller.claudeModel,
                    effort: controller.claudeEffort,
                    statusScriptPath: script?.path(percentEncoded: false),
                    statusDir: script == nil ? nil : ClaudeStatusFeed.statusDir(root: root).path,
                    sessionID: id.uuidString,
                    sbxProxyAuth: await SbxClient.shared.hasAnthropicSecret(sandbox: containerName))
            }
            // Right before the terminal starts, so fewer other execs can show up beside its own.
            await runtime.prepareLaunch(id, containerName: containerName)
            // Closed meanwhile (window, session), or started by another launch.
            guard !surfaces.isTornDown, controller.session(id: id) != nil, terminals[id] == nil else { return }
            let terminal = TerminalSession(
                sessionID: id, containerName: containerName, agent: session.agent,
                workdir: controller.sandboxWorkdir(session.workdir, agent: session.containerAgentKind),
                mcpURL: controller.workspace.mcpURL,
                theme: controller.theme,
                resumeID: resumeID,
                claude: claudeOptions)
            // Not this pane's: the terminal moves to whichever pane shows it.
            terminal.onProcessExit = { [weak surfaces = self.surfaces] in surfaces?.runtime.terminalDidExit(id) }
            addTerminalView(terminal.view)
            terminals[id] = terminal
            runtime.terminalStarted(id)
            runtime.startTracking(session, resumeID: resumeID, launchTag: terminal.tag.pairs[1])

            surfaces.onLaunched(id)
        }
    }

    private func showOpenElsewhere(_ session: Session) {
        showStatus("“\(controller.displayName(of: session))” is open in another window on this folder.", busy: false)
    }

    /// The chat's Session Details (context, background tasks, connectors,
    /// environment), shown beside it when the person has it on.
    private func attachInspector(to view: ChatSessionView, chat: ChatSession, sessionID id: UUID) {
        let model = SessionInspectorModel(sessionID: id, chat: chat, workspace: controller)
        model.stopTask = { [weak chat] task in await chat?.stopBackgroundTask(task.id) ?? false }
        // Like the chat's own callbacks, none of these is this pane's.
        model.openWorkflow = { [controller, weak chat] run in
            let taskID = controller.backgroundTasks[id]?.first { $0.runID == run.id }?.id
            WorkflowWindowController.show(run, sessionID: id, workspace: controller,
                                          stop: taskID.map { tid in { await chat?.stopBackgroundTask(tid) ?? false } })
        }
        model.openSubagent = { [controller] info in SubagentWindowController.show(info, workspace: controller) }
        model.openTask = { [weak surfaces] _ in surfaces?.paneShowing(id)?.showBackgroundTasks() }
        model.showMCP = { [weak view] in view?.showMCPDetails() }
        model.openMCPSettings = { [controller, weak view] in
            SettingsWindowController.show(for: controller, pane: .mcp, owner: view?.window)
        }
        view.setInspector(NSHostingView(rootView: SessionInspectorView(model: model)))
    }

    /// The session's prior history is gone — ask whether to start fresh.
    private func confirmStartFresh(_ session: Session) -> Bool {
        Alerts.confirm("Couldn’t restore “\(controller.displayName(of: session))”.", "This session’s \(session.agent.displayName) history "
                       + "is no longer available. Start a new session in its place?",
                       confirm: "New Session", style: .informational)
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
        case .claude: true
        case .codex: FileManager.default.fileExists(atPath: home.appending(path: ".codex").path(percentEncoded: false))
        default: false
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
           FileManager.default.fileExists(atPath: home.appending(path: ".codex/auth.json").path(percentEncoded: false)) {
            return nil
        }
        return ChatSession.credentialHelp(for: agent)
    }

    /// Bring the container up, then start the session's ACP agent and show its
    /// chat. Resumes the prior conversation when its transcript still exists.
    private func launchChat(_ session: Session) {
        let id = session.id
        if pending.contains(id) { return showStatus("Starting \(session.agent.displayName) chat…", busy: true) }
        guard chats[id] == nil else { return }
        if surfaces.isRunningElsewhere(id) { return showOpenElsewhere(session) }
        pending.insert(id)
        showStatus("Starting \(session.agent.displayName) chat…", busy: true)
        // Its `sbx exec` goes first: the window's background reads wait for it.
        SbxClient.launchBegan(id)
        Task { [weak self] in
            guard let self else { SbxClient.launchSettled(id); return }
            // Pending until the chat is registered: a second launch while this
            // one awaits would start another agent (and orphan one of them).
            // Once it is, the chat says when it's up.
            defer {
                pending.remove(id)
                if chats[id] == nil { SbxClient.launchSettled(id) }
            }
            let containerName = await controller.ensureContainerReady(for: session.containerAgentKind)
            // The hold is for the launch itself, however long the sandbox took.
            SbxClient.launchBegan(id)
            // The window closed while the sandbox came up: reap nothing (another
            // window may have started this session since), start nothing.
            guard !surfaces.isTornDown else { return }
            guard let containerName else {
                let message = controller.lastError ?? "Failed to start the sandbox."
                surfaces.launchFailures[id] = message
                surfaces.onLaunched(id)
                return
            }
            guard let current = controller.session(id: id), current.isChat, chats[id] == nil else { return }
            // Its folder moved while it last ran: its conversation comes along
            // now (the agent from then is gone: it closed before this launch).
            controller.settleConversation(id)
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
            await reapLeftovers(id, in: containerName)
            let proxyAuth = await SbxClient.shared.hasAnthropicSecret(sandbox: containerName)
            let unavailable = await Self.missingCredential(for: current.agent, container: containerName,
                                                           home: controller.home)
            // The window closed (or the session went) while the sandbox came up.
            guard !surfaces.isTornDown, controller.session(id: id)?.isChat == true, chats[id] == nil else { return }
            let chat = ChatSession(title: current.agent.displayName, agent: current.agent,
                                   containerName: containerName,
                                   workdir: controller.sandboxWorkdir(current.workdir, agent: current.containerAgentKind),
                                   home: controller.home.path,
                                   mcpURL: controller.mcpURL, resumeID: resumeID, sbxProxyAuth: proxyAuth,
                                   sessionID: id, unavailable: unavailable,
                                   model: current.agent == .claude ? controller.claudeModel : nil,
                                   effort: current.agent == .claude ? controller.claudeEffort : nil)
            chat.onSessionID = { [controller] sid in controller.setTranscriptID(id, sid) }
            chat.onClosed = { [controller] why in controller.setStopped(id, why) }
            chat.onUnexpectedExit = { [surfaces] in surfaces.onChatAgentExit(id) }
            chat.onUsage = { [surfaces] in surfaces.onChatStatus(id) }
            chat.onWaitingChange = { [controller, weak chat] waiting in
                controller.setWaiting(id, waiting, for: chat?.waitingFor)
                // Answered (or cancelled): "needs you" is old news.
                if !waiting { NotificationManager.shared.withdrawNeedsInput(sessionID: id) }
            }
            chat.onNeedsInput = { [controller, surfaces] text in
                guard !surfaces.isVisible(id), let s = controller.session(id: id) else { return }
                NotificationManager.shared.sendNeedsInput(sessionID: id, agentName: s.agent.displayName,
                                                          sessionName: controller.displayName(of: s), text: text)
            }
            controller.setStopped(id, nil)
            var lastPrompt: String?
            chat.onPrompt = { [controller] prompt in
                lastPrompt = prompt
                controller.autoName(id, from: prompt)
            }
            chat.onWorkingChange = { [controller, surfaces] working in
                let now = Date.now
                let transition = controller.reportActivity(id, working: working, lastWrite: now, at: now)
                // Same "finished" notification terminals send, when you're elsewhere.
                if transition.finishedWork, let s = controller.session(id: id), !surfaces.isVisible(id) {
                    NotificationManager.shared.sendWorkComplete(
                        sessionID: id, agentName: s.agent.displayName, sessionName: controller.displayName(of: s),
                        lastPrompt: lastPrompt, workSeconds: transition.workSeconds, workdir: s.workdir)
                }
            }
            let view = ChatSessionView(session: chat)
            attachInspector(to: view, chat: chat, sessionID: id)
            // None of these is this pane's: the chat moves to whichever pane shows it.
            view.onReconnect = { [weak surfaces = self.surfaces] in surfaces?.paneShowing(id)?.reconnectChat(id) }
            view.onOpenFile = { [weak surfaces = self.surfaces] url, line in
                surfaces?.paneShowing(id)?.onOpenFileInFiles?(url, line)
            }
            view.onFork = { [controller] reply in
                if controller.forkChat(id, upTo: reply) == nil { NSSound.beep() }
            }
            view.sessionName = { [controller] in controller.displayName(id) }
            view.resolveFileURLs = { [weak view] urls in
                Self.materializeDroppedURLs(urls, workdir: current.workdir) { error in
                    Self.reportDropFailure(error, in: view?.window)
                }.map { URL(filePath: $0, directoryHint: .checkFileSystem) }
            }
            addTerminalView(view)
            chats[id] = view
            controller.setLive(id, true)
            chat.start()
            surfaces.onLaunched(id)
            // The message goes when the agent is ready; the composer's part
            // stays there to be looked over.
            if let draft = drafts.removeValue(forKey: id) {
                if !draft.message.isEmpty {
                    view.applyDraft(text: draft.message.text, urls: draft.message.urls,
                                    attachments: draft.message.attachments, send: true)
                }
                if !draft.composer.isEmpty {
                    view.applyDraft(text: draft.composer.text, urls: draft.composer.urls, send: false)
                }
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

    /// Ask the session's agent for a change: sent in a chat; typed (not
    /// entered) into a terminal agent's prompt.
    func askAgent(_ text: String, on id: UUID) {
        guard let session = controller.session(id: id) else { return }
        if session.isChat {
            queueDraft(text, urls: [], send: true, for: id)
        } else if activeSessionID == id, let context = activeTerminalContext() {
            context.view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// Put a draft into the session's chat — now if it's open, else when it
    /// starts (with whatever was already waiting for it).
    func queueDraft(_ text: String, urls: [URL], send: Bool, for id: UUID) {
        if let chat = chats[id] { return chat.applyDraft(text: text, urls: urls, send: send) }
        drafts[id, default: ChatDraft()].add(text: text, urls: urls, send: send)
    }

    private func showChat(_ id: UUID, _ chat: ChatSessionView) {
        // `refresh` runs on every revision (another chat named, a store change
        // from another window): a chat already up here keeps the keyboard where
        // you put it — a card's text field, the sidebar, the Files editor.
        let alreadyShown = activeSessionID == id && chat.superview === host && !chat.isHidden
        adopt(chat)
        hideHostContents(except: chat)
        chat.isHidden = false
        guard let session = controller.session(id: id) else { return }
        activeSessionID = id
        configureHeader(session)
        updateHeaderStatus(id)
        frameView.isHidden = false
        restartButton.isHidden = true
        spinner.stopAnimation(nil)
        statusStack.isHidden = true
        kitBannerContextActive = true
        updateKitBanner()
        updateFocusRing()
        if isFocused, !alreadyShown { chat.focusComposer() }
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
        if let last = surfaces.lastAutoReconnect[id], Date.now.timeIntervalSince(last) < 60 { return false }
        surfaces.lastAutoReconnect[id] = .now
        reconnectChat(id)
        return true
    }

    /// What switching to Terminal and back did by hand: drop the dead chat and
    /// launch it again, resuming its conversation.
    func reconnectChat(_ id: UUID) {
        guard let session = controller.session(id: id), session.isChat, !pending.contains(id) else { return }
        Log.info(.workspace, "reconnecting chat “\(session.name)”")
        closeChat(id)   // (a message waiting to go goes from the new agent)
        surfaces.launchFailures[id] = nil
        launchChat(session)
    }

    /// Before (re)launching a session: end anything a crash, kill or earlier
    /// launch of it left running — by its own tag and, for a chat that ran on
    /// a warm spare, by that spare's. A session this run just made has none.
    private func reapLeftovers(_ id: UUID, in container: String) async {
        if !SbxClient.takeFirstLaunch(id) {
            await SbxClient.reapSessionProcessesAndWait(container: container, match: "SANDSHELL_SESSION=\(id.uuidString)")
        }
        if let match = surfaces.leftoverProcesses.removeValue(forKey: id) {
            await SbxClient.reapSessionProcessesAndWait(container: container, match: match)
        }
    }

    private func closeChat(_ id: UUID) { surfaces.closeChat(id) }

    /// Tear down a session's terminal (e.g. when it switches to chat). That it
    /// exited (or was stopped) goes with it: the next terminal starts anew.
    private func dropTerminal(_ id: UUID) {
        runtime.resetExit(id)
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
        for id in terminals.keys where !existing.contains(id) { dropTerminal(id) }
        runtime.forgetExits(except: existing)   // a stopped one's too (its terminal is gone)
    }

    /// The pane closed (its sessions live on in other panes): stop its timer,
    /// event monitor and its session's search window, but leave the shared
    /// terminals (and the other sessions' search windows) alone.
    func paneClosed() {
        contextBar.stop()
        if let m = pasteEventMonitor { NSEvent.removeMonitor(m); pasteEventMonitor = nil }
        if let id = shownSession {
            searchWindows[id]?.close()
            searchWindows[id] = nil
        }
    }

    /// Tear down every terminal when the window closes — kills each session's
    /// `sbx exec` (libghostty closes the PTY on surface teardown) and removes its
    /// temp launch script. Without this, closing a window leaks the scripts.
    func teardown() {
        surfaces.isTornDown = true
        contextBar.stop()
        if let m = pasteEventMonitor { NSEvent.removeMonitor(m); pasteEventMonitor = nil }
        for wc in searchWindows.values { wc.close() }
        searchWindows.removeAll()
        let ran = Set(chats.keys).union(terminals.keys).union(pending)
        for id in Array(chats.keys) { closeChat(id) }
        for id in Array(terminals.keys) { dropTerminal(id) }
        runtime.stopAll()
        surfaces.releasedToOthers(ran)
    }

    /// Sessions whose sandbox is being rebuilt (other sandboxes' keep running).
    private func dropRebuildingSessions() {
        func rebuilding(_ id: UUID) -> Bool {
            guard let kind = controller.session(id: id)?.containerAgentKind else { return true }
            return controller.containerPhases[kind] == .rebuilding
        }
        for id in chats.keys.filter(rebuilding) { closeChat(id) }
        for id in terminals.keys.filter(rebuilding) { dropTerminal(id) }
    }
}

// MARK: - Terminal Key Equivalents

extension TerminalStackController {
    /// What the pane takes from a focused terminal before it sees the key.
    enum TerminalKeyIntercept: Equatable { case paste, search }

    /// Plain ⌘V (files and images) and ⌘F (search) only: ⌥⌘F (Filter
    /// Sessions), ⌃⌘F (Full Screen) and the like belong to the menu, though
    /// `charactersIgnoringModifiers` reads "f" for them too.
    static func terminalKeyIntercept(for event: NSEvent) -> TerminalKeyIntercept? {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else { return nil }
        switch event.charactersIgnoringModifiers {
        case "v": return .paste
        case "f": return .search
        default: return nil
        }
    }

    /// Central dispatch for Cmd+key intercepts. Returns nil to consume the event,
    /// or the original event to pass it through to the focused terminal view.
    private func handleTerminalKeyEquivalent(_ event: NSEvent) -> NSEvent? {
        guard let intercept = Self.terminalKeyIntercept(for: event),
              let id = activeSessionID,
              let tv = terminals[id]?.view,
              tv.window?.isKeyWindow == true,
              tv.window?.firstResponder === tv else { return event }
        switch intercept {
        case .paste: return handlePaste(event, id: id, tv: tv)
        case .search: openSearch(for: id, tv: tv); return nil
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
              shouldInterceptPasteboard(NSPasteboard.general) else { return event }
        if pasteImages(NSPasteboard.general, session: session, into: tv) { return nil }
        guard let text = terminalInput(from: NSPasteboard.general, workdir: session.workdir),
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
        guard let context = activeTerminalContext() else { return false }
        if pasteImages(pasteboard, session: context.session, into: context.view) { return true }
        guard let text = terminalInput(from: pasteboard, workdir: context.session.workdir),
              !text.isEmpty else { return false }
        context.view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    private func shouldInterceptPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL, .URL, .tiff, .png]) != nil
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
            let paths = images.compactMap(Self.png).compactMap { saveClipboardImage($0, workdir: workdir) }
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
        let paths = Self.materializeDroppedURLs(urls, workdir: workdir) { [weak self] error in
            Self.reportDropFailure(error, in: self?.view.window)
        }
        guard !paths.isEmpty else { return nil }
        return paths.map(SbxCommand.shellQuote).joined(separator: " ")
    }

    /// Images pasted into a terminal: Claude Code reads the clipboard of the
    /// machine it runs on, which can't see the Mac's, so each image is written
    /// into the sandbox's own /tmp and its path typed (a moment later). Only if
    /// that fails does it land in the project's `.sbx/`. False: no images here.
    private func pasteImages(_ pasteboard: NSPasteboard, session: Session, into tv: AppTerminalView) -> Bool {
        guard pasteboardFileURLs(pasteboard) == nil, pasteboard.string(forType: .URL) == nil,
              let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              !images.isEmpty else { return false }
        let pngs = images.compactMap(Self.png)
        guard !pngs.isEmpty else { return false }
        let container = controller.containerName(for: session.containerAgentKind)
        let workdir = session.workdir
        Task { [weak self, weak tv] in
            var paths: [String] = []
            for (i, png) in pngs.enumerated() {
                let name = "paste-\(Int(Date.now.timeIntervalSince1970))-\(i).png"
                if await SbxClient.writePaste(png, named: name, container: container) {
                    paths.append(SbxClient.pasteDirectory + "/" + name)
                } else if let path = self?.saveClipboardImage(png, workdir: workdir) {
                    Log.info(.app, "image paste: couldn't write into “\(container)”; saved to the project instead")
                    paths.append(path)
                }
            }
            guard !paths.isEmpty else {
                // Neither the sandbox nor the project took it: the ⌘V did nothing.
                if tv != nil { NSSound.beep() }
                return
            }
            tv?.insertText(paths.map(SbxCommand.shellQuote).joined(separator: " "),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        return true
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// The fallback: `.sbx/` in the session's folder (shared with the sandbox).
    private func saveClipboardImage(_ png: Data, workdir: String) -> String? {
        let sbxDir = URL(filePath: workdir, directoryHint: .isDirectory).appending(path: ".sbx")
        do {
            try FileManager.default.createDirectory(at: sbxDir, withIntermediateDirectories: true)
        } catch {
            Log.error(.app, "image paste: failed to create .sbx dir: \(error)")
            return nil
        }
        pruneStalePastes(in: sbxDir)
        let name = "paste-\(Int(Date.now.timeIntervalSince1970)).png"
        let url = sbxDir.appending(path: name)
        do {
            try png.write(to: url)
            return url.path(percentEncoded: false)
        } catch {
            Log.error(.app, "image paste: failed to write \(url.path(percentEncoded: false)): \(error)")
            return nil
        }
    }

    /// Files dropped or pasted into a session, copied into its folder's
    /// `.sbx/drops` (which the sandbox sees). One that can't be copied — or
    /// every one, when `.sbx/drops` can't be made — keeps its host path, and
    /// `onFailure` hears why (once a call).
    static func materializeDroppedURLs(_ urls: [URL], workdir: String,
                                       onFailure: (any Error) -> Void) -> [String] {
        let dropDir = URL(filePath: workdir, directoryHint: .isDirectory)
            .appending(path: ".sbx/drops", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dropDir, withIntermediateDirectories: true)
        } catch {
            Log.error(.app, "drop: failed to create \(dropDir.path): \(error)")
            onFailure(error)
            return urls.map(\.path)
        }
        var failure: (any Error)?
        let paths = urls.compactMap { url in
            guard FileManager.default.fileExists(atPath: url.path) else {
                return url.path
            }
            let destination = uniqueDestination(for: url.lastPathComponent, in: dropDir)
            do {
                if url.standardizedFileURL.path != destination.standardizedFileURL.path {
                    try FileManager.default.copyItem(at: url, to: destination)
                    recordProvenance(source: url, destination: destination, in: dropDir)
                }
                return destination.path(percentEncoded: false)
            } catch {
                Log.error(.app, "drop: failed to copy \(url.path) to \(destination.path(percentEncoded: false)): \(error)")
                failure = failure ?? error
                return url.path
            }
        }
        if let failure { onFailure(failure) }
        return paths
    }

    /// Dropped or pasted files couldn't be copied where the sandbox sees them:
    /// say so, as one sheet. A chat resolves its attachments a file at a time
    /// (and again on send), so a sheet already up has said it.
    private static func reportDropFailure(_ error: any Error, in window: NSWindow?) {
        guard let window else { return NSSound.beep() }
        guard window.attachedSheet == nil else { return }
        Alerts.inform("Couldn’t copy the files into the session’s folder",
                      error.localizedDescription + " The agent may not be able to read them.",
                      style: .warning, in: window)
    }

    // Append an entry to .sbx/drops/.provenance so tools can trace each file back
    // to the path it was dragged from. The file is a JSON object keyed by the
    // destination filename; existing entries are preserved across drops.
    private static func recordProvenance(source: URL, destination: URL, in dropDir: URL) {
        let provenanceURL = dropDir.appending(path: ".provenance")
        var entries: [String: [String: String]] = [:]
        if let data = try? Data(contentsOf: provenanceURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
            entries = existing
        }
        entries[destination.lastPathComponent] = [
            "source": source.path,
            "droppedAt": Date.now.ISO8601Format(),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: provenanceURL)
    }

    private static func uniqueDestination(for filename: String, in directory: URL) -> URL {
        let base = filename.isEmpty ? "item" : filename
        let original = directory.appending(path: base)
        if !FileManager.default.fileExists(atPath: original.path(percentEncoded: false)) { return original }
        let ext = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        for index in 1..<10_000 {
            let name = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let candidate = directory.appending(path: name)
            if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return directory.appending(path: "\(UUID().uuidString)-\(base)")
    }

    /// Delete paste-*.png files in `.sbx/` that are older than 7 days so the
    /// folder doesn't grow unbounded across sessions.
    private func pruneStalePastes(in dir: URL) {
        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 3600)
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
        Task { [weak self] in
            guard let self else { return }
            let text = self.extractAndRestoreClipboard(from: tv)

            if let wc = self.searchWindows[id] {
                if let text { wc.loadText(text) }
                wc.window?.makeKeyAndOrderFront(nil)
                return
            }
            let wc = TerminalSearchWindowController(sessionName: self.controller.displayName(of: session))
            // The session's, not this pane's (which may close first).
            wc.onClose = { [weak surfaces = self.surfaces] in surfaces?.searchWindows[id] = nil }
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
        let changeCount = pb.changeCount
        let saved = pb.snapshotItems()   // before we clobber it
        let text = tv.copySelectedTextToPasteboard() ? pb.string(forType: .string) : nil
        pb.restore(saved)
        PasteboardURLWatcher.shared.ignoreRestore(since: changeCount)
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
    /// Chat/Terminal toggle only for agents that can chat (`SbxCommand.supportsACP`),
    /// and it shows the mode you'd switch *to*.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let action = item.action else { return false }
        guard action == #selector(toggleChatClicked) else { return canPerformSessionAction(action) }
        let label = chatToggleTitle
        let isChat = label == "Show as Terminal"
        if item.label != label {
            item.label = label
            item.paletteLabel = "Chat / Terminal"
            item.toolTip = label
            item.image = NSImage(systemSymbolName: isChat ? "terminal" : "bubble.left.and.text.bubble.right",
                                 accessibilityDescription: label)
        }
        return canPerformSessionAction(action)
    }

    /// Whether a session action (toolbar, Session menu) applies to what this pane shows.
    func canPerformSessionAction(_ action: Selector) -> Bool {
        switch action {
        case #selector(revealInFinderClicked): return activeSessionID != nil || shownFiles != nil
        case #selector(toggleChatClicked):
            return activeSessionID.flatMap { controller.session(id: $0) }.map { SbxCommand.supportsACP($0.agent) } ?? false
        case #selector(stopClicked):
            guard let id = activeSessionID else { return false }
            if let chat = chats[id] { return chat.session.phase == .running }
            return terminals[id] != nil
        default: return activeSessionID != nil
        }
    }

    /// The Chat ⇄ Terminal command's name: the mode it switches to.
    var chatToggleTitle: String {
        activeSessionID.flatMap { controller.session(id: $0) }?.isChat == true ? "Show as Terminal" : "Show as Chat"
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

/// Draws but never takes clicks (the pane's dimming wash).
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

#if DEBUG
extension TerminalStackController {
    /// Self-test: whether the runtime saw `id`'s terminal exit.
    func debugIsExited(_ id: UUID) -> Bool { runtime.isExited(id) }

    /// Self-test: the status the pane shows instead of a session, if any.
    var debugStatusText: String? { statusStack.isHidden ? nil : statusLabel.stringValue }

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
    /// Self-test: paste from `pasteboard` into the shown terminal (as ⌘V would).
    func debugPaste(_ pasteboard: NSPasteboard) -> Bool { insertPasteboard(pasteboard) }
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
