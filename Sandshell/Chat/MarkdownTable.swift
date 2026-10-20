import AppKit
import CoreText

/// A GitHub-flavored Markdown table in a reply: a header row, a delimiter row
/// (`---`, `:--`, `--:`, `:-:` per column) and the body rows up to the first
/// blank line or line without a pipe. Outer pipes are optional; `\|` is a pipe
/// inside a cell, and so is one inside a code span. A table may sit in a
/// blockquote (`> | a | b |`) or a list item (indented), and may follow a
/// paragraph line directly.
struct MarkdownTable: Equatable {
    enum Alignment: Equatable, Sendable { case left, center, right }

    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]

    /// The widest row's cell count (a body row may run past the header).
    var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    /// The table that starts at `lines[start]`, and the index past its last row.
    /// Both the header and its delimiter row must be there (and agree on the
    /// column count): a reply still streaming its header renders as text until
    /// the delimiter row arrives.
    static func parse(_ lines: [String], at start: Int) -> (table: MarkdownTable, end: Int)? {
        guard start + 1 < lines.count else { return nil }
        let head = container(lines[start]), delimiter = container(lines[start + 1])
        guard head.quote == delimiter.quote, hasPipe(head.text),
              let alignments = alignments(delimiter.text) else { return nil }
        let header = cells(head.text)
        guard header.count == alignments.count else { return nil }
        var rows: [[String]] = []
        var end = start + 2
        while end < lines.count {
            let line = container(lines[end])
            guard line.quote == head.quote, !line.text.isEmpty, hasPipe(line.text),
                  !line.text.hasPrefix("```") else { break }
            rows.append(cells(line.text))
            end += 1
        }
        return (MarkdownTable(header: header, alignments: alignments, rows: rows), end)
    }

    /// A line without its containers: how many `>` quote it, and the rest
    /// trimmed (a list item's indentation goes with it).
    static func container(_ line: String) -> (quote: Int, text: String) {
        var rest = Substring(line)
        var quote = 0
        while true {
            let trimmed = rest.drop { $0 == " " || $0 == "\t" }
            guard trimmed.first == ">" else { break }
            quote += 1
            rest = trimmed.dropFirst()
        }
        return (quote, rest.trimmingCharacters(in: .whitespaces))
    }

    /// The delimiter row's alignments, or nil when `line` isn't one: every
    /// cell is dashes with optional colons at either end, and there's a pipe.
    static func alignments(_ line: String) -> [Alignment]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|") else { return nil }
        let specs = cells(t)
        guard !specs.isEmpty else { return nil }
        var out: [Alignment] = []
        for spec in specs {
            guard spec.wholeMatch(of: /:?-+:?/) != nil else { return nil }
            out.append(spec.hasSuffix(":") ? (spec.hasPrefix(":") ? .center : .right) : .left)
        }
        return out
    }

    /// Whether `line` has a pipe that splits cells (not `\|`).
    static func hasPipe(_ line: String) -> Bool {
        var escaped = false
        for ch in line {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true } else if ch == "|" { return true }
        }
        return false
    }

    /// A row's cells: split on pipes that aren't escaped or inside a code span
    /// (an unclosed backtick doesn't swallow the rest of the row).
    static func cells(_ row: String) -> [String] {
        split(row, codeSpans: true) ?? split(row, codeSpans: false) ?? []
    }

    private static func split(_ row: String, codeSpans: Bool) -> [String]? {
        var t = row.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = [], current = "", inCode = false, escaped = false
        for ch in t {
            if escaped { current.append(ch == "|" ? "|" : "\\\(ch)"); escaped = false; continue }
            switch ch {
            case "\\": escaped = true
            case "`" where codeSpans: inCode.toggle(); current.append(ch)
            case "|" where !inCode: cells.append(current); current = ""
            default: current.append(ch)
            }
        }
        if inCode { return nil }
        if escaped { current.append("\\") }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Layout

    /// Column widths for a grid `available` points wide (gaps excluded), from
    /// each column's one-line width (`natural`) and widest word (`minimum`).
    /// Everything on one line if it fits; else every column gets its widest
    /// word and the rest goes to the columns with the most text to wrap; else
    /// the columns shrink in proportion (long words break), down to `floor`.
    /// Nil when even that doesn't fit.
    static func columnWidths(natural: [CGFloat], minimum: [CGFloat], available: CGFloat,
                             floor: CGFloat = 40) -> [CGFloat]? {
        guard !natural.isEmpty, natural.count == minimum.count else { return nil }
        let natural = natural.map { Swift.max($0, 1) }
        let minimum = zip(minimum, natural).map { Swift.min(Swift.max($0, 1), $1) }
        let total = natural.reduce(0, +)
        if total <= available { return natural }
        let least = minimum.reduce(0, +)
        if least <= available {
            // Share the spare room out evenly: a column that needs less than its
            // share gets all it needs (short columns stay on one line), and the
            // rest is shared again among the columns that still want more.
            var widths = minimum
            var spare = available - least
            var open = Array(widths.indices)
            while spare > 0.5, !open.isEmpty {
                let share = spare / CGFloat(open.count)
                let satisfied = open.filter { natural[$0] - widths[$0] <= share }
                if satisfied.isEmpty {
                    for c in open { widths[c] += share }
                    break
                }
                for c in satisfied {
                    spare -= natural[c] - widths[c]
                    widths[c] = natural[c]
                }
                open.removeAll { satisfied.contains($0) }
            }
            return widths.map { $0.rounded(.down) }
        }
        guard floor * CGFloat(natural.count) <= available else { return nil }
        // Shrink the wide columns toward the floor, keeping narrow ones whole.
        var widths = minimum
        var excess = least - available
        while excess > 0.5 {
            let shrinkable = widths.indices.filter { widths[$0] > floor }
            guard !shrinkable.isEmpty else { return nil }
            let room = shrinkable.reduce(CGFloat(0)) { $0 + widths[$1] - floor }
            let take = Swift.min(excess, room)
            for i in shrinkable { widths[i] -= take * (widths[i] - floor) / room }
            excess -= take
        }
        return widths.map { $0.rounded(.down) }
    }

    /// `text` broken into lines at most `width` wide: at line separators
    /// (U+2028, a cell's `<br>`), then between words, and inside a word only
    /// when the word alone is too wide. Spaces at the breaks are dropped.
    static func wrap(_ text: NSAttributedString, width: CGFloat) -> [NSAttributedString] {
        var lines: [NSAttributedString] = []
        let ns = text.string as NSString
        var start = 0
        while true {
            let next = ns.range(of: "\u{2028}", range: NSRange(location: start, length: ns.length - start))
            let end = next.location == NSNotFound ? ns.length : next.location
            lines += wrapParagraph(text.attributedSubstring(from: NSRange(location: start, length: end - start)), width: width)
            guard next.location != NSNotFound else { break }
            start = next.location + next.length
        }
        return lines
    }

    private static func wrapParagraph(_ text: NSAttributedString, width: CGFloat) -> [NSAttributedString] {
        guard text.length > 0 else { return [text] }
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var lines: [NSAttributedString] = []
        var start = 0
        while start < text.length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if count <= 0 { count = Swift.max(1, CTTypesetterSuggestClusterBreak(typesetter, start, Double(width))) }
            lines.append(trimmed(text.attributedSubstring(from: NSRange(location: start, length: count))))
            start += count
        }
        return lines
    }

    private static func trimmed(_ s: NSAttributedString) -> NSAttributedString {
        let ns = s.string as NSString
        var end = ns.length
        while end > 0, let scalar = UnicodeScalar(ns.character(at: end - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
        return end == ns.length ? s : s.attributedSubstring(from: NSRange(location: 0, length: end))
    }

    /// The widest run between spaces, in points.
    static func widestWord(_ text: NSAttributedString) -> CGFloat {
        let ns = text.string as NSString
        var widest: CGFloat = 0
        var start = 0
        func measure(_ end: Int) {
            guard end > start else { return }
            widest = Swift.max(widest, ceil(text.attributedSubstring(from: NSRange(location: start, length: end - start)).size().width))
        }
        for i in 0..<ns.length {
            if let scalar = UnicodeScalar(ns.character(at: i)), CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar == "\u{2028}" {
                measure(i)
                start = i + 1
            }
        }
        measure(ns.length)
        return widest
    }
}
