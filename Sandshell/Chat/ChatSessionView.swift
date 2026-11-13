import Combine
import WebKit
import SwiftUI

/// A native chat surface for one session, hosted in the detail pane in place
/// of the terminal: transcript, permission prompt bar, the composer (a pill
/// with Send/Stop inside), and under it every per-turn setting — attach, MCP,
/// model, effort, approval mode, and the readout that opens Session details.
@MainActor
final class ChatSessionView: NSView {
    let session: ChatSession

    private let transcript: ChatWebTranscript
    /// Until the first message: the tide line, where this runs, how to start.
    let emptyModel: ChatEmptyModel
    /// This chat already counted toward the tips' first few chats.
    private var countedForTips = false
    private lazy var emptyState = NSHostingView(rootView: ChatEmptyState(model: emptyModel))
    private let composer = ChatComposerView()

    /// The window's theme: Send takes its accent.
    /// The send button wears the folder's sidebar color.
    func applySendColor(sidebarHex: String, dark: Bool) {
        composer.sendButton.accent = ComposerSendButton.accent(sidebarHex: sidebarHex, dark: dark)
    }
    #if DEBUG
    var debugSendAccent: NSColor? { composer.sendButton.accent?.fill }
    #endif
    /// Messages typed while a turn runs, above the composer until they go.
    private let queuedView = QueuedPromptsView()
    /// How many messages wait (the status line's wording).
    private var queuedCount = 0
    /// The running turn's plan, above the queued messages.
    private let planView = PlanPinView()
    /// Takes a finished plan down after a moment.
    private var planHide: Task<Void, Never>?
    private let permissionBar = NSStackView()
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionButtons = NSStackView()
    /// The controls under the composer.
    private let bar = ComposerBar()
    private var statusLabel: NSTextField { bar.statusLabel }
    private var modePopup: ChoicePopUp { bar.modePopup }
    private var modelPopup: ChoicePopUp { bar.modelPopup }
    private var mcpButton: NSButton { bar.mcpButton }
    private var sendButton: ComposerSendButton { composer.sendButton }
    private var mcpPopover: NSPopover?
    private var detailsPopover: NSPopover?
    /// Where a `!` / `&` line runs, shown in the status line while you type it
    /// (and what the line said before).
    private var commandHint: String?
    private var statusBeforeHint = ""
    private var detailsHost: NSHostingController<ClaudeStatsDetailView>?
    /// A Claude model picked here, until the chat relaunches on it.
    private var pendingModel: String??
    private var bag: Set<AnyCancellable> = []
    /// The user chose to send while another app is mid-turn.
    private var sendDespiteOtherApp = false
    /// "Send When It Finishes": the composer's message goes once the other app is idle.
    private(set) var sendingWhenOtherAppIdles = false
    /// Gives up on "Send When It Finishes"; each new wait replaces it.
    private var idleTimeout: Task<Void, Never>?

    /// Maps dropped/pasted file URLs to paths the sandbox can read (files outside
    /// the mounts are copied into the workspace's drops dir by the host).
    var resolveFileURLs: (([URL]) -> [URL])? {
        get { composer.resolveFileURLs }
        set { composer.resolveFileURLs = newValue }
    }

    /// Keeps the queued messages on disk until they've gone.
    private var queueSaver: AnyCancellable?

    init(session: ChatSession) {
        self.session = session
        transcript = ChatWebTranscript(source: session)
        emptyModel = ChatEmptyModel(agent: session.title.capitalized, sandbox: session.containerName,
                                    folder: session.workdir, showsTips: ChatTips().showing)
        super.init(frame: .zero)
        composer.agentName = session.title
        buildLayout()
        bind()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The keyboard to the chat: to the agent's open question, else the composer.
    /// One of the card's own text fields being typed in keeps it (the host would
    /// turn the next keys into picks, a skip or a half-typed submit).
    func focusComposer() {
        if let questionHost {
            if !keyboardIsIn(questionHost) { window?.makeFirstResponder(questionHost) }
        } else {
            composer.focus()
        }
    }

    #if DEBUG
    var debugTranscript: ChatWebTranscript { transcript }
    var debugComposer: ChatComposerView { composer }
    var debugComposerEnabled: Bool { composer.isEnabled }
    var debugQueuedView: QueuedPromptsView { queuedView }
    var debugPlanView: PlanPinView { planView }
    var debugStatusText: String { statusLabel.stringValue }
    var debugSendButton: ComposerSendButton { sendButton }
    func debugSetDraft(_ text: String) { composer.setDraft(text) }
    /// The round button in the pill: its mode, and a click on it.
    var debugSendMode: ComposerSendButton.Mode { sendButton.mode }
    var debugSendEnabled: Bool { sendButton.isEnabled }
    func debugClickSendButton() { sendButton.performClick(nil) }
    var debugSendButtonFrame: NSRect { sendButton.convert(sendButton.bounds, to: self) }
    /// The controls under the composer (accessibility ids), and their parts.
    var debugBarShown: [String] { bar.debugShown }
    var debugBarFrame: NSRect { bar.convert(bar.bounds, to: self) }
    var debugReadoutText: String { bar.readoutText }
    var debugContextGaugeShown: Bool { bar.contextFraction != nil && bar.debugShown.contains("chat-details") }
    var debugChooserTitle: String { bar.chooserTitle }
    var debugChooserMenu: [String] { bar.debugChooserMenu }
    var debugMCPTitle: String { mcpButton.attributedTitle.string }
    var debugModelTitle: String { bar.claude.modelButton.item(at: 0)?.attributedTitle?.string ?? "" }
    var debugEffortTitle: String { bar.claude.effortButton.item(at: 0)?.attributedTitle?.string ?? "" }
    var debugModeTitle: String { modePopup.item(at: 0)?.attributedTitle?.string ?? "" }
    /// Pick a Claude model as the chooser under the composer does.
    func debugPickClaudeModel(_ id: String?) { claudeModelPicked(id) }
    func debugPickClaudeEffort(_ level: String?) { claudeEffortPicked(level) }
    /// The readout's click: Session details.
    func debugClickReadout() { bar.readoutButton.performClick(nil) }
    var debugDetailsShown: Bool { detailsPopover?.isShown == true }
    var debugDetailsCanCompact: Bool { detailsHost?.rootView.canCompact == true }
    #endif

    /// A file path in the conversation was clicked.
    var onOpenFile: ((URL, Int?) -> Void)? {
        get { transcript.onOpenFile }
        set { transcript.onOpenFile = newValue }
    }

    /// Relaunch the agent on this conversation (the pane wires it).
    var onReconnect: (() -> Void)?

    /// The session's name, as the sidebar shows it (the pane wires it).
    var sessionName: (() -> String?)?

    /// A reply's "Fork to New Chat" (the window wires it to the controller).
    var onFork: ((String) -> Void)? {
        get { transcript.onFork }
        set { transcript.onFork = newValue }
    }

    func addAttachments(urls: [URL]) {
        composer.addAttachments(urls: urls)
        composer.focus()
    }

    /// Start from a draft: text in the composer and files as attachments, or
    /// sent straight away.
    func applyDraft(text: String, urls: [URL], attachments: [ChatAttachment] = [], send: Bool) {
        if send {
            let files = urls.map { ComposerTextView.attachment(for: resolveFileURLs?([$0]).first ?? $0) }
            session.sendWhenReady(text: text, attachments: attachments + files)
        } else {
            if !text.isEmpty { composer.addToDraft(text) }
            if !urls.isEmpty { composer.addAttachments(urls: urls) }
            if !attachments.isEmpty { composer.addAttachments(attachments) }
            composer.focus()
        }
    }

    /// Back in the field: what was typed and never went. `carryingQueued`: this
    /// chat was handed the messages queued in the last one, to send.
    func restoreDraft(carryingQueued: Bool) {
        let text = ComposerDrafts.restore(for: session.ownSessionID, keepQueued: !carryingQueued)
        if !text.isEmpty { composer.setDraft(text) }
    }

    /// The chat's closing: its queued messages are about to be handed on, and
    /// what's on disk stays until they've gone. Returns the composer's attachments.
    func prepareToClose() -> [ChatAttachment] {
        queueSaver = nil
        return composer.takeAttachments()
    }

    func addAttachments(from pasteboard: NSPasteboard) -> Bool {
        defer { composer.focus() }
        return composer.addAttachments(from: pasteboard)
    }

    // MARK: Layout

    private func buildLayout() {
        permissionLabel.font = .role(.body)
        permissionButtons.orientation = .horizontal
        permissionButtons.spacing = 8
        permissionBar.orientation = .vertical
        permissionBar.alignment = .leading
        permissionBar.spacing = 6
        permissionBar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        permissionBar.wantsLayer = true
        permissionBar.layer?.cornerRadius = 10
        permissionBar.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.15).cgColor
        permissionBar.addArrangedSubview(permissionLabel)
        permissionBar.addArrangedSubview(permissionButtons)
        permissionBar.isHidden = true
        permissionBar.setAccessibilityIdentifier("chat-permission")

        let draftID = session.ownSessionID
        composer.draftID = draftID
        queueSaver = session.$queue.dropFirst().sink { ComposerDrafts.save(queued: $0.items.map(\.text), for: draftID) }
        session.onUnsent = { [weak self] in self?.composer.setDraft(ComposerDrafts.typed(for: draftID)) }
        composer.onSubmit = { [weak self] text, attachments in
            guard let self else { return false }
            // `&` runs on this Mac: the first time, say so and ask.
            if case .mac? = ChatSession.localCommand(text), !Self.confirmMacCommands(in: self.window) { return false }
            self.sendingWhenOtherAppIdles = false   // sent (or queued) by hand
            self.idleTimeout?.cancel()
            let first = self.session.items.isEmpty && !self.countedForTips
            let sent = self.session.submit(text: text, attachments: attachments)
            // A chat you started: one fewer to show the getting-started tips in.
            if sent, first {
                self.countedForTips = true
                if !AutomatedRun.isActive, !AppDelegate.isHostingTests { ChatTips().chatStarted() }
            }
            return sent
        }
        composer.shouldSubmit = { [weak self] in self?.confirmSendWhileOtherAppWorks() ?? true }
        composer.commands = { [weak session] in session?.commands ?? [] }
        composer.sentHistory = { [weak session] in
            // Messages, and the `!` / `&` commands you ran (↑ brings them back too).
            session?.items.compactMap {
                switch $0 {
                case .user(_, let text, _): text
                case .tool(let t) where t.id.hasPrefix("local-"): t.title
                default: nil
                }
            } ?? []
        }
        composer.onTextChange = { [weak self] text in self?.showCommandHint(text) }
        queuedView.onEdit = { [weak self] prompt in
            guard let self, self.session.unqueue(prompt.id) != nil else { return }
            self.composer.edit(prompt)
        }
        queuedView.onRemove = { [weak self] prompt in self?.session.unqueue(prompt.id) }
        composer.onFind = { [weak self] sender in self?.transcript.performFind(sender) }
        composer.fileRoot = session.workdir
        transcript.workdir = session.workdir
        composer.onEscape = { [weak self] in
            guard let self, case .running = self.session.phase else { return false }
            self.session.cancel()
            return true
        }

        modePopup.onPick = { [weak self] id in if let id { self?.session.setMode(id) } }
        modelPopup.onPick = { [weak self] id in if let id { self?.session.setModel(id) } }
        bar.claude.onModelPicked = { [weak self] id in self?.claudeModelPicked(id) }
        bar.claude.onEffortPicked = { [weak self] level in self?.claudeEffortPicked(level) }
        bar.claude.currentModelID = { [weak self] in self.flatMap { $0.displayedModel } }
        composer.onSendButton = { [weak self] in self?.sendOrStop() }
        bar.attachButton.target = self
        bar.attachButton.action = #selector(showAttachMenu(_:))
        mcpButton.target = self
        mcpButton.action = #selector(showMCP)
        bar.readoutButton.target = self
        bar.readoutButton.action = #selector(showDetails)
        transcript.onUndo = { [weak self] turn in self?.undo(turn) }
        let footer = bar
        updatePieces()

        // Permission bar + composer stack: a hidden bar collapses (no blank band).
        let bottom = NSStackView(views: [permissionBar, planView, queuedView, composer])
        bottomStack = bottom
        bottom.orientation = .vertical
        bottom.alignment = .width
        bottom.spacing = 8
        bottom.detachesHiddenViews = true

        // No SwiftUI min/ideal size: measured at zero width the wrapped hint is
        // thousands of points tall, which pinned the window's height (even
        // with the empty state hidden).
        emptyState.sizingOptions = []
        for v in [transcript, emptyState, bottom, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        // The conversation's column: up to the edge, or to the inspector beside it.
        addLayoutGuide(column)
        columnToEdge = column.trailingAnchor.constraint(equalTo: trailingAnchor)
        // What you type and answer lines up with the transcript's centered
        // column: the column's width, up to the readable width (plus margins).
        // It only *wants* that width, below the window's split view (260): a
        // stronger pull shrinks this pane to it and pins the sidebar at its widest.
        addLayoutGuide(readable)
        let fill = readable.widthAnchor.constraint(equalToConstant: ChatWebTranscript.readableWidth + 32)
        fill.priority = .init(100)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            columnToEdge,
            readable.centerXAnchor.constraint(equalTo: column.centerXAnchor),
            readable.topAnchor.constraint(equalTo: column.topAnchor),
            readable.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            readable.widthAnchor.constraint(lessThanOrEqualToConstant: ChatWebTranscript.readableWidth + 32),
            readable.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor),
            readable.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
            fill,
        ])
        NSLayoutConstraint.activate([
            // Edge to edge over the transcript: the sea is full bleed. It takes
            // the transcript's size and imposes none (see `sizingOptions`).
            emptyState.topAnchor.constraint(equalTo: transcript.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: transcript.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: transcript.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: transcript.trailingAnchor),
        ])
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: topAnchor),
            transcript.leadingAnchor.constraint(equalTo: leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            bottom.topAnchor.constraint(equalTo: transcript.bottomAnchor, constant: 6),
            bottom.leadingAnchor.constraint(equalTo: readable.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: readable.trailingAnchor, constant: -16),

            // The controls: plain text under the pill, 10 pt in from its sides.
            footer.topAnchor.constraint(equalTo: bottom.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    // MARK: Binding

    private func bind() {
        // The transcript follows the chat by itself (`ChatFeed`); here, only
        // whether there's anything yet. (A catch-up keeps the old transcript up.)
        session.$items.sink { [weak self] items in
            guard let self, !self.session.isCatchingUp else { return }
            self.showEmptyState(items.isEmpty)
        }.store(in: &bag)
        session.$permission.sink { [weak self] in self?.showPermission($0) }.store(in: &bag)
        session.$question.sink { [weak self] in self?.showQuestion($0) }.store(in: &bag)
        session.$mcpServers.sink { [weak self] in self?.showMCPSummary($0) }.store(in: &bag)
        session.$suggestedPrompt.sink { [weak self] in self?.composer.suggestion = $0 }.store(in: &bag)
        session.$queue.sink { [weak self] queue in
            guard let self else { return }
            // @Published sends before it stores: go by the value sent.
            self.queuedView.show(queue.items)
            self.queuedCount = queue.items.count
            if case .running = self.session.phase { self.showPhase(.running) }
        }.store(in: &bag)
        session.$turnPlan.sink { [weak self] in self?.showPlan($0) }.store(in: &bag)
        session.$hasExtras.dropFirst().sink { [weak self] on in
            // Published before it's stored: the pieces read it next turn.
            Task { [weak self] in self?.updatePieces() }
            if on { self?.refreshMCPQuietly() }
        }.store(in: &bag)
        session.$phase.sink { [weak self] phase in
            guard let self else { return }
            if self.emptyModel.phase != phase { self.emptyModel.phase = phase }
            if case .starting = phase {} else { self.showEmptyState(self.session.items.isEmpty) }
            self.showPhase(phase)
        }.store(in: &bag)
        // Usage (and, for Claude, the model it answered with) → the readout.
        session.$usage.dropFirst().sink { [weak self] _ in
            Task { [weak self] in self?.showUsage() }
        }.store(in: &bag)
        session.$modes.combineLatest(session.$currentMode).sink { [weak self] modes, current in
            guard let self else { return }
            let mode = modes.first { $0.id == current }?.name
            if self.emptyModel.mode != mode { self.emptyModel.mode = mode }
            self.fill(self.modePopup, modes, current)
            self.updatePieces()
        }.store(in: &bag)
        session.$models.combineLatest(session.$currentModel).sink { [weak self] models, current in
            guard let self else { return }
            self.fill(self.modelPopup, models, current)
            self.updatePieces()
        }.store(in: &bag)
        if session.agent == .claude {
            // The conversation's priced total (the readout's cost), and the
            // price feed behind the model chooser (both throttled).
            ClaudeUsageStore.shared.refresh()
            ClaudeUsageStore.shared.$sessionTotals.dropFirst()
                .sink { [weak self] _ in Task { [weak self] in self?.showUsage() } }
                .store(in: &bag)
        }
        showUsage()
    }

    /// The running turn's plan, pinned above the composer while it runs; a
    /// finished one stays a moment, then goes (as it does when the turn ends).
    private func showPlan(_ entries: [ChatItem.PlanEntry]?) {
        planHide?.cancel()
        planHide = nil
        guard let entries, let progress = PlanProgress(entries) else { return planView.hide() }
        planView.show(entries)
        guard progress.isComplete else { return }
        planHide = Task { [weak self] in
            try? await Task.sleep(for: PlanPinView.lingerAfterDone)
            guard !Task.isCancelled else { return }
            self?.planView.hide()
        }
    }

    /// Which controls apply to this chat now.
    private func updatePieces() {
        bar.pieces = .for(agent: session.agent, hasModels: !session.models.isEmpty, hasModes: !session.modes.isEmpty,
                          hasExtras: session.hasExtras, hasUsage: session.usage != nil)
        bar.choicesChanged()
    }

    private func showEmptyState(_ show: Bool) {
        if show, emptyState.isHidden || emptyModel.git == nil { emptyModel.refreshGit() }
        emptyState.isHidden = !show
    }

    /// The chat's folder on this Mac and how its sandbox sees it, for the empty chat.
    func setSandboxAccess(folder: URL, access: SandboxAccess) {
        let path = folder.path(percentEncoded: false)
        if emptyModel.folder != path { emptyModel.folder = path; emptyModel.git = nil }
        if emptyModel.access != access { emptyModel.access = access }
        if !emptyState.isHidden, emptyModel.git == nil { emptyModel.refreshGit() }
    }

    private func showPhase(_ phase: ChatSession.Phase) {
        detailsHost?.rootView = detailView(phase: phase)
        switch phase {
        // The status line under the pill says only what's out of the ordinary.
        case .starting:
            statusLabel.stringValue = session.isCatchingUp
                ? "Catching up with \(session.otherWriterName)…" : "Starting \(session.title)…"
            sendButton.mode = .send; sendButton.isEnabled = false
            // Nothing to type into until the agent is up.
            composer.setEnabled(false)
        case .ready:
            refreshMCPQuietly()
            statusLabel.stringValue = ""
            sendButton.mode = .send; sendButton.isEnabled = true
            composer.setEnabled(true)
            if window?.firstResponder === window { composer.focus() }
        case .running:
            // Return still sends: the message waits for the turn.
            statusLabel.stringValue = switch queuedCount {
            case 0: ""
            case 1: "Your message sends when this turn ends"
            default: "Your messages send together when this turn ends"
            }
            sendButton.mode = .stop; sendButton.isEnabled = true
        case .closed(let why):
            statusLabel.stringValue = why
            // An agent that died on its own (e.g. over sleep) can come back.
            let reconnect = session.canReconnect && onReconnect != nil
            sendButton.mode = reconnect ? .reconnect : .send
            sendButton.isEnabled = reconnect
            composer.setEnabled(false)
        }
        statusLabel.toolTip = statusLabel.stringValue.isEmpty ? nil : statusLabel.stringValue
    }

    // MARK: MCP

    private func showMCPSummary(_ servers: [ChatSession.MCPServer]?) {
        // Red only for a real failure: a connector waiting for sign-in (most
        // claude.ai ones nobody uses here) or turned off is routine.
        bar.showMCP(count: servers?.count, failing: MCPServerList.failing(servers ?? []).map(\.name))
    }

    // MARK: Inspector (beside the conversation)

    private let column = NSLayoutGuide()
    private let readable = NSLayoutGuide()
    private var columnToEdge: NSLayoutConstraint!
    private var inspector: NSView?
    private var inspectorConstraints: [NSLayoutConstraint] = []
    /// The person wants it shown (it still steps aside in a narrow pane).
    var inspectorWanted = false { didSet { updateInspector() } }
    /// Below this width the conversation keeps the whole pane.
    static let inspectorMinPaneWidth: CGFloat = 640

    /// The session inspector to show beside the conversation (built once);
    /// shown while Session Details is on (View ▸ Show Session Details).
    func setInspector(_ view: NSView) {
        inspector?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        inspector = view
        inspectorWanted = SessionDetails.isShown
        NotificationCenter.default.publisher(for: SessionDetails.didToggle)
            .sink { [weak self] _ in self?.inspectorWanted = SessionDetails.isShown }
            .store(in: &bag)
        updateInspector()
    }

    var isInspectorShown: Bool { inspector?.superview === self }

    private func updateInspector() {
        guard let inspector else { return }
        let show = inspectorWanted && bounds.width >= Self.inspectorMinPaneWidth
        guard show != isInspectorShown else { return }
        NSLayoutConstraint.deactivate(inspectorConstraints)
        if show {
            addSubview(inspector)
            inspectorConstraints = [
                inspector.topAnchor.constraint(equalTo: topAnchor),
                inspector.bottomAnchor.constraint(equalTo: bottomAnchor),
                inspector.trailingAnchor.constraint(equalTo: trailingAnchor),
                inspector.widthAnchor.constraint(equalToConstant: 300),
                column.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            ]
            columnToEdge.isActive = false
            NSLayoutConstraint.activate(inspectorConstraints)
        } else {
            inspector.removeFromSuperview()
            inspectorConstraints = []
            columnToEdge.isActive = true
        }
    }

    override func layout() {
        super.layout()
        updateInspector()
        // Like the Claude app's: what you type grows to about half the chat.
        composer.maximumHeight = (bounds.height / 2).rounded()
    }

    /// The MCP details (the Connectors card's rows open them too).
    func showMCPDetails() { showMCP() }

    @objc private func showMCP() {
        // Below its chip when that's on the bar (a server failing), else below `+`.
        let anchor: NSView = mcpButton.isHiddenOrHasHiddenAncestor ? bar.attachButton : mcpButton
        NSPopover.toggle(&mcpPopover, below: anchor) { .hosting(MCPStatusView(session: session)) }
    }

    /// Check MCP once the agent's up (and after each turn: servers come and go).
    private func refreshMCPQuietly() {
        guard session.hasExtras else { return }
        Task { try? await session.refreshMCP() }
    }

    // MARK: Undo a turn

    /// Put back the files a turn changed, after saying which.
    func undo(_ turn: String) {
        Task { @MainActor in
            do {
                let preview = try await session.previewRewind(turn)
                guard preview.canRewind, !preview.files.isEmpty else {
                    return Alerts.inform("Nothing to undo", preview.error ?? "These files are already as they were before this message.", in: window)
                }
                let names = preview.files.map { ($0 as NSString).lastPathComponent }
                // The first eight, then how many more: "a.swift, b.swift, and 3 more".
                let shown = Array(names.prefix(8)) + (names.count > 8 ? ["\(names.count - 8) more"] : [])
                let info = "Puts \(names.count == 1 ? "1 file" : "\(names.count) files") back as they were before it "
                    + "(+\(preview.insertions) −\(preview.deletions) lines):\n\(shown.formatted())"
                    + "\n\nChanges made by shell commands aren’t tracked and stay as they are. The conversation isn’t changed."
                guard await Alerts.confirm("Undo the changes from this message?", info, confirm: "Undo Changes",
                                           destructive: true, in: window) else { return }
                let done = try await session.rewind(turn)
                if !done.canRewind { Alerts.inform("Couldn’t undo the changes", done.error ?? "Claude Code couldn’t restore the files.", in: window) }
            } catch {
                Alerts.inform("Couldn’t undo the changes", error.localizedDescription, in: window)
            }
        }
    }


    // MARK: Model, effort, readout

    /// The Claude model the chooser shows: one just picked (until the chat
    /// relaunches on it), else the one it answered with, else its launch model.
    private var displayedModel: String? {
        if let pendingModel { return pendingModel }
        return session.liveModel ?? session.launchModel
    }

    /// The readout (`$0.47 · 38%`) and, for Claude, the model and effort
    /// choosers' titles; an open Session details follows along.
    private func showUsage() {
        updatePieces()
        let usage = session.usage
        let percent = usage.flatMap { ClaudeReadout.percent(used: $0.used, size: $0.size) }
        bar.contextFraction = usage.flatMap { $0.size > 0 ? Double($0.used) / Double($0.size) : nil }
        var tip = usage.map { "Context: \($0.used.formatted()) of \($0.size.formatted()) tokens" }
        if session.agent == .claude {
            let status = session.claudeStatus
            if let id = status.sessionID { ClaudeUsageStore.shared.refreshSession(id) }
            let cost = ClaudeReadout.cost(of: status)
            bar.readoutText = ClaudeReadout.text(cost: cost, percent: percent)
            bar.claude.showModel(title: ClaudeReadout.modelTitle(displayedModel), id: displayedModel, color: .labelColor)
            bar.claude.showEffort(title: ClaudeReadout.effortTitle(session.launchEffort), id: session.launchEffort,
                                  color: .secondaryLabelColor)
            tip = [tip, cost.map { "Estimated cost: \(ClaudeStatsFormat.usd($0, fractionDigits: 4))" }, "Click for session details"]
                .compactMap { $0 }.joined(separator: "\n")
            detailsHost?.rootView = detailView()
        } else {
            bar.readoutText = ClaudeReadout.text(cost: usage?.cost, percent: percent)
        }
        bar.readoutDetail = tip ?? ""
        bar.choicesChanged()
    }

    /// `phase`: the one just reported, when `session.phase` may not have it yet.
    private func detailView(phase: ChatSession.Phase? = nil) -> ClaudeStatsDetailView {
        ClaudeStatsDetailView(status: session.claudeStatus, defaultModel: session.launchModel,
                              defaultEffort: session.launchEffort, canCompact: (phase ?? session.phase) == .ready,
                              onCompact: { [weak self] in self?.compactFromDetails() })
    }

    /// Session details' Compact Session: closes them, so the turn shows.
    private func compactFromDetails() {
        session.compact()
        detailsPopover?.close()
        detailsPopover = nil
        detailsHost = nil
    }

    /// The readout's ⓘ: Session details, with the context gauge.
    @objc private func showDetails() {
        guard bar.pieces.readoutOpensDetails else { return }
        if detailsPopover?.isShown != true { ClaudeUsageStore.shared.refresh() }
        let host = NSHostingController(rootView: detailView())
        guard NSPopover.toggle(&detailsPopover, below: bar.readoutButton, content: { host }) != nil else {
            detailsHost = nil
            return
        }
        detailsHost = host
    }

    /// A Claude model or effort picked under the composer (the pane wires it:
    /// the workspace's from now on; a new model relaunches the chat on it,
    /// keeping the conversation — now, or when the running turn ends).
    var onClaudeModelPicked: ((String?) -> Void)?
    var onClaudeEffortPicked: ((String?) -> Void)?

    private func claudeModelPicked(_ id: String?) {
        // Shown as the chat's model until it relaunches on it.
        if ClaudePriceBook.normalize(id ?? "") != ClaudePriceBook.normalize(session.launchModel ?? "") {
            pendingModel = .some(id)
        }
        onClaudeModelPicked?(id)
        showUsage()
    }

    private func claudeEffortPicked(_ level: String?) {
        onClaudeEffortPicked?(level)
        showUsage()
    }

    // MARK: Attach

    @objc private func showAttachMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem("Attach Files…") { [weak self] in self?.chooseAttachments() })
        let mention = NSMenuItem("Mention a Workspace File") { [weak self] in self?.composer.startMention() }
        mention.isEnabled = composer.isEnabled
        menu.addItem(mention)
        // The chat's MCP servers (on the bar too while one isn't working).
        if bar.pieces.mcp {
            menu.addItem(.separator())
            let count = bar.mcpCount.map { " (\($0))" } ?? ""
            let mcp = NSMenuItem("MCP Servers\(count)…") { [weak self] in self?.showMCP() }
            mcp.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil)
            menu.addItem(mcp)
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func chooseAttachments() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = URL(filePath: session.workdir, directoryHint: .isDirectory)
        panel.prompt = "Attach"
        Task { [weak self] in
            guard await panel.beginSheetModal(for: window) == .OK, let self else { return }
            self.addAttachments(urls: panel.urls)
        }
    }


    /// The agent's question, above the composer, with the keyboard while it's up.
    private func showQuestion(_ q: AgentQuestion?) {
        if let host = questionHost, host.form.question == q { return }
        let hadFocus = questionHost.map { keyboardIsIn($0) } ?? false
        questionHost?.removeFromSuperview()
        questionHost = nil
        focusQuestionOnKey = nil
        guard let q else {
            if hadFocus, !isHiddenOrHasHiddenAncestor { composer.focus() }
            return
        }
        let host = AgentQuestionHost(AgentQuestionForm(q) { [weak self] answer in
            self?.session.answerQuestion(q, answer)
        })
        bottomStack?.insertArrangedSubview(host, at: 0)
        if let stack = bottomStack { host.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        questionHost = host
        if let window, !window.isKeyWindow {
            // Asked while you were elsewhere: the keyboard goes to it when you're back.
            focusQuestionOnKey = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: window)
                .first()
                .sink { [weak self] _ in self?.focusQuestionIfHere() }
        } else {
            focusQuestionIfHere()
        }
    }

    /// Give the open question the keyboard, but only from this chat: a hidden
    /// chat's card (or one in a pane you're not in) would take every key. A
    /// chat shown later hands it over in `focusComposer`.
    private func focusQuestionIfHere() {
        guard let host = questionHost, let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor,
              !keyboardIsIn(host), window.firstResponder === window || keyboardIsIn(self) else { return }
        window.makeFirstResponder(host)
    }

    /// Whether the keyboard is in `view`: it or a view inside it, or a text
    /// field in it being edited (its field editor has the keys).
    private func keyboardIsIn(_ view: NSView) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
            || ((responder as? NSTextView)?.delegate as? NSView)?.isDescendant(of: view) == true
    }

    private var questionHost: AgentQuestionHost?
    private var focusQuestionOnKey: AnyCancellable?
    private weak var bottomStack: NSStackView?

    #if DEBUG
    var debugQuestionForm: AgentQuestionForm? { questionHost?.form }
    var debugQuestionHost: NSView? { questionHost }
    /// Where the keyboard is in this chat: the question card (or a field in
    /// it), the composer, or neither.
    var debugQuestionHasKeyboard: Bool { questionHost.map { keyboardIsIn($0) } ?? false }
    var debugComposerHasKeyboard: Bool { keyboardIsIn(composer) }
    /// The composer's frame and the transcript's text column, in this view.
    func debugColumn() async -> (composer: NSRect, text: NSRect) {
        (composer.convert(composer.bounds, to: self), transcript.convert(await transcript.debugTextColumn(), to: self))
    }
    #endif

    private func showPermission(_ p: PendingPermission?) {
        permissionButtons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let p else { permissionBar.isHidden = true; return }
        permissionLabel.stringValue = p.title
        for (i, option) in p.options.enumerated() {
            let b = NSButton(title: option.name, target: self, action: #selector(permissionChosen(_:)))
            b.tag = i
            b.bezelStyle = .rounded
            b.controlSize = .small
            if option.kind == "allow_once" { b.keyEquivalent = "\r"; b.keyEquivalentModifierMask = [.command] }
            if option.kind.hasPrefix("reject") { b.hasDestructiveAction = true }
            b.setAccessibilityIdentifier("chat-permission-\(option.kind)")
            permissionButtons.addArrangedSubview(b)
        }
        permissionBar.isHidden = false
    }

    private func fill(_ popup: ChoicePopUp?, _ choices: [ChatSession.Choice], _ current: String?) {
        popup?.set(choices.map { ChoicePopUp.Choice(id: $0.id, title: $0.name) }, current: current)
    }

    // MARK: Actions

    /// Another app is mid-turn in this conversation: sending now forks it. Ask
    /// first (the draft stays put); "Send Anyway" sends it.
    private func confirmSendWhileOtherAppWorks() -> Bool {
        if sendDespiteOtherApp { sendDespiteOtherApp = false; return true }
        guard session.otherAppIsWorking, let window else { return true }
        let alert = NSAlert()
        alert.messageText = "\(session.otherWriterName.prefix(1).uppercased() + session.otherWriterName.dropFirst()) is still working in this conversation"
        alert.informativeText = "Sending now starts a second line of conversation alongside it, and neither side "
            + "sees the other’s replies. Send yours when it finishes, or send it now anyway."
        alert.addButton(withTitle: "Send When It Finishes")
        alert.addButton(withTitle: "Send Anyway")
        alert.addButton(withTitle: "Cancel")
        Task { [weak self] in
            let response = await alert.beginSheetModal(for: window)
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.sendWhenOtherAppIdles()
            case .alertSecondButtonReturn:
                self.sendDespiteOtherApp = true
                self.composer.submitFromButton()
            default: break
            }
        }
        return false
    }

    /// Hold the message until the other app's turn ends (the registry says idle).
    func sendWhenOtherAppIdles() {
        let send = { [weak self] in
            guard let self, self.sendingWhenOtherAppIdles else { return }
            self.sendingWhenOtherAppIdles = false
            self.session.onOtherAppIdle = nil
            self.idleTimeout?.cancel()
            // Give its last lines a moment to land, so the reload sees them.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                self.sendDespiteOtherApp = true
                self.composer.submitFromButton()
            }
        }
        sendingWhenOtherAppIdles = true
        // An earlier wait's timeout mustn't end this one.
        idleTimeout?.cancel()
        // It may have finished while the question was up.
        guard session.otherAppIsWorking else { return send() }
        statusLabel.stringValue = "Sends when \(session.otherWriterName) finishes…"
        session.onOtherAppIdle = send
        // Don't wait forever on an app that never says it's done (half an hour awake).
        idleTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30 * 60), clock: .suspending)
            guard !Task.isCancelled, let self, self.sendingWhenOtherAppIdles else { return }
            self.sendingWhenOtherAppIdles = false
            self.session.onOtherAppIdle = nil
            self.showPhase(self.session.phase)
        }
    }

    /// ⎋ stops a running turn (standard Cocoa cancel).
    override func cancelOperation(_ sender: Any?) {
        if case .running = session.phase { session.cancel() } else { super.cancelOperation(sender) }
    }

    /// Where a `!` or `&` line runs, under the composer while you type it.
    private func showCommandHint(_ text: String) {
        let hint: String? = switch ChatSession.localCommand(text.isEmpty ? text : text + "x") {
        case .sandbox?: "! runs in the sandbox “\(session.containerName)”, in \(session.workdir.tildeAbbreviated)"
        case .mac?: session.macFolder.map { "& runs on this Mac, in \($0.tildeAbbreviated), as you" }
            ?? "& runs on the Mac only from its window"
        case nil: nil
        }
        if let hint {
            if commandHint == nil { statusBeforeHint = statusLabel.stringValue }
            commandHint = hint
            statusLabel.stringValue = hint
            statusLabel.textColor = .controlAccentColor
        } else if commandHint != nil {
            commandHint = nil
            statusLabel.stringValue = statusBeforeHint
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    /// The first `&` command: what it does, and whether to go on (remembered).
    static let macCommandsKey = "macCommandsConfirmed"
    static func confirmMacCommands(in window: NSWindow?) -> Bool {
        if UserDefaults.standard.bool(forKey: macCommandsKey) || AutomatedRun.isActive { return true }
        guard Alerts.confirm("Run commands on this Mac?",
                             "A line starting with & runs in a shell on this Mac — not in the sandbox — in the "
                             + "session's folder, as you. The agent can't run these; only you can, from this window. "
                             + "(! runs a command in the sandbox.) Help ▸ Show Command Log lists every one you've run.",
                             confirm: "Run on This Mac") else { return false }
        UserDefaults.standard.set(true, forKey: macCommandsKey)
        CommandLog.shared.record(["event": "allowed", "sigil": "&"])
        return true
    }

    @objc private func sendOrStop() {
        switch session.phase {
        case .running: session.cancel()
        case .closed where session.canReconnect: onReconnect?()
        default: composer.submitFromButton()
        }
    }

    @objc private func permissionChosen(_ sender: NSButton) {
        guard let p = session.permission, p.options.indices.contains(sender.tag) else { return }
        session.answerPermission(p, optionID: p.options[sender.tag].id)
        composer.focus()
    }

}

// MARK: - File ▸ Print / Export Conversation

extension ChatSessionView {
    @objc func printDocument(_ sender: Any?) { transcript.printTranscript() }

    /// What File ▸ Export Conversation… calls the conversation (its heading)
    /// and the file it suggests: the session's own name, whichever session the
    /// window's title follows.
    var exportName: (heading: String, fileName: String) {
        let name = sessionName?() ?? session.title
        return (name, (name.isEmpty ? "Conversation" : name).replacing("/", with: "-") + ".md")
    }

    @objc func exportConversation(_ sender: Any?) {
        guard let window else { return }
        let name = exportName
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = name.fileName
        panel.directoryURL = URL(filePath: session.workdir, directoryHint: .isDirectory)
        let markdown = session.markdownExport(sessionName: name.heading)
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            do { try markdown.write(to: url, atomically: true, encoding: .utf8) }
            catch { Alerts.inform("Couldn’t export the conversation.", error.localizedDescription, in: window) }
        }
    }
}
