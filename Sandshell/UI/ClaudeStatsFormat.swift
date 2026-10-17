import Foundation

/// Number formatting shared by the strip and the popover.
enum ClaudeStatsFormat {
    static func compact(_ n: Int) -> String { Format.tokens(n) }
    static func duration(_ ms: Double) -> String {
        let s = Int(ms / 1000)
        return s >= 3600 ? "\(s / 3600)h \((s % 3600) / 60)m" : s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }
    /// Dollars as the user's locale writes them, to `fractionDigits` decimals.
    static func usd(_ amount: Double, fractionDigits: Int = 2) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(fractionDigits)))
    }
}
