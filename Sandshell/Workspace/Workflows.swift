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
    /// — a JS object literal (unquoted keys, ' or " strings), read without a JS engine.
    nonisolated static func parseMeta(_ script: String) -> Meta {
        guard let start = script.range(of: "export const meta") else { return Meta() }
        // The literal: from its first { to the matching }, skipping strings.
        let tail = script[start.upperBound...]
        guard let open = tail.firstIndex(of: "{") else { return Meta() }
        var depth = 0, quote: Character?, escaped = false, end = open
        for i in tail[open...].indices {
            let c = tail[i]
            if let q = quote {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == q { quote = nil }
                continue
            }
            if c == "'" || c == "\"" || c == "`" { quote = c; continue }
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1; if depth == 0 { end = i; break } }
        }
        let literal = String(tail[open...end])
        var meta = Meta()
        meta.name = field("name", in: topLevel(literal))
        meta.description = field("description", in: topLevel(literal))
        if let phasesStart = literal.range(of: #"phases\s*:\s*\["#, options: .regularExpression) {
            let rest = literal[phasesStart.upperBound...]
            for object in objects(in: rest) {
                if let title = field("title", in: object) {
                    meta.phases.append(.init(title: title, detail: field("detail", in: object)))
                }
            }
        }
        return meta
    }

    /// The literal without its nested objects/arrays (so `name:` inside a phase isn't the workflow's).
    private static func topLevel(_ literal: String) -> String {
        var out = "", depth = 0, quote: Character?, escaped = false
        for c in literal {
            if let q = quote {
                if depth <= 1 { out.append(c) }
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == q { quote = nil }
                continue
            }
            if c == "'" || c == "\"" || c == "`" { quote = c; if depth <= 1 { out.append(c) }; continue }
            if c == "{" || c == "[" { depth += 1; if depth == 1 { out.append(c) }; continue }
            if c == "}" || c == "]" { depth -= 1; if depth == 0 { out.append(c) }; continue }
            if depth <= 1 { out.append(c) }
        }
        return out
    }

    /// The `{…}` objects of an array literal, until its closing `]`.
    private static func objects(in text: Substring) -> [String] {
        var out: [String] = [], depth = 0, quote: Character?, escaped = false, current = ""
        for c in text {
            if let q = quote {
                current.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == q { quote = nil }
                continue
            }
            if c == "'" || c == "\"" || c == "`" { quote = c; current.append(c); continue }
            if c == "{" { depth += 1 }
            if depth > 0 { current.append(c) }
            if c == "}" { depth -= 1; if depth == 0 { out.append(current); current = "" } }
            if c == "]", depth == 0 { break }
        }
        return out
    }

    /// `key: 'value'` (or "value") in an object literal, unescaped.
    private static func field(_ key: String, in literal: String) -> String? {
        let pattern = #"(?:^|[{,\s])"# + key + #"\s*:\s*(['"`])((?:\\.|(?!\1).)*)\1"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: literal, range: NSRange(literal.startIndex..., in: literal)),
              let r = Range(m.range(at: 2), in: literal) else { return nil }
        return literal[r].replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
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
