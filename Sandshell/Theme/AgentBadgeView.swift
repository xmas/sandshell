import AppKit

/// A colored rounded-square badge with the agent's white glyph (sidebar 22pt,
/// detail header 30pt). VoiceOver reads it as one image named for the agent.
final class AgentBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let radius: CGFloat
    /// A design session's: the ring that pulses while its agent draws.
    private var pulse: CAShapeLayer?

    init(side: CGFloat, fontSize: CGFloat, radius: CGFloat) {
        self.radius = radius
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = radius
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .mark(fontSize, weight: .bold, monospaced: true)

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
        isPulsing = false
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

    /// A design session's mark: a palette in its color (in place of its agent's).
    func configureDesign(_ color: NSColor, agent: AgentKind) {
        layer?.backgroundColor = color.cgColor
        pulse?.strokeColor = color.cgColor
        setAccessibilityLabel("Design session, \(agent.displayName)")
        icon.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: bounds.height * 0.5, weight: .semibold))
        icon.image?.isTemplate = true
        icon.isHidden = false
        label.isHidden = true
    }

    /// Its agent is drawing: a ring in the badge's color swells and fades,
    /// over and over (held still with Reduce Motion).
    var isPulsing = false {
        didSet { if isPulsing != oldValue { updatePulse() } }
    }

    private func updatePulse() {
        pulse?.removeFromSuperlayer()
        pulse = nil
        guard isPulsing, let layer else { return }
        let ring = CAShapeLayer()
        ring.frame = bounds
        ring.path = CGPath(roundedRect: bounds.insetBy(dx: -1.5, dy: -1.5), cornerWidth: radius + 1.5,
                           cornerHeight: radius + 1.5, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = layer.backgroundColor
        ring.lineWidth = 2
        layer.addSublayer(ring)
        pulse = ring
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            ring.opacity = 0.7
            return
        }
        ring.opacity = 0
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.92
        scale.toValue = 1.45
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.6
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = .infinity
        ring.add(group, forKey: "pulse")
    }
}

extension DesignColor {
    var color: NSColor { .hex(hex) }
}
