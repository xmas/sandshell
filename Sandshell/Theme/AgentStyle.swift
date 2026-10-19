import AppKit

/// Brand glyph + color for each agent, used by the colored badges in the
/// sidebar session rows and the detail header (design handoff §Agents).
extension AgentKind {
    var badgeGlyph: String {
        switch self {
        case .claude, .dockerAgent: "✳"
        case .codex: "</>"
        case .shell: "›_"
        case .gemini: "✦"
        default: "•"
        }
    }

    var badgeColor: NSColor {
        switch self {
        case .claude: .hex("d97757")
        case .codex: .hex("10a37f")
        case .gemini: .hex("4285f4")
        case .shell: .hex("64748b")
        default: .hex(AgentProfileStore.profile(for: self)?.colorHex ?? "64748b")
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
        case .claude, .dockerAgent: "AgentClaude"
        case .codex: "AgentCodex"
        default: nil
        }
    }
}

extension NSColor {
    /// A session at work: the sidebar row's spinner, word and timer, and
    /// anywhere else a session reads as working (one colour for one status).
    static let sessionWorking = NSColor.hex("E8845A")
}
