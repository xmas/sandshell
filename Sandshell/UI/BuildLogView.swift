import AppKit

/// sbx's output while it makes a sandbox (`BuildLog`), under the pane's
/// "Building…" status: on the left the steps (sbx's sections: done, under way,
/// still to come, each with its time and a tally), on the right everything sbx
/// printed, a section per step — set to be read (`BuildLogTypesetter`: values
/// lined up, digests shortened, the image's layers as one line), finished
/// sections folded to their heading (click to open), the current one open.
/// Show Raw Output has sbx's text exactly as printed; Copy Log copies that.
/// The log follows the end unless scrolled up.
final class BuildLogView: NSView, NSTextViewDelegate {
    private let steps = NSStackView()
    private let divider = NSBox()
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let copyButton = NSButton(title: "Copy Log", target: nil, action: nil)
    private let rawButton = NSButton(title: "Show Raw Output", target: nil, action: nil)
    private var shown = BuildLog()
    private var progress = BuildProgress([])
    private var colors: ThemeColors?
    /// Raw: sbx's text as printed.
    private(set) var showsRaw = false
    /// Finished sections opened by a click (by index).
    private var opened: Set<Int> = []
    /// When each step was first seen (its time in the list).
    private var started: [Int: Date] = [:]
    private var finishedAt: [Int: Date] = [:]
    private var tick: Timer?
    /// The rows' tallies, by step: the tick updates them in place (rebuilt
    /// rows would restart the spinner each second).
    private var detailLabels: [Int: NSTextField] = [:]
    private var rowsShow: BuildProgress?

    static let stepsWidth: CGFloat = 210
    private static let sectionLink = "sandshell-build-section:"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 2
        steps.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        steps.translatesAutoresizingMaskIntoConstraints = false
        steps.setAccessibilityIdentifier("build-steps")
        steps.setAccessibilityLabel("Build steps")
        addSubview(steps)

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .role(.code)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.delegate = self
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.setAccessibilityIdentifier("build-log")
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        for (button, action, id) in [(copyButton, #selector(copyLog), "build-copy"),
                                     (rawButton, #selector(toggleRaw), "build-raw")] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = .role(.meta)
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(id)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        copyButton.toolTip = "Copy everything sbx printed, as printed"
        rawButton.toolTip = "Show sbx's output exactly as it printed it"

        NSLayoutConstraint.activate([
            steps.topAnchor.constraint(equalTo: topAnchor),
            steps.leadingAnchor.constraint(equalTo: leadingAnchor),
            steps.widthAnchor.constraint(equalToConstant: Self.stepsWidth),
            steps.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: steps.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -6),
            copyButton.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 10),
            copyButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            rawButton.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 6),
            rawButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The current step's time counts up.
        tick?.invalidate()
        tick = nil
        guard window != nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isHiddenOrHasHiddenAncestor else { return }
                self.updateTimes()
            }
        }
    }

    func show(_ log: BuildLog) {
        guard log != shown else { return }
        // Another build (it started over): times and opened sections go with the old one.
        if log.dropped == 0, log.lines.count < shown.lines.count || !log.lines.starts(with: shown.lines.prefix(min(3, log.lines.count))) {
            started = [:]
            finishedAt = [:]
            opened = []
        }
        shown = log
        progress = BuildProgress(log.lines)
        let now = Date.now
        for (i, step) in progress.steps.enumerated() where step.state != .waiting {
            if started[i] == nil { started[i] = now }
            if step.state == .done, finishedAt[i] == nil { finishedAt[i] = now }
        }
        renderSteps()
        renderLog()
    }

    func applyTheme(_ c: ThemeColors) {
        layer?.backgroundColor = c.termBg.cgColor
        layer?.borderColor = c.border.cgColor
        colors = c
        renderSteps(force: true)
        renderLog()
    }

    // MARK: Steps

    private func renderSteps(force: Bool = false) {
        guard force || rowsShow != progress else { return updateTimes() }
        rowsShow = progress
        detailLabels = [:]
        let rows = progress.steps.enumerated().map { stepRow($0.element, index: $0.offset) }
        steps.setViews(rows, in: .top)
    }

    private func updateTimes() {
        for (i, label) in detailLabels where progress.steps.indices.contains(i) {
            let text = detailText(progress.steps[i], index: i)
            if label.stringValue != text { label.stringValue = text }
        }
    }

    private func stepRow(_ step: BuildProgress.Step, index: Int) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        row.wantsLayer = true
        row.layer?.cornerRadius = 7
        let icon: NSView
        switch step.state {
        case .current:
            let spinner = NSProgressIndicator.spinner(.small)
            spinner.startAnimation(nil)
            icon = spinner
            row.layer?.backgroundColor = (colors?.hover ?? .quaternaryLabelColor).cgColor
        default:
            let (symbol, tint): (String, NSColor) = switch step.state {
            case .done: ("checkmark.circle.fill", colors?.termGreen ?? .systemGreen)
            case .failed: ("xmark.circle.fill", colors?.termRed ?? .systemRed)
            default: ("circle", colors?.termDim ?? .tertiaryLabelColor)
            }
            let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) ?? NSImage())
            image.contentTintColor = tint
            icon = image
        }
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let title = NSTextField(labelWithString: step.title)
        title.font = .role(.body, weight: step.state == .current ? .semibold : .regular)
        title.textColor = step.state == .waiting ? colors?.termDim ?? .tertiaryLabelColor : colors?.termText ?? .labelColor
        let detail = NSTextField(labelWithString: detailText(step, index: index))
        detail.font = .role(.meta)
        detail.textColor = colors?.termDim ?? .secondaryLabelColor
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabels[index] = detail
        row.setViews([icon, title, detail], in: .leading)
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel("\(step.title), \(Self.spoken(step.state))" + (detail.stringValue.isEmpty ? "" : ", \(detail.stringValue)"))
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.stepsWidth - 16).isActive = true
        return row
    }

    /// The step's tally, and how long it took (or has taken so far).
    private func detailText(_ step: BuildProgress.Step, index: Int) -> String {
        var parts: [String] = []
        if step.state == .current, let tally = step.detail { parts.append(tally) }
        if let start = started[index], step.state != .waiting {
            let seconds = Int((finishedAt[index] ?? .now).timeIntervalSince(start).rounded())
            if seconds > 0 || step.state == .current { parts.append(Format.workTime(TimeInterval(seconds))) }
        }
        return parts.joined(separator: " · ")
    }

    private static func spoken(_ state: BuildProgress.State) -> String {
        switch state {
        case .done: "done"
        case .current: "under way"
        case .failed: "failed"
        case .waiting: "to come"
        }
    }

    // MARK: Log

    private func renderLog() {
        let atEnd = isScrolledToEnd
        textView.textStorage?.setAttributedString(showsRaw ? raw(shown.lines) : typeset())
        rawButton.title = showsRaw ? "Show Steps" : "Show Raw Output"
        if atEnd { textView.scrollToEndOfDocument(nil) }
    }

    private var font: NSFont { .role(.code) }
    private var text: NSColor { colors?.termText ?? .labelColor }
    private var dim: NSColor { colors?.termDim ?? .secondaryLabelColor }
    private var green: NSColor { colors?.termGreen ?? .systemGreen }
    private var red: NSColor { colors?.termRed ?? .systemRed }

    /// A section per step: finished ones folded to their heading (a link that
    /// opens them), the current one and a failed one open.
    private func typeset() -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, step) in progress.steps.enumerated() where step.state != .waiting {
            if out.length > 0 { out.append(line("", color: text)) }
            let open = step.state != .done || opened.contains(i)
            let fold = step.state == .done ? (open ? "▾ " : "▸ ") : ""
            let mark: (String, NSColor) = switch step.state {
            case .done: ("✓ ", green)
            case .failed: ("✗ ", red)
            default: ("● ", colors?.accent ?? .controlAccentColor)
            }
            let heading = NSMutableAttributedString()
            heading.append(NSAttributedString(string: fold, attributes: [.font: font, .foregroundColor: dim]))
            heading.append(NSAttributedString(string: mark.0, attributes: [.font: font, .foregroundColor: mark.1]))
            heading.append(NSAttributedString(string: step.heading.isEmpty ? "STARTING" : step.heading,
                                              attributes: [.font: NSFont.role(.code, weight: .semibold), .foregroundColor: text]))
            if !open, let tally = step.detail ?? (step.lines.isEmpty ? nil : "\(step.lines.count) line\(step.lines.count == 1 ? "" : "s")") {
                heading.append(NSAttributedString(string: "  " + tally, attributes: [.font: font, .foregroundColor: dim]))
            }
            if step.state == .done {
                heading.addAttribute(.link, value: Self.sectionLink + "\(i)", range: NSRange(location: 0, length: heading.length))
            }
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(heading)
            guard open else { continue }
            for piece in BuildLogTypesetter.pieces(step.lines) {
                out.append(NSAttributedString(string: "\n"))
                out.append(render(piece))
            }
        }
        return out
    }

    private func render(_ piece: BuildLogTypesetter.Piece) -> NSAttributedString {
        switch piece {
        case .text(let s, let indent, let full):
            let color: NSColor = switch BuildProgress.mark(of: s) {
            case "✓", "✔": green
            case "✗", "✘": red
            case "⚠": NSColor.systemYellow
            default: text
            }
            return withTip(line(String(repeating: " ", count: indent) + s, color: color, hang: indent + 2), full)
        case .pair(let key, let value, let indent, let full):
            let out = NSMutableAttributedString(string: String(repeating: " ", count: indent)
                                                + (key + ":").padding(toLength: max(key.count + 2, 11), withPad: " ", startingAt: 0),
                                                attributes: [.font: font, .foregroundColor: dim])
            out.append(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: text]))
            out.addAttribute(.paragraphStyle, value: hanging(indent + max(key.count + 2, 11)), range: NSRange(location: 0, length: out.length))
            return withTip(out, full)
        case .layers(let count, let latest, let indent):
            let out = NSMutableAttributedString(string: String(repeating: " ", count: indent),
                                                attributes: [.font: font])
            out.append(NSAttributedString(string: String(repeating: "■", count: min(count, 24)) + " ",
                                          attributes: [.font: font, .foregroundColor: green]))
            out.append(NSAttributedString(string: "\(count) layer\(count == 1 ? "" : "s") · ",
                                          attributes: [.font: font, .foregroundColor: dim]))
            out.append(NSAttributedString(string: latest, attributes: [.font: font, .foregroundColor: text]))
            return out
        }
    }

    /// A shortened line keeps its whole self on hover (a digest's full hash).
    private func withTip(_ s: NSAttributedString, _ full: String?) -> NSAttributedString {
        guard let full else { return s }
        let out = NSMutableAttributedString(attributedString: s)
        out.addAttribute(.toolTip, value: full, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// One line, wrapping under its own text (not back to the margin).
    private func line(_ s: String, color: NSColor, hang: Int = 0) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: hanging(hang)])
    }

    private func hanging(_ columns: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let width = ("0" as NSString).size(withAttributes: [.font: font]).width
        style.headIndent = CGFloat(columns) * width
        return style
    }

    /// sbx's text as printed: a step that's done in green, one that failed in
    /// red, the image's layers dimmed.
    private func raw(_ lines: [String]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, l) in lines.enumerated() {
            let color: NSColor = switch BuildProgress.mark(of: l) {
            case "✓", "✔": green
            case "✗", "✘": red
            default: BuildProgress.isLayer(l) ? dim : text
            }
            out.append(NSAttributedString(string: (i > 0 ? "\n" : "") + l, attributes: [.font: font, .foregroundColor: color]))
        }
        return out
    }

    // MARK: Actions

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let s = (link as? String) ?? (link as? URL)?.absoluteString, s.hasPrefix(Self.sectionLink),
              let i = Int(s.dropFirst(Self.sectionLink.count)) else { return false }
        if opened.contains(i) { opened.remove(i) } else { opened.insert(i) }
        let visible = scroll.contentView.bounds.origin
        textView.textStorage?.setAttributedString(typeset())
        scroll.contentView.scroll(to: visible)
        return true
    }

    @objc private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shown.text, forType: .string)
    }

    @objc private func toggleRaw() {
        showsRaw.toggle()
        renderLog()
    }

    private var isScrolledToEnd: Bool {
        let visible = scroll.contentView.documentVisibleRect
        return visible.maxY >= textView.bounds.maxY - 24
    }
}
