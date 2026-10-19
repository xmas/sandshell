import Foundation

/// What `sbx create` prints while it makes a sandbox — its progress (left on:
/// no `--no-progress`): the sandbox's settings, the image pull layer by layer,
/// each kit's install steps — read from its output files as they grow.
struct BuildLog: Equatable, Sendable {
    /// Lines kept: a pull of many layers mustn't grow without end.
    static let limit = 500

    private(set) var lines: [String] = []
    /// Lines dropped from the top to stay within `limit`.
    private(set) var dropped = 0

    /// The latest step sbx marked (`○ image — pulling…`, `✓ Created sandbox x`),
    /// without its mark.
    var step: String? {
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let mark = trimmed.first, Self.stepMarks.contains(mark) else { continue }
            let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    var isEmpty: Bool { lines.isEmpty }
    var text: String { lines.joined(separator: "\n") }

    private static let stepMarks: Set<Character> = ["○", "●", "✓", "✔", "✗", "✘", "⚠"]

    mutating func append(_ new: [String]) {
        for line in new {
            // Blank lines before anything say nothing.
            if lines.isEmpty, line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            lines.append(line)
        }
        if lines.count > Self.limit {
            dropped += lines.count - Self.limit
            lines.removeFirst(lines.count - Self.limit)
        }
    }

    /// Bytes to lines, for output that arrives in pieces: a line is out once
    /// its newline is; a carriage return starts it over (a redrawn progress
    /// line keeps its last state); terminal escapes are dropped.
    struct LineSplitter: Sendable {
        private var pending = Data()

        /// The lines `data` completes.
        mutating func feed(_ data: Data) -> [String] {
            pending.append(data)
            guard let end = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
            let complete = pending[pending.startIndex..<end]
            pending = Data(pending[pending.index(after: end)...])
            return Self.lines(in: complete)
        }

        /// What's left once the output ends (a last line with no newline).
        mutating func flush() -> [String] {
            defer { pending = Data() }
            return pending.isEmpty ? [] : Self.lines(in: pending)
        }

        private static func lines(in data: Data) -> [String] {
            String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    // CRLF ends a line; any other CR redrew it.
                    var line = Substring(line)
                    if line.hasSuffix("\r") { line = line.dropLast() }
                    if let cr = line.lastIndex(of: "\r") { line = line[line.index(after: cr)...] }
                    return stripEscapes(String(line))
                }
        }

        /// Without ANSI escape sequences (colors, cursor moves).
        static func stripEscapes(_ s: String) -> String {
            guard s.contains("\u{1B}") else { return s }
            return s.replacing(/\x1B\[[0-9;?]*[ -\/]*[@-~]|\x1B[@-Z\\-_]/, with: "")
        }
    }
}
