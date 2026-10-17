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

enum SubagentScanner {
    /// The session's subagents, oldest first. Blocks: call off main.
    /// `known`: what the background-task monitor already knows (state wins).
    nonisolated static func scan(sessionID: UUID, transcript: URL,
                                 known: [String: BackgroundTask.State] = [:], now: Date = Date()) -> [SubagentInfo] {
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
            let description = (meta["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = meta["agentType"] as? String
            let state: SubagentInfo.State
            switch known[id] {
            case .running?: state = .running
            case .failed?: state = .failed
            case .stopped?: state = .stopped
            case .completed?: state = .done
            case nil: state = finished(url) || now.timeIntervalSince(modified) > 90 ? .done : .running
            }
            return SubagentInfo(id: id, sessionID: sessionID, title: description.flatMap { $0.isEmpty ? nil : $0 } ?? type ?? "Subagent",
                                agentType: type, transcript: url, startedAt: created, lastWrite: modified, state: state)
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    /// Its last assistant message ended its turn (the subagent is done).
    nonisolated static func finished(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        guard let data = try? fh.readToEnd() else { return false }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  o["type"] as? String == "assistant", let m = o["message"] as? [String: Any] else { continue }
            return (m["stop_reason"] as? String).map { ["end_turn", "stop_sequence", "max_tokens"].contains($0) } ?? false
        }
        return false
    }

    /// The subagent's transcript as chat items (its prompt, replies, tool calls).
    nonisolated static func items(_ url: URL) -> [ChatItem] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return items(from: ClaudeTranscriptTail.parse(text, sidechains: true).events)
    }

    nonisolated static func items(from events: [ClaudeTranscriptTail.Event]) -> [ChatItem] {
        var items: [ChatItem] = []
        var tools: [String: Int] = [:]
        for event in events {
            switch event {
            case .user(let text): items.append(.user(id: UUID(), text: text, attachments: []))
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
