import AppKit

// MARK: - What the composer shows (pure)

/// The composer's readout, `38% context · $0.47` (beside its gauge), and the choosers' titles.
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

    /// `38% context · $0.47`; either half alone; empty with neither.
    static func text(cost: Double?, percent: Int?) -> String {
        [percent.map { "\($0.formatted(.percent)) context" }, cost.map { ClaudeStatsFormat.usd($0) }]
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
    /// A card above the pill (a queued message, the pinned plan): the pill's
    /// fill at 60 % — of its own alpha in dark (`withAlphaComponent` would
    /// replace the 7 % with 60 %, a grey slab).
    static let composerCardFill = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.07 * 0.6)
            : NSColor(white: 1, alpha: 0.6)
    }
    /// The Stop button: a quiet secondary-label grey, not the Send button's
    /// near-black (opaque, so its ring can be a fainter share of it).
    static let composerStopInk = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .hex("#A39D97") : .hex("#8A847E")
    }
    /// The pill's 1 pt border (#DCD3C9).
    static let composerBorder = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.16) : .hex("#DCD3C9")
    }
}

// MARK: - Send / Stop

/// The round button inside the composer: Send (a filled circle, arrow up)
/// while idle; Stop (a square in a faint ring, a short bright arc orbiting it
/// while the turn works) while a turn runs — the only chat-turn stop there
/// is; Reconnect after the agent went away.
final class ComposerSendButton: NSButton {
    enum Mode: Equatable { case send, stop, reconnect }

    var mode: Mode = .send {
        didSet {
            guard mode != oldValue else { return }
            needsDisplay = true
            describe()
            updateOrbit()
        }
    }

    /// The Stop ring's bright arc, turned about the button's centre.
    private let orbit = CAShapeLayer()
    /// One trip round, in seconds.
    static let orbitPeriod: CFTimeInterval = 1.2
    private static let orbitKey = "orbit"
    private var reduceMotionObserver: NSObjectProtocol?

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
        wantsLayer = true
        orbit.fillColor = nil
        orbit.lineWidth = Self.ringWidth
        orbit.lineCap = .round
        orbit.isHidden = true
        layer?.addSublayer(orbit)
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateOrbit() } }
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let reduceMotionObserver { NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver) }
    }

    private static let ringWidth: CGFloat = 2

    /// The arc travels round the ring (unless Reduce Motion is on: the ring
    /// stands still). Shown only in Stop.
    private func updateOrbit() {
        let animate = mode == .stop && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if orbit.isHidden == animate { needsDisplay = true }   // the ring under it fades or firms
        orbit.isHidden = !animate
        guard animate else { return orbit.removeAnimation(forKey: Self.orbitKey) }
        layoutOrbit()
        guard orbit.animation(forKey: Self.orbitKey) == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi   // clockwise
        spin.duration = Self.orbitPeriod
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.isRemovedOnCompletion = false
        orbit.add(spin, forKey: Self.orbitKey)
    }

    /// A quarter of the ring, starting at the top, in a layer centred on the button.
    private func layoutOrbit() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = Self.diameter
        orbit.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        orbit.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = side / 2 - Self.ringWidth / 2   // on the drawn ring's centre line
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: side / 2, y: side / 2), radius: radius,
                    startAngle: .pi / 2, endAngle: 0, clockwise: true)
        orbit.path = path
        effectiveAppearance.performAsCurrentDrawingAppearance {
            orbit.strokeColor = NSColor.composerStopInk.cgColor
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Off screen it stops; back in a window it picks up again.
        orbit.removeAnimation(forKey: Self.orbitKey)
        updateOrbit()
    }

    override func layout() {
        super.layout()
        if !orbit.isHidden { layoutOrbit() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !orbit.isHidden { layoutOrbit() }
    }

    #if DEBUG
    /// The arc is going round.
    var debugOrbiting: Bool { !orbit.isHidden && orbit.animation(forKey: Self.orbitKey) != nil }
    #endif

    /// Send's fill and its arrow (nil: the composer's ink).
    var accent: (fill: NSColor, ink: NSColor)? { didSet { needsDisplay = true } }

    /// The folder's sidebar color, with an arrow that reads on it. On a dark
    /// chat a dark sidebar color is lifted, or the button sinks into the pill.
    static func accent(sidebarHex: String, dark: Bool) -> (fill: NSColor, ink: NSColor) {
        let color = NSColor.hex(sidebarHex)
        let fill = dark && color.perceivedIsDark ? color.blended(withFraction: 0.3, of: .white) ?? color : color
        return (fill, fill.prefersLightInk ? .white : .black)
    }

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
        let alpha: CGFloat = isEnabled ? (isHighlighted ? 0.7 : 1) : 0.3
        let ink = NSColor.composerInk.withAlphaComponent(alpha)
        let circle = bounds.insetBy(dx: (bounds.width - Self.diameter) / 2, dy: (bounds.height - Self.diameter) / 2)
        switch mode {
        case .stop:
            // A faint ring the arc orbits (with Reduce Motion, a steady one).
            let stopInk = NSColor.composerStopInk
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
            ring.lineWidth = Self.ringWidth
            stopInk.withAlphaComponent(alpha * (orbit.isHidden ? 1 : 0.25)).setStroke()
            ring.stroke()
            let side: CGFloat = 9
            let square = NSRect(x: circle.midX - side / 2, y: circle.midY - side / 2, width: side, height: side)
            stopInk.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: square, xRadius: 1.5, yRadius: 1.5).fill()
        case .send, .reconnect:
            (accent.map { $0.fill.withAlphaComponent(alpha) } ?? ink).setFill()
            NSBezierPath(ovalIn: circle).fill()
            let name = mode == .send ? "arrow.up" : "arrow.clockwise"
            let config = NSImage.SymbolConfiguration(pointSize: TypeRole.meta.symbolPointSize, weight: .bold)
                .applying(.init(paletteColors: [accent?.ink ?? .composerPaper]))
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
    /// `+`: attach, mention a file, and the chat's MCP servers.
    let attachButton = NSButton()
    /// MCP, on the bar only while a server isn't working (else it's in `+`).
    let mcpButton = NSButton()
    let statusLabel = NSTextField(labelWithString: "")
    /// The one chooser: "Opus 5.5 · High" — model, effort and approvals in one menu.
    let chooserButton = NSButton()
    /// Where the choices live (and their titles): the chooser's menu is built from them.
    let claude = ClaudeChoosers(font: .role(.body))
    let modelPopup = ChoicePopUp(tip: "Model", font: .role(.body))
    let modePopup = ChoicePopUp(tip: "Approval mode", font: .role(.body))
    /// How full the context window is, as a ring; hover for it and the cost,
    /// click for Session details (Claude).
    let readoutButton = NSButton()

    private let stack = NSStackView()
    private lazy var attachChip = HoverChip(attachButton)
    private lazy var mcpChip = HoverChip(mcpButton)
    private lazy var chooserChip = HoverChip(chooserButton, inset: 2)
    private lazy var readoutChip = HoverChip(readoutButton)
    private var mcpFailing = false

    var pieces = ComposerPieces() { didSet { if pieces != oldValue { choicesChanged() } } }
    /// The readout's text (`38% context · $0.47`): the ring's tooltip and what VoiceOver says.
    var readoutText = "" { didSet { if readoutText != oldValue { drawReadout() } } }
    /// More for the ring's tooltip (the token counts; "Session details").
    var readoutDetail = "" { didSet { if readoutDetail != oldValue { drawReadout() } } }
    /// The context window's fill (0…1; nil: not known yet).
    var contextFraction: Double? { didSet { if contextFraction != oldValue { drawReadout() } } }
    /// A narrow pane: the chooser says just the model.
    private var compact = false

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
        attachButton.toolTip = "Attach files, mention a workspace file (@), MCP servers"
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

        chooserButton.isBordered = false
        chooserButton.imagePosition = .imageTrailing
        chooserButton.imageHugsTitle = true
        chooserButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.role(.meta, weight: .semibold))
        chooserButton.contentTintColor = .secondaryLabelColor
        chooserButton.target = self
        chooserButton.action = #selector(chooserClicked)
        chooserButton.setAccessibilityIdentifier("chat-model")
        chooserButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        claude.modelButton.setAccessibilityIdentifier("chat-model-choices")
        claude.effortButton.setAccessibilityIdentifier("chat-effort")
        modelPopup.setAccessibilityIdentifier("chat-model-choices")
        modePopup.setAccessibilityIdentifier("chat-mode")

        readoutButton.isBordered = false
        readoutButton.imagePosition = .imageOnly
        readoutButton.setAccessibilityIdentifier("chat-details")
        drawReadout()

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([attachChip, mcpChip, statusLabel, chooserChip, readoutChip], in: .leading)
        stack.setCustomSpacing(8, after: mcpChip)
        stack.setCustomSpacing(8, after: statusLabel)
        stack.setCustomSpacing(6, after: chooserChip)
        addSubview(stack)
        // Controls that don't fit clip (and `fit` shortens the chooser) rather
        // than widen the pane.
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
        choicesChanged()
    }

    /// MCP's server count (nil: not known yet), red with the ones failing
    /// named. On the bar only while one fails; else it's in `+`.
    private(set) var mcpCount: Int?
    func showMCP(count: Int?, failing: [String]) {
        mcpCount = count
        mcpFailing = !failing.isEmpty
        let color: NSColor = failing.isEmpty ? .secondaryLabelColor : .systemRed
        mcpButton.attributedTitle = NSAttributedString(
            string: count.map { "\($0)" } ?? "",
            attributes: [.font: NSFont.role(.body), .foregroundColor: color])
        mcpButton.contentTintColor = color
        mcpButton.toolTip = failing.isEmpty ? "MCP servers in this session"
            : "\(failing.formatted()) \(failing.count == 1 ? "isn’t" : "aren’t") working"
        mcpButton.setAccessibilityLabel(count.map { "MCP servers: \($0)" } ?? "MCP servers")
        apply()
    }

    // MARK: The chooser

    /// The chooser's title: the model, and the effort (Claude) or the
    /// approval mode (other agents) — just the model in a narrow pane.
    var chooserTitle: String {
        var parts: [String] = []
        if pieces.claudeChoosers {
            parts = [claude.modelTitle, claude.effortTitle]
        } else {
            if pieces.agentModel, !modelPopup.choices.isEmpty { parts.append(modelTitle(of: modelPopup)) }
            if pieces.mode, !modePopup.choices.isEmpty { parts.append(modelTitle(of: modePopup)) }
        }
        parts = parts.filter { !$0.isEmpty }
        return (compact ? Array(parts.prefix(1)) : parts).joined(separator: " · ")
    }

    private func modelTitle(of popup: ChoicePopUp) -> String {
        popup.item(at: 0)?.attributedTitle?.string ?? popup.item(at: 0)?.title ?? ""
    }

    /// A model, effort or mode was shown (or the pieces changed): the chooser's title follows.
    func choicesChanged() {
        let title = chooserTitle
        chooserButton.attributedTitle = NSAttributedString(string: title + " ", attributes: [
            .font: NSFont.role(.body), .foregroundColor: NSColor.labelColor])
        let mode = pieces.mode && !modePopup.choices.isEmpty ? modelTitle(of: modePopup) : nil
        chooserButton.toolTip = [pieces.claudeChoosers ? "Model: \(claude.modelTitle)" : nil,
                                 pieces.claudeChoosers ? "Effort: \(claude.effortTitle)" : nil,
                                 mode.map { "Approvals: \($0)" }].compactMap { $0 }.joined(separator: "\n")
        chooserButton.setAccessibilityLabel("Model and options: \(title)")
        apply()
        needsLayout = true
    }

    /// Model, effort and approvals in one menu, each its own section.
    func chooserMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func section(_ title: String, _ items: [NSMenuItem]) {
            guard !items.isEmpty else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: title))
            items.forEach(menu.addItem)
        }
        if pieces.claudeChoosers {
            section("Model", claude.modelMenuItems())
            section("Effort", claude.effortMenuItems())
        } else if pieces.agentModel {
            section("Model", modelPopup.menuItems())
        }
        if pieces.mode { section("Approvals", modePopup.menuItems()) }
        return menu
    }

    @objc private func chooserClicked() {
        chooserMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: chooserButton.bounds.height + 4), in: chooserButton)
    }

    // MARK: The ring

    private func drawReadout() {
        let fraction = contextFraction
        if let fraction {
            readoutButton.image = ContextRing.image(fraction: fraction)
            readoutButton.imagePosition = .imageOnly
            readoutButton.attributedTitle = NSAttributedString(string: "")
        } else if pieces.readoutOpensDetails {
            readoutButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Session details")?
                .withSymbolConfiguration(.role(.code))
            readoutButton.imagePosition = .imageOnly
            readoutButton.attributedTitle = NSAttributedString(string: "")
        } else {
            // Another agent's cost with no window to fill: the text itself.
            readoutButton.image = nil
            readoutButton.imagePosition = .noImage
            readoutButton.attributedTitle = NSAttributedString(
                string: readoutText, attributes: [.font: NSFont.role(.code), .foregroundColor: NSColor.secondaryLabelColor])
        }
        readoutButton.contentTintColor = .secondaryLabelColor
        let tip = [readoutText, readoutDetail].filter { !$0.isEmpty }.joined(separator: "\n")
        readoutButton.toolTip = tip.isEmpty ? nil : tip
        readoutButton.setAccessibilityLabel(pieces.readoutOpensDetails
                                            ? "Session details" + (readoutText.isEmpty ? "" : ": \(readoutText)") : readoutText)
        apply()
    }

    // MARK: Fitting

    override func layout() {
        super.layout()
        fit()
    }

    /// Too narrow for the whole title: the chooser says just the model.
    private func fit() {
        let wasCompact = compact
        compact = false
        if requiredWidth(compact: false) > bounds.width { compact = true }
        if compact != wasCompact { choicesChanged() }
    }

    private func apply() {
        func show(_ chip: NSView, _ on: Bool) { if chip.isHidden == on { chip.isHidden = !on } }
        show(mcpChip, pieces.mcp && mcpFailing)
        show(chooserChip, !chooserTitle.isEmpty)
        show(readoutChip, pieces.readout && (pieces.readoutOpensDetails || contextFraction != nil || !readoutText.isEmpty))
        readoutChip.isInteractive = pieces.readoutOpensDetails
    }

    /// The controls' width (the status text gives way to them).
    private func requiredWidth(compact: Bool) -> CGFloat {
        let shown = stack.arrangedSubviews.filter { !$0.isHidden && $0 !== statusLabel && $0 !== chooserChip }
        let title = NSAttributedString(string: chooserTitle + " ", attributes: [.font: NSFont.role(.body)])
        let chooser = chooserChip.isHidden ? 0 : ceil(title.size().width) + 24
        return shown.reduce(chooser) { $0 + $1.fittingSize.width } + CGFloat(max(shown.count + 1, 1)) * 10
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
    /// The chooser's menu: its section headers and items ("" for a separator).
    var debugChooserMenu: [String] { chooserMenu().items.map { $0.isSeparatorItem ? "" : $0.title } }
    #endif
}

/// The context window's fill as a ring: green, then orange past 70 %, red
/// past 90 % (where auto-compact comes).
enum ContextRing {
    static let side: CGFloat = 14

    static func color(_ fraction: Double) -> NSColor {
        fraction >= 0.9 ? .systemRed : fraction >= 0.7 ? .systemOrange : .systemGreen
    }

    static func image(fraction: Double) -> NSImage {
        let f = min(max(fraction, 0), 1)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let lw: CGFloat = 2.2
            let ring = rect.insetBy(dx: lw / 2 + 0.5, dy: lw / 2 + 0.5)
            let track = NSBezierPath(ovalIn: ring)
            track.lineWidth = lw
            NSColor.secondaryLabelColor.withAlphaComponent(0.25).setStroke()
            track.stroke()
            guard f > 0 else { return true }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: ring.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * f, clockwise: true)
            arc.lineWidth = lw
            arc.lineCapStyle = .round
            color(f).setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "\(Int(f * 100))% of the context window"
        return image
    }
}
