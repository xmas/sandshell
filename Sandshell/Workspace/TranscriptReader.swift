import Foundation

/// Extracts a session's first user prompt from the agent's on-disk transcript,
/// used to auto-name a session (e.g. "me talk pretty?"). The agent runs in the
/// container but writes to the **mounted** host config dir (`~/.claude`,
/// `~/.codex`), so these files are readable host-side.
enum TranscriptReader {
    // MARK: - Public API

    /// Locate the transcript for a single launched session.
    /// - Claude: newest `.jsonl` in the project dir modified since `since`.
    /// - Codex: newest rollout `.jsonl` under `~/.codex/sessions` whose
    ///   `session_meta.cwd` matches and whose file mtime is newer than `since`.
    static func transcriptURL(agent: AgentKind, workdir: String, home: URL,
                              since: Date, excluding claimed: Set<URL>) -> URL? {
        switch agent {
        case .claude: return claudeTranscriptURL(workdir: workdir, home: home,
                                                  since: since, excluding: claimed)
        case .codex:  return codexTranscriptURL(workdir: workdir, home: home,
                                                 since: since, excluding: claimed)
        default:      return nil
        }
    }

    /// Locate an already-known transcript id. Used when restoring a History item
    /// so live status/title tracking can follow the actual JSONL file.
    static func transcriptURL(agent: AgentKind, workdir: String, home: URL, id: String) -> URL? {
        switch agent {
        case .claude:
            let url = home
                .appendingPathComponent(".claude/projects/\(claudeEncodedDir(for: workdir))/\(id).jsonl")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .codex:
            return codexTranscriptURL(home: home, id: id)
        default:
            return nil
        }
    }

    /// The resumable conversation id for a transcript URL.
    static func transcriptID(at url: URL, agent: AgentKind) -> String? {
        switch agent {
        case .codex:
            return codexMetadata(at: url).sessionID
        default:
            return url.deletingPathExtension().lastPathComponent
        }
    }

    /// Whether a past conversation should come back as a chat: written by
    /// anything but Claude Code in a terminal (`entrypoint` "cli") — a
    /// Sandshell chat (sdk-ts), the Claude app — or, for Codex, by an ACP
    /// client rather than its own CLI. Reads only the transcript's head.
    static func startedAsChat(at url: URL, agent: AgentKind) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let head = String(decoding: (try? fh.read(upToCount: 256 * 1024)) ?? Data(), as: UTF8.self)
        for line in head.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if agent == .codex {
                guard obj["type"] as? String == "session_meta" else { continue }
                let originator = ((obj["payload"] as? [String: Any])?["originator"] as? String ?? "").lowercased()
                return originator.contains("acp")
            }
            if let entrypoint = obj["entrypoint"] as? String { return entrypoint != "cli" }
        }
        return false
    }

    /// Live polling state: whether the agent is mid-turn plus its latest prompt.
    struct LiveState { var working: Bool; var latestPrompt: String? }
    static func liveState(in url: URL) -> LiveState? {
        url.pathComponents.contains(".codex")
            ? codexLiveState(in: url)
            : claudeLiveState(in: url)
    }

    /// Some transcript formats have time-based state: their "working" verdict
    /// can change from active to idle even if the file has not been written again.
    static func liveStateMayChangeWithoutFileWrite(agent: AgentKind) -> Bool {
        switch agent {
        case .codex: return true
        default: return false
        }
    }

    /// Result of an incremental file read — only the bytes appended since
    /// `fromOffset` are parsed, avoiding re-reading the entire transcript each tick.
    struct IncrementalLiveStateResult {
        var liveState: LiveState
        var newOffset: Int
        /// Last-seen message role (Codex only), cached for quiet-state rechecks.
        var lastRole: String?
    }

    /// Read only the bytes appended to `url` since `fromOffset` and return the
    /// updated live state. Returns `nil` when there are no new bytes or the new
    /// bytes contain no status-bearing lines (no state change needed).
    static func incrementalLiveState(in url: URL, fromOffset: Int) -> IncrementalLiveStateResult? {
        url.pathComponents.contains(".codex")
            ? codexIncrementalLiveState(in: url, fromOffset: fromOffset)
            : claudeIncrementalLiveState(in: url, fromOffset: fromOffset)
    }

    /// Whether a resumable conversation with `id` still exists.
    /// - Claude: the `<id>.jsonl` transcript is present for this workdir.
    /// - Codex: a rollout JSONL with `session_meta.id == id` exists.
    /// Returns false for all other agents (no resume equivalent).
    static func transcriptExists(agent: AgentKind, workdir: String, home: URL, id: String) -> Bool {
        switch agent {
        case .claude:
            let url = home
                .appendingPathComponent(".claude/projects/\(claudeEncodedDir(for: workdir))/\(id).jsonl")
            return FileManager.default.fileExists(atPath: url.path)
        case .codex:
            return codexTranscriptURL(home: home, id: id) != nil
        default:
            return false
        }
    }

    // MARK: - Claude

    private static func claudeTranscriptURL(workdir: String, home: URL,
                                             since: Date, excluding claimed: Set<URL>) -> URL? {
        let dir = home.appendingPathComponent(".claude/projects/\(claudeEncodedDir(for: workdir))")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return nil }
        let slack = since.addingTimeInterval(-5)
        return entries
            .filter { $0.pathExtension == "jsonl" && !claimed.contains($0) }
            .compactMap { url -> (URL, Date)? in
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let m, m >= slack else { return nil }
                return (url, m)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Incremental variant of `claudeLiveState`: reads only bytes from `fromOffset`
    /// to end-of-file, avoiding a full re-read on every tick.
    private static func claudeIncrementalLiveState(in url: URL,
                                                    fromOffset: Int) -> IncrementalLiveStateResult? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { fh.closeFile() }
        let fileSize = fh.seekToEndOfFile()
        let startOffset = UInt64(max(0, fromOffset))
        guard fileSize > startOffset else { return nil }
        fh.seek(toFileOffset: startOffset)
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
        let newOffset = Int(fileSize)
        let terminal: Set<String> = ["end_turn", "stop_sequence", "max_tokens"]
        var working: Bool?
        var latest: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            // A subagent's own turn-by-turn lines (Claude Code can inline them,
            // tagged isSidechain) belong to a nested conversation, not the
            // top-level one — never let them decide whether *this* session is done.
            if obj["isSidechain"] as? Bool == true { continue }
            switch obj["type"] as? String {
            case "user":
                working = true
                if let message = obj["message"] as? [String: Any],
                   let t = extractText(message["content"]), !t.isEmpty,
                   !t.hasPrefix("<") { latest = t }
            case "assistant":
                let stop = (obj["message"] as? [String: Any])?["stop_reason"] as? String
                working = !(stop.map(terminal.contains) ?? false)
            case "system":
                // Claude Code appends one of these after every assistant turn.
                // pendingBackgroundAgentCount is only present (and only ever
                // positive) while a dispatched subagent (the Agent/Task tool)
                // hasn't returned yet — the dispatching turn itself already
                // ended with stop_reason "end_turn" (it's a non-blocking async
                // call), so without this override the session reads as idle
                // for however long the subagent is still running. Unconditional
                // assignment: this line is always the freshest signal, and must
                // win even if this scan's only content is this one line.
                if obj["subtype"] as? String == "turn_duration",
                   (obj["pendingBackgroundAgentCount"] as? Int ?? 0) > 0 {
                    working = true
                }
            default:
                continue
            }
        }
        guard let working else { return nil }
        return IncrementalLiveStateResult(
            liveState: LiveState(working: working, latestPrompt: latest),
            newOffset: newOffset,
            lastRole: nil)
    }

    /// Incremental variant of `codexLiveState`: reads only new bytes, returning
    /// the updated role and a freshly-computed time-based working verdict.
    private static func codexIncrementalLiveState(in url: URL,
                                                   fromOffset: Int) -> IncrementalLiveStateResult? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { fh.closeFile() }
        let fileSize = fh.seekToEndOfFile()
        let startOffset = UInt64(max(0, fromOffset))
        guard fileSize > startOffset else { return nil }
        fh.seek(toFileOffset: startOffset)
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
        let newOffset = Int(fileSize)
        var lastRole: String?
        var latestPrompt: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  obj["type"] as? String == "response_item",
                  let (role, raw) = codexMessage(payload) else { continue }
            lastRole = role
            if role == "user" { latestPrompt = clean(raw) }
        }
        guard let lastRole else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let recentlyWritten = mtime.map { Date().timeIntervalSince($0) < 10 } ?? false
        let working = lastRole == "user" || (lastRole != "assistant" && recentlyWritten)
        return IncrementalLiveStateResult(
            liveState: LiveState(working: working, latestPrompt: latestPrompt),
            newOffset: newOffset,
            lastRole: lastRole)
    }

    /// End-of-turn detection: the turn is **done** when the last message is an
    /// assistant entry with a terminal stop reason; a trailing `user` entry or
    /// assistant `tool_use` means still working. Far more precise than mtime.
    private static func claudeLiveState(in url: URL) -> LiveState? {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let terminal: Set<String> = ["end_turn", "stop_sequence", "max_tokens"]
        var working: Bool?
        var latest: String?
        for line in data.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            // See claudeIncrementalLiveState — same reasoning, same fix.
            if obj["isSidechain"] as? Bool == true { continue }
            switch obj["type"] as? String {
            case "user":
                working = true
                if let message = obj["message"] as? [String: Any],
                   let text = extractText(message["content"]), !text.isEmpty,
                   !text.hasPrefix("<") { latest = text }
            case "assistant":
                let stop = (obj["message"] as? [String: Any])?["stop_reason"] as? String
                working = !(stop.map(terminal.contains) ?? false)
            case "system":
                if obj["subtype"] as? String == "turn_duration",
                   (obj["pendingBackgroundAgentCount"] as? Int ?? 0) > 0 {
                    working = true
                }
            default:
                continue
            }
        }
        guard let working else { return nil }
        return LiveState(working: working, latestPrompt: latest)
    }

    // MARK: - Codex

    /// Find the rollout JSONL for a newly-started Codex session matching this
    /// workdir. Codex writes the resume id and cwd into `session_meta` in the
    /// rollout file, so there is no side-channel dependency here.
    private static func codexTranscriptURL(workdir: String, home: URL,
                                            since: Date, excluding claimed: Set<URL>) -> URL? {
        let slack = since.addingTimeInterval(-5)
        return codexFiles(home: home)
            .filter { !claimed.contains($0.url) && $0.date >= slack }
            .compactMap { item -> (URL, Date)? in
                let meta = codexMetadata(at: item.url)
                guard meta.cwd == workdir else { return nil }
                return (item.url, item.date)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Find an existing rollout JSONL by Codex session id.
    private static func codexTranscriptURL(home: URL, id: String) -> URL? {
        codexFiles(home: home)
            .compactMap { item -> (URL, Date)? in
                codexMetadata(at: item.url).sessionID == id ? (item.url, item.date) : nil
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Live status from the rollout file only. This intentionally avoids the
    /// Codex SQLite state. The `working` flag is a heuristic: a trailing user
    /// message is definitely in-flight, otherwise recent file writes imply active
    /// streaming/tool work and quiet files are treated as idle.
    private static func codexLiveState(in url: URL) -> LiveState? {
        let meta = codexMetadata(at: url)
        guard meta.sawConversation else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let recentlyWritten = mtime.map { Date().timeIntervalSince($0) < 10 } ?? false
        let working = meta.lastRole == "user" || (meta.lastRole != "assistant" && recentlyWritten)
        return LiveState(working: working, latestPrompt: meta.latestPrompt)
    }

    // MARK: - History (browse / search)

    /// Lightweight summary of a conversation transcript, for the History browser.
    struct ConversationSummary {
        var firstPrompt: String?
        var cwd: String?
        var messageCount: Int
        var searchText: String
        /// The conversation's own id (Codex thread id from `session_meta`). `nil`
        /// for Claude, where the caller derives it from the transcript filename.
        var sessionID: String?
    }

    /// Summarize a conversation, dispatching on the agent's on-disk format:
    /// Claude's `~/.claude/.../*.jsonl` vs Codex's `~/.codex/sessions/**/*.jsonl`
    /// rollout files (a different line schema — see `codexSummary`).
    static func summary(at url: URL, agent: AgentKind) -> ConversationSummary? {
        switch agent {
        case .claude: return claudeSummary(at: url)
        case .codex:  return codexSummary(at: url)
        default:      return nil   // unknown format — don't guess it's Claude-shaped
        }
    }

    /// Ordered (role, text) messages for the History preview pane.
    static func messages(at url: URL, agent: AgentKind) -> [(role: String, text: String)] {
        switch agent {
        case .claude: return claudeMessages(at: url)
        case .codex:  return codexMessages(at: url)
        default:      return []
        }
    }

    private static func claudeSummary(at url: URL) -> ConversationSummary? {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var first: String?, cwd: String?, count = 0
        var text = SearchText()
        for line in data.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
            let type = obj["type"] as? String
            guard type == "user" || type == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let raw = rawText(msg["content"]), !raw.isEmpty else { continue }
            count += 1
            if type == "user", first == nil { first = clean(raw) }
            text.append(raw)
        }
        guard count > 0 else { return nil }
        return ConversationSummary(firstPrompt: first, cwd: cwd, messageCount: count,
                                   searchText: text.joined, sessionID: nil)
    }

    private static func claudeMessages(at url: URL) -> [(role: String, text: String)] {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [(String, String)] = []
        for line in data.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let raw = rawText(msg["content"]), !raw.isEmpty else { continue }
            out.append((type, raw))
        }
        return out
    }

    // MARK: - Codex history (rollout files)

    private struct CodexMetadata {
        var sessionID: String?
        var cwd: String?
        var firstPrompt: String?
        var latestPrompt: String?
        var lastRole: String?
        var messageCount = 0
        var searchText = SearchText()
        var sawConversation: Bool { messageCount > 0 }
    }

    /// All visible Codex rollout JSONL files, newest-ish first. Kept here so
    /// History, live tracking, and resume validation all use the same source.
    static func codexFiles(home: URL, limit: Int = 2_000) -> [(url: URL, date: Date)] {
        let fm = FileManager.default
        let sessions = home.appendingPathComponent(".codex/sessions")
        guard let enumerator = fm.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var files: [(url: URL, date: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url: url, date: date))
            if files.count >= limit { break }
        }
        return files.sorted { $0.date > $1.date }
    }

    private static func codexMetadata(at url: URL) -> CodexMetadata {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return CodexMetadata() }
        var meta = CodexMetadata()
        for line in data.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "session_meta":
                if meta.cwd == nil, let c = payload["cwd"] as? String { meta.cwd = c }
                if meta.sessionID == nil, let i = payload["id"] as? String { meta.sessionID = i }
            case "response_item":
                guard let (role, raw) = codexMessage(payload) else { continue }
                meta.messageCount += 1
                meta.lastRole = role
                if role == "user" {
                    let prompt = clean(raw)
                    if meta.firstPrompt == nil { meta.firstPrompt = prompt }
                    meta.latestPrompt = prompt
                }
                meta.searchText.append(raw)
            default:
                continue
            }
        }
        return meta
    }

    /// Parse a Codex rollout file (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).
    /// Each line is `{timestamp, type, payload}`; `session_meta` carries the cwd,
    /// and `response_item` lines with `payload.type == "message"` carry the turns.
    /// Early `user` messages are injected context wrappers (`<environment_context>`,
    /// `<user_instructions>`, …) and are skipped so the title is the real prompt.
    private static func codexSummary(at url: URL) -> ConversationSummary? {
        let meta = codexMetadata(at: url)
        guard meta.messageCount > 0 else { return nil }
        return ConversationSummary(firstPrompt: meta.firstPrompt, cwd: meta.cwd,
                                   messageCount: meta.messageCount,
                                   searchText: meta.searchText.joined,
                                   sessionID: meta.sessionID)
    }

    private static func codexMessages(at url: URL) -> [(role: String, text: String)] {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [(String, String)] = []
        for line in data.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "response_item",
                  let payload = obj["payload"] as? [String: Any],
                  let (role, raw) = codexMessage(payload) else { continue }
            out.append((role, raw))
        }
        return out
    }

    /// A single user/assistant turn from a Codex `response_item` payload, or nil
    /// for tool calls, reasoning, developer preamble, and injected `<…>` context.
    private static func codexMessage(_ payload: [String: Any]) -> (role: String, text: String)? {
        guard payload["type"] as? String == "message",
              let role = payload["role"] as? String,
              role == "user" || role == "assistant",
              let raw = codexText(payload["content"]), !raw.isEmpty else { return nil }
        if role == "user", raw.hasPrefix("<") { return nil }   // injected context
        return (role, raw)
    }

    /// Codex message content is an array of `{type, text}` blocks (`input_text`
    /// for user, `output_text` for assistant); join their `text` fields.
    private static func codexText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined(separator: " ")
        }
        return nil
    }

    private static func rawText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            return texts.isEmpty ? nil : texts.joined(separator: " ")
        }
        return nil
    }

    /// A conversation's text for body search, bounded: its opening (what it
    /// was about) and its latest stretch, ~200 KB in all.
    struct SearchText {
        private var head = "", tail: [String] = [], tailCount = 0
        private var headFull = false
        static let headLimit = 40_000, tailLimit = 160_000

        mutating func append(_ text: String) {
            if !headFull {
                if head.count + text.count <= Self.headLimit { head += text + "\n"; return }
                headFull = true
            }
            tail.append(text)
            tailCount += text.count + 1
            while tailCount > Self.tailLimit, tail.count > 1 { tailCount -= tail.removeFirst().count + 1 }
        }

        var joined: String { tail.isEmpty ? head : head + "…\n" + tail.joined(separator: "\n") + "\n" }
    }

    // MARK: - Claude helpers

    static func claudeEncodedDir(for workdir: String) -> String {
        String(workdir.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    private static func extractText(_ content: Any?) -> String? {
        if let s = content as? String { return clean(s) }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            return clean(texts.joined(separator: " "))
        }
        return nil
    }

    private static func clean(_ s: String) -> String? {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.isEmpty ? nil : oneLine
    }
}
