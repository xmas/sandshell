import AppKit

/// The running turn's plan, pinned above the composer: one line — what the
/// agent is on, its spinner turning, and "3 of 6" — that opens (a click, or
/// the chevron) to the whole checklist, marked as in the transcript's card.
/// The chat shows it while a turn with a plan runs.
@MainActor
final class PlanPinView: NSView, NSGestureRecognizerDelegate {
    private(set) var entries: [ChatItem.PlanEntry] = []
    private(set) var isExpanded = false

    static let markDiameter: CGFloat = 14
    static let rowHeight: CGFloat = 22
    /// More rows than this scroll.
    static let maxRows = 8
    /// How long a finished plan stays up before it goes (the turn may run on).
    static let lingerAfterDone: Duration = .seconds(2)

    private let header = NSStackView()
    private let headerMark = PlanMarkView(.pending, diameter: markDiameter)
    private let headline = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let chevron: NSButton
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    /// The closed line's text (what it's on), and whether that's "All done".
    private var headlineText = ""
    private var headlineDone = false

    init() {
        chevron = NSButton.symbol("chevron.up", label: "Show the Whole Plan", pointSize: TypeRole.meta.symbolPointSize,
                                  weight: .semibold, target: nil, action: nil, id: "chat-plan-toggle")
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("chat-plan-pin")
        // Like the queued cards: the composer's width, never asking for less.
        setContentHuggingPriority(QueuedPromptsView.slack, for: .horizontal)

        headline.font = .role(.body)
        headline.textColor = .labelColor
        headline.lineBreakMode = .byTruncatingTail
        headline.maximumNumberOfLines = 1
        headline.setContentCompressionResistancePriority(QueuedPromptsView.slack - 10, for: .horizontal)
        headline.setContentHuggingPriority(QueuedPromptsView.slack - 10, for: .horizontal)
        count.font = .role(.meta)
        count.textColor = .secondaryLabelColor
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)
        chevron.target = self
        chevron.action = #selector(toggle)

        header.setViews([headerMark, headline], in: .leading)
        header.setViews([count, chevron], in: .trailing)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.setCustomSpacing(10, after: count)
        header.setHuggingPriority(QueuedPromptsView.slack, for: .horizontal)
        header.addGestureRecognizer(click)
        header.translatesAutoresizingMaskIntoConstraints = false

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        list.setHuggingPriority(QueuedPromptsView.slack, for: .horizontal)
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.isHidden = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityIdentifier("chat-plan-list")
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        for v in [header, scroll] as [NSView] { addSubview(v) }
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            header.heightAnchor.constraint(equalToConstant: Self.rowHeight - 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            // Under the line (hidden past the card's bottom while it's closed).
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scrollHeight,
        ])
        closed = [header.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)]
        open = [scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)]
        NSLayoutConstraint.activate(closed)
        click.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The card's height closed (the line) and open (the line and the list).
    private var closed: [NSLayoutConstraint] = []
    private var open: [NSLayoutConstraint] = []
    private lazy var click = NSClickGestureRecognizer(target: self, action: #selector(toggle))

    /// The stack it's in drops it while it's hidden (and its constraints with
    /// it): each time it's back, it takes the stack's width again.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let superview else { return }
        widthAnchor.constraint(equalTo: superview.widthAnchor).isActive = true
    }

    /// Show this plan (as it stands now); the open or closed state stays.
    func show(_ entries: [ChatItem.PlanEntry]) {
        guard let progress = PlanProgress(entries) else { return hide() }
        isHidden = false
        guard entries != self.entries else { return }
        self.entries = entries
        headerMark.state = progress.headlineState
        headlineText = progress.headline
        headlineDone = progress.headlineState == .completed
        count.stringValue = progress.count
        setAccessibilityLabel(progress.accessibilityLabel + (progress.current.map { ", now: \($0)" } ?? ""))
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for entry in entries {
            let row = PlanPinRow(entry)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        let shown = min(entries.count, Self.maxRows)
        scrollHeight.constant = CGFloat(shown) * Self.rowHeight
        updateExpansion()
    }

    /// Gone (the turn ended, or its plan is done), closed for next time.
    func hide() {
        isHidden = true
        entries = []
        if isExpanded { isExpanded = false; updateExpansion() }
    }

    @objc func toggle() {
        isExpanded.toggle()
        updateExpansion()
    }

    private func updateExpansion() {
        scroll.isHidden = !isExpanded
        NSLayoutConstraint.deactivate(isExpanded ? closed : open)
        NSLayoutConstraint.activate(isExpanded ? open : closed)
        // Open, the list says what it's on: the line above just heads it.
        headerMark.isHidden = isExpanded
        headline.stringValue = isExpanded ? "Plan" : headlineText
        headline.font = isExpanded ? .role(.meta, weight: .semibold) : .role(.body)
        headline.textColor = isExpanded || headlineDone ? .secondaryLabelColor : .labelColor
        headline.toolTip = isExpanded ? nil : headlineText
        let label = isExpanded ? "Hide the Plan" : "Show the Whole Plan"
        chevron.configureSymbol(isExpanded ? "chevron.down" : "chevron.up", label: label,
                                pointSize: TypeRole.meta.symbolPointSize, weight: .semibold,
                                target: self, action: #selector(toggle), id: "chat-plan-toggle")
        chevron.toolTip = label
        setAccessibilityExpanded(isExpanded)
        if isExpanded, let current = list.arrangedSubviews.firstIndex(where: { ($0 as? PlanPinRow)?.state == .inProgress }) {
            // Its current entry in view (a long plan scrolls).
            layoutSubtreeIfNeeded()
            list.arrangedSubviews[current].scrollToVisible(list.arrangedSubviews[current].bounds)
        }
    }

    /// A click on the line opens or closes it; the chevron does that itself.
    func gestureRecognizer(_ recognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let point = chevron.convert(event.locationInWindow, from: nil)
        return !chevron.bounds.contains(point)
    }

    // Like the queued cards and the pill: a fill and a 1 pt border (drawn,
    // so the colours follow the appearance wherever it's drawn).
    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.composerCardFill.setFill()
        card.fill()
        NSColor.composerBorder.setStroke()
        card.lineWidth = 1
        card.stroke()
    }

    #if DEBUG
    var debugHeadline: String { headline.stringValue }
    var debugCount: String { count.stringValue }
    var debugSpinning: Bool { headerMark.debugSpinning }
    var debugRows: [PlanPinRow] { list.arrangedSubviews.compactMap { $0 as? PlanPinRow } }
    var debugListShown: Bool { !scroll.isHidden }
    func debugClickChevron() { chevron.performClick(nil) }
    #endif
}

/// One entry of the open pinned plan: its mark and its text.
@MainActor
final class PlanPinRow: NSView {
    let state: ChatItem.PlanEntry.State
    let mark: PlanMarkView
    let text: NSTextField

    init(_ entry: ChatItem.PlanEntry) {
        state = entry.state
        mark = PlanMarkView(entry.state, diameter: PlanPinView.markDiameter)
        let content = entry.content.split(whereSeparator: \.isNewline).joined(separator: " ")
        text = NSTextField(labelWithString: content)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        text.font = .role(.body)
        text.textColor = state == .completed ? .secondaryLabelColor : .labelColor
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.toolTip = content
        text.setContentCompressionResistancePriority(QueuedPromptsView.slack - 10, for: .horizontal)
        text.setContentHuggingPriority(QueuedPromptsView.slack - 10, for: .horizontal)
        text.translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        let word = switch state {
        case .completed: "Done"
        case .inProgress: "In progress"
        case .pending: "To do"
        }
        setAccessibilityLabel("\(word): \(content)")
        addSubview(mark)
        addSubview(text)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: PlanPinView.rowHeight),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: PlanPinView.markDiameter),
            mark.heightAnchor.constraint(equalToConstant: PlanPinView.markDiameter),
            text.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
