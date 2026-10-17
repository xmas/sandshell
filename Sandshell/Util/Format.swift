import Foundation
import Synchronization

/// Text formatting shared across the app, so the same thing reads the same
/// everywhere (token counts, ages, work times, home-relative paths).
enum Format {
    /// 15500 → "15.5k", 200000 → "200k", 1_250_000 → "1.25M". The unit is
    /// the one the rounded count reads in (999_999 → "1.00M", not "1000k"),
    /// and a count that rounds to whole thousands drops the decimal (1_999 → "2k").
    /// The digits and decimal separator are the locale's ("15,5k" in German),
    /// whole counts included, so one readout never mixes digit systems.
    static func tokens(_ n: Int, locale: Locale = .current) -> String {
        switch n {
        case ..<1000: return number(n, places: 0, locale)
        case ..<100_000:
            let tenths = (n + 50) / 100
            return tenths % 10 == 0 ? number(tenths / 10, places: 0, locale) + "k"
                                    : number(tenths, places: 1, locale) + "k"
        case ..<999_500: return number((n + 500) / 1000, places: 0, locale) + "k"
        case ..<999_995_000: return number((n + 5_000) / 10_000, places: 2, locale) + "M"
        default:
            // Rounded in whole numbers like the other units (n + 5_000_000 can overflow).
            let (q, r) = n.quotientAndRemainder(dividingBy: 10_000_000)
            return number(q + (r >= 5_000_000 ? 1 : 0), places: 2, locale) + "B"
        }
    }

    /// A count of tenths or hundredths (`places` 1 or 2) as an exact decimal,
    /// or a whole number (`places` 0), ungrouped: 125 hundredths → "1.25".
    private static func number(_ units: Int, places: Int, _ locale: Locale) -> String {
        guard places > 0 else { return units.formatted(.number.grouping(.never).locale(locale)) }
        return (Decimal(units) / pow(10, places))
            .formatted(.number.precision(.fractionLength(places)).grouping(.never).locale(locale))
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

    /// "5 minutes ago", "in 2 hours": the system's wording, for longer lines.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        relativeFormatter.withLock { $0.localizedString(for: date, relativeTo: now) }
    }
    /// One formatter, used under its lock (it isn't Sendable). Not a
    /// `Date.AnchoredRelativeFormatStyle`: that rounds ("1 hour ago" at 59m 59s)
    /// where this truncates ("59 minutes ago").
    private static let relativeFormatter = Mutex(RelativeDateTimeFormatter())

    /// A work time: "1s" → "3m 20s" → "1h 05m"; `compact` for narrow places:
    /// "1s" → "2m" → "1h" (nil under a second).
    static func workTime(_ seconds: TimeInterval) -> String {
        let s = Int(ceil(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        let m = (s % 3600) / 60
        return "\(s / 3600)h \(m < 10 ? "0" : "")\(m)m"
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
    /// The decoded file-system path without a trailing slash: what the
    /// soft-deprecated `path` gives. (`path(percentEncoded: false)` keeps the
    /// slash a folder's URL often ends in, from `contentsOfDirectory(at:)` or
    /// `URL(fileURLWithPath:)` on a folder that exists.)
    var plainPath: String {
        let decoded = path(percentEncoded: false)
        return decoded.count > 1 && decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
    }

    /// The path with every symlink resolved, the way git and `realpath` report
    /// it: /tmp/x is /private/tmp/x (`resolvingSymlinksInPath` strips /private).
    /// A path that doesn't exist (a deleted file) resolves its longest leading
    /// part that does, as written (so a `..` after a symlink steps out of the
    /// folder it points at, as realpath does), and adds the missing rest with
    /// `.` and `..` applied, so it still matches git's path.
    var realPath: String {
        if let resolved = Self.realpath(path) { return resolved }
        guard path.hasPrefix("/") else { return standardizedFileURL.path }
        let components = path.split(separator: "/")
        // The whole path failed; "/" (no components) always resolves.
        for existing in stride(from: components.count - 1, through: 0, by: -1) {
            guard let resolved = Self.realpath("/" + components[..<existing].joined(separator: "/")) else { continue }
            var parts = resolved.split(separator: "/")
            for component in components[existing...] {
                switch component {
                case ".": continue
                case "..": _ = parts.popLast()
                default: parts.append(component)
                }
            }
            return "/" + parts.joined(separator: "/")
        }
        return standardizedFileURL.path
    }

    private static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
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
