import AppKit
import Combine

/// A native chat surface for one session, hosted in the detail pane in place
/// of the terminal: transcript, permission prompt bar, composer, and a footer
/// with mode/model pickers, context/cost readout and Send/Stop.
@MainActor
final class ChatSessionView: NSView {
    let session: ChatSession

    private let transcript = ChatTranscriptView()
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

    /// Maps dropped/pasted file URLs to paths the sandbox can read (files outside
    /// the mounts are copied into the workspace's drops dir by the host).
    var resolveFileURLs: (([URL]) -> [URL])? {
        get { composer.resolveFileURLs }
        set { composer.resolveFileURLs = newValue }
    }

    init(session: ChatSession) {
        self.session = session
        super.init(frame: .zero)
        buildLayout()
        bind()
    }

    required init?(coder: NSCoder) { fatalError() }

    func focusComposer() { composer.focus() }

    func addAttachments(urls: [URL]) {
        composer.addAttachments(urls: urls)
        composer.focus()
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
        composer.commands = { [weak session] in session?.commands ?? [] }
        composer.fileRoot = session.workdir
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

        for v in [transcript, bottom, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
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
        session.$items.sink { [weak self] in self?.transcript.update($0) }.store(in: &bag)
        session.$permission.sink { [weak self] in self?.showPermission($0) }.store(in: &bag)
        session.$phase.sink { [weak self] in self?.showPhase($0) }.store(in: &bag)
        session.$usage.sink { [weak self] in self?.showUsage($0) }.store(in: &bag)
        session.$modes.combineLatest(session.$currentMode).sink { [weak self] modes, current in
            self?.fill(self?.modePopup, modes, current)
        }.store(in: &bag)
        session.$models.combineLatest(session.$currentModel).sink { [weak self] models, current in
            self?.fill(self?.modelPopup, models, current)
        }.store(in: &bag)
    }

    private func showPhase(_ phase: ChatSession.Phase) {
        switch phase {
        case .starting:
            statusLabel.stringValue = "Starting \(session.title)…"
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
            sendButton.title = "Send"; sendButton.isEnabled = false
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

    /// ⎋ stops a running turn (standard Cocoa cancel).
    override func cancelOperation(_ sender: Any?) {
        if case .running = session.phase { session.cancel() } else { super.cancelOperation(sender) }
    }

    @objc private func sendOrStop() {
        if case .running = session.phase { session.cancel() } else { composer.submitFromButton() }
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
