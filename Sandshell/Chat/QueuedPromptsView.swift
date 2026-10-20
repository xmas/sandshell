import AppKit

/// The messages waiting for the running turn, above the composer, in the
/// order they'll go: each a small card with its text, a "Queued" marker,
/// Edit (back into the composer) and Remove.
@MainActor
final class QueuedPromptsView: NSStackView {
    var onEdit: ((QueuedPrompt) -> Void)?
    var onRemove: ((QueuedPrompt) -> Void)?
    private(set) var prompts: [QueuedPrompt] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .width
        spacing = 4
        isHidden = true
        setAccessibilityIdentifier("chat-queued-list")
        // It takes the composer's width and never asks for less: the column
        // only *wants* its readable width (priority 100), so anything here
        // hugging harder would narrow the composer with it.
        setHuggingPriority(Self.slack, for: .horizontal)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Queued messages")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Below the chat column's pull to its readable width (100).
    static let slack = NSLayoutConstraint.Priority(50)

    /// The stack it's in drops it while it's hidden (and its constraints with
    /// it): each time it's back, it takes the stack's width again.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let superview else { return }
        widthAnchor.constraint(equalTo: superview.widthAnchor).isActive = true
    }

    func show(_ prompts: [QueuedPrompt]) {
        guard prompts != self.prompts else { return }
        self.prompts = prompts
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for prompt in prompts {
            let card = QueuedPromptCard(prompt)
            card.onEdit = { [weak self] in self?.onEdit?(prompt) }
            card.onRemove = { [weak self] in self?.onRemove?(prompt) }
            addArrangedSubview(card)
            // As wide as the composer under it.
            card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        isHidden = prompts.isEmpty
    }

    #if DEBUG
    var debugCards: [QueuedPromptCard] { arrangedSubviews.compactMap { $0 as? QueuedPromptCard } }
    #endif
}

/// One queued message: `🕘 Queued  the message…   Edit  ×`.
@MainActor
final class QueuedPromptCard: NSView {
    var onEdit: (() -> Void)?
    var onRemove: (() -> Void)?
    let prompt: QueuedPrompt
    let editButton = NSButton()
    let removeButton: NSButton

    init(_ prompt: QueuedPrompt) {
        self.prompt = prompt
        removeButton = NSButton.symbol("xmark", label: "Remove from queue", pointSize: TypeRole.meta.symbolPointSize,
                                       weight: .medium, target: nil, action: nil, id: "chat-queued-remove")
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("chat-queued")
        setAccessibilityLabel("Queued: \(prompt.text)")

        let clock = NSImageView(image: NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: TypeRole.meta.symbolPointSize, weight: .regular)) ?? NSImage())
        clock.contentTintColor = .secondaryLabelColor
        let marker = NSTextField(labelWithString: "Queued")
        marker.font = .role(.meta)
        marker.textColor = .secondaryLabelColor
        let files = prompt.attachments.isEmpty ? "" : "  " + prompt.attachments.map(\.displayName).joined(separator: ", ")
        let text = NSTextField(labelWithString: prompt.text.replacing("\n", with: " ") + files)
        text.font = .role(.body)
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.toolTip = prompt.text
        text.setContentCompressionResistancePriority(QueuedPromptsView.slack - 10, for: .horizontal)
        text.setContentHuggingPriority(QueuedPromptsView.slack - 10, for: .horizontal)

        editButton.isBordered = false
        editButton.attributedTitle = NSAttributedString(string: "Edit", attributes: [
            .font: NSFont.role(.meta), .foregroundColor: NSColor.controlAccentColor])
        editButton.toolTip = "Edit this message (it leaves the queue)"
        editButton.setAccessibilityIdentifier("chat-queued-edit")
        editButton.target = self
        editButton.action = #selector(edit)
        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.toolTip = "Remove from queue"

        let row = NSStackView(views: [clock, marker, text, editButton, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.setHuggingPriority(QueuedPromptsView.slack, for: .horizontal)
        row.setCustomSpacing(10, after: marker)
        row.setCustomSpacing(10, after: text)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Like the pill below it, lighter: a fill and a 1 pt border.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.composerCardFill.cgColor
            layer?.borderColor = NSColor.composerBorder.cgColor
        }
    }

    @objc private func edit() { onEdit?() }
    @objc private func remove() { onRemove?() }
}
