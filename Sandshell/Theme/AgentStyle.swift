import AppKit
import SwiftUI

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
        default: return .hex(AgentProfileStore.profile(for: self)?.colorHex ?? "64748b")
        }
    }

    /// SF Symbol a custom agent's profile picked (nil for builtins, which use
    /// their brand logo or glyph).
    var customSymbol: String? {
        isBuiltin ? nil : AgentProfileStore.profile(for: self)?.icon
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

extension NSColor {
    /// A session at work (sidebar timer, title-strip status, background pill).
    static let sessionWorking = NSColor.hex("16a34a")
}

// MARK: - SwiftUI badges

/// The colored rounded square with a white mark, in SwiftUI: agents (brand
/// logo, a custom agent's symbol, or its glyph), folders and profiles. One
/// look everywhere — the AppKit `AgentBadgeView` draws the same.
struct BadgeMark: View {
    enum Content { case image(NSImage), symbol(String), glyph(String) }
    let color: NSColor
    let content: Content
    var side: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
            .fill(Color(nsColor: color))
            .frame(width: side, height: side)
            .overlay {
                switch content {
                case .image(let image):
                    Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                        .frame(width: side * 0.6, height: side * 0.6).foregroundStyle(.white)
                case .symbol(let name):
                    Image(systemName: name).font(.system(size: side * 0.5, weight: .semibold)).foregroundStyle(.white)
                case .glyph(let text):
                    Text(text).font(.system(size: side * 0.45, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                }
            }
    }
}

extension AgentKind {
    /// What the agent's badge shows: its logo, else a custom agent's symbol,
    /// else its glyph.
    var badgeContent: BadgeMark.Content {
        if let image = badgeImageName.flatMap({ NSImage(named: $0) }) { return .image(image) }
        if let symbol = customSymbol { return .symbol(symbol) }
        return .glyph(badgeGlyph)
    }
}
