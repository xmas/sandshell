import Foundation

/// Work a Claude session sent off to run on its own — a subagent (Agent/Task
/// tool), a background shell command (`Bash` with `run_in_background`) or a
/// `Monitor` — reconstructed from the session's transcript.
struct BackgroundTask: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case agent, shell, monitor, workflow }
    enum State: String, Sendable { case running, completed, failed, stopped }

    /// Claude Code's task id (`backgroundTaskId` / `agentId` / Monitor's task).
    let id: String
    let kind: Kind
    /// What it's for: the tool call's `description`, else its command.
    var title: String
    /// The command, or the subagent's type.
    var detail: String?
    let startedAt: Date
    var finishedAt: Date?
    var state: State = .running
    /// Claude Code's one-line result (`<summary>` of the task notification).
    var summary: String?
    /// Latest progress: a Monitor's last event, a subagent's last step.
    var activity: String?
    /// Monitor events delivered so far.
    var events = 0
    /// Where the output goes (a path inside the session's sandbox for shells).
    var outputPath: String?
    /// A workflow's run id (`wf_…`): its agents are under the session's
    /// `subagents/workflows/<run id>/` (see `WorkflowScanner`).
    var runID: String?
    /// Launched before Sandshell started watching and never seen finishing —
    /// Claude Code's background tasks don't outlive its process.
    var orphaned = false

    var isRunning: Bool { state == .running }

    func duration(at now: Date = Date()) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }
}

/// Incremental reader of a Claude Code transcript (JSONL) that tracks the
/// session's background tasks: tool calls that launched one, their results
/// (which carry the task id), and the `<task-notification>`s Claude Code queues
/// back into the conversation when a task finishes (or a Monitor emits).
struct BackgroundTaskParser: Sendable {
    private(set) var tasks: [BackgroundTask] = []

    /// Background-capable tool calls awaiting their result, by tool_use id.
    private var launches: [String: Launch] = [:]
    /// Notifications show up more than once (queued, then delivered or taken
    /// off the queue); handle each once. The queued copies still in the queue,
    /// by body: a copy leaving it uses one up, so the same text queued again
    /// later (a Monitor's repeated line) counts.
    private var inQueue: [String: Int] = [:]
    /// Lines that delivered notifications, by `uuid`: Claude Code can write a
    /// line again (same uuid), and its notifications were handled the first time.
    private var deliveredLines: Set<String> = []

    /// Where a notification's text turned up.
    private enum Copy {
        /// An enqueue: a new queue entry.
        case queued
        /// Off the queue (a remove, carrying the text): delivered as an
        /// attachment, or dropped. Never new.
        case leftQueue
        /// In a user line: a queued entry's delivery, else new (Claude Code
        /// also delivers some notifications without queueing them).
        case delivered
    }

    private struct Launch: Sendable {
        let tool: String
        let title: String
        let detail: String?
        let at: Date
    }

    /// Tasks that finished during the last `consume` (for "it's done" callbacks).
    private(set) var justFinished: [BackgroundTask] = []

    init() {}

    /// Feed newly appended transcript text (whole lines).
    mutating func consume(_ text: String) {
        justFinished = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Cheap prefilter: most lines (assistant text, file snapshots) can't matter.
            guard line.contains("tool_use") || line.contains("task-notification")
                    || line.contains("toolUseResult") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["isSidechain"] as? Bool != true else { continue }
            let at = Self.date(obj["timestamp"]) ?? Date()
            switch obj["type"] as? String {
            case "assistant":
                for block in Self.blocks(obj["message"]) where block["type"] as? String == "tool_use" {
                    noteLaunch(block, at: at)
                }
            case "user":
                for block in Self.blocks(obj["message"]) where block["type"] as? String == "tool_result" {
                    noteResult(block, toolUseResult: obj["toolUseResult"] as? [String: Any], at: at)
                }
                if let text = Self.text(of: obj["message"]), text.contains("<task-notification>"),
                   firstWrite(of: obj) {
                    noteNotifications(in: text, at: at, copy: .delivered)
                }
            case "queue-operation":
                // An enqueue is a new entry; any other operation that carries
                // the text (a remove) is that entry leaving. A dequeue carries none.
                guard let content = obj["content"] as? String else { continue }
                let enqueue = obj["operation"] as? String ?? "enqueue" == "enqueue"
                noteNotifications(in: content, at: at, copy: enqueue ? .queued : .leftQueue)
            default:
                continue
            }
        }
    }

    /// After the first read of a transcript Sandshell didn't start: whatever is
    /// still "running" belonged to an earlier Claude Code process.
    mutating func markOrphans(launchedBefore date: Date) {
        for i in tasks.indices where tasks[i].isRunning && tasks[i].startedAt < date {
            tasks[i].state = .stopped
            tasks[i].orphaned = true
        }
    }

    /// The session's Claude process ended: nothing it launched is still running.
    mutating func endAll(at date: Date = Date()) {
        for i in tasks.indices where tasks[i].isRunning {
            tasks[i].state = .stopped
            tasks[i].finishedAt = date
            tasks[i].summary = tasks[i].summary ?? "Ended with the session"
        }
    }

    mutating func setActivity(_ activity: String, for id: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].activity = activity
    }

    // MARK: Events

    private mutating func noteLaunch(_ block: [String: Any], at: Date) {
        guard let id = block["id"] as? String, let tool = block["name"] as? String,
              ["Bash", "Agent", "Task", "Monitor", "Workflow"].contains(tool) else { return }
        let input = block["input"] as? [String: Any] ?? [:]
        // A foreground Bash call never becomes a task; skip the bookkeeping.
        if tool == "Bash", input["run_in_background"] as? Bool != true { return }
        let command = (input["command"] as? String).map(Self.oneLine)
        let description = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let title: String
        let detail: String?
        switch tool {
        case "Agent", "Task":
            title = description ?? "Subagent"
            detail = input["subagent_type"] as? String
        case "Workflow":
            title = (input["name"] as? String) ?? "Workflow"   // the script's meta name arrives with the result
            detail = nil
        default:
            title = description ?? command ?? tool
            detail = command
        }
        launches[id] = Launch(tool: tool, title: title, detail: detail, at: at)
    }

    private mutating func noteResult(_ block: [String: Any], toolUseResult: [String: Any]?, at: Date) {
        guard let useID = block["tool_use_id"] as? String,
              let launch = launches.removeValue(forKey: useID) else { return }
        let resultText = Self.text(of: ["content": block["content"] as Any]) ?? ""
        var taskID: String?
        var kind = BackgroundTask.Kind.shell
        var outputPath: String?
        var title = launch.title, detail = launch.detail, runID: String?
        switch launch.tool {
        case "Workflow":
            kind = .workflow
            taskID = toolUseResult?["taskId"] as? String
                ?? Self.firstMatch(#"Workflow launched in background\. Task ID: ([A-Za-z0-9_-]+)"#, in: resultText)
            runID = toolUseResult?["runId"] as? String ?? Self.firstMatch(#"Run ID: (wf_[A-Za-z0-9_-]+)"#, in: resultText)
            title = toolUseResult?["workflowName"] as? String ?? title
            detail = toolUseResult?["summary"] as? String
                ?? Self.firstMatch(#"Summary: ([^\n]+)"#, in: resultText)
        case "Bash":
            taskID = toolUseResult?["backgroundTaskId"] as? String
                ?? Self.firstMatch(#"running in background with ID: ([A-Za-z0-9_-]+)"#, in: resultText)
            outputPath = Self.firstMatch(#"Output is being written to: (\S+?)\.?(?:\s|$)"#, in: resultText)
        case "Agent", "Task":
            kind = .agent
            if toolUseResult?["status"] as? String == "async_launched" || toolUseResult?["isAsync"] as? Bool == true {
                taskID = toolUseResult?["agentId"] as? String
            }
            taskID = taskID ?? Self.firstMatch(#"Async agent launched[\s\S]*?agentId: ([A-Za-z0-9_-]+)"#, in: resultText)
        default:   // Monitor
            kind = .monitor
            taskID = Self.firstMatch(#"Monitor started \(task ([A-Za-z0-9_-]+)"#, in: resultText)
        }
        guard let taskID, !tasks.contains(where: { $0.id == taskID }) else { return }
        var task = BackgroundTask(id: taskID, kind: kind, title: title, detail: detail,
                                  startedAt: launch.at, outputPath: outputPath)
        task.runID = runID
        tasks.append(task)
    }

    private mutating func noteNotifications(in text: String, at: Date, copy: Copy) {
        guard text.contains("<task-notification>") else { return }
        for chunk in text.components(separatedBy: "<task-notification>").dropFirst() {
            let body = chunk.components(separatedBy: "</task-notification>").first ?? chunk
            switch copy {
            case .queued:
                inQueue[body, default: 0] += 1
            case .leftQueue:
                takeOffQueue(body)
                continue
            case .delivered:
                if takeOffQueue(body) { continue }   // the delivered copy of one already handled
            }
            guard let id = Self.tag("task-id", in: body),
                  let i = tasks.firstIndex(where: { $0.id == id }) else { continue }
            var summary = Self.tag("summary", in: body)
            let status = Self.tag("status", in: body)?.lowercased()
            if let event = Self.tag("event", in: body) {
                // A Monitor's output line; the watch itself ends with a status,
                // or with an "expired" notice in place of an event.
                let expired = event.hasPrefix("[Monitor expired")
                if !expired {
                    tasks[i].events += 1
                    tasks[i].activity = Self.oneLine(event)
                }
                if status == nil {
                    guard expired else { continue }
                    summary = event.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                }
            } else if status == nil {
                continue
            }
            guard tasks[i].isRunning else { continue }
            switch status {
            case "failed", "error": tasks[i].state = .failed
            case "killed", "stopped", "cancelled", "canceled", "timeout", "timed_out": tasks[i].state = .stopped
            default: tasks[i].state = .completed
            }
            tasks[i].finishedAt = at
            tasks[i].summary = summary.map(Self.oneLine) ?? tasks[i].summary
            justFinished.append(tasks[i])
        }
    }

    /// False for a line Claude Code wrote again (same `uuid`) after the one
    /// whose notifications were already handled.
    private mutating func firstWrite(of line: [String: Any]) -> Bool {
        guard let uuid = line["uuid"] as? String else { return true }
        return deliveredLines.insert(uuid).inserted
    }

    /// Uses up one queued copy of `body`; false when none is in the queue.
    @discardableResult
    private mutating func takeOffQueue(_ body: String) -> Bool {
        guard let copies = inQueue[body] else { return false }
        inQueue[body] = copies > 1 ? copies - 1 : nil
        return true
    }

    // MARK: Parsing helpers

    private static func blocks(_ message: Any?) -> [[String: Any]] {
        (message as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    /// A message's text: string content, or its text blocks joined.
    private static func text(of message: Any?) -> String? {
        let content = (message as? [String: Any])?["content"]
        if let s = content as? String { return s }
        let parts = (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func oneLine(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ⏎ ")
        return flat.count > 300 ? String(flat.prefix(299)) + "…" : flat
    }

    private static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s))
            ?? (try? Date.ISO8601FormatStyle().parse(s))
    }
}

/// A subagent's latest step, from the tail of its own transcript
/// (`<session>/subagents/agent-<id>.jsonl`): its last tool call, else its last words.
enum SubagentProgress {
    static func transcriptURL(sessionTranscript: URL, agentID: String) -> URL {
        sessionTranscript.deletingPathExtension()
            .appendingPathComponent("subagents/agent-\(agentID).jsonl")
    }

    static func latestStep(in url: URL, maxBytes: Int = 64 * 1024) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        // Lossy: the window can start mid-character (that first line is cut anyway).
        guard let data = try? fh.readToEnd() else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard line.contains("\"assistant\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in blocks.reversed() {
                if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                    let input = block["input"] as? [String: Any] ?? [:]
                    // The first one that says something: a blank description falls through to the command.
                    let what = ["description", "file_path", "command", "pattern", "url", "query"]
                        .lazy.compactMap { (input[$0] as? String).map(BackgroundTaskParser.oneLine) }.first { !$0.isEmpty }
                    return what.map { "\(name): \($0)" } ?? name
                }
                if block["type"] as? String == "text", let t = block["text"] as? String,
                   !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return BackgroundTaskParser.oneLine(t)
                }
            }
        }
        return nil
    }
}
