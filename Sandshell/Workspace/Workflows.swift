import Foundation

/// A workflow Claude ran in a session (the Workflow tool): its script's name,
/// description and phases, and every agent it spawned — label, phase, model,
/// tokens (its context now), time, state. Claude Code keeps a run under the
/// session's folder:
///   `subagents/workflows/<run id>/journal.jsonl`   started / result per agent
///   `subagents/workflows/<run id>/agent-<id>.jsonl`   each agent's transcript
///   `workflows/scripts/<name>-<run id>.js`   the script (`export const meta = {…}`)
struct WorkflowRun: Identifiable, Equatable, Sendable {
    struct Agent: Identifiable, Equatable, Sendable {
        enum State: String, Sendable { case running, done, failed }
        let id: String
        let label: String
        let phase: String?
        var model: String?
        /// Its context now (the last reply's input + cache + output tokens).
        var tokens: Int
        var startedAt: Date?
        var lastWrite: Date?
        var state: State

        func duration(at now: Date = .now) -> TimeInterval {
            guard let startedAt else { return 0 }
            return (state == .running ? now : (lastWrite ?? now)).timeIntervalSince(startedAt)
        }
    }
    struct Phase: Identifiable, Equatable, Sendable {
        let title: String
        let detail: String?
        var id: String { title }
    }

    let id: String          // run id, wf_…
    /// Its folder (the agents' transcripts are `agent-<id>.jsonl` in it).
    let dir: URL
    let name: String
    let summary: String?
    /// The script's phases, in order (and any the agents name that it doesn't).
    let phases: [Phase]
    let agents: [Agent]
    let startedAt: Date?
    let lastWrite: Date?
    /// Every agent it started has answered (the run itself may still be
    /// between phases — the background task says when it's over).
    var agentsSettled: Bool { agents.allSatisfy { $0.state != .running } }
    var totalTokens: Int { agents.reduce(0) { $0 + $1.tokens } }

    func agents(in phase: Phase) -> [Agent] { agents.filter { $0.phase == phase.title } }
    func transcript(of agent: Agent) -> URL { dir.appendingPathComponent("agent-\(agent.id).jsonl") }
    func progress(of phase: Phase) -> (done: Int, total: Int) {
        let list = agents(in: phase)
        return (list.count { $0.state != .running }, list.count)
    }
}

enum WorkflowScanner {
    /// The runs under a session's transcript, oldest first. Blocks: call off main.
    nonisolated static func scan(transcript: URL) -> [WorkflowRun] {
        let sessionDir = transcript.deletingPathExtension()
        let runsDir = sessionDir.appendingPathComponent("subagents/workflows", isDirectory: true)
        guard let runIDs = try? FileManager.default.contentsOfDirectory(atPath: runsDir.path) else { return [] }
        let scripts = (try? FileManager.default.contentsOfDirectory(
            atPath: sessionDir.appendingPathComponent("workflows/scripts").path)) ?? []
        return runIDs.filter { $0.hasPrefix("wf_") }.compactMap { runID in
            let script = scripts.first { $0.hasSuffix("-\(runID).js") }
                .map { sessionDir.appendingPathComponent("workflows/scripts/\($0)") }
            return run(runID, dir: runsDir.appendingPathComponent(runID), script: script)
        }
        .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    nonisolated static func run(_ runID: String, dir: URL, script: URL?) -> WorkflowRun? {
        guard let journal = try? String(contentsOf: dir.appendingPathComponent("journal.jsonl"), encoding: .utf8) else { return nil }
        var order: [String] = []
        var started: [String: (label: String, phase: String?)] = [:]
        var results: [String: Bool] = [:]   // agent id → answered with something
        for line in journal.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = o["agentId"] as? String else { continue }
            switch o["type"] as? String {
            case "started":
                if started[id] == nil { order.append(id) }
                started[id] = (o["label"] as? String ?? id, o["phase"] as? String)
            case "result":
                results[id] = !(o["result"] is NSNull) && o["result"] != nil
            default: continue
            }
        }
        let meta = script.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(parseMeta) ?? Meta()
        let agents = order.map { id -> WorkflowRun.Agent in
            let info = started[id]!
            let t = transcriptFacts(dir.appendingPathComponent("agent-\(id).jsonl"))
            let state: WorkflowRun.Agent.State = results[id].map { $0 ? .done : .failed } ?? .running
            return .init(id: id, label: info.label, phase: info.phase, model: t.model, tokens: t.tokens,
                         startedAt: t.first, lastWrite: t.last, state: state)
        }
        // The script's phases first, then any an agent names that it doesn't.
        var phases = meta.phases
        for agent in agents {
            if let p = agent.phase, !phases.contains(where: { $0.title == p }) { phases.append(.init(title: p, detail: nil)) }
        }
        let dirAttrs = try? FileManager.default.attributesOfItem(atPath: dir.path)
        let starts = agents.compactMap(\.startedAt), lasts = agents.compactMap(\.lastWrite)
        return WorkflowRun(id: runID, dir: dir, name: meta.name ?? runID, summary: meta.description, phases: phases, agents: agents,
                           startedAt: starts.min() ?? dirAttrs?[.creationDate] as? Date,
                           lastWrite: lasts.max() ?? dirAttrs?[.modificationDate] as? Date)
    }

    // MARK: The script's meta

    struct Meta: Equatable {
        var name: String?
        var description: String?
        var phases: [WorkflowRun.Phase] = []
    }

    /// `export const meta = { name: '…', description: '…', phases: [{ title: '…', detail: '…' }] }`
    /// — a JS object literal (bare or quoted keys, ' " or ` strings, comments),
    /// read with a small literal parser rather than a JS engine.
    nonisolated static func parseMeta(_ script: String) -> Meta {
        guard let start = script.range(of: "export const meta") else { return Meta() }
        var parser = JSLiteralParser(script[start.upperBound...])
        parser.skip(past: "=")
        guard case .object(let meta) = parser.value() else { return Meta() }
        var out = Meta()
        out.name = meta["name"]?.string
        out.description = meta["description"]?.string
        if case .array(let phases)? = meta["phases"] {
            for case .object(let phase) in phases {
                if let title = phase["title"]?.string { out.phases.append(.init(title: title, detail: phase["detail"]?.string)) }
            }
        }
        return out
    }

    // MARK: An agent's transcript

    /// Its model and context size (from its last reply), and its first/last times.
    nonisolated static func transcriptFacts(_ url: URL) -> (model: String?, tokens: Int, first: Date?, last: Date?) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return (nil, 0, nil, nil) }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 4096)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let tailText = (try? fh.readToEnd()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let first = head.split(separator: "\n").first.flatMap(timestamp)
        var last: Date?, model: String?, tokens = 0
        for line in tailText.split(separator: "\n").reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if last == nil { last = (o["timestamp"] as? String).flatMap(parseDate) }
            if o["type"] as? String == "assistant", let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any] {
                model = m["model"] as? String
                tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                    .reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
                break
            }
        }
        return (model, tokens, first, last)
    }

    private static func timestamp(_ line: Substring) -> Date? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["timestamp"]
            .flatMap { $0 as? String }.flatMap(parseDate)
    }

    nonisolated static func parseDate(_ s: String) -> Date? {
        (try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(s, strategy: .iso8601))
    }
}

/// A JavaScript literal, as far as a workflow's `meta` needs: strings,
/// arrays, objects; anything else is `.other`.
enum JSLiteral: Equatable {
    case string(String)
    case array([JSLiteral])
    case object([String: JSLiteral])
    case other

    var string: String? { if case .string(let s) = self { s } else { nil } }
}

/// Reads one JS literal value: objects with bare or quoted keys, arrays,
/// strings in ' " or ` with backslash escapes, comments, trailing commas;
/// numbers, booleans and expressions are skipped as `.other`.
struct JSLiteralParser {
    private let chars: [Character]
    private var i = 0

    init(_ text: Substring) { chars = Array(text) }

    mutating func skip(past c: Character) {
        while i < chars.count, chars[i] != c { i += 1 }
        if i < chars.count { i += 1 }
    }

    mutating func value() -> JSLiteral {
        skipSpace()
        guard i < chars.count else { return .other }
        switch chars[i] {
        case "{": return object()
        case "[": return array()
        case "'", "\"", "`": return .string(quoted())
        default:
            // A number, true/false/null, an identifier or expression: skip to the next , } or ].
            var depth = 0
            while i < chars.count {
                let c = chars[i]
                if c == "(" || c == "[" || c == "{" { depth += 1 }
                if c == ")" || c == "]" || c == "}" { if depth == 0 { break }; depth -= 1 }
                if c == ",", depth == 0 { break }
                i += 1
            }
            return .other
        }
    }

    private mutating func object() -> JSLiteral {
        i += 1   // {
        var out: [String: JSLiteral] = [:]
        while true {
            skipSpace()
            guard i < chars.count else { break }
            if chars[i] == "}" { i += 1; break }
            if chars[i] == "," { i += 1; continue }
            let key: String
            if chars[i] == "'" || chars[i] == "\"" || chars[i] == "`" {
                key = quoted()
            } else {
                var k = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$" { k.append(chars[i]); i += 1 }
                if k.isEmpty { i += 1; continue }   // not a key: step over it
                key = k
            }
            skipSpace()
            guard i < chars.count, chars[i] == ":" else { continue }   // shorthand property: no value
            i += 1
            out[key] = value()
        }
        return .object(out)
    }

    private mutating func array() -> JSLiteral {
        i += 1   // [
        var out: [JSLiteral] = []
        while true {
            skipSpace()
            guard i < chars.count else { break }
            if chars[i] == "]" { i += 1; break }
            if chars[i] == "," { i += 1; continue }
            let before = i
            out.append(value())
            if i == before { i += 1 }   // never stall on an unexpected character
        }
        return .array(out)
    }

    private mutating func quoted() -> String {
        let quote = chars[i]
        i += 1
        var s = ""
        while i < chars.count, chars[i] != quote {
            if chars[i] == "\\", i + 1 < chars.count {
                i += 1
                switch chars[i] {
                case "n": s.append("\n")
                case "t": s.append("\t")
                default: s.append(chars[i])
                }
            } else {
                s.append(chars[i])
            }
            i += 1
        }
        i += 1   // closing quote
        return s
    }

    private mutating func skipSpace() {
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            break
        }
    }
}

