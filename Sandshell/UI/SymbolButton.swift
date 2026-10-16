import AppKit

extension NSButton {
    /// A borderless SF Symbol button that never takes focus — the toolbar's,
    /// a pane's title-strip controls, a reply's hover actions. `size` fixes
    /// its frame; `tint` nil leaves the theme to color it.
    @MainActor
    static func symbol(_ name: String, label: String, pointSize: CGFloat = 11, weight: NSFont.Weight = .medium,
                       tint: NSColor? = .secondaryLabelColor, size: NSSize? = nil,
                       target: AnyObject?, action: Selector?, id: String? = nil) -> NSButton {
        let button = NSButton()
        button.configureSymbol(name, label: label, pointSize: pointSize, weight: weight, tint: tint, size: size,
                               target: target, action: action, id: id)
        return button
    }

    /// The same, applied to an existing button.
    @MainActor
    func configureSymbol(_ name: String, label: String, pointSize: CGFloat = 11, weight: NSFont.Weight = .medium,
                         tint: NSColor? = .secondaryLabelColor, size: NSSize? = nil,
                         target: AnyObject?, action: Selector?, id: String? = nil) {
        isBordered = false
        title = ""
        image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        refusesFirstResponder = true
        if let tint { contentTintColor = tint }
        toolTip = label
        setAccessibilityLabel(label)
        if let id { setAccessibilityIdentifier(id) }
        self.target = target
        self.action = action
        if let size {
            translatesAutoresizingMaskIntoConstraints = false
            widthAnchor.constraint(equalToConstant: size.width).isActive = true
            heightAnchor.constraint(equalToConstant: size.height).isActive = true
        }
    }
}
