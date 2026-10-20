import AppKit

/// A labelled title-bar button (symbol + word, 28 pt high): no bezel or glass
/// capsule, a hover wash, and a pressed fill while it's "on" (the Files toggle
/// while the Files sidebar shows). Coloured by `apply(_:)` from the window's theme.
@MainActor
final class ChromeButton: NSButton {
    /// Shown pressed (the thing it toggles is showing).
    var isOn = false { didSet { updateFill(); setAccessibilityValue(isOn ? "on" : "off") } }
    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.4
            updateFill()
        }
    }

    private var symbolName: String
    private let glyphConfiguration: NSImage.SymbolConfiguration
    private var word: String
    private var textColor = NSColor.labelColor, symbolColor = NSColor.secondaryLabelColor
    private var hovering = false { didSet { updateFill() } }
    private var hoverArea: NSTrackingArea?
    private var pressedColor = NSColor.clear
    private var hoverColor = NSColor.clear

    init(_ word: String, symbol: String, symbolConfiguration: NSImage.SymbolConfiguration = .role(.meta, weight: .semibold),
         toolTip: String, target: AnyObject?, action: Selector?, id: String) {
        self.symbolName = symbol
        self.glyphConfiguration = symbolConfiguration
        self.word = word
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        refusesFirstResponder = true
        imagePosition = .imageLeading
        imageHugsTitle = true
        wantsLayer = true
        layer?.cornerRadius = 7
        self.toolTip = toolTip
        self.target = target
        self.action = action
        setAccessibilityLabel(word)
        setAccessibilityHelp(toolTip)
        setAccessibilityIdentifier(id)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        apply(text: .labelColor, symbol: .secondaryLabelColor, pressed: .clear, hover: .clear)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Colours from the window's theme.
    func apply(_ colors: ThemeColors) {
        apply(text: colors.text, symbol: colors.text2, pressed: colors.chromePressed, hover: colors.chromeHover)
    }

    /// Square corners: a segment inside a pill (the pill rounds them).
    var isSegment = false { didSet { layer?.cornerRadius = isSegment ? 0 : 7 } }

    /// Say something else (Stop ⇄ Start).
    func set(word: String, symbol: String, toolTip: String) {
        guard word != self.word || symbol != symbolName else { return }
        self.word = word
        symbolName = symbol
        self.toolTip = toolTip
        setAccessibilityHelp(toolTip)
        apply(text: textColor, symbol: symbolColor, pressed: pressedColor, hover: hoverColor)
        invalidateIntrinsicContentSize()
    }

    private func apply(text: NSColor, symbol: NSColor, pressed: NSColor, hover: NSColor) {
        textColor = text
        symbolColor = symbol
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(glyphConfiguration)
        contentTintColor = symbol
        // A wider gap between the glyph and the word than the button's own.
        let title = NSMutableAttributedString(string: " ", attributes: [.font: NSFont.role(.body), .kern: 2])
        title.append(NSAttributedString(string: word, attributes: [.font: NSFont.role(.body), .foregroundColor: text]))
        attributedTitle = title
        // A new image renames the button after its symbol ("refresh"): say the word again.
        setAccessibilityLabel(word)
        pressedColor = pressed
        hoverColor = hover
        updateFill()
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: ceil(size.width) + (isSegment ? 18 : 16), height: 28)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func updateFill() {
        let fill: NSColor = isOn ? pressedColor : (hovering && isEnabled ? hoverColor : .clear)
        layer?.backgroundColor = fill.cgColor
    }
}

/// The title bar's Sandbox group: one bordered pill — the focused session's
/// sandbox by name (click: its menu, Inspect / Capture Changes as Kit /
/// Restart / …), then Stop (Start while it's stopped) and Rebuild for the
/// sandbox itself. A session's own Stop / Restart are in its pane's strip; a
/// chat's turn stops in its composer.
@MainActor
final class SandboxActionsView: NSView {
    let stopButton: ChromeButton
    let rebuildButton: ChromeButton
    /// The sandbox's menu, shown under the name.
    var sandboxMenu: (() -> NSMenu?)?
    private let label = NSStackView()
    private let labelIcon = NSImageView()
    private let labelChevron = NSImageView()
    private var labelHover = false { didSet { updateLabelFill() } }
    private var colors = ThemeColors.lightBase
    private let labelText = NSTextField(labelWithString: "Sandbox")
    private let dividers = [NSView(), NSView()]

    init(target: AnyObject?, stop: Selector, rebuild: Selector) {
        stopButton = ChromeButton("Stop", symbol: "stop.fill", toolTip: Self.stopTip,
                                  target: target, action: stop, id: "toolbar-sandbox-stop")
        rebuildButton = ChromeButton("Rebuild", symbol: "hammer",
                                     toolTip: "Make the sandbox again from its image and kits (offers to keep what was added)",
                                     target: target, action: rebuild, id: "toolbar-sandbox-rebuild")
        super.init(frame: .zero)
        stopButton.isSegment = true
        rebuildButton.isSegment = true
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Sandbox")
        setAccessibilityIdentifier("toolbar-sandbox")

        labelIcon.image = NSImage(systemSymbolName: "cube", accessibilityDescription: nil)?
            .withSymbolConfiguration(.role(.meta))
        labelIcon.setAccessibilityElement(false)
        labelText.font = .role(.meta)
        labelText.lineBreakMode = .byTruncatingMiddle
        labelText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelText.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        labelChevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        labelChevron.setAccessibilityElement(false)
        label.setViews([labelIcon, labelText, labelChevron], in: .leading)
        label.orientation = .horizontal
        label.spacing = 5
        label.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
        label.wantsLayer = true

        let row = NSStackView(views: [label, dividers[0], stopButton, dividers[1], rebuildButton])
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        for divider in dividers {
            divider.wantsLayer = true
            divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
            divider.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            label.heightAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Clicks on the name land here (it opens the menu); the buttons take their own.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit.map { $0 === stopButton || $0 === rebuildButton || $0.isDescendant(of: stopButton)
            || $0.isDescendant(of: rebuildButton) ? $0 : self }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard label.convert(label.bounds, to: self).contains(point), let menu = sandboxMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: label.bounds.maxY + 4), in: label)
    }

    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseMoved(with event: NSEvent) {
        labelHover = label.convert(label.bounds, to: self).contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { labelHover = false }

    private func updateLabelFill() {
        label.layer?.backgroundColor = (labelHover ? colors.pillLabelFill.blended(withFraction: 0.5, of: colors.chromeHover)
                                                   ?? colors.pillLabelFill : colors.pillLabelFill).cgColor
    }

    func apply(_ colors: ThemeColors) {
        layer?.backgroundColor = colors.pillFill.cgColor
        layer?.borderColor = colors.chromeLine.cgColor
        self.colors = colors
        updateLabelFill()
        labelIcon.contentTintColor = colors.text2
        labelChevron.contentTintColor = colors.text2
        labelText.textColor = colors.text2
        for divider in dividers { divider.layer?.backgroundColor = colors.chromeInnerLine.cgColor }
        stopButton.apply(colors)
        rebuildButton.apply(colors)
    }

    /// The focused session's sandbox ("Sandbox" when no session is focused).
    func setSandboxName(_ name: String?) {
        let shown = name ?? "Sandbox"
        guard labelText.stringValue != shown else { return }
        labelText.stringValue = shown
        toolTip = name.map { "Sandbox \($0)" }
        setAccessibilityLabel(name.map { "Sandbox \($0)" } ?? "Sandbox")
    }

    var debugLabel: String { labelText.stringValue }

    private static let stopTip = "Stop the sandbox (every session in it stops)"

    /// Stop while the sandbox runs, Start while it's stopped.
    func setSandboxRunning(_ running: Bool) {
        if running { stopButton.set(word: "Stop", symbol: "stop.fill", toolTip: Self.stopTip) }
        else { stopButton.set(word: "Start", symbol: "play.fill", toolTip: "Start the sandbox and its sessions in this window") }
    }

    /// Stop / Rebuild enabled for the focused session's sandbox (both off without one).
    func setEnabled(stop: Bool, rebuild: Bool) {
        if stopButton.isEnabled != stop { stopButton.isEnabled = stop }
        if rebuildButton.isEnabled != rebuild { rebuildButton.isEnabled = rebuild }
    }
}

/// A toolbar item whose custom view validates itself: NSToolbar only
/// auto-validates image items, so view items run `onValidate` instead.
@MainActor
final class SelfValidatingToolbarItem: NSToolbarItem {
    var onValidate: (() -> Void)?
    override func validate() { onValidate?() }
}
