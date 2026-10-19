import Combine
import SwiftUI

/// A native chat surface for one session, hosted in the detail pane in place
/// of the terminal: transcript, permission prompt bar, composer, and a footer
/// with mode/model pickers, context/cost readout and Send/Stop.
@MainActor
final class ChatSessionView: NSView {
    let session: ChatSession

    private let transcript = ChatTranscriptView()
    /// Until the first message: a sea of creatures, and where this runs.
    private lazy var emptyState = NSHostingView(rootView: ChatEmptyState(
        agent: session.title.capitalized, folder: (session.workdir as NSString).lastPathComponent))
    private let composer = ChatComposerView()
    private let permissionBar = NSStackView()
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionButtons = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let usageLabel = NSTextField(labelWithString: "")
    private let modePopup = ChoicePopUp(tip: "Permission mode")
    private let modelPopup = ChoicePopUp(tip: "Model")
    private let sendButton = NSButton()
    /// "MCP 3" (a red dot when one's failing): opens the servers popover.
    private let mcpButton = NSButton()
    private var mcpPopover: NSPopover?
    private var bag: Set<AnyCancellable> = []
    /// History replayed while resuming, shown in one go when it's done.
    private var heldReplay: [ChatItem]?
    /// Reloading to catch up with another app: keep the old transcript up meanwhile.
    private var heldForCatchUp = false
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

    init(session: ChatSession) {
        self.session = session
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
    var debugTranscript: ChatTranscriptView { transcript }
    var debugComposerEnabled: Bool { composer.isEnabled }
    func debugSetDraft(_ text: String) { composer.setDraft(text) }
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
            if !text.isEmpty { composer.setDraft(text) }
            if !urls.isEmpty { composer.addAttachments(urls: urls) }
            composer.focus()
        }
    }

    func addAttachments(from pasteboard: NSPasteboard) -> Bool {
        defer { composer.focus() }
        return composer.addAttachments(from: pasteboard)
    }

    // MARK: Layout

    private func buildLayout() {
        permissionLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
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

        composer.onSubmit = { [weak self] text, attachments in
            guard let self else { return false }
            self.sendingWhenOtherAppIdles = false   // sent (or queued) by hand
            self.idleTimeout?.cancel()
            return self.session.submit(text: text, attachments: attachments)
        }
        composer.shouldSubmit = { [weak self] in self?.confirmSendWhileOtherAppWorks() ?? true }
        composer.commands = { [weak session] in session?.commands ?? [] }
        composer.onFind = { [weak self] sender in self?.transcript.performFind(sender) }
        composer.fileRoot = session.workdir
        transcript.workdir = session.workdir
        composer.onEscape = { [weak self] in
            guard let self, case .running = self.session.phase else { return false }
            self.session.cancel()
            return true
        }

        for label in [statusLabel, usageLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        usageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modePopup.onPick = { [weak self] id in if let id { self?.session.setMode(id) } }
        modelPopup.onPick = { [weak self] id in if let id { self?.session.setModel(id) } }
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .small
        sendButton.target = self
        sendButton.action = #selector(sendOrStop)
        sendButton.setAccessibilityIdentifier("chat-send-stop")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        mcpButton.bezelStyle = .accessoryBarAction
        mcpButton.controlSize = .small
        mcpButton.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "MCP servers")
        mcpButton.imagePosition = .imageLeading
        mcpButton.title = "MCP"
        mcpButton.toolTip = "MCP servers in this session"
        mcpButton.target = self
        mcpButton.action = #selector(showMCP)
        mcpButton.setAccessibilityIdentifier("chat-mcp")
        mcpButton.isHidden = true   // until the kit's wrapper says it's there
        transcript.onUndo = { [weak self] turn in self?.undo(turn) }
        let footer = NSStackView(views: [modePopup, modelPopup, mcpButton, statusLabel, spacer, usageLabel, sendButton])
        footer.orientation = .horizontal
        footer.spacing = 8

        // Permission bar + composer stack: a hidden bar collapses (no blank band).
        let bottom = NSStackView(views: [permissionBar, composer])
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
        let fill = readable.widthAnchor.constraint(equalToConstant: ChatTranscriptView.readableWidth + 32)
        fill.priority = .init(100)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            columnToEdge,
            readable.centerXAnchor.constraint(equalTo: column.centerXAnchor),
            readable.topAnchor.constraint(equalTo: column.topAnchor),
            readable.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            readable.widthAnchor.constraint(lessThanOrEqualToConstant: ChatTranscriptView.readableWidth + 32),
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

            footer.topAnchor.constraint(equalTo: bottom.bottomAnchor, constant: 6),
            footer.leadingAnchor.constraint(equalTo: readable.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: readable.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    // MARK: Binding

    private func bind() {
        session.$items.sink { [weak self] items in
            guard let self else { return }
            if self.session.isCatchingUp {
                self.heldForCatchUp = true
                return
            }
            self.showEmptyState(items.isEmpty)
            // Resuming replays the whole history before the session is ready:
            // draw it once at the end (already at the bottom), not message by
            // message as a long scroll.
            if case .starting = self.session.phase, !items.isEmpty {
                self.heldReplay = items
                return
            }
            self.transcript.update(items)
        }.store(in: &bag)
        session.$permission.sink { [weak self] in self?.showPermission($0) }.store(in: &bag)
        session.$question.sink { [weak self] in self?.showQuestion($0) }.store(in: &bag)
        session.$mcpServers.sink { [weak self] in self?.showMCPSummary($0) }.store(in: &bag)
        session.$hasQueued.dropFirst().sink { [weak self] _ in
            // @Published sends before it stores: read it on the next turn.
            Task { [weak self] in
                guard let self else { return }
                self.showPhase(self.session.phase)
            }
        }.store(in: &bag)
        session.$hasExtras.sink { [weak self] on in
            self?.mcpButton.isHidden = !on
            if on { self?.refreshMCPQuietly() }
        }.store(in: &bag)
        session.$phase.sink { [weak self] phase in
            guard let self else { return }
            if case .starting = phase {} else if let held = self.heldReplay {
                self.heldReplay = nil
                self.heldForCatchUp = false
                self.transcript.update(self.session.items.isEmpty ? held : self.session.items)
            } else if self.heldForCatchUp {
                self.heldForCatchUp = false
                self.showEmptyState(self.session.items.isEmpty)
                self.transcript.update(self.session.items)
            }
            self.showPhase(phase)
        }.store(in: &bag)
        // A Claude chat's usage and model live in the pane's title-strip readout.
        session.$usage.sink { [weak self] in
            guard let self, self.session.agent != .claude else { return }
            self.showUsage($0)
        }.store(in: &bag)
        session.$modes.combineLatest(session.$currentMode).sink { [weak self] modes, current in
            self?.fill(self?.modePopup, modes, current)
        }.store(in: &bag)
        session.$models.combineLatest(session.$currentModel).sink { [weak self] models, current in
            guard let self else { return }
            self.fill(self.modelPopup, models, current)
            if self.session.agent == .claude { self.modelPopup.isHidden = true }
        }.store(in: &bag)
    }

    private func showEmptyState(_ show: Bool) {
        emptyState.isHidden = !show
    }

    private func showPhase(_ phase: ChatSession.Phase) {
        switch phase {
        case .starting:
            statusLabel.stringValue = session.isCatchingUp
                ? "Catching up with \(session.otherWriterName)…" : "Starting \(session.title)…"
            sendButton.title = "Send"; sendButton.isEnabled = false
            // Nothing to type into until the agent is up.
            composer.setEnabled(false)
        case .ready:
            refreshMCPQuietly()
            statusLabel.stringValue = "↩ send · ⇧↩ new line"
            sendButton.title = "Send"; sendButton.isEnabled = true
            composer.setEnabled(true)
            if window?.firstResponder === window { composer.focus() }
        case .running:
            statusLabel.stringValue = session.hasQueued ? "Working… your message sends when it’s done  ⎋ to stop"
                : "Working…  ⎋ to stop"
            sendButton.title = "Stop"; sendButton.isEnabled = true
        case .closed(let why):
            statusLabel.stringValue = why
            // An agent that died on its own (e.g. over sleep) can come back.
            let reconnect = session.canReconnect && onReconnect != nil
            sendButton.title = reconnect ? "Reconnect" : "Send"
            sendButton.isEnabled = reconnect
            composer.setEnabled(false)
        }
    }

    // MARK: MCP

    private func showMCPSummary(_ servers: [ChatSession.MCPServer]?) {
        guard let servers else { mcpButton.title = "MCP"; mcpButton.contentTintColor = nil; return }
        let failing = servers.filter { $0.status == "failed" || $0.status == "needs-auth" }
        mcpButton.title = servers.isEmpty ? "MCP" : "MCP \(servers.count { $0.status == "connected" })/\(servers.count)"
        mcpButton.contentTintColor = failing.isEmpty ? nil : .systemRed
        mcpButton.toolTip = failing.isEmpty ? "MCP servers in this session"
            : "\(failing.map(\.name).formatted()) \(failing.count == 1 ? "isn’t" : "aren’t") working"
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
    }

    /// The MCP details (the Connectors card's rows open them too).
    func showMCPDetails() { showMCP() }

    @objc private func showMCP() {
        NSPopover.toggle(&mcpPopover, below: mcpButton) { .hosting(MCPStatusView(session: session)) }
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


    private func showUsage(_ usage: ChatSession.Usage?) {
        guard let usage else { usageLabel.stringValue = ""; return }
        var parts = ["\(Format.tokens(usage.used)) / \(Format.tokens(usage.size)) ctx"]
        if let cost = usage.cost { parts.append(cost.formatted(.currency(code: "USD"))) }
        usageLabel.stringValue = parts.joined(separator: " · ")
        usageLabel.toolTip = "Context: \(usage.used.formatted()) of \(usage.size.formatted()) tokens"
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
    /// The composer's frame (in this view), the transcript's text inset and its text area's width.
    var debugColumn: (composer: NSRect, textInset: CGFloat, textWidth: CGFloat) {
        (composer.convert(composer.bounds, to: self), transcript.debugTextInset, transcript.debugContentWidth)
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

