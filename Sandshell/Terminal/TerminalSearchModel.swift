import Foundation
import Observation

/// A terminal session's scrollback, searched line by line for its search window.
@MainActor @Observable
final class TerminalSearchModel {
    struct Match: Identifiable, Hashable {
        /// Its line (a line matches once at most), so a row keeps its identity
        /// as the query changes.
        var id: Int { lineIndex }
        let lineNumber: Int
        let lineIndex: Int
        let snippet: String
    }

    struct ContextLine: Identifiable {
        let id: Int     // 1-based line number; unique within any context window
        let text: String
        let isMatch: Bool
    }

    var query = "" {
        didSet { guard query != oldValue else { return }; runSearch() }
    }
    private(set) var matches: [Match] = []
    var selectedID: Int?

    var selectedMatch: Match? { matches.first { $0.id == selectedID } }
    private(set) var lines: [String] = []

    func load(text: String) {
        lines = Self.stripANSI(text).components(separatedBy: "\n")
        runSearch()
    }

    func context(for match: Match, radius: Int = 14) -> [ContextLine] {
        let lo = max(0, match.lineIndex - radius)
        let hi = min(lines.count, match.lineIndex + radius + 1)
        return (lo..<hi).map { i in
            ContextLine(id: i + 1, text: lines[i], isMatch: i == match.lineIndex)
        }
    }

    private func runSearch() {
        guard !query.isEmpty else { matches = []; selectedID = nil; return }
        var found: [Match] = []
        let q = query
        for (i, line) in lines.enumerated() where line.localizedStandardContains(q) {
            found.append(Match(lineNumber: i + 1, lineIndex: i, snippet: line))
        }
        matches = found
        selectedID = found.first?.id
    }

    private static func stripANSI(_ s: String) -> String {
        var t = s
        let patterns = [
            #"\x1B\[[0-?]*[ -/]*[@-~]"#,              // CSI (colors, cursor, etc.)
            #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#,    // OSC (window title, hyperlinks)
            #"\x1B[@-Z\\\-_]"#,                        // Two-char ESC sequences
        ]
        for pat in patterns {
            if let re = try? NSRegularExpression(pattern: pat) {
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
            }
        }
        return t
    }
}
