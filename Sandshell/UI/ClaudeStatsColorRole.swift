/// Colour roles of the title-strip readout. Each can be overridden in
/// Settings ▸ Terminal; otherwise it falls back to the terminal theme.
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
}
