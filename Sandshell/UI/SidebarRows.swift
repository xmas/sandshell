import AppKit
import QuartzCore

// The sidebar's rows and chrome pieces (SidebarOutlineController.swift lists
// them). Geometry: rows sit 6 pt in from the sidebar's edges with a 7 pt
// corner; a row pads 7 × 8; child rows (forks, the subagents row, subagents)
// hang from a 1 pt rail 17 pt in.

enum SidebarMetrics {
    /// The rows' inset from the sidebar's edges.
    static let rowInset: CGFloat = 6
    /// A row's own horizontal padding.
    static let rowPadding: CGFloat = 8
    /// Where the rail runs (from the sidebar's leading edge).
    static let railX: CGFloat = rowInset + 17
    /// How far a child row's fill starts in from a top-level one's: margin + rail + padding.
    static let childIndent: CGFloat = 17 + 1 + 7
    static let badgeSide: CGFloat = 20
    static let badgeGap: CGFloat = 9
    static let summaryRowHeight: CGFloat = 24
    static let childRowHeight: CGFloat = 34
}

// MARK: - Row view (fills, rail)

/// Draws a row's fill — selected, hovered, or open in another pane — and,
/// for child rows, the rail. Background fills only: no outline, no bar.
final class SidebarRowView: NSTableRowView {
    var palette: SidebarPalette { didSet { needsDisplay = true } }
    /// Extra leading inset of the fill (a child row's).
    var indent: CGFloat = 0
    var drawsRail = false
    /// The session shows in another pane of this window (it has more than one).
    var isOpenElsewhere = false { didSet { if oldValue != isOpenElsewhere { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(palette: SidebarPalette) {
        self.palette = palette
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func drawSelection(in dirtyRect: NSRect) {}

    // Hover is read live from the pointer: state kept from enter/exit goes
    // stale across the frequent in-place row updates.
    private var isHovered: Bool {
        guard let window, window.isKeyWindow else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    var fillRect: NSRect {
        let x = SidebarMetrics.rowInset + indent
        return NSRect(x: x, y: 0.5, width: max(0, bounds.width - x - SidebarMetrics.rowInset), height: bounds.height - 1)
    }

    /// The fill drawn now (nil: none) — what a self-test reads.
    var currentFill: NSColor? {
        if isSelected { return palette.selectedFill }
        if isHovered { return palette.hoverFill }
        if isOpenElsewhere { return palette.otherPaneFill }
        return nil
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if drawsRail {
            palette.rail.setFill()
            NSRect(x: SidebarMetrics.railX, y: 0, width: 1, height: bounds.height).fill()
        }
        guard let fill = currentFill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 7, yRadius: 7).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { needsDisplay = true }
}

// MARK: - Status glyphs

/// The 7 pt status dot (at 45 % when dimmed).
final class StatusDotView: NSView {
    var color: NSColor = .gray { didSet { needsDisplay = true } }
    var dimmed = false { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }
    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(dimmed ? 0.45 : 1).setFill()
        let side = min(bounds.width, bounds.height, 7)
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)).fill()
    }
}

/// The 10 pt working spinner: a faint ring with a turning arc — the only
/// animated thing in a row. Still under Reduce Motion.
final class StatusSpinnerView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    var color: NSColor = .sessionWorking { didSet { applyColor() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for l in [track, arc] {
            l.fillColor = nil
            l.lineWidth = 1.5
            layer?.addSublayer(l)
        }
        arc.lineCap = .round
        applyColor()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }

    private func applyColor() {
        track.strokeColor = color.withAlphaComponent(0.3).cgColor
        arc.strokeColor = color.cgColor
    }

    override func layout() {
        super.layout()
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        track.frame = bounds
        arc.frame = bounds
        track.path = CGPath(ellipseIn: rect, transform: nil)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: rect.width / 2,
                    startAngle: .pi / 2, endAngle: 0, clockwise: true)
        arc.path = path
        restart()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restart()
    }
    override var isHidden: Bool { didSet { restart() } }

    /// Whether it's turning now (self-tests).
    var isAnimating: Bool { arc.animation(forKey: "spin") != nil }

    private func restart() {
        guard window != nil, !isHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            arc.removeAnimation(forKey: "spin")
            return
        }
        guard arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * CGFloat.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }
}

// MARK: - Labels

extension NSTextField {
    /// A one-line label that ellipsizes instead of wrapping — every row text is one.
    static func sidebarLabel(_ font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.usesSingleLineMode = true
        label.cell?.wraps = false
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

extension NSFont {
    /// The role's font, italic (the row's first instruction).
    static func italic(_ role: TypeRole) -> NSFont {
        NSFontManager.shared.convert(.role(role), toHaveTrait: .italicFontMask)
    }
}

// MARK: - Session row

final class SessionCellView: NSTableCellView {
    var sessionID: UUID?
    private weak var owner: SidebarListController?
    private let badge = AgentBadgeView(side: SidebarMetrics.badgeSide, fontSize: 9, radius: 6)
    private let forkGlyph = NSImageView()
    private let nameLabel = NSTextField.sidebarLabel(.role(.body))
    private let timeLabel = NSTextField.sidebarLabel(.role(.code))
    private let closeButton = NSButton()
    private let glyphSlot = NSView()
    private var glyphWidth: NSLayoutConstraint!
    private let dot = StatusDotView()
    private let spinner = StatusSpinnerView()
    private let wordLabel = NSTextField.sidebarLabel(.role(.meta, weight: .semibold))
    private let detailLabel = NSTextField.sidebarLabel(.role(.meta))
    private let instructionLabel = NSTextField.sidebarLabel(.italic(.meta))
    private var leading: NSLayoutConstraint!
    private var tracking: NSTrackingArea?
    private var palette: SidebarPalette
    private(set) var status = SessionRowStatus(state: .idle, word: "Not running", detail: nil)
    private var selected = false
    private var live = false
    private var agentName = ""

    init(owner: SidebarListController, palette: SidebarPalette) {
        self.owner = owner
        self.palette = palette
        super.init(frame: .zero)

        forkGlyph.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Fork")
        forkGlyph.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        forkGlyph.setContentHuggingPriority(.required, for: .horizontal)
        forkGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        forkGlyph.isHidden = true

        timeLabel.alignment = .right
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The name takes the room; the time sits at the right edge.
        nameLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        let titleRow = NSStackView(views: [forkGlyph, nameLabel, timeLabel])
        titleRow.orientation = .horizontal
        titleRow.distribution = .fill
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.setCustomSpacing(6, after: forkGlyph)

        glyphSlot.translatesAutoresizingMaskIntoConstraints = false
        for v in [dot, spinner] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            glyphSlot.addSubview(v)
        }
        wordLabel.setContentCompressionResistancePriority(.init(760), for: .horizontal)
        wordLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        let statusRow = NSStackView(views: [glyphSlot, wordLabel, detailLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6

        let text = NSStackView(views: [titleRow, statusRow, instructionLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.detachesHiddenViews = true
        text.translatesAutoresizingMaskIntoConstraints = false

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Session")?
            .withSymbolConfiguration(.role(.meta))
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true

        addSubview(badge)
        addSubview(text)
        addSubview(closeButton)
        leading = badge.leadingAnchor.constraint(equalTo: leadingAnchor)
        glyphWidth = glyphSlot.widthAnchor.constraint(equalToConstant: 7)
        NSLayoutConstraint.activate([
            leading,
            badge.topAnchor.constraint(equalTo: text.topAnchor, constant: 1),
            text.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: SidebarMetrics.badgeGap),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(SidebarMetrics.rowInset + SidebarMetrics.rowPadding)),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleRow.widthAnchor.constraint(equalTo: text.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: text.widthAnchor),
            instructionLabel.widthAnchor.constraint(equalTo: text.widthAnchor),
            glyphWidth,
            glyphSlot.heightAnchor.constraint(equalToConstant: 10),
            dot.centerXAnchor.constraint(equalTo: glyphSlot.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: glyphSlot.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            spinner.centerXAnchor.constraint(equalTo: glyphSlot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: glyphSlot.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 10),
            spinner.heightAnchor.constraint(equalToConstant: 10),
            closeButton.trailingAnchor.constraint(equalTo: text.trailingAnchor, constant: 2),
            closeButton.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Full configure: identity, layout, then the state-driven bits.
    func configure(_ session: Session, name: String, instruction: String?, density: SidebarDensity, nested: Bool,
                   status: SessionRowStatus, time: String?, selected: Bool, live: Bool) {
        badge.configure(session.agent)
        agentName = session.agent.displayName
        leading.constant = SidebarMetrics.rowInset + SidebarMetrics.rowPadding + (nested ? SidebarMetrics.childIndent : 0)
        forkGlyph.isHidden = !nested
        forkGlyph.contentTintColor = palette.muted
        nameLabel.stringValue = name
        instructionLabel.stringValue = instruction.map { "“\($0)”" } ?? ""
        instructionLabel.isHidden = density == .compact || instruction == nil
        instructionLabel.textColor = palette.instruction
        // Compact: the instruction is the row's tooltip.
        toolTip = density == .compact ? instruction : nil
        closeButton.contentTintColor = palette.muted
        update(status: status, time: time, selected: selected, live: live)
    }

    /// The state-driven bits, in place (no rebuild): glyph, word, detail,
    /// time, the title's weight and colour.
    func update(status: SessionRowStatus, time: String?, selected: Bool, live: Bool) {
        self.status = status
        self.selected = selected
        self.live = live
        let tone = palette.color(for: status.tone)
        spinner.isHidden = status.glyph != .spinner
        dot.isHidden = status.glyph == .spinner
        glyphWidth.constant = status.glyph == .spinner ? 10 : 7
        spinner.color = tone
        dot.color = tone
        dot.dimmed = status.glyph == .dimDot
        wordLabel.stringValue = status.word
        wordLabel.textColor = tone
        detailLabel.stringValue = status.detail.map { "· \($0)" } ?? ""
        detailLabel.isHidden = status.detail == nil
        detailLabel.textColor = palette.muted
        detailLabel.toolTip = status.detail
        setTime(time)
        applyTitleStyle()
        setAccessibilityLabel([nameLabel.stringValue, agentName, status.word, status.detail, time]
            .compactMap { $0 }.joined(separator: ", "))
    }

    func setTime(_ time: String?) {
        timeLabel.stringValue = time ?? ""
        timeLabel.textColor = palette.color(for: status.timeTone)
    }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        applyTitleStyle()
    }

    private func applyTitleStyle() {
        nameLabel.font = .role(status.titleIsEmphasized ? .bodyEmphasis : .body)
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let full = status.titleIsFullStrength(selected: selected, live: live) || contrast
        // Not running: the whole row steps back — a muted title and a faded badge.
        let running = status.isRunning(live: live)
        nameLabel.textColor = full ? palette.foreground : running ? palette.dimForeground : palette.muted
        badge.alphaValue = running || contrast ? 1 : 0.45
    }

    // MARK: Hover: the close button takes the time's place

    private func syncHover() {
        let hovered = window.map { $0.isKeyWindow && bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        closeButton.isHidden = !hovered || isRenaming
        timeLabel.alphaValue = closeButton.isHidden ? 1 : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        syncHover()
    }
    override func mouseEntered(with event: NSEvent) { syncHover() }
    override func mouseExited(with event: NSEvent) { syncHover() }
    override func mouseMoved(with event: NSEvent) { syncHover() }

    @objc private func closeClicked() { if let sessionID { owner?.closeSessionFromRow(sessionID) } }

    // MARK: Inline rename

    private var renameDone: ((String?) -> Void)?
    private var nameBeforeRename = ""

    /// Its name is being edited.
    var isRenaming: Bool { renameDone != nil && nameLabel.currentEditor() != nil }

    /// Edit the name in place: Return keeps it, Esc puts the old one back.
    /// False when it can't take focus (not on screen): nothing is left editable.
    func beginRenaming(_ done: @escaping (String?) -> Void) -> Bool {
        renameDone = done
        nameBeforeRename = nameLabel.stringValue
        nameLabel.isEditable = true
        nameLabel.isSelectable = true
        nameLabel.delegate = self
        guard window?.makeFirstResponder(nameLabel) == true else {
            renameDone = nil
            nameLabel.isEditable = false
            nameLabel.isSelectable = false
            return false
        }
        nameLabel.currentEditor()?.selectAll(nil)
        syncHover()
        return true
    }

    /// `name` nil: cancelled. Committing it unchanged counts as cancelling (it
    /// would pin the automatic name and add an Undo step).
    private func finishRenaming(_ name: String?) {
        guard let done = renameDone else { return }
        renameDone = nil
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        if name == nil { nameLabel.stringValue = nameBeforeRename }
        done(name == nameBeforeRename ? nil : name)
    }

    #if DEBUG
    var debugName: String { nameLabel.stringValue }
    func debugFinishRenaming(_ name: String?) {
        if let name { nameLabel.stringValue = name }
        finishRenaming(name)
    }
    var debugWord: String { wordLabel.stringValue }
    var debugDetail: String { detailLabel.isHidden ? "" : detailLabel.stringValue }
    var debugTime: String { timeLabel.stringValue }
    var debugInstructionShown: Bool { !instructionLabel.isHidden && !instructionLabel.stringValue.isEmpty }
    var debugTitleFont: NSFont? { nameLabel.font }
    var debugForkGlyphShown: Bool { !forkGlyph.isHidden }
    var debugSpinning: Bool { !spinner.isHidden && spinner.isAnimating }
    var debugBadgeMinX: CGFloat { badge.frame.minX }
    var debugBadgeAlpha: CGFloat { badge.alphaValue }
    /// Every label showing, for the no-wrap checks.
    var debugLabels: [NSTextField] {
        [nameLabel, timeLabel, wordLabel, detailLabel, instructionLabel].filter { !$0.isHidden && !$0.stringValue.isEmpty }
    }
    #endif
}

extension SessionCellView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finishRenaming(nil)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) { finishRenaming(nameLabel.stringValue) }
}

// MARK: - Subagents row

/// What a session's one subagents row sums up.
struct SubagentSummary: Equatable {
    var subagents = 0
    var workflows = 0
    /// Subagents and workflows running now.
    var running = 0
    /// Background shells and monitors running now.
    var background = 0

    var isEmpty: Bool { subagents == 0 && workflows == 0 && background == 0 }
    /// There are rows to show under it (else it opens Background Tasks).
    var hasChildRows: Bool { subagents + workflows > 0 }

    /// "4 subagents", "1 workflow", "2 background" — the leading, muted part.
    var title: String {
        var parts: [String] = []
        if subagents > 0 { parts.append("\(subagents) subagent\(subagents == 1 ? "" : "s")") }
        if workflows > 0 { parts.append("\(workflows) workflow\(workflows == 1 ? "" : "s")") }
        if background > 0 { parts.append("\(background) background") }
        return parts.joined(separator: " · ")
    }

    /// "2 running", in the working colour (nil when none).
    var runningText: String? { running > 0 ? "\(running) running" : nil }

    init(subagents: [SubagentInfo], workflows: [WorkflowRun], tasks: [BackgroundTask]) {
        self.subagents = subagents.count
        self.workflows = workflows.count
        running = subagents.count(where: \.isRunning) + workflows.count { run in
            tasks.first { $0.runID == run.id }.map(\.isRunning) ?? !run.agentsSettled
        }
        background = tasks.count { $0.isRunning && ($0.kind == .shell || $0.kind == .monitor) }
    }

    init(subagents: Int = 0, workflows: Int = 0, running: Int = 0, background: Int = 0) {
        (self.subagents, self.workflows, self.running, self.background) = (subagents, workflows, running, background)
    }
}

/// `▸ 4 subagents  ◌ 2 running`: one row under a session for all its
/// subagents, workflows and background tasks; a click shows or hides them.
final class SubagentSummaryCellView: NSTableCellView {
    private let chevron = NSImageView()
    private let titleLabel = NSTextField.sidebarLabel(.role(.meta))
    private let spinner = StatusSpinnerView()
    private let runningLabel = NSTextField.sidebarLabel(.role(.meta))

    init(_ summary: SubagentSummary, expanded: Bool, palette: SidebarPalette) {
        super.init(frame: .zero)
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        chevron.contentTintColor = palette.muted
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.stringValue = summary.title
        titleLabel.textColor = palette.muted
        titleLabel.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        runningLabel.stringValue = summary.runningText ?? ""
        runningLabel.textColor = palette.color(for: .working)
        runningLabel.isHidden = summary.runningText == nil
        runningLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        spinner.color = palette.color(for: .working)
        spinner.isHidden = summary.running == 0
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [chevron, titleLabel, spinner, runningLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(10, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor,
                                           constant: SidebarMetrics.rowInset + SidebarMetrics.childIndent + SidebarMetrics.rowPadding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -(SidebarMetrics.rowInset + SidebarMetrics.rowPadding)),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 10),
            spinner.heightAnchor.constraint(equalToConstant: 10),
        ])
        let words = [summary.title, summary.runningText].compactMap { $0 }.joined(separator: ", ")
        toolTip = summary.hasChildRows ? "\(expanded ? "Hide" : "Show") \(words)" : "Show background tasks"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(words)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    #if DEBUG
    var debugText: String { [titleLabel.stringValue, runningLabel.isHidden ? nil : runningLabel.stringValue].compactMap { $0 }.joined(separator: "  ") }
    var debugLabels: [NSTextField] { [titleLabel, runningLabel].filter { !$0.isHidden && !$0.stringValue.isEmpty } }
    #endif
}

// MARK: - Subagent / workflow rows

/// A subagent (or workflow) under its session, on the rail: what it's doing, its state.
final class SubagentCellView: NSTableCellView {
    convenience init(_ info: SubagentInfo, palette: SidebarPalette) {
        let state = switch info.state {
        case .running: "Working"
        case .done: Format.ago(info.lastWrite)
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
        self.init(title: info.title, subtitle: [info.agentType, state].compactMap { $0 }.joined(separator: " · "),
                  running: info.isRunning, failed: info.state == .failed, palette: palette,
                  accessibility: "Subagent: \(info.title), \(state)")
    }

    /// A workflow under its session: its name, and where it's got to.
    convenience init(workflow run: WorkflowRun, task: BackgroundTask?, palette: SidebarPalette) {
        let running = task.map(\.isRunning) ?? !run.agentsSettled
        var parts = ["Workflow"]
        if running, let phase = run.phases.last(where: { run.progress(of: $0).total > 0 }) {
            let p = run.progress(of: phase)
            parts.append("\(phase.title) \(p.done)/\(p.total)")
        } else if let last = run.lastWrite {
            parts.append(task?.state == .failed ? "Failed" : Format.ago(last))
        }
        parts.append("\(run.agents.count) agents")
        self.init(title: run.name, subtitle: parts.joined(separator: " · "), running: running,
                  failed: task?.state == .failed, palette: palette,
                  accessibility: "Workflow: \(run.name), \(parts.dropFirst().joined(separator: ", "))",
                  symbol: "point.3.connected.trianglepath.dotted")
        toolTip = run.summary ?? run.name
    }

    init(title: String, subtitle: String, running: Bool, failed: Bool, palette: SidebarPalette,
         accessibility: String, symbol: String? = nil) {
        super.init(frame: .zero)
        let titleLabel = NSTextField.sidebarLabel(.role(.body))
        titleLabel.stringValue = title
        titleLabel.textColor = running ? palette.foreground : palette.dimForeground
        let sub = NSTextField.sidebarLabel(.role(.meta))
        sub.stringValue = subtitle
        sub.textColor = palette.muted
        let tone = running ? palette.color(for: .working) : failed ? palette.color(for: .error) : palette.muted
        let mark: NSView
        if let symbol {
            let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            image.symbolConfiguration = .role(.meta, weight: .semibold)
            image.contentTintColor = tone
            mark = image
        } else if running {
            let spinner = StatusSpinnerView()
            spinner.color = tone
            mark = spinner
        } else {
            let dot = StatusDotView()
            dot.color = tone
            dot.dimmed = !failed
            mark = dot
        }
        let text = NSStackView(views: [titleLabel, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for v in [mark, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let markSize: CGFloat = symbol == nil ? (running ? 10 : 7) : 12
        let left = SidebarMetrics.rowInset + SidebarMetrics.childIndent + SidebarMetrics.rowPadding
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: leadingAnchor, constant: left + 5),
            mark.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: markSize),
            mark.heightAnchor.constraint(equalToConstant: markSize),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: left + 16),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(SidebarMetrics.rowInset + SidebarMetrics.rowPadding)),
            titleLabel.widthAnchor.constraint(equalTo: text.widthAnchor),
            sub.widthAnchor.constraint(equalTo: text.widthAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(accessibility)
        toolTip = title
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Footer


// MARK: - Header pieces

/// A borderless icon button with a resting fill (the header's +).
final class SidebarIconButton: NSControl {
    private let imageView = NSImageView()

    var contentTintColor: NSColor = .labelColor {
        didSet { imageView.contentTintColor = contentTintColor }
    }
    var restingBackgroundColor: NSColor = .clear {
        didSet { if !hovering { layer?.backgroundColor = restingBackgroundColor.cgColor } }
    }
    var hoverBackgroundColor: NSColor = .clear {
        didSet { if hovering { layer?.backgroundColor = hoverBackgroundColor.cgColor } }
    }
    private var hovering = false

    init(symbolName: String, configuration: NSImage.SymbolConfiguration, accessibilityDescription: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        setAccessibilityElement(true)   // a custom NSControl isn't one by default
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityDescription)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(configuration)
        imageView.image?.isTemplate = true
        imageView.imageScaling = .scaleNone
        imageView.contentTintColor = contentTintColor
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        layer?.backgroundColor = hoverBackgroundColor.cgColor
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = restingBackgroundColor.cgColor
    }
    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }
    override func accessibilityPerformPress() -> Bool { sendAction(action, to: target) }
}

/// The header's workspace identity (mark, name, ▾). A click pops the
/// workspace switcher.
final class SidebarHeaderView: NSStackView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }

    // A button to VoiceOver and Full Keyboard Access: it opens the workspace menu.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityLabel() -> String? {
        "Workspace: " + (arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.first ?? "")
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func accessibilityPerformShowMenu() -> Bool { onClick?(); return true }
}

/// The search field: a magnifier, the field, and the shortcut that focuses
/// it. Built from a borderless text field so its padding and centering are ours.
final class SidebarSearchField: NSView {
    let field = NSTextField()
    private let icon = NSImageView()
    private let hint = NSTextField.sidebarLabel(.role(.code))
    var onChange: ((String) -> Void)?
    /// ↓ / Return from the field: into the list.
    var onMoveDown: (() -> Void)?

    init(shortcutHint: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.symbolConfiguration = .role(.meta, weight: .medium)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .role(.body)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("Search sessions")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hint.stringValue = shortcutHint ?? ""
        hint.isHidden = shortcutHint == nil
        hint.setContentHuggingPriority(.required, for: .horizontal)
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        hint.setAccessibilityElement(false)

        for v in [icon, field, hint] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: hint.leadingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { focus() }

    func focus() { window?.makeFirstResponder(field) }

    /// Empty it: every session shows again.
    func clear() {
        field.stringValue = ""
        textChanged()
    }

    fileprivate func textChanged() {
        if !hint.stringValue.isEmpty { hint.isHidden = !field.stringValue.isEmpty }
        onChange?(field.stringValue)
    }

    var hintText: String? { hint.isHidden ? nil : hint.stringValue }

    #if DEBUG
    /// As if typed (one keystroke's change).
    func debugSetText(_ text: String) {
        field.stringValue = text
        textChanged()
    }
    #endif

    func style(_ p: SidebarPalette) {
        layer?.backgroundColor = p.searchFill.cgColor
        icon.contentTintColor = p.muted
        hint.textColor = p.hint
        field.textColor = p.foreground
        field.placeholderAttributedString = NSAttributedString(
            string: "Search sessions", attributes: [.foregroundColor: p.muted, .font: NSFont.role(.body)])
    }
}

extension SidebarSearchField: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { textChanged() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { onMoveDown?() } else { clear() }
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            onMoveDown?()
            return true
        default: return false
        }
    }
}
