import AppKit
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
    private let modePopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
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

    func focusComposer() { composer.focus() }

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
    func applyDraft(text: String, urls: [URL], send: Bool) {
        if send {
            let files = urls.map { ComposerTextView.attachment(for: resolveFileURLs?([$0]).first ?? $0) }
            session.sendWhenReady(text: text, attachments: files)
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
        for popup in [modePopup, modelPopup] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 11)
            popup.isBordered = false
            popup.target = self
        }
        modePopup.action = #selector(modeChanged)
        modePopup.toolTip = "Permission mode"
        modelPopup.action = #selector(modelChanged)
        modelPopup.toolTip = "Model"
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
            transcript.trailingAnchor.constraint(equalTo: trailingAnchor),

            bottom.topAnchor.constraint(equalTo: transcript.bottomAnchor, constant: 6),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            footer.topAnchor.constraint(equalTo: bottom.bottomAnchor, constant: 6),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
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
        session.$mcpServers.sink { [weak self] in self?.showMCPSummary($0) }.store(in: &bag)
        session.$hasQueued.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.showPhase(self.session.phase) }
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
        mcpButton.title = servers.isEmpty ? "MCP" : "MCP \(servers.filter { $0.status == "connected" }.count)/\(servers.count)"
        mcpButton.contentTintColor = failing.isEmpty ? nil : .systemRed
        mcpButton.toolTip = failing.isEmpty ? "MCP servers in this session"
            : "\(failing.map(\.name).joined(separator: ", ")) \(failing.count == 1 ? "isn’t" : "aren’t") working"
    }

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
                let info = "Puts \(names.count == 1 ? "1 file" : "\(names.count) files") back as they were before it "
                    + "(+\(preview.insertions) −\(preview.deletions) lines):\n\(names.prefix(8).joined(separator: ", "))"
                    + (names.count > 8 ? " and \(names.count - 8) more" : "")
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
        if let cost = usage.cost { parts.append(String(format: "$%.2f", cost)) }
        usageLabel.stringValue = parts.joined(separator: " · ")
        usageLabel.toolTip = "Context: \(usage.used) of \(usage.size) tokens"
    }


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

    private func fill(_ popup: NSPopUpButton?, _ choices: [ChatSession.Choice], _ current: String?) {
        guard let popup else { return }
        popup.removeAllItems()
        for c in choices {
            popup.addItem(withTitle: c.name)
            popup.lastItem?.representedObject = c.id
        }
        if let current, let idx = choices.firstIndex(where: { $0.id == current }) { popup.selectItem(at: idx) }
        popup.isHidden = choices.isEmpty
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
        alert.beginSheetModal(for: window) { [weak self] response in
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
            // Give its last lines a moment to land, so the reload sees them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.sendDespiteOtherApp = true
                self.composer.submitFromButton()
            }
        }
        sendingWhenOtherAppIdles = true
        // It may have finished while the question was up.
        guard session.otherAppIsWorking else { return send() }
        statusLabel.stringValue = "Sends when \(session.otherWriterName) finishes…"
        session.onOtherAppIdle = send
        // Don't wait forever on an app that never says it's done.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30 * 60) { [weak self] in
            guard let self, self.sendingWhenOtherAppIdles else { return }
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

    @objc private func modeChanged() {
        if let id = modePopup.selectedItem?.representedObject as? String { session.setMode(id) }
    }

    @objc private func modelChanged() {
        if let id = modelPopup.selectedItem?.representedObject as? String { session.setModel(id) }
    }
}

/// An empty chat: a sea of creatures to stir up, over what to do next.
private struct ChatEmptyState: View {
    let agent: String
    let folder: String

    var body: some View {
        SeaBackdrop {
            VStack(spacing: 14) {
                Text("What should \(agent) work on?")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("It works in \(folder), inside its sandbox. Type / for commands, @ to mention a file, or drop files here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .accessibilityElement(children: .combine)
        }
    }
}
