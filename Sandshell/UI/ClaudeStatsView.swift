import AppKit
import Combine
import SwiftUI

/// Compact Claude readout for the terminal frame's title strip: a context
/// gauge + %, tokens, cost, and the model + effort pull-downs (the choosers). Clicking the
/// readout opens a popover with the full status and visibility toggles. Colours
/// come from the terminal theme so it reads against the terminal background.
/// Hidden for non-Claude sessions; numbers appear once the first status arrives.
@MainActor
final class ClaudeStatsView: NSView {
    /// Fired with the chosen model id (`nil` = Claude's default).
    var onModelPicked: ((String?) -> Void)?
    /// Fired with the chosen effort level (`nil` = Claude's default).
    var onEffortPicked: ((String?) -> Void)?

    private let gauge = ContextGaugeView()
    private let ctxLabel = NSTextField(labelWithString: "")
    private let tokensLabel = NSTextField(labelWithString: "")
    private let costLabel = NSTextField(labelWithString: "")
    private let modelButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let effortButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let infoButton = NSButton()
    private let stack = NSStackView()
    private let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private var colors: ThemeColors?
    private var status: ClaudeSessionStatus?
    private var defaultModel: String?
    private var defaultEffort: String?
    private var popover: NSPopover?
    private var detailHost: NSHostingController<ClaudeStatsDetailView>?
    private var cancellables: Set<AnyCancellable> = []
    /// The widest the readout may get: optional pieces give way (tokens, cost,
    /// gauge, effort, %, then the model chooser — ⓘ still has it all) so the
    /// strip's context chips keep their room.
    var maxWidth: CGFloat = .greatestFiniteMagnitude {
        didSet { if abs(oldValue - maxWidth) >= 1 { render() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError("unsupported") }

    private func build() {
        for l in [ctxLabel, tokensLabel, costLabel] {
            l.font = font
            l.lineBreakMode = .byClipping
            l.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        for b in [modelButton, effortButton] {
            b.isBordered = false
            b.controlSize = .small
            b.font = .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
            b.target = self
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        modelButton.action = #selector(modelChanged(_:))
        modelButton.toolTip = "Claude model. Changing it offers to restart the session; new sessions use it too."
        effortButton.action = #selector(effortChanged(_:))
        effortButton.toolTip = "Claude effort level. Changing it offers to restart the session; new sessions use it too."
        fillModels()
        Self.fill(effortButton, with: ClaudeEffortChoice.catalog.map { ($0.id, $0.title) })

        infoButton.bezelStyle = .inline
        infoButton.isBordered = false
        infoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Session details")
        infoButton.imagePosition = .imageOnly
        infoButton.target = self
        infoButton.action = #selector(showDetails)
        infoButton.toolTip = "Session details and readout options"
        infoButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.detachesHiddenViews = true
        stack.setHuggingPriority(.defaultHigh, for: .horizontal)   // shrink as pieces drop out
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([gauge, ctxLabel, tokensLabel, costLabel, modelButton, effortButton, infoButton], in: .leading)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        toolTip = "Click for session details"
        // @Published fires on willSet, so re-render on the next main-actor hop
        // where the new value is readable (a direct render() here saw stale state).
        ClaudeStatsVisibility.shared.$hidden.dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.render() } }
            .store(in: &cancellables)
        ClaudeStatsAppearance.shared.$overrides.dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.render() } }
            .store(in: &cancellables)
        ClaudeModelCatalog.shared.$menu.dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.fillModels(); self?.render() } }
            .store(in: &cancellables)
        // Loads the price feed + transcript models behind the chooser (throttled).
        ClaudeUsageStore.shared.refresh()
        ClaudeUsageStore.shared.$sessionTotals.dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.render() } }
            .store(in: &cancellables)
        render()
    }

    /// Pull-down: item 0 is the visible title; the rest are the choices.
    private static func fill(_ button: NSPopUpButton, with choices: [(id: String?, title: String)]) {
        button.removeAllItems()
        button.addItem(withTitle: "")
        for choice in choices {
            button.addItem(withTitle: choice.title)
            button.lastItem?.representedObject = choice.id
        }
    }

    private static let otherModelTag = 1

    /// Model pull-down from the live catalog: Default, current models, an
    /// "Older" submenu, then "Other model id…" for anything the list lacks.
    private func fillModels() {
        let menu = ClaudeModelCatalog.shared.menu
        Self.fill(modelButton, with: ([ClaudeModelChoice.systemDefault] + menu.current).map { ($0.id, $0.title) })
        if !menu.older.isEmpty {
            let sub = NSMenu()
            for choice in menu.older {
                // Submenu picks don't go through the pop-up's own action.
                let item = NSMenuItem(title: choice.title, action: #selector(olderModelChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = choice.id
                item.toolTip = choice.id
                sub.addItem(item)
            }
            let older = NSMenuItem(title: "Older", action: nil, keyEquivalent: "")
            older.submenu = sub
            modelButton.menu?.addItem(older)
        }
        modelButton.menu?.addItem(.separator())
        modelButton.addItem(withTitle: "Other model id…")
        modelButton.lastItem?.tag = Self.otherModelTag
        for item in modelButton.itemArray.dropFirst() where item.toolTip == nil {
            item.toolTip = item.representedObject as? String
        }
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, sender.indexOfSelectedItem > 0 else { return }
        if item.tag == Self.otherModelTag { promptForModelID(); return }
        onModelPicked?(item.representedObject as? String)
    }

    @objc private func olderModelChosen(_ sender: NSMenuItem) {
        onModelPicked?(sender.representedObject as? String)
    }

    /// Free-form id for a model the catalog doesn't list yet (or a gateway
    /// alias); remembered so it stays in the chooser.
    private func promptForModelID() {
        let alert = NSAlert()
        alert.messageText = "Use another Claude model"
        alert.informativeText = "Enter a model id as `claude --model` accepts it, e.g. claude-sonnet-5-5. "
            + "The sandbox's Claude Code must be new enough to know the model."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.placeholderString = "claude-…"
        if let live = status?.model?.id {
            field.stringValue = ClaudePriceBook.normalize(live)
        } else {
            field.stringValue = defaultModel ?? ""
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Use Model")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains(where: \.isWhitespace) else { return }
        ClaudeModelCatalog.shared.addCustom(id)
        onModelPicked?(id)
    }

    @objc private func effortChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, sender.indexOfSelectedItem > 0 else { return }
        onEffortPicked?(item.representedObject as? String)
    }

    /// Visible title + checkmark on the current choice.
    private func setChooser(_ button: NSPopUpButton, title: String, currentID: String?, color: NSColor) {
        button.item(at: 0)?.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: color,
                         .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)])
        // Live ids can carry Claude Code's "[1m]" suffix; menu ids don't.
        let current = currentID.map(ClaudePriceBook.normalize)
        func mark(_ items: [NSMenuItem]) {
            for item in items {
                if let sub = item.submenu { mark(sub.items); continue }
                if item.isSeparatorItem || item.tag == Self.otherModelTag { continue }
                item.state = (item.representedObject as? String).map(ClaudePriceBook.normalize) == current ? .on : .off
            }
        }
        mark(Array(button.itemArray.dropFirst()))
    }

    /// Clicks on the readout (anywhere but the choosers) open the details.
    override func mouseDown(with event: NSEvent) { showDetails() }

    @objc private func showDetails() {
        if let popover, popover.isShown { popover.performClose(nil); return }
        ClaudeUsageStore.shared.refresh()
        let host = NSHostingController(rootView: detailView())
        let pop = NSPopover()
        // Semitransient (not transient): the colour pickers open NSColorPanel,
        // a separate window, which would dismiss a transient popover.
        pop.behavior = .semitransient
        pop.contentViewController = host
        // Anchor on the ⓘ button and open below the title strip. `.minY` is the
        // bottom edge only in unflipped coordinates, so pick the edge from the
        // anchor's own flippedness rather than assuming.
        let anchor: NSView = infoButton.isHidden ? self : infoButton
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
        popover = pop
        detailHost = host
    }

    func applyTheme(_ c: ThemeColors) {
        colors = c
        render()
    }

    func update(status: ClaudeSessionStatus?, defaultModel: String?, defaultEffort: String?) {
        self.status = status
        self.defaultModel = defaultModel
        self.defaultEffort = defaultEffort
        if let id = status?.sessionID { ClaudeUsageStore.shared.refreshSession(id) }
        render()
    }

    private func detailView() -> ClaudeStatsDetailView {
        ClaudeStatsDetailView(status: status, defaultModel: defaultModel,
                              defaultEffort: defaultEffort, theme: colors)
    }

    /// Terminal-palette colour for a role when the user hasn't overridden it.
    static func themeFallback(_ role: ClaudeStatsColorRole, _ c: ThemeColors?) -> NSColor {
        switch role {
        case .low: return c?.termGreen ?? .systemGreen
        case .mid: return c?.termAccent ?? .systemOrange
        case .high: return c?.termRed ?? .systemRed
        case .track: return (c?.termDim ?? .secondaryLabelColor).withAlphaComponent(0.3)
        case .secondary: return c?.termDim ?? .secondaryLabelColor
        case .model: return c?.termText ?? .labelColor
        }
    }

    private func color(_ role: ClaudeStatsColorRole) -> NSColor {
        ClaudeStatsAppearance.shared.color(role, fallback: Self.themeFallback(role, colors))
    }

    /// Green → accent → red as the context window fills (same thresholds as the
    /// kit status line); each level is user-overridable.
    private func levelColor(_ pct: Int) -> NSColor {
        color(pct >= 80 ? .high : pct >= 50 ? .mid : .low)
    }

    private func render() {
        let vis = ClaudeStatsVisibility.shared
        let dim = color(.secondary)
        let text = color(.model)
        let f = ClaudeStatsFormat.self
        infoButton.contentTintColor = colors?.termDim ?? .secondaryLabelColor

        // Model / effort: what the live session reports, else the workspace's choice.
        setChooser(modelButton,
                   title: status?.model?.displayName ?? ClaudeModelChoice.title(forID: defaultModel),
                   currentID: status?.model?.id ?? defaultModel, color: text)
        modelButton.isHidden = !vis.isVisible(.model)
        let effortID = status?.effort?.level ?? defaultEffort
        setChooser(effortButton, title: "effort: " + ClaudeEffortChoice.title(forID: effortID).lowercased(),
                   currentID: effortID, color: dim)
        effortButton.isHidden = !vis.isVisible(.effort)

        // Context: gauge + percent.
        if let pct = status?.contextWindow?.usedPercentage {
            let p = Int(pct.rounded(.down))
            let level = levelColor(p)
            gauge.fraction = CGFloat(min(max(pct / 100, 0), 1))
            gauge.fillColor = level
            gauge.trackColor = color(.track)
            gauge.isHidden = !vis.isVisible(.gauge)
            var s = "\(p)%"
            if let size = status?.contextWindow?.contextWindowSize, size > 0 { s += "/\(f.compact(size))" }
            ctxLabel.stringValue = s
            ctxLabel.textColor = level
            ctxLabel.isHidden = !vis.isVisible(.percent)
            var tip = "Context window: \(p)% used"
            if let used = status?.contextTokens { tip += " (\(used.formatted()) tokens)" }
            ctxLabel.toolTip = tip
            gauge.toolTip = tip
        } else {
            gauge.isHidden = true
            ctxLabel.isHidden = true
        }

        // Tokens: session totals in/out.
        if let cw = status?.contextWindow, cw.totalInputTokens != nil || cw.totalOutputTokens != nil {
            let i = cw.totalInputTokens ?? 0, o = cw.totalOutputTokens ?? 0
            tokensLabel.stringValue = "↑\(f.compact(i)) ↓\(f.compact(o))"
            tokensLabel.textColor = dim
            tokensLabel.toolTip = "Session tokens: \(i.formatted()) in, \(o.formatted()) out"
            tokensLabel.isHidden = !vis.isVisible(.tokens)
        } else {
            tokensLabel.isHidden = true
        }

        // Cost: the whole conversation priced from its transcript (survives
        // --resume), else Claude Code's estimate for the current run.
        let convo = status?.sessionID.flatMap { ClaudeUsageStore.shared.sessionTotals[$0] }
        if let convo, convo.messages > 0 {
            costLabel.stringValue = String(format: "$%.2f", convo.costUSD)
            costLabel.textColor = dim
            costLabel.toolTip = String(format: "Estimated conversation cost: $%.4f over %d messages", convo.costUSD, convo.messages)
            costLabel.isHidden = !vis.isVisible(.cost)
        } else if let usd = status?.cost?.totalCostUSD {
            costLabel.stringValue = String(format: "$%.2f", usd)
            costLabel.textColor = dim
            costLabel.toolTip = String(format: "Estimated session cost: $%.4f", usd)
            costLabel.isHidden = !vis.isVisible(.cost)
        } else {
            costLabel.isHidden = true
        }

        for piece in [tokensLabel, costLabel, gauge, effortButton, ctxLabel, modelButton] as [NSView]
        where stack.fittingSize.width > maxWidth {
            piece.isHidden = true
        }

        // Keep an open popover current.
        detailHost?.rootView = detailView()
    }
}

/// A slim rounded bar that fills left→right with the context window, like the
/// bar in Claude Code's own multi-line status line.
final class ContextGaugeView: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var fillColor: NSColor = .systemGreen { didSet { needsDisplay = true } }
    var trackColor: NSColor = .quaternaryLabelColor { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 56, height: 6) }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        trackColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        guard fraction > 0 else { return }
        var fill = bounds
        fill.size.width = max(bounds.height, bounds.width * min(fraction, 1))
        fillColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
    }
}

#if DEBUG
extension ClaudeStatsView {
    var debugFitting: String {
        "fit \(Int(stack.fittingSize.width)) shown \(stack.views.filter { !$0.isHidden }.map { "\(type(of: $0)):\(Int($0.frame.width))" })"
    }
}
#endif
