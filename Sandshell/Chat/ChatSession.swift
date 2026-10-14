import AppKit
import Foundation

/// One transcript entry, transport-agnostic: an ACP adapter (or any future
/// engine) is folded into these, and the transcript view only renders these.
enum ChatItem: Identifiable, Equatable {
    case user(id: UUID, text: String, attachments: [String])
    case agentText(id: String, text: String)
    case thought(id: String, text: String)
    case tool(ToolCall)
    case plan(id: UUID, entries: [PlanEntry])
    case notice(id: UUID, text: String, isError: Bool)

    var id: String {
        switch self {
        case .user(let id, _, _): return "user-\(id)"
        case .agentText(let id, _): return "text-\(id)"
        case .thought(let id, _): return "thought-\(id)"
        case .tool(let call): return "tool-\(call.id)"
        case .plan(let id, _): return "plan-\(id)"
        case .notice(let id, _, _): return "notice-\(id)"
        }
    }

    struct ToolCall: Equatable {
        var id: String
        var title: String
        var kind: String
        var status: String          // pending | in_progress | completed | failed
        var output: String          // text content blocks, joined
        var diffs: [Diff]
    }

    struct Diff: Equatable {
        var path: String
        var oldText: String?
        var newText: String
    }

    struct PlanEntry: Equatable {
        var content: String
        var status: String
    }
}

/// A permission prompt waiting on the user (ACP `session/request_permission`).
struct PendingPermission: Equatable {
    struct Option: Equatable { let id: String; let name: String; let kind: String }
    let id: JSONValue          // JSON-RPC request id to answer
    let title: String
    let options: [Option]
}

/// Something the user attached in the composer.
struct ChatAttachment: Equatable {
    enum Kind: Equatable { case file(URL), image(data: Data, mimeType: String, name: String) }
    let kind: Kind
    var displayName: String {
        switch kind {
        case .file(let url): return url.lastPathComponent
        case .image(_, _, let name): return name
        }
    }
}

/// A native chat session driving one ACP agent process in a sandbox.
@MainActor
final class ChatSession: ObservableObject {
    enum Phase: Equatable { case starting, ready, running, closed(String) }

    struct Usage: Equatable { var used: Int; var size: Int; var cost: Double? }
    struct Choice: Equatable { let id: String; let name: String }

    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var phase: Phase = .starting {
        didSet {
            if (oldValue == .running) != (phase == .running) { onWorkingChange?(phase == .running) }
        }
    }
    @Published private(set) var permission: PendingPermission?
    @Published private(set) var modes: [Choice] = []
    @Published private(set) var currentMode: String?
    @Published private(set) var models: [Choice] = []
    @Published private(set) var currentModel: String?
    /// Context window fill and session cost, from `usage_update`.
    @Published private(set) var usage: Usage?
    @Published private(set) var commands: [String] = []
    /// Unrecognized `session/update` kinds seen (spike: what else the adapter sends).
    @Published private(set) var unknownUpdates: Set<String> = []

    /// The agent's conversation id (the Claude session UUID) once known —
    /// persisted as the sidebar session's `transcriptID`.
    var onSessionID: ((String) -> Void)?
    /// Turn started (true) / finished (false), for the sidebar + header status.
    var onWorkingChange: ((Bool) -> Void)?
    /// Each prompt the user sends (the sidebar names sessions after them).
    var onPrompt: ((String) -> Void)?

    let title: String
    private let resumeID: String?
    private let sbxProxyAuth: Bool
    private let containerName: String
    private let workdir: String
    private let home: String
    private let mcpURL: URL?
    private var connection: ACPConnection?
    private var sessionID: String?
    private var pumpTask: Task<Void, Never>?

    init(title: String, containerName: String, workdir: String, home: String, mcpURL: URL?,
         resumeID: String? = nil, sbxProxyAuth: Bool = false) {
        self.title = title
        self.sbxProxyAuth = sbxProxyAuth
        self.resumeID = resumeID
        self.containerName = containerName
        self.workdir = workdir
        self.home = home
        self.mcpURL = mcpURL
    }

    // MARK: Lifecycle

    func start() {
        let args = SbxCommand.acpArguments(containerName: containerName, workdir: workdir, home: home, mcpURL: mcpURL,
                                           sbxProxyAuth: sbxProxyAuth)
        let conn = ACPConnection(executable: PathFixer.sbxPath(), arguments: args)
        connection = conn
        do { try conn.start() } catch {
            phase = .closed("Couldn’t launch sbx: \(error.localizedDescription)")
            return
        }
        Log.info(.sbx, "chat: launched ACP adapter in “\(containerName)” at \(workdir) (auth: \(sbxProxyAuth ? "sbx proxy" : "~/.claude credentials"))")
        pumpTask = Task { [weak self] in
            for await event in conn.incoming { self?.handle(event) }
        }
        Task {
            do {
                _ = try await conn.request("initialize", [
                    "protocolVersion": 1,
                    "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                ])
                let result = try await openSession(conn)
                applyModes(result["modes"])
                applyConfig(result["configOptions"])
                if let sid = sessionID { onSessionID?(sid) }
                phase = .ready
            } catch {
                phase = .closed("Agent failed to start: \(error.localizedDescription)")
            }
        }
    }

    /// Resume the prior conversation when there is one (`session/load` replays
    /// it as updates), else start fresh.
    private func openSession(_ conn: ACPConnection) async throws -> JSONValue {
        if let resumeID {
            do {
                let result = try await conn.request("session/load", [
                    "sessionId": .string(resumeID), "cwd": .string(workdir), "mcpServers": []])
                sessionID = resumeID
                return result
            } catch {
                Log.info(.sbx, "chat: session/load \(resumeID) failed (\(error.localizedDescription)); starting fresh")
                notice("Couldn’t restore the earlier conversation — started a new one.", isError: false)
            }
        }
        let result = try await conn.request("session/new", ["cwd": .string(workdir), "mcpServers": []])
        sessionID = result["sessionId"]?.string
        return result
    }

    func close() {
        pumpTask?.cancel()
        connection?.terminate()
        connection = nil
    }

    // MARK: User actions

    func send(text: String, attachments: [ChatAttachment]) {
        guard phase == .ready, let conn = connection, let sid = sessionID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        items.append(.user(id: UUID(), text: trimmed, attachments: attachments.map(\.displayName)))
        if !trimmed.isEmpty { onPrompt?(trimmed) }

        var blocks: [JSONValue] = []
        if !trimmed.isEmpty { blocks.append(["type": "text", "text": .string(trimmed)]) }
        for a in attachments {
            switch a.kind {
            case .file(let url):
                // Mounted host paths appear at the same path in the sandbox.
                blocks.append(["type": "resource_link", "uri": .string(url.absoluteString),
                               "name": .string(url.lastPathComponent)])
            case .image(let data, let mime, _):
                blocks.append(["type": "image", "mimeType": .string(mime),
                               "data": .string(data.base64EncodedString())])
            }
        }
        phase = .running
        Task {
            do {
                let result = try await conn.request("session/prompt", ["sessionId": .string(sid), "prompt": .array(blocks)])
                if let reason = result["stopReason"]?.string, reason != "end_turn" {
                    notice("Stopped: \(reason)", isError: false)
                }
            } catch {
                // The agent often streams the same failure as its reply first
                // ("Failed to refresh…" then "Internal error: Failed to refresh…");
                // only add the notice when it says something new.
                let message = error.localizedDescription
                if case .agentText(_, let said)? = items.last,
                   message.hasSuffix(said.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    // already shown as the reply
                } else {
                    notice(message, isError: true)
                }
            }
            if case .running = phase { phase = .ready }
        }
    }

    func cancel() {
        guard case .running = phase, let sid = sessionID else { return }
        connection?.notify("session/cancel", ["sessionId": .string(sid)])
        if let p = permission { answerPermission(p, optionID: nil) }
    }

    /// Answer the pending permission prompt; nil = cancelled.
    func answerPermission(_ p: PendingPermission, optionID: String?) {
        let outcome: JSONValue = optionID.map { ["outcome": "selected", "optionId": .string($0)] }
            ?? ["outcome": "cancelled"]
        connection?.respond(id: p.id, result: ["outcome": outcome])
        if permission == p { permission = nil }
    }

    func setModel(_ id: String) {
        guard let conn = connection, let sid = sessionID, id != currentModel else { return }
        currentModel = id
        Task {
            do {
                let result = try await conn.request("session/set_config_option", [
                    "sessionId": .string(sid), "configId": "model", "value": .string(id)])
                applyConfig(result["configOptions"])
            } catch {
                notice("Couldn’t switch model: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func setMode(_ id: String) {
        guard let conn = connection, let sid = sessionID else { return }
        currentMode = id
        Task { _ = try? await conn.request("session/set_mode", ["sessionId": .string(sid), "modeId": .string(id)]) }
    }

    // MARK: Incoming

    private func handle(_ event: ACPConnection.Incoming) {
        switch event {
        case .notification("session/update", let params):
            if let update = params["update"] { apply(update) }
        case .notification(let method, _):
            if !method.hasPrefix("_") { Log.info(.sbx, "chat: unhandled notification \(method)") }
        case .request(let id, "session/request_permission", let params):
            let opts = (params["options"]?.array ?? []).compactMap { o -> PendingPermission.Option? in
                guard let oid = o["optionId"]?.string else { return nil }
                return .init(id: oid, name: o["name"]?.string ?? oid, kind: o["kind"]?.string ?? "")
            }
            let call = params["toolCall"]
            let title = call?["title"]?.string ?? toolTitle(id: call?["toolCallId"]?.string) ?? "Allow this action?"
            if let call { apply(call.merging(["sessionUpdate": "tool_call_update"])) }
            permission = PendingPermission(id: id, title: title, options: opts)
        case .request(let id, let method, _):
            connection?.respondError(id: id, code: -32601, message: "\(method) is not supported by Sandshell")
        case .stderr(let line):
            Log.info(.sbx, "chat[acp]: \(line)")
        case .closed(let status):
            phase = .closed(status == 0 ? "The agent exited." : "The agent exited (\(status)).")
            permission = nil
        }
    }

    private func apply(_ u: JSONValue) {
        switch u["sessionUpdate"]?.string ?? "" {
        case "agent_message_chunk":
            appendText(u, thought: false)
        case "agent_thought_chunk":
            appendText(u, thought: true)
        case "user_message_chunk":
            // Our own prompts are shown when sent (and echoed mid-turn); outside a
            // turn these are a `session/load` history replay.
            guard phase != .running, let text = u["content"]?["text"]?.string else { return }
            if case .user(let id, let t, let a)? = items.last {
                items[items.count - 1] = .user(id: id, text: t + text, attachments: a)
            } else {
                items.append(.user(id: UUID(), text: text, attachments: []))
            }
        case "usage_update":
            if let used = u["used"]?.int, let size = u["size"]?.int {
                usage = Usage(used: used, size: size, cost: u["cost"]?["amount"]?.double)
            }
        case "config_option_update":
            applyConfig(u["configOptions"])
        case "tool_call", "tool_call_update":
            guard let tid = u["toolCallId"]?.string else { return }
            var call = toolCall(id: tid) ?? .init(id: tid, title: "", kind: "", status: "pending", output: "", diffs: [])
            if let t = u["title"]?.string { call.title = t }
            if let k = u["kind"]?.string { call.kind = k }
            if let s = u["status"]?.string { call.status = s }
            if let content = u["content"]?.array {
                call.output = content.compactMap { $0["content"]?["text"]?.string }.joined(separator: "\n")
                call.diffs = content.filter { $0["type"]?.string == "diff" }.map {
                    .init(path: $0["path"]?.string ?? "", oldText: $0["oldText"]?.string, newText: $0["newText"]?.string ?? "")
                }
            }
            upsert(.tool(call))
        case "plan":
            let entries = (u["entries"]?.array ?? []).map {
                ChatItem.PlanEntry(content: $0["content"]?.string ?? "", status: $0["status"]?.string ?? "")
            }
            if let idx = items.lastIndex(where: { if case .plan = $0 { return true }; return false }) {
                if case .plan(let id, _) = items[idx] { items[idx] = .plan(id: id, entries: entries) }
            } else {
                items.append(.plan(id: UUID(), entries: entries))
            }
        case "available_commands_update":
            commands = (u["availableCommands"]?.array ?? []).compactMap { $0["name"]?.string }
        case "current_mode_update":
            currentMode = u["currentModeId"]?.string
        case let other:
            if !unknownUpdates.contains(other) {
                unknownUpdates.insert(other)
                Log.info(.sbx, "chat: unhandled session/update \(other): \(u.compactString.prefix(400))")
            }
        }
    }

    private func appendText(_ u: JSONValue, thought: Bool) {
        guard let text = u["content"]?["text"]?.string else { return }
        let mid = u["messageId"]?.string ?? "current"
        if let last = items.last {
            switch (last, thought) {
            case (.agentText(let id, let t), false) where id == mid:
                items[items.count - 1] = .agentText(id: id, text: t + text); return
            case (.thought(let id, let t), true) where id == mid:
                items[items.count - 1] = .thought(id: id, text: t + text); return
            default: break
            }
        }
        items.append(thought ? .thought(id: mid, text: text) : .agentText(id: mid, text: text))
    }

    private func toolCall(id: String) -> ChatItem.ToolCall? {
        for item in items.reversed() { if case .tool(let c) = item, c.id == id { return c } }
        return nil
    }

    private func toolTitle(id: String?) -> String? { id.flatMap { toolCall(id: $0)?.title } }

    private func upsert(_ item: ChatItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) { items[idx] = item } else { items.append(item) }
    }

    private func notice(_ text: String, isError: Bool) {
        items.append(.notice(id: UUID(), text: text, isError: isError))
    }

    private func applyModes(_ m: JSONValue?) {
        guard let m else { return }
        modes = (m["availableModes"]?.array ?? []).compactMap {
            guard let id = $0["id"]?.string else { return nil }
            return Choice(id: id, name: $0["name"]?.string ?? id)
        }
        currentMode = m["currentModeId"]?.string
    }

    /// Session config options (ACP); only the model selector is surfaced so far.
    private func applyConfig(_ options: JSONValue?) {
        guard let model = options?.array?.first(where: { $0["id"]?.string == "model" }) else { return }
        models = (model["options"]?.array ?? []).compactMap {
            guard let id = $0["value"]?.string else { return nil }
            return Choice(id: id, name: $0["name"]?.string ?? id)
        }
        currentModel = model["currentValue"]?.string
    }
}

private extension JSONValue {
    func merging(_ other: [String: JSONValue]) -> JSONValue {
        guard case .object(var o) = self else { return self }
        for (k, v) in other { o[k] = v }
        return .object(o)
    }
}
