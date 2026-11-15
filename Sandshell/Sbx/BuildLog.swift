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

/// What a build has done so far, read from sbx's progress: a step per section
/// sbx printed (SANDBOX, IMAGE, AGENT, …), each done, under way or failed, the
/// ones sbx usually prints next still to come, and each section's own lines.
struct BuildProgress: Equatable, Sendable {
    enum State: Equatable, Sendable { case done, current, failed, waiting }

    struct Step: Equatable, Sendable {
        /// sbx's heading ("IMAGE"); "" for what came before the first.
        let heading: String
        var lines: [String]
        var state: State

        /// The step as a person reads it.
        var title: String { BuildProgress.title(heading) }

        /// The image's layers seen so far (one line each).
        var layers: Int { lines.count { BuildProgress.isLayer($0) } }

        /// A short tally for the step list: the image's layers and the size
        /// of the latest; an install's commands done.
        var detail: String? {
            if heading == "IMAGE" {
                guard layers > 0 else { return nil }
                let size = lines.last { BuildProgress.isLayer($0) }.flatMap(BuildProgress.size)
                return "\(layers) layer\(layers == 1 ? "" : "s")" + (size.map { " · \($0)" } ?? "")
            }
            let done = lines.count { BuildProgress.mark(of: $0) == "✓" || BuildProgress.mark(of: $0) == "✔" }
            return done > 0 && heading != "SANDBOX" ? "\(done) done" : nil
        }
    }

    var steps: [Step] = []
    /// sbx said it made the sandbox.
    var created = false

    /// Sections sbx prints, in order: the ones not seen yet are still to come.
    static let usualHeadings = ["SANDBOX", "IMAGE", "AGENT"]

    init(_ lines: [String]) {
        var current: Step?
        for line in lines {
            if Self.isHeading(line) {
                if let current { steps.append(current) }
                current = Step(heading: line.trimmingCharacters(in: .whitespaces), lines: [], state: .current)
                continue
            }
            if current == nil {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                current = Step(heading: "", lines: [], state: .current)
            }
            current?.lines.append(line)
            if let mark = Self.mark(of: line), mark == "✓" || mark == "✔",
               line.contains("Created sandbox") { created = true }
        }
        if let current { steps.append(current) }
        // Trailing blank lines say nothing.
        for i in steps.indices {
            while let last = steps[i].lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { steps[i].lines.removeLast() }
        }
        for i in steps.indices {
            let failed = steps[i].lines.contains { ["✗", "✘"].contains(Self.mark(of: $0)) }
            steps[i].state = failed ? .failed : i < steps.count - 1 || created ? .done : .current
        }
        if !created, steps.allSatisfy({ $0.state != .failed }) {
            let seen = Set(steps.map(\.heading))
            let after = steps.last.flatMap { Self.usualHeadings.firstIndex(of: $0.heading) } ?? -1
            for (i, heading) in Self.usualHeadings.enumerated() where i > after && !seen.contains(heading) {
                steps.append(Step(heading: heading, lines: [], state: .waiting))
            }
        }
    }

    /// sbx's section headings: a line of capitals at the margin ("IMAGE").
    static func isHeading(_ line: String) -> Bool {
        guard let first = line.first, first != " ", line.count >= 3, line.count <= 24 else { return false }
        return line.allSatisfy { $0.isUppercase || $0 == " " } && line.contains { $0.isLetter }
    }

    static func title(_ heading: String) -> String {
        switch heading {
        case "": "Starting"
        case "SANDBOX": "Settings"
        case "IMAGE": "Image"
        case "AGENT": "Install"
        default: heading.capitalized
        }
    }

    /// A line's step mark (`✓ image — ready`), if it starts with one.
    static func mark(of line: String) -> Character? {
        let first = line.trimmingCharacters(in: .whitespaces).first
        return first.flatMap { ["○", "●", "✓", "✔", "✗", "✘", "⚠"].contains($0) ? $0 : nil }
    }

    /// `1560168ac5fb already present`: an image layer's digest, then what became of it.
    static func isLayer(_ line: String) -> Bool {
        let digest = line.trimmingCharacters(in: .whitespaces).prefix { $0 != " " }
        return digest.count == 12 && digest.allSatisfy(\.isHexDigit)
    }

    /// The size at a line's end ("… downloaded  360.5 MB" → "360.5 MB").
    static func size(_ line: String) -> String? {
        line.firstMatch(of: /([0-9]+(?:\.[0-9]+)?\s?(?:B|kB|KB|MB|GB))\s*$/).map { String($0.1) }
    }
}

/// sbx's lines, set to be read — every word kept: `Key:  value` lines line
/// up, a digest shows its ends (all of it on hover), the home folder is `~`,
/// and a run of image-layer lines is one line: a block per layer, then the latest.
enum BuildLogTypesetter {
    enum Piece: Equatable {
        /// Plain text, as printed (escapes gone); `full`: the line as printed
        /// when tidying shortened it (a digest), for its tooltip.
        case text(String, indent: Int, full: String?)
        /// `Key: value`, the key padded so values line up.
        case pair(key: String, value: String, indent: Int, full: String?)
        /// A run of layers: how many, and the last line.
        case layers(count: Int, latest: String, indent: Int)
    }

    /// The pieces a step's lines make.
    static func pieces(_ lines: [String]) -> [Piece] {
        var out: [Piece] = []
        var run: [String] = []
        func flush() {
            guard let last = run.last else { return }
            out.append(.layers(count: run.count, latest: last.trimmingCharacters(in: .whitespaces),
                               indent: indent(of: last)))
            run = []
        }
        for line in lines {
            if BuildProgress.isLayer(line) { run.append(line); continue }
            flush()
            let pad = indent(of: line)
            let body = String(line.dropFirst(pad))
            let full = digests(body).isEmpty ? nil : body.trimmingCharacters(in: .whitespaces)
            if let m = body.firstMatch(of: /^([A-Za-z][A-Za-z ]{0,18}):\s+(\S.*)$/) {
                out.append(.pair(key: String(m.1), value: tidy(String(m.2)), indent: pad, full: full))
            } else {
                out.append(.text(tidy(body), indent: pad, full: full))
            }
        }
        flush()
        return out
    }

    /// The home folder as `~`, and a digest as its ends.
    static func tidy(_ s: String, home: String = NSHomeDirectory()) -> String {
        var s = s
        if !home.isEmpty { s = s.replacing(home + "/", with: "~/") }
        return s.replacing(/sha256:([0-9a-f]{8})[0-9a-f]{50}([0-9a-f]{6})/) { "sha256:\($0.1)…\($0.2)" }
    }

    /// The full digests in a line (for its tooltip).
    static func digests(_ s: String) -> [String] {
        s.matches(of: /sha256:[0-9a-f]{64}/).map { String($0.0) }
    }

    static func indent(of line: String) -> Int { line.prefix { $0 == " " }.count }
}
