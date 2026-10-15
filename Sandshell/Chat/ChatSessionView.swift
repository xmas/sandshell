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
    /// Until the first message: a little sea of dolphins, and where this runs.
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
    private var bag: Set<AnyCancellable> = []
    /// History replayed while resuming, shown in one go when it's done.
    private var heldReplay: [ChatItem]?
    /// Reloading to catch up with another app: keep the old transcript up meanwhile.
    private var heldForCatchUp = false
    /// The user chose to send while another app is mid-turn.
    private var sendDespiteOtherApp = false

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

        composer.onSubmit = { [weak self] text, attachments in self?.session.send(text: text, attachments: attachments) }
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
        let footer = NSStackView(views: [modePopup, modelPopup, statusLabel, spacer, usageLabel, sendButton])
        footer.orientation = .horizontal
        footer.spacing = 8

        // Permission bar + composer stack: a hidden bar collapses (no blank band).
        let bottom = NSStackView(views: [permissionBar, composer])
        bottom.orientation = .vertical
        bottom.alignment = .width
        bottom.spacing = 8
        bottom.detachesHiddenViews = true

        for v in [transcript, emptyState, bottom, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: transcript.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: transcript.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: transcript.widthAnchor, constant: -48),
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
        session.$usage.sink { [weak self] in self?.showUsage($0) }.store(in: &bag)
        session.$modes.combineLatest(session.$currentMode).sink { [weak self] modes, current in
            self?.fill(self?.modePopup, modes, current)
        }.store(in: &bag)
        session.$models.combineLatest(session.$currentModel).sink { [weak self] models, current in
            self?.fill(self?.modelPopup, models, current)
        }.store(in: &bag)
    }

    /// The empty chat's sea swims only while it's shown.
    private func showEmptyState(_ show: Bool) {
        guard emptyState.isHidden == show else { return }
        emptyState.isHidden = !show
        emptyState.rootView.swimming = show
    }

    private func showPhase(_ phase: ChatSession.Phase) {
        switch phase {
        case .starting:
            statusLabel.stringValue = session.isCatchingUp
                ? "Catching up with \(session.otherWriterName)…" : "Starting \(session.title)…"
            sendButton.title = "Send"; sendButton.isEnabled = false
        case .ready:
            statusLabel.stringValue = "↩ send · ⇧↩ new line"
            sendButton.title = "Send"; sendButton.isEnabled = true
            composer.setEnabled(true)
            if window?.firstResponder === window { composer.focus() }
        case .running:
            statusLabel.stringValue = "Working…  ⎋ to stop"
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

    private func showUsage(_ usage: ChatSession.Usage?) {
        guard let usage else { usageLabel.stringValue = ""; return }
        var parts = ["\(Self.compact(usage.used)) / \(Self.compact(usage.size)) ctx"]
        if let cost = usage.cost { parts.append(String(format: "$%.2f", cost)) }
        usageLabel.stringValue = parts.joined(separator: " · ")
        usageLabel.toolTip = "Context: \(usage.used) of \(usage.size) tokens"
    }

    private static func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%gM", (Double(n) / 1_000_000 * 10).rounded() / 10)
            : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
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
            + "sees the other’s replies. Wait for it to finish, or send anyway."
        alert.addButton(withTitle: "Wait")
        alert.addButton(withTitle: "Send Anyway")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            self.sendDespiteOtherApp = true
            self.composer.submitFromButton()
        }
        return false
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

/// An empty chat: a little sea of dolphins over what to do next.
private struct ChatEmptyState: View {
    let agent: String
    let folder: String
    var swimming = true

    var body: some View {
        VStack(spacing: 14) {
            DolphinPod(paused: !swimming)
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
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
