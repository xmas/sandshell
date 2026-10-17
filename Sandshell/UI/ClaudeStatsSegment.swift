/// Which segments of the title-strip readout are shown. Global (all windows),
/// persisted in UserDefaults; toggled from the detail popover.
enum ClaudeStatsSegment: String, CaseIterable, Identifiable {
    case gauge, percent, tokens, cost, model, effort
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gauge: "Context gauge"
        case .percent: "Context %"
        case .tokens: "Tokens in / out"
        case .cost: "Cost"
        case .model: "Model"
        case .effort: "Effort"
        }
    }
}
