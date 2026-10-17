import AppKit

/// A colored rounded-square badge with the agent's white glyph (sidebar 22pt,
/// detail header 30pt). VoiceOver reads it as one image named for the agent.
final class AgentBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init(side: CGFloat, fontSize: CGFloat, radius: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = radius
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: fontSize, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .white   // brand SVGs are template images
        addSubview(label)
        addSubview(icon)
        // One element, not the glyph spelled out ("✳", "</>") or an unnamed logo.
        label.setAccessibilityElement(false)
        icon.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Logo sits inside the badge with padding.
            icon.widthAnchor.constraint(equalToConstant: round(side * 0.6)),
            icon.heightAnchor.constraint(equalToConstant: round(side * 0.6)),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ agent: AgentKind) {
        layer?.backgroundColor = agent.badgeColor.cgColor
        setAccessibilityLabel(agent.displayName)
        let image: NSImage? = switch agent.badgeContent {
        case .image(let image): image
        case .symbol(let name): NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .glyph: nil
        }
        if let image {
            image.isTemplate = true
            icon.image = image
            icon.isHidden = false
            label.isHidden = true
        } else {
            icon.image = nil
            icon.isHidden = true
            label.isHidden = false
            label.stringValue = agent.badgeGlyph
        }
    }
}
