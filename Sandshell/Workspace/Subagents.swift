import Foundation

/// A subagent a Claude session started (the Agent/Task tool): Claude Code
/// keeps its transcript beside the session's, under
/// `<session>/subagents/agent-<id>.jsonl`, with `agent-<id>.meta.json`
/// (`agentType`, `description`).
struct SubagentInfo: Identifiable, Equatable, Sendable {
    enum State: String, Sendable { case running, done, failed, stopped }
    let id: String
    let sessionID: UUID
    let title: String
    let agentType: String?
    let transcript: URL
    let startedAt: Date
    var lastWrite: Date
    var state: State

    var isRunning: Bool { state == .running }
}

extension SubagentInfo {
    /// A workflow agent's run folder: its transcript is
    /// `subagents/workflows/<run id>/agent-<id>.jsonl` (a subagent's sits in
    /// `subagents/` itself). Its state is the run journal's, not the transcript's.
    var workflowRunDir: URL? {
        let dir = transcript.deletingLastPathComponent()
        return dir.lastPathComponent.hasPrefix("wf_") && dir.deletingLastPathComponent().lastPathComponent == "workflows"
            ? dir : nil
    }
}

extension SubagentInfo.State {
    /// A workflow agent's, for its transcript window.
    init(_ state: WorkflowRun.Agent.State) {
        switch state {
        case .running: self = .running
        case .done: self = .done
        case .failed: self = .failed
        }
    }

    /// A background subagent's, from the task the background-task monitor tracks.
    init(_ state: BackgroundTask.State) {
        switch state {
        case .running: self = .running
        case .completed: self = .done
        case .failed: self = .failed
        case .stopped: self = .stopped
        }
    }
}

enum SubagentScanner {
    /// The session's subagents, oldest first. Blocks: call off main.
    /// `known`: what the background-task monitor already knows (state wins).
    /// `parentWorkingSince`: when the session's current turn began (nil: it isn't working).
    nonisolated static func scan(sessionID: UUID, transcript: URL, known: [String: BackgroundTask.State] = [:],
                                 parentWorkingSince: Date? = nil, now: Date = Date()) -> [SubagentInfo] {
        let dir = transcript.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }.compactMap { name -> SubagentInfo? in
            let id = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
            let url = dir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            let modified = attrs[.modificationDate] as? Date ?? now
            let created = attrs[.creationDate] as? Date ?? modified
            let meta = (try? Data(contentsOf: dir.appendingPathComponent("agent-\(id).meta.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            func text(_ key: String) -> String? {
                (meta[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            let description = text("description"), type = text("agentType")
            let state = known[id].map { SubagentInfo.State($0) }
                ?? Self.state(url, lastWrite: modified, parentWorkingSince: parentWorkingSince, now: now)
            return SubagentInfo(id: id, sessionID: sessionID, title: description ?? type ?? "Subagent",
                                agentType: type, transcript: url, startedAt: created, lastWrite: modified, state: state)
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    /// The state of a subagent no background task tracks (a foreground one),
    /// from its transcript: done once its turn ended. Until then its session's
    /// turn waits on it, so it's running while that turn is (if it's written
    /// since the turn began: an earlier turn's was cut off), however long it's
    /// quiet; otherwise for 90 s after its last write, then it was stopped.
    nonisolated static func state(_ url: URL, lastWrite: Date, parentWorkingSince: Date?,
                                  now: Date = Date()) -> SubagentInfo.State {
        if finished(url) { return .done }
        if let since = parentWorkingSince, lastWrite >= since { return .running }
        return now.timeIntervalSince(lastWrite) > 90 ? .stopped : .running
    }

    /// Its turn ended (the subagent is done): its last assistant message
    /// stopped for good, or a tool that ends the turn answered after it
    /// (`"toolEndsTurn": true` — Claude Code 2.1.286+ hands a subagent's report
    /// back with SubagentHandback, and a workflow agent's with StructuredOutput,
    /// and writes no end_turn after). Other user lines (tool results, a message
    /// that resumes it) are passed over. Reads the file's tail, widened while
    /// it holds no whole line that says (a long final report runs well past 16 KB).
    nonisolated static func finished(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        var window: UInt64 = 16_384
        while true {
            let start = size > window ? size - window : 0
            try? fh.seek(toOffset: start)
            guard var data = try? fh.readToEnd() else { return false }
            // Past the file's start, the window's first line is cut: skip it.
            if start > 0 { data = data.firstIndex(of: 0x0A).map { data[data.index(after: $0)...] } ?? Data() }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if o["type"] as? String == "user", o["toolEndsTurn"] as? Bool == true { return true }
                guard o["type"] as? String == "assistant", let m = o["message"] as? [String: Any] else { continue }
                return (m["stop_reason"] as? String).map(TranscriptReader.claudeTurnEndingStopReasons.contains) ?? false
            }
            guard start > 0, window < 4 << 20 else { return false }
            window *= 4
        }
    }

    /// The subagent's transcript as chat items (its prompt, replies, tool calls).
    /// Decoded leniently: a read mid-write can end inside a character, and that
    /// half-written last line is skipped like any other unfinished one.
    nonisolated static func items(_ url: URL) -> [ChatItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return items(from: ClaudeTranscriptTail.parse(String(decoding: data, as: UTF8.self), sidechains: true).events)
    }

    nonisolated static func items(from events: [ClaudeTranscriptTail.Event]) -> [ChatItem] {
        var items: [ChatItem] = []
        var tools: [String: Int] = [:]
        for event in events {
            switch event {
            // Numbered by position, so rereading the growing transcript keeps
            // its id (the viewer updates in place instead of starting over).
            case .user(let text):
                let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", items.count))!
                items.append(.user(id: id, text: text, attachments: []))
            case .text(let mid, let text):
                if case .agentText(let id, let t)? = items.last, id == mid {
                    items[items.count - 1] = .agentText(id: id, text: t + "\n\n" + text)
                } else {
                    items.append(.agentText(id: mid, text: text))
                }
            case .thought(let mid, let text): items.append(.thought(id: "\(mid)-\(items.count)", text: text))
            case .toolUse(let call):
                tools[call.id] = items.count
                items.append(.tool(call))
            case .toolResult(let id, let output, let images, let failed):
                guard let i = tools[id], case .tool(var call) = items[i] else { continue }
                call.status = failed ? "failed" : "completed"
                call.output = output
                call.images = images
                items[i] = .tool(call)
            }
        }
        return items
    }
}
