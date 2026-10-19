import AppKit

/// Colour roles of the Claude readout (the Session details gauge). Each can
/// be overridden in Settings ▸ Terminal; otherwise it falls back to the
/// terminal theme.
enum ClaudeStatsColorRole: String, CaseIterable, Identifiable {
    case low, mid, high, track, secondary, model
    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: "Context under 50%"
        case .mid: "Context 50–80%"
        case .high: "Context over 80%"
        case .track: "Gauge track"
        case .secondary: "Tokens & cost"
        case .model: "Model name"
        }
    }

    /// The terminal palette's colour for this role when it isn't overridden.
    func themeFallback(_ c: ThemeColors?) -> NSColor {
        switch self {
        case .low: c?.termGreen ?? .systemGreen
        case .mid: c?.termAccent ?? .systemOrange
        case .high: c?.termRed ?? .systemRed
        case .track: (c?.termDim ?? .secondaryLabelColor).withAlphaComponent(0.3)
        case .secondary: c?.termDim ?? .secondaryLabelColor
        case .model: c?.termText ?? .labelColor
        }
    }
}
