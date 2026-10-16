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
    static func parse(_ text: String, skippingEntrypoint skipped: String? = nil) -> Batch {
        var batch = Batch()
        let terminal: Set<String> = ["end_turn", "stop_sequence", "max_tokens"]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["isSidechain"] as? Bool != true,
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
            if let prompt = prompt(texts.joined(separator: "\n")) { batch.events.append(.user(prompt)) }
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

    /// How to name the writer in "Continued in …".
    static func writerName(_ entrypoint: String?) -> String {
        switch entrypoint {
        case "claude-desktop": return "the Claude app"
        case "cli": return "Claude Code in a terminal"
        case "claude-vscode", "vscode": return "VS Code"
        default: return "another app"
        }
    }

    /// Bytes appended since `offset`, up to the last complete line (a line
    /// still being written is picked up whole next time).
    static func readLines(_ url: URL, from offset: UInt64) -> (String, UInt64)? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > offset else { return nil }
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return nil }
        let complete = data[data.startIndex...lastNewline]
        guard let text = String(data: complete, encoding: .utf8) else { return nil }
        return (text, offset + UInt64(complete.count))
    }

    /// The file's inode, to notice it being replaced rather than appended to.
    static func fileID(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64
    }

    static func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
