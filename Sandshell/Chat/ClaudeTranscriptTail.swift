import Foundation

/// Lines another client (the Claude app, Claude Code in a terminal) appended to
/// a Claude transcript a chat has open, as chat events — so the chat follows a
/// conversation that's still being written elsewhere.
struct ClaudeTranscriptTail {
    enum Event: Equatable {
        case user(String)
        case text(messageID: String, String)
        case thought(messageID: String, String)
        case toolUse(ChatItem.ToolCall)
        case toolResult(id: String, output: String, images: [Data], failed: Bool)
    }

    struct Batch {
        var events: [Event] = []
        /// Any conversation line at all (the agent's copy is now behind).
        var sawConversation = false
        /// The writer's turn state after these lines (nil = unchanged).
        var working: Bool?
        /// Who wrote them (`entrypoint`: claude-desktop, cli, sdk-ts…).
        var entrypoint: String?
    }

    /// `skippingEntrypoint`: lines written by that client (the chat's own agent) are ignored.
    /// `sidechains`: read a subagent's own transcript (every line is one).
    static func parse(_ text: String, skippingEntrypoint skipped: String? = nil, sidechains: Bool = false) -> Batch {
        var batch = Batch()
        let terminal = TranscriptReader.claudeTurnEndingStopReasons
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  sidechains || obj["isSidechain"] as? Bool != true,
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            let entrypoint = obj["entrypoint"] as? String
            if let skipped, entrypoint == skipped { continue }
            batch.sawConversation = true
            if let entrypoint { batch.entrypoint = entrypoint }
            if type == "assistant" {
                let stop = message["stop_reason"] as? String
                batch.working = !(stop.map(terminal.contains) ?? false)
                let mid = message["id"] as? String ?? obj["uuid"] as? String ?? UUID().uuidString
                for block in message["content"] as? [[String: Any]] ?? [] {
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String, !t.isEmpty { batch.events.append(.text(messageID: mid, t)) }
                    case "thinking":
                        // Often only a signature (the text redacted): nothing to show.
                        if let t = block["thinking"] as? String, !t.isEmpty { batch.events.append(.thought(messageID: mid, t)) }
                    case "tool_use":
                        guard let id = block["id"] as? String else { continue }
                        let name = block["name"] as? String ?? "Tool"
                        let input = (block["input"] as? [String: Any]).flatMap(inputSummary) ?? ""
                        let short = input.split(separator: "\n").first.map(String.init) ?? ""
                        batch.events.append(.toolUse(.init(
                            id: id, title: short.isEmpty || short.count > 100 ? name : "\(name) \(short)",
                            kind: name.lowercased(), status: "in_progress", output: "", diffs: [], input: input)))
                    default:
                        continue
                    }
                }
                continue
            }
            // user: a prompt (string or text blocks) or tool results.
            if obj["isMeta"] as? Bool == true { continue }
            batch.working = true
            if let s = message["content"] as? String {
                if let prompt = prompt(s) { batch.events.append(.user(prompt)) }
                continue
            }
            var texts: [String] = []
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String { texts.append(t) }
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String else { continue }
                    var output = "", images: [Data] = []
                    if let s = block["content"] as? String {
                        output = s
                    } else {
                        for part in block["content"] as? [[String: Any]] ?? [] {
                            if part["type"] as? String == "text", let t = part["text"] as? String {
                                output += (output.isEmpty ? "" : "\n") + t
                            } else if part["type"] as? String == "image",
                                      let b64 = (part["source"] as? [String: Any])?["data"] as? String,
                                      let data = Data(base64Encoded: b64) {
                                images.append(data)
                            }
                        }
                    }
                    batch.events.append(.toolResult(id: id, output: output, images: images,
                                                    failed: block["is_error"] as? Bool == true))
                default:
                    continue
                }
            }
            // Each block on its own: IDE context or a reminder rides along as
            // a block of its own, before or after what the person typed.
            let typed = texts.compactMap(prompt)
            if !typed.isEmpty { batch.events.append(.user(typed.joined(separator: "\n"))) }
        }
        return batch
    }

    /// What a person typed: not a harness wrapper (`<command-name>`,
    /// `<task-notification>`, `<system-reminder>`…), not blank.
    private static func prompt(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.hasPrefix("<") ? nil : t
    }

    /// The most telling field of a tool's input (as the ACP adapter shows it).
    private static func inputSummary(_ input: [String: Any]) -> String? {
        for key in ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt"] {
            if let v = input[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    /// Claude Code's title for the conversation in transcript `text`: the
    /// latest `{"type":"custom-title","customTitle":…}` (renamed in Claude
    /// itself), else the latest `{"type":"ai-title","aiTitle":…}` (the title it
    /// generates during the first turn, what `claude --resume` lists). Nil
    /// when it has none (yet).
    static func title(in text: String) -> String? {
        var custom: String?, generated: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true)
        where line.contains("-title\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            func value(_ key: String) -> String? {
                (obj[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            switch obj["type"] as? String {
            case "custom-title": custom = value("customTitle") ?? custom
            case "ai-title": generated = value("aiTitle") ?? generated
            default: continue
            }
        }
        return custom ?? generated
    }

    /// `title(in:)` of the transcript at `url`.
    static func title(at url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap(title(in:))
    }

    /// A fork of transcript `text` at the reply ending in `replyText`: its lines
    /// up to and including that reply's, filed under session `newID`. The
    /// source's titles are left behind (the fork's are its own). Nil when no
    /// reply holds that text. `cut` is the reply's line (0-based) of `lines`.
    static func fork(_ text: String, upTo replyText: String, newID: String) -> (text: String, cut: Int, lines: Int)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // The reply's last words identify its transcript line (streamed text == stored text).
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = String(trimmed.suffix(80))
        guard !needle.isEmpty, let cut = lines.lastIndex(where: { line in
            guard line.contains("\"assistant\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return false }
            return blocks.contains { ($0["text"] as? String)?.contains(needle) == true }
        }) else { return nil }

        var out = ""
        for line in lines[...cut] {
            guard var obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let type = obj["type"] as? String, type == "ai-title" || type == "custom-title" { continue }
            if obj["sessionId"] != nil { obj["sessionId"] = newID }
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
               let json = String(data: data, encoding: .utf8) { out += json + "\n" }
        }
        return (out, cut, lines.count)
    }

    /// How to name the writer in "Continued in …".
    static func writerName(_ entrypoint: String?) -> String {
        switch entrypoint {
        case "claude-desktop": "the Claude app"
        case "cli": "Claude Code in a terminal"
        case "claude-vscode", "vscode": "VS Code"
        default: "another app"
        }
    }

    /// Bytes appended since `offset`, up to the last complete line (a line
    /// still being written is picked up whole next time).
    static func readLines(_ url: URL, from offset: UInt64) -> (String, UInt64)? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > offset else { return nil }
        // Start on a line boundary: after an in-place rewrite (Claude's
        // cost-state line) the offset can land mid-line, even mid-character.
        let start = offset > 0 ? offset - 1 : 0
        try? fh.seek(toOffset: start)
        guard var data = try? fh.readToEnd() else { return nil }
        if offset > 0 {
            guard let first = data.first else { return nil }
            if first == 0x0A {
                data = data.dropFirst()
            } else {
                // Mid-line: drop the rest of that line.
                guard let nl = data.firstIndex(of: 0x0A) else { return nil }
                data = data[data.index(after: nl)...]
            }
        }
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return nil }
        let complete = data[data.startIndex...lastNewline]
        // (Indices count from `start`: slices keep the read's own.)
        return (String(decoding: complete, as: UTF8.self), start + UInt64(lastNewline + 1))
    }

    /// The file's inode, to notice it being replaced rather than appended to.
    static func fileID(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64
    }

    static func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
