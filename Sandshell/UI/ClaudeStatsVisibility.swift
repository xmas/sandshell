import Combine
import Foundation

/// The readout segments the user hid (see `ClaudeStatsSegment`).
@MainActor
final class ClaudeStatsVisibility: ObservableObject {
    static let shared = ClaudeStatsVisibility()
    private static let key = "claudeStats.hiddenSegments"
    @Published private(set) var hidden: Set<ClaudeStatsSegment>

    private init() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        hidden = Set(raw.compactMap(ClaudeStatsSegment.init(rawValue:)))
    }
    func isVisible(_ s: ClaudeStatsSegment) -> Bool { !hidden.contains(s) }
    func set(_ s: ClaudeStatsSegment, visible: Bool) {
        if visible { hidden.remove(s) } else { hidden.insert(s) }
        UserDefaults.standard.set(hidden.map(\.rawValue).sorted(), forKey: Self.key)
    }

    /// `isVisible` / `set(_:visible:)` as one, for a binding (`$visibility[visible: s]`).
    subscript(visible s: ClaudeStatsSegment) -> Bool {
        get { isVisible(s) }
        set { set(s, visible: newValue) }
    }
}
