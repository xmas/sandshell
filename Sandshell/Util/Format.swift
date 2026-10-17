import Foundation

/// Text formatting shared across the app, so the same thing reads the same
/// everywhere (token counts, ages, work times, home-relative paths).
enum Format {
    /// 15500 → "15.5k", 200000 → "200k", 1_250_000 → "1.25M". The unit is
    /// the one the rounded count reads in (999_999 → "1.00M", not "1000k"),
    /// and a count that rounds to whole thousands drops the decimal (1_999 → "2k").
    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<100_000:
            let tenths = (n + 50) / 100
            return tenths % 10 == 0 ? "\(tenths / 10)k" : "\(tenths / 10).\(tenths % 10)k"
        case ..<999_500: return "\((n + 500) / 1000)k"
        case ..<999_995_000:
            let hundredths = (n + 5_000) / 10_000
            return String(format: "%d.%02dM", hundredths / 100, hundredths % 100)
        default: return String(format: "%.2fB", Double(n) / 1_000_000_000)
        }
    }

    /// "just now", "45s ago", "3m ago", "2h ago", "4d ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = Int(max(0, now.timeIntervalSince(date)))
        switch s {
        case ..<10: return "just now"
        case ..<60: return "\(s)s ago"
        case ..<3600: return "\(s / 60)m ago"
        case ..<86400: return "\(s / 3600)h ago"
        default: return "\(s / 86400)d ago"
        }
    }

    /// "5 minutes ago", "yesterday": the system's wording, for longer lines.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: now)
    }
    nonisolated(unsafe) private static let relativeFormatter = RelativeDateTimeFormatter()

    /// A work time: "1s" → "3m 20s" → "1h 05m"; `compact` for narrow places:
    /// "1s" → "2m" → "1h" (nil under a second).
    static func workTime(_ seconds: TimeInterval) -> String {
        let s = Int(ceil(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }
    static func compactWorkTime(_ seconds: TimeInterval) -> String? {
        guard seconds >= 1 else { return nil }
        let s = Int(ceil(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}

extension String {
    /// The path with the home folder as "~" (only a whole leading component).
    var tildeAbbreviated: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + dropFirst(home.count) }
        return self
    }
}

extension URL {
    /// The path with every symlink resolved, the way git and `realpath` report
    /// it: /tmp/x is /private/tmp/x (`resolvingSymlinksInPath` strips /private).
    /// A path that doesn't exist (a deleted file) resolves its nearest existing
    /// folder and keeps the rest as is, so it still matches git's path.
    var realPath: String {
        if let resolved = Darwin.realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let standardized = standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
        guard parent.path.count < standardized.path.count else { return standardized.path }
        return (parent.realPath as NSString).appendingPathComponent(standardized.lastPathComponent)
    }
}

import AppKit

extension NSAttributedString {
    /// "+12 −3" in green and red, the same wherever line counts show (the
    /// branch chip, Files' changed list).
    static func diffCounts(added: Int, removed: Int, size: CGFloat = 11) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let out = NSMutableAttributedString(string: "+\(added)", attributes: [.font: font, .foregroundColor: NSColor.systemGreen])
        out.append(NSAttributedString(string: " −\(removed)", attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
        return out
    }
}
