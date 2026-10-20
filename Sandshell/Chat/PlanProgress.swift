import AppKit

extension ChatItem.PlanEntry {
    /// Where an entry stands: done, being worked on, or still to do.
    enum State: Equatable, Sendable {
        case pending, inProgress, completed

        /// ACP's `status` ("pending" | "in_progress" | "completed"); anything else is still to do.
        init(_ status: String) {
            switch status {
            case "completed": self = .completed
            case "in_progress": self = .inProgress
            default: self = .pending
            }
        }
    }

    var state: State { State(status) }
}

/// How far the agent is through its plan (its to-do list): "3 of 6", and
/// what it's on now. Nil for an empty plan.
struct PlanProgress: Equatable, Sendable {
    let done: Int
    let total: Int
    /// The entry being worked on (the first in progress).
    let current: String?
    /// The first entry still to do, for when nothing is in progress.
    let next: String?

    init?(_ entries: [ChatItem.PlanEntry]) {
        guard !entries.isEmpty else { return nil }
        done = entries.count { $0.state == .completed }
        total = entries.count
        current = entries.first { $0.state == .inProgress }?.content
        next = entries.first { $0.state == .pending }?.content
    }

    var isComplete: Bool { done == total }

    /// "3 of 6": the pinned plan's count.
    var count: String { "\(done) of \(total)" }

    /// "3/6": the sidebar row's.
    var compact: String { "\(done)/\(total)" }

    /// "Plan: 3 of 6 done".
    var accessibilityLabel: String { "Plan: \(done) of \(total) done" }

    /// The collapsed pin's line: what it's on, else what's next, else that it's all done.
    var headline: String {
        let line = current ?? (isComplete ? "All done" : next ?? "")
        return line.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// The mark beside the headline.
    var headlineState: ChatItem.PlanEntry.State {
        current != nil ? .inProgress : isComplete ? .completed : .pending
    }
}

// MARK: - The marks

/// A plan entry's mark, as the Claude app draws its checklist: a filled
/// check-circle when done, a faint ring with a bright arc on it while in
/// progress, an empty ring still to do. Drawn into any context (the
/// transcript's layout fragments, the pinned plan's views), in the current
/// drawing appearance's colours.
enum PlanGlyph {
    /// The arc's sweep over the ring (a static in-progress mark; the pinned plan turns it).
    static let arcSweep: CGFloat = 1.95

    static func lineWidth(_ diameter: CGFloat) -> CGFloat { max(1.2, diameter / 11) }

    static var ringColor: NSColor { NSColor.labelColor.withAlphaComponent(0.36) }
    /// The ring under an in-progress arc: fainter, so the arc reads.
    static var trackColor: NSColor { NSColor.labelColor.withAlphaComponent(0.16) }
    static var arcColor: NSColor { .labelColor }

    /// Draw `state`'s mark filling `rect` (a square). `flipped`: y grows
    /// downward in `context`. `arc`: false leaves an in-progress mark's arc
    /// to someone else (an animated layer over it).
    static func draw(_ state: ChatItem.PlanEntry.State, in rect: CGRect, context: CGContext,
                     flipped: Bool, arc: Bool = true) {
        let d = min(rect.width, rect.height)
        let lw = lineWidth(d)
        let ring = rect.insetBy(dx: lw / 2, dy: lw / 2)
        context.saveGState()
        defer { context.restoreGState() }
        switch state {
        case .completed:
            context.setFillColor(NSColor.composerInk.cgColor)
            context.fillEllipse(in: rect)
            // The tick, in the paper colour (white on dark ink; dark on light ink).
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * d, y: flipped ? rect.minY + y * d : rect.maxY - y * d)
            }
            context.setStrokeColor(NSColor.composerPaper.cgColor)
            context.setLineWidth(max(1.4, d * 0.115))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: point(0.29, 0.52))
            context.addLine(to: point(0.44, 0.665))
            context.addLine(to: point(0.715, 0.37))
            context.strokePath()
        case .pending:
            context.setStrokeColor(ringColor.cgColor)
            context.setLineWidth(lw)
            context.strokeEllipse(in: ring)
        case .inProgress:
            context.setStrokeColor(trackColor.cgColor)
            context.setLineWidth(lw)
            context.strokeEllipse(in: ring)
            guard arc else { return }
            context.setStrokeColor(arcColor.cgColor)
            context.setLineCap(.round)
            context.addPath(arcPath(center: CGPoint(x: rect.midX, y: rect.midY), radius: ring.width / 2, flipped: flipped))
            context.strokePath()
        }
    }

    /// The in-progress arc: from the top, clockwise, `arcSweep` round.
    static func arcPath(center: CGPoint, radius: CGFloat, flipped: Bool) -> CGPath {
        let path = CGMutablePath()
        if flipped {
            // y down: the top is -π/2, and clockwise on screen is increasing angle.
            path.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + arcSweep, clockwise: false)
        } else {
            path.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - arcSweep, clockwise: true)
        }
        return path
    }
}

/// A plan entry's mark in the transcript: carried by the entry's paragraph
/// (`.chatPlanMark`) and drawn by `BlockBackgroundFragment` in the space the
/// paragraph's indent leaves, centred on its first line.
final class PlanMark: NSObject, @unchecked Sendable {
    let state: ChatItem.PlanEntry.State
    /// From the line fragment padding to the mark's left edge.
    let leading: CGFloat
    let diameter: CGFloat
    /// The text's cap height: the mark centres on it.
    let capHeight: CGFloat

    init(_ state: ChatItem.PlanEntry.State, leading: CGFloat, diameter: CGFloat, capHeight: CGFloat) {
        self.state = state
        self.leading = leading
        self.diameter = diameter
        self.capHeight = capHeight
    }
}

// MARK: - A mark as a view

/// One plan mark as a view (the pinned plan's). In progress, its arc goes
/// round the ring while it's in a window — unless Reduce Motion is on, when
/// it stands still.
@MainActor
final class PlanMarkView: NSView {
    var state: ChatItem.PlanEntry.State {
        didSet { if state != oldValue { needsDisplay = true; updateSpin() } }
    }
    let diameter: CGFloat
    private let arc = CAShapeLayer()
    private static let spinKey = "spin"
    /// One trip round, in seconds.
    static let period: CFTimeInterval = 1.1
    private var reduceMotionObserver: NSObjectProtocol?

    init(_ state: ChatItem.PlanEntry.State, diameter: CGFloat) {
        self.state = state
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        arc.fillColor = nil
        arc.lineCap = .round
        arc.isHidden = true
        layer?.addSublayer(arc)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateSpin() } }
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let reduceMotionObserver { NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver) }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    private var markRect: CGRect {
        CGRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        PlanGlyph.draw(state, in: markRect, context: context, flipped: isFlipped, arc: arc.isHidden)
    }

    /// The arc turns while it's in progress and on screen (and motion is welcome).
    private func updateSpin() {
        let spin = state == .inProgress && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if arc.isHidden == spin { needsDisplay = true }   // the drawn arc goes, or comes back
        arc.isHidden = !spin
        guard spin else { return arc.removeAnimation(forKey: Self.spinKey) }
        layoutArc()
        guard arc.animation(forKey: Self.spinKey) == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi   // clockwise
        turn.duration = Self.period
        turn.repeatCount = .infinity
        turn.timingFunction = CAMediaTimingFunction(name: .linear)
        turn.isRemovedOnCompletion = false
        arc.add(turn, forKey: Self.spinKey)
    }

    private func layoutArc() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = markRect
        arc.bounds = CGRect(origin: .zero, size: rect.size)
        arc.position = CGPoint(x: rect.midX, y: rect.midY)
        let lw = PlanGlyph.lineWidth(diameter)
        arc.lineWidth = lw
        arc.path = PlanGlyph.arcPath(center: CGPoint(x: diameter / 2, y: diameter / 2), radius: diameter / 2 - lw / 2,
                                     flipped: false)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            arc.strokeColor = PlanGlyph.arcColor.cgColor
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Off screen it stops; back in a window it picks up again.
        arc.removeAnimation(forKey: Self.spinKey)
        updateSpin()
    }

    override func layout() {
        super.layout()
        if !arc.isHidden { layoutArc() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !arc.isHidden { layoutArc() }
    }

    #if DEBUG
    /// The arc is going round.
    var debugSpinning: Bool { !arc.isHidden && arc.animation(forKey: Self.spinKey) != nil }
    #endif
}
