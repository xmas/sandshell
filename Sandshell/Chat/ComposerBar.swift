import AppKit

// MARK: - What the composer shows (pure)

/// The composer's readout, `$0.47 · 38%`, and the choosers' titles.
enum ClaudeReadout {
    /// The conversation's cost: its transcript priced (that survives
    /// `--resume`), else Claude Code's figure for this run.
    static func cost(conversation: ClaudeUsageTotals?, run: Double?) -> Double? {
        if let conversation, conversation.messages > 0 { return conversation.costUSD }
        return run
    }

    @MainActor static func cost(of status: ClaudeSessionStatus?) -> Double? {
        cost(conversation: status?.sessionID.flatMap { ClaudeUsageStore.shared.sessionTotals[$0] },
             run: status?.cost?.totalCostUSD)
    }

    /// How full the context window is, in whole percent (rounded down, like the strip's).
    static func percent(used: Int, size: Int) -> Int? {
        guard size > 0 else { return nil }
        return Int((Double(max(used, 0)) / Double(size) * 100).rounded(.down))
    }

    /// `$0.47 · 38%`; either half alone; empty with neither.
    static func text(cost: Double?, percent: Int?) -> String {
        [cost.map { ClaudeStatsFormat.usd($0) }, percent.map { $0.formatted(.percent) }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The model chooser's title: the model's name, or "Default model".
    static func modelTitle(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "Default model" }
        return ClaudeModelChoice.title(forID: ClaudePriceBook.normalize(id))
    }

    /// The effort chooser's title: "High", or "Default effort".
    static func effortTitle(_ level: String?) -> String {
        guard let level, !level.isEmpty else { return "Default effort" }
        return ClaudeEffortChoice.title(forID: level)
    }
}

/// Which of the composer's controls a chat shows. Pieces that don't apply
/// stay out: Claude's model/effort choosers only for Claude, the agent's own
/// model list for the others, MCP only through Sandshell's adapter wrapper,
/// a readout once there's something to read.
struct ComposerPieces: Equatable {
    var claudeChoosers = false
    var agentModel = false
    var mode = false
    var mcp = false
    var readout = false
    /// The readout opens Session details (Claude's status); otherwise it's text.
    var readoutOpensDetails = false

    static func `for`(agent: AgentKind, hasModels: Bool, hasModes: Bool, hasExtras: Bool, hasUsage: Bool) -> ComposerPieces {
        let claude = agent == .claude
        return ComposerPieces(claudeChoosers: claude, agentModel: !claude && hasModels, mode: hasModes,
                              mcp: hasExtras, readout: claude || hasUsage, readoutOpensDetails: claude)
    }
}

extension ChatSession {
    /// The chat's state in Claude Code's status-line terms (Session details).
    var claudeStatus: ClaudeSessionStatus {
        var status = ClaudeSessionStatus()
        status.sessionID = sessionID
        if let model = liveModel ?? launchModel {
            status.model = .init(id: model, displayName: ClaudeReadout.modelTitle(model))
        }
        if let effort = launchEffort { status.effort = .init(level: effort) }
        if let usage, usage.size > 0 {
            status.contextWindow = .init(contextWindowSize: usage.size,
                                         usedPercentage: Double(usage.used) / Double(usage.size) * 100)
        }
        if let cost = usage?.cost { status.cost = .init(totalCostUSD: cost) }
        return status
    }
}

// MARK: - Colours

extension NSColor {
    /// The composer's ink: the Send button's fill, the Stop ring (#1F1B18; near-white in dark).
    static let composerInk = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .hex("#EDE7E1") : .hex("#1F1B18")
    }
    /// What's drawn on the ink (the Send arrow).
    static let composerPaper = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .hex("#1F1B18") : .white
    }
    /// The pill's fill: white; a lift off the background in dark.
    static let composerFill = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.07) : .white
    }
    /// The pill's 1 pt border (#DCD3C9).
    static let composerBorder = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.16) : .hex("#DCD3C9")
    }
}

// MARK: - Send / Stop

/// The round button inside the composer: Send (a filled circle, arrow up)
/// while idle; Stop (a 2 pt ring around a filled square) while a turn runs —
/// the only chat-turn stop there is; Reconnect after the agent went away.
final class ComposerSendButton: NSButton {
    enum Mode: Equatable { case send, stop, reconnect }

    var mode: Mode = .send {
        didSet {
            guard mode != oldValue else { return }
            needsDisplay = true
            describe()
        }
    }

    static let diameter: CGFloat = 24

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        focusRingType = .none
        refusesFirstResponder = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("chat-send-stop")
        describe()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.diameter, height: Self.diameter) }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    private func describe() {
        let (label, tip) = switch mode {
        case .send: ("Send", "Send (↩)")
        case .stop: ("Stop", "Stop this turn (⎋)")
        case .reconnect: ("Reconnect", "Reconnect to the agent")
        }
        setAccessibilityLabel(label)
        toolTip = tip
    }

    override func draw(_ dirtyRect: NSRect) {
        let ink = NSColor.composerInk.withAlphaComponent(isEnabled ? (isHighlighted ? 0.7 : 1) : 0.3)
        let circle = bounds.insetBy(dx: (bounds.width - Self.diameter) / 2, dy: (bounds.height - Self.diameter) / 2)
        switch mode {
        case .stop:
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ink.setStroke()
            ring.stroke()
            let side: CGFloat = 9
            let square = NSRect(x: circle.midX - side / 2, y: circle.midY - side / 2, width: side, height: side)
            ink.setFill()
            NSBezierPath(roundedRect: square, xRadius: 1.5, yRadius: 1.5).fill()
        case .send, .reconnect:
            ink.setFill()
            NSBezierPath(ovalIn: circle).fill()
            let name = mode == .send ? "arrow.up" : "arrow.clockwise"
            let config = NSImage.SymbolConfiguration(pointSize: TypeRole.meta.symbolPointSize, weight: .bold)
                .applying(.init(paletteColors: [.composerPaper]))
            guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            let size = glyph.size
            glyph.draw(in: NSRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2,
                                  width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.6,
                       respectFlipped: true, hints: nil)
        }
    }
}

// MARK: - Plain text controls

/// One of the controls under the composer: plain, no fill until the pointer
/// is over it (a click anywhere in it goes to its control).
final class HoverChip: NSView {
    let content: NSView
    /// Highlights on hover (a plain readout doesn't).
    var isInteractive = true { didSet { if !isInteractive { hovering = false } } }
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(_ content: NSView, inset: CGFloat = 6) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 6
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovering ? NSColor.labelColor.withAlphaComponent(0.06).cgColor : nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = isInteractive }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func viewDidHide() { super.viewDidHide(); hovering = false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? content : hit
    }
}

/// The plain text controls under the composer's pill. Left: `+` (attach a
/// file, or mention one with `@`) and MCP with its server count. Right: the
/// model, the effort, the approval mode, and the readout that opens Session
/// details. In a narrow pane the least needed give way first.
@MainActor
final class ComposerBar: NSView {
    let attachButton = NSButton()
    let mcpButton = NSButton()
    let statusLabel = NSTextField(labelWithString: "")
    let claude = ClaudeChoosers(font: .role(.body))
    let modelPopup = ChoicePopUp(tip: "Model", font: .role(.body))
    let modePopup = ChoicePopUp(tip: "Approval mode", font: .role(.body))
    let readoutButton = NSButton()

    private let stack = NSStackView()
    private lazy var attachChip = HoverChip(attachButton)
    private lazy var mcpChip = HoverChip(mcpButton)
    private lazy var claudeModelChip = HoverChip(claude.modelButton, inset: 2)
    private lazy var effortChip = HoverChip(claude.effortButton, inset: 2)
    private lazy var modelChip = HoverChip(modelPopup, inset: 2)
    private lazy var modeChip = HoverChip(modePopup, inset: 2)
    private lazy var readoutChip = HoverChip(readoutButton)

    var pieces = ComposerPieces() { didSet { if pieces != oldValue { drawReadout(); needsLayout = true; fit() } } }
    /// The readout's text (`$0.47 · 38%`); in a narrow pane only its ⓘ shows.
    var readoutText = "" { didSet { if readoutText != oldValue { drawReadout(); needsLayout = true } } }
    /// How many of the controls a narrow pane has shed (see `fit`).
    private var shed = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let symbol = NSImage.SymbolConfiguration.role(.body)
        attachButton.isBordered = false
        attachButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Attach")?.withSymbolConfiguration(symbol)
        attachButton.imagePosition = .imageOnly
        attachButton.contentTintColor = .secondaryLabelColor
        attachButton.toolTip = "Attach files, or mention a workspace file (@)"
        attachButton.setAccessibilityIdentifier("chat-attach")

        mcpButton.isBordered = false
        mcpButton.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted",
                                  accessibilityDescription: "MCP servers")?.withSymbolConfiguration(symbol)
        mcpButton.imagePosition = .imageLeading
        mcpButton.imageHugsTitle = true
        mcpButton.contentTintColor = .secondaryLabelColor
        mcpButton.toolTip = "MCP servers in this session"
        mcpButton.setAccessibilityIdentifier("chat-mcp")
        showMCP(count: nil, failing: [])

        statusLabel.font = .role(.meta)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        statusLabel.setAccessibilityIdentifier("chat-status")

        claude.modelButton.setAccessibilityIdentifier("chat-model")
        claude.effortButton.setAccessibilityIdentifier("chat-effort")
        modelPopup.setAccessibilityIdentifier("chat-model")
        modePopup.setAccessibilityIdentifier("chat-mode")
        modePopup.toolTip = "Approval mode: what the agent may do without asking"

        readoutButton.isBordered = false
        readoutButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Session details")?
            .withSymbolConfiguration(.role(.code))
        readoutButton.imagePosition = .imageLeading
        readoutButton.imageHugsTitle = true
        readoutButton.contentTintColor = .secondaryLabelColor
        readoutButton.setAccessibilityIdentifier("chat-details")
        drawReadout()

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([attachChip, mcpChip, statusLabel, claudeModelChip, modelChip, effortChip, modeChip, readoutChip],
                       in: .leading)
        stack.setCustomSpacing(8, after: mcpChip)
        stack.setCustomSpacing(8, after: statusLabel)
        addSubview(stack)
        // Controls that don't fit clip (and `fit` sheds them) rather than
        // widen the pane.
        let trailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        trailing.priority = .init(249)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailing,
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        clipsToBounds = true
        fit()
    }

    /// MCP's server count (nil: not known yet), red with the ones failing named.
    func showMCP(count: Int?, failing: [String]) {
        let color: NSColor = failing.isEmpty ? .secondaryLabelColor : .systemRed
        mcpButton.attributedTitle = NSAttributedString(
            string: count.map { "\($0)" } ?? "",
            attributes: [.font: NSFont.role(.body), .foregroundColor: color])
        mcpButton.contentTintColor = color
        mcpButton.toolTip = failing.isEmpty ? "MCP servers in this session"
            : "\(failing.formatted()) \(failing.count == 1 ? "isn’t" : "aren’t") working"
        mcpButton.setAccessibilityLabel(count.map { "MCP servers: \($0)" } ?? "MCP servers")
    }

    private func drawReadout() {
        let text = shed >= Self.compactReadoutLevel ? "" : readoutText
        readoutButton.attributedTitle = NSAttributedString(
            string: text, attributes: [.font: NSFont.role(.code), .foregroundColor: NSColor.secondaryLabelColor])
        readoutButton.imagePosition = pieces.readoutOpensDetails ? (text.isEmpty ? .imageOnly : .imageLeading) : .noImage
        readoutButton.setAccessibilityLabel(pieces.readoutOpensDetails
                                            ? "Session details" + (readoutText.isEmpty ? "" : ": \(readoutText)") : readoutText)
    }

    // MARK: Fitting

    /// What gives way, in order, when the controls don't fit: the effort, the
    /// readout's text (its ⓘ stays), the approval mode, the model, MCP.
    private static let compactReadoutLevel = 2
    private static let maxShed = 5

    override func layout() {
        super.layout()
        fit()
    }

    private func fit() {
        var level = 0
        apply(level)
        while level < Self.maxShed, requiredWidth > bounds.width {
            level += 1
            apply(level)
        }
    }

    private func apply(_ level: Int) {
        let readoutWasCompact = shed >= Self.compactReadoutLevel
        shed = level
        if readoutWasCompact != (shed >= Self.compactReadoutLevel) { drawReadout() }
        func show(_ chip: NSView, _ on: Bool) { if chip.isHidden == on { chip.isHidden = !on } }
        show(effortChip, pieces.claudeChoosers && level < 1)
        show(modeChip, pieces.mode && !modePopup.choices.isEmpty && level < 3)
        show(claudeModelChip, pieces.claudeChoosers && level < 4)
        show(modelChip, pieces.agentModel && !modelPopup.choices.isEmpty && level < 4)
        show(mcpChip, pieces.mcp && level < 5)
        show(readoutChip, pieces.readout && (pieces.readoutOpensDetails || !readoutText.isEmpty))
        readoutChip.isInteractive = pieces.readoutOpensDetails
        // The approval mode stands a little apart from the model and effort.
        let beforeMode = [effortChip, claudeModelChip, modelChip].first { !$0.isHidden }
        for chip in [effortChip, claudeModelChip, modelChip] { stack.setCustomSpacing(chip === beforeMode ? 10 : 2, after: chip) }
    }

    /// The controls' width (the status text gives way to them).
    private var requiredWidth: CGFloat {
        let shown = stack.arrangedSubviews.filter { !$0.isHidden && $0 !== statusLabel }
        return shown.reduce(0) { $0 + $1.fittingSize.width } + CGFloat(max(shown.count, 1)) * 10
    }

    #if DEBUG
    /// The controls showing, by accessibility id.
    var debugShown: [String] {
        stack.arrangedSubviews.compactMap { v in
            guard !v.isHidden, let chip = v as? HoverChip else { return nil }
            return chip.content.accessibilityIdentifier()
        }
    }
    /// Their frames, in the bar.
    var debugShownFrames: [NSRect] {
        stack.arrangedSubviews.filter { !$0.isHidden && $0 is HoverChip }.map { $0.convert($0.bounds, to: self) }
    }
    #endif
}
