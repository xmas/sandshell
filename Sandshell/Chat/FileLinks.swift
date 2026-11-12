import Foundation

/// The file paths in a chat's text that name files on this Mac, for the
/// transcript to link (they open in Files). The page asks with an item's
/// text as it shows it, and its inline code (where a path may hold spaces).
enum FileLinks {
    struct Link: Codable, Equatable, Sendable {
        /// The text as it shows (no `:line`).
        let text: String
        /// The file, absolute.
        let path: String
        let line: Int?
    }

    /// At most this many lookups on disk for one text.
    static let lookupLimit = 400

    /// Path-like tokens: absolute, ~/, ./, or relative with a slash or an
    /// extension (a backslash-escaped space is part of the name), optionally
    /// followed by :line(:col).
    private static let pathPattern = try? NSRegularExpression(
        pattern: #"(?<![\w/.~-])((?:~|\.{1,2})?/?(?:[A-Za-z0-9_.@+-]|\\ )+(?:/(?:[A-Za-z0-9_.@+-]|\\ )+)*)(?::(\d+))?(?::\d+)?"#)
    /// A path in double quotes, where it may contain plain spaces (single
    /// quotes pair up across prose).
    private static let quotedPattern = try? NSRegularExpression(pattern: #""([^"\n]{3,300})""#)
    /// A trailing :line(:col).
    private static let lineSuffix = try? NSRegularExpression(pattern: #":(\d+)(?::\d+)?$"#)

    /// The links in `text`, relative paths against `workdir`; `code` is the
    /// text's inline code (a path in it may have spaces). `exists` is asked
    /// at most `lookupLimit` times.
    static func find(in text: String, code: [String] = [], workdir: String,
                     exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Link] {
        guard text.count < 200_000, !workdir.isEmpty, let pattern = pathPattern else { return [] }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var found: [Link] = []
        var seen = Set<String>()
        var checked = 0
        func existing(_ token: String) -> String? {
            guard checked < lookupLimit else { return nil }
            checked += 1
            let expanded = (token.replacing("\\ ", with: " ") as NSString).expandingTildeInPath
            let path = expanded.hasPrefix("/") ? expanded : (workdir as NSString).appendingPathComponent(expanded)
            return exists(path) ? (path as NSString).standardizingPath : nil
        }
        func add(_ text: String, _ path: String, _ line: String?) {
            guard seen.insert(text).inserted else { return }
            found.append(Link(text: text, path: path, line: line.flatMap { Int($0) }))
        }
        func trimmed(_ token: String) -> String {
            var token = token
            while let last = token.last, ".,;:)".contains(last) { token.removeLast() }
            return token
        }
        func looksLikePath(_ token: String) -> Bool {
            token.count >= 3 && (token.contains("/") || token.contains(".")) && !token.hasPrefix("http")
        }
        /// "My Folder/notes.md:12" → ("My Folder/notes.md", "12").
        func splitLine(_ token: String) -> (String, String?) {
            let t = token as NSString
            guard let m = lineSuffix?.firstMatch(in: token, range: NSRange(location: 0, length: t.length)) else { return (token, nil) }
            return (trimmed(t.substring(to: m.range.location)), t.substring(with: m.range(at: 1)))
        }

        // `My Folder/notes.md` (inline code), "…/Read Me.txt:12": spaces allowed.
        let quoted = (quotedPattern?.matches(in: text, range: whole) ?? []).map { ns.substring(with: $0.range(at: 1)) }
        for span in code + quoted {
            let (token, line) = splitLine(span.trimmingCharacters(in: .whitespaces))
            guard looksLikePath(token), token.contains(" "), let path = existing(token) else { continue }
            add(token, path, line)
        }

        for m in pattern.matches(in: text, range: whole) {
            guard checked < lookupLimit else { break }
            let r1 = m.range(at: 1)
            let token = trimmed(ns.substring(with: r1))
            guard looksLikePath(token) else { continue }
            let line = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2))
            if let path = existing(token) {
                add(token, path, line)
                continue
            }
            // An unquoted path with spaces ("/Users/me/My Folder/a.txt"): the
            // longest run of following words, on this line, that names a file.
            guard token.hasPrefix("/") || token.hasPrefix("~/"), m.range.location + m.range.length < ns.length,
                  ns.character(at: m.range.location + m.range.length) == 0x20 else { continue }
            let lineEnd = ns.rangeOfCharacter(from: .newlines, range: NSRange(
                location: r1.location, length: ns.length - r1.location)).location
            // A few hundred characters is plenty for a path; long lines stay cheap.
            let rest = ns.substring(with: NSRange(location: r1.location,
                                                  length: min((lineEnd == NSNotFound ? ns.length : lineEnd) - r1.location, 300)))
            let words = rest.components(separatedBy: " ")
            guard words.count >= 2 else { continue }
            var best: (text: String, path: String, line: String?)?
            for count in 2...min(words.count, 8) {
                let (candidate, candidateLine) = splitLine(trimmed(words.prefix(count).joined(separator: " ")))
                if let path = existing(candidate) { best = (candidate, path, candidateLine) }
            }
            if let best { add(best.text, best.path, best.line) }
        }
        return found
    }
}
