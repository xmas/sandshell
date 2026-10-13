import AppKit

/// Brand glyph + color for each agent, used by the colored badges in the
/// sidebar session rows and the detail header (design handoff §Agents).
extension AgentKind {
    var badgeGlyph: String {
        switch self {
        case .claude, .dockerAgent: return "✳"
        case .codex: return "</>"
        case .shell: return "›_"
        case .gemini: return "✦"
        default: return "•"
        }
    }

    var badgeColor: NSColor {
        switch self {
        case .claude: return .hex("d97757")
        case .codex: return .hex("10a37f")
        case .gemini: return .hex("4285f4")
        case .shell: return .hex("64748b")
        default: return .hex("64748b")
        }
    }

    /// Asset-catalog name of the agent's brand logo (template SVG), or nil to
    /// fall back to the unicode glyph.
    var badgeImageName: String? {
        switch self {
        case .claude, .dockerAgent: return "AgentClaude"
        case .codex: return "AgentCodex"
        default: return nil
        }
    }
}

/// A colored rounded-square badge with the agent's white glyph (sidebar 22pt,
/// detail header 30pt).
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
        if let name = agent.badgeImageName, let image = NSImage(named: name) {
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
