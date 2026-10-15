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
    /// An image the agent sent as message content.
    case image(id: UUID, data: Data)
    /// Display only (the transcript view makes these): a run of consecutive
    /// tool calls, shown as one "Ran 3 commands ›" line.
    case toolGroup([ToolCall])

    var id: String {
        switch self {
        case .user(let id, _, _): return "user-\(id)"
        case .agentText(let id, _): return "text-\(id)"
        case .thought(let id, _): return "thought-\(id)"
        case .tool(let call): return "tool-\(call.id)"
        case .plan(let id, _): return "plan-\(id)"
        case .notice(let id, _, _): return "notice-\(id)"
        case .image(let id, _): return "image-\(id)"
        case .toolGroup(let calls): return "group-\(calls.first?.id ?? "")"
        }
    }

    struct ToolCall: Equatable {
        var id: String
        var title: String
        var kind: String
        var status: String          // pending | in_progress | completed | failed
        var output: String          // text content blocks, joined
        var diffs: [Diff]
        /// Image content (e.g. a Read of a PNG), decoded.
        var images: [Data] = []
        /// What the tool was given — the command, path or pattern — when it
        /// says more than the title.
        var input: String = ""
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
            if phase != .starting { isCatchingUp = false }
            if case .closed(let why) = phase, oldValue != phase { onClosed?(why) }
        }
    }
    @Published private(set) var permission: PendingPermission?
    @Published private(set) var modes: [Choice] = []
    @Published private(set) var currentMode: String?
    @Published private(set) var models: [Choice] = []
    @Published private(set) var currentModel: String?
    /// Context window fill and session cost, from `usage_update`.
    @Published private(set) var usage: Usage?
    /// Slash commands and skills the agent advertises (`available_commands_update`).
    struct Command: Equatable { let name: String; let description: String; let hint: String? }
    @Published private(set) var commands: [Command] = []
    /// Unrecognized `session/update` kinds seen (spike: what else the adapter sends).
    @Published private(set) var unknownUpdates: Set<String> = []
    /// Restarting the agent so it sees turns another app added (`.starting` meanwhile).
    @Published private(set) var isCatchingUp = false

    /// The agent's conversation id (the Claude session UUID) once known —
    /// persisted as the sidebar session's `transcriptID`.
    var onSessionID: ((String) -> Void)?
    /// Turn started (true) / finished (false), for the sidebar + header status.
    var onWorkingChange: ((Bool) -> Void)?
    /// Each prompt the user sends (the sidebar names sessions after them).
    var onPrompt: ((String) -> Void)?
    /// The agent stopped for good (not signed in, exited): why.
    var onClosed: ((String) -> Void)?
    /// A ready agent's process went away on its own (e.g. the Mac slept and its
    /// `sbx exec` connection died): relaunching would pick the conversation up.
    var onUnexpectedExit: (() -> Void)?
    /// Closed, but not for a reason a relaunch can't fix (no credentials, no
    /// ACP): the chat can offer Reconnect.
    private(set) var canReconnect = false
    /// Down, and a relaunch would bring it back.
    var needsReconnect: Bool { if case .closed = phase { canReconnect } else { false } }

    let title: String
    /// Which agent's ACP entry point runs (`SbxCommand.acpAgents`).
    let agent: AgentKind
    /// Set when the chat can't work before it starts (e.g. no credentials for
    /// the agent): shown instead of launching anything.
    private let unavailable: String?
    private var resumeID: String?
    private let sbxProxyAuth: Bool
    private let tag: SbxCommand.ProcessTag
    private let containerName: String
    /// Host path of the session's working directory (mounted at the same path).
    let workdir: String
    private let home: String
    private let mcpURL: URL?
    private var connection: ACPConnection?
    private var sessionID: String?
    private var pumpTask: Task<Void, Never>?
    /// The model list came as ACP's older `models` field (Gemini CLI), which is
    /// switched with `session/set_model` rather than a config option.
    private var modelViaSetModel = false
    /// Last `sandshell: …` line our launch script wrote to stderr — the reason
    /// to show when the agent exits before it ever answered.
    private var launchError: String?

    /// `close()` ran: nothing may start the agent again (a pending catch-up).
    private var isClosed = false

    /// Following the transcript for turns another app writes (Claude only).
    private var follower: Task<Void, Never>?
    private var followURL: URL?
    private var followOffset: UInt64 = 0
    /// Our own turn just ended; its last lines are still landing in the file.
    private var ownTurnEnded: Date?
    private var sawOwnTurn = false
    /// Another app added turns the agent hasn't loaded: reload before sending.
    private var agentIsBehind = false
    /// The other app's turn state, and when it last wrote.
    private var otherWriterWorking = false
    private var otherWriterLastWrite: Date?
    /// The transcript's last items came from another app (one "Continued in" notice per run).
    private var inExternalRun = false

    init(title: String, agent: AgentKind = .claude, containerName: String, workdir: String, home: String,
         mcpURL: URL?, resumeID: String? = nil, sbxProxyAuth: Bool = false, sessionID: UUID = UUID(),
         unavailable: String? = nil) {
        self.title = title
        self.agent = agent
        self.unavailable = unavailable
        self.tag = SbxCommand.ProcessTag(session: sessionID)
        self.sbxProxyAuth = sbxProxyAuth
        self.resumeID = resumeID
        self.containerName = containerName
        self.workdir = workdir
        self.home = home
        self.mcpURL = mcpURL
    }

    // MARK: Lifecycle

    func start() {
        guard !isClosed else { return }
        launchError = nil
        if let unavailable {
            notice(unavailable, isError: true)
            phase = .closed("\(title) can’t start — see above.")
            return
        }
        guard let args = SbxCommand.acpArguments(agent: agent, containerName: containerName, workdir: workdir,
                                                 home: home, mcpURL: mcpURL, sbxProxyAuth: sbxProxyAuth, tag: tag)
        else {
            phase = .closed("\(title) can’t run as a chat (no ACP support).")
            return
        }
        let conn = ACPConnection(executable: PathFixer.sbxPath(), arguments: args)
        connection = conn
        do { try conn.start() } catch {
            phase = .closed("Couldn’t launch sbx: \(error.localizedDescription)")
            return
        }
        let auth = agent == .claude ? (sbxProxyAuth ? "sbx proxy" : "~/.claude credentials") : "sbx proxy"
        Log.info(.sbx, "chat: launched \(agent.rawValue) ACP agent in “\(containerName)” at \(workdir) (auth: \(auth))")
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
                applyModels(result["models"])
                applyConfig(result["configOptions"])
                if let sid = sessionID { onSessionID?(sid) }
                phase = .ready
                startFollowing()
                if let (text, attachments) = queued {
                    queued = nil
                    send(text: text, attachments: attachments)
                }
            } catch {
                if Self.isAuthRequired(error), let help = Self.credentialHelp(for: agent) {
                    notice(help, isError: true)
                    phase = .closed("\(title) isn’t signed in — see above.")
                } else if case .closed = phase {
                    // The process already exited and said why.
                } else {
                    canReconnect = true
                    phase = .closed("Agent failed to start: \(launchError ?? error.localizedDescription)")
                }
                connection?.terminate()
            }
        }
    }

    /// ACP's "authentication required" error (the agent has no usable credential).
    static func isAuthRequired(_ error: Error) -> Bool {
        guard let rpc = error as? ACPConnection.RPCError else { return false }
        return rpc.code == -32000 || rpc.message.localizedCaseInsensitiveContains("authentication required")
    }

    /// A prompt failure that means the provider refused the (missing or placeholder) credential.
    static func isCredentialRejection(_ message: String) -> Bool {
        ["API key not valid", "API_KEY_INVALID", "invalid_api_key", "Incorrect API key", "401 Unauthorized"]
            .contains { message.localizedCaseInsensitiveContains($0) }
    }

    /// The sbx secret service an agent's API traffic is authenticated with
    /// (sbx's proxy injects the real credential; nothing secret enters the sandbox).
    static func credentialService(for agent: AgentKind) -> String? {
        switch agent {
        case .claude: return "anthropic"
        case .codex: return "openai"
        case .gemini: return "google"
        default: return nil
        }
    }

    /// What to tell the user when an agent has no credential: how to give sbx one.
    static func credentialHelp(for agent: AgentKind) -> String? {
        let rebuild = " A sandbox picks up a new credential when it’s created, so then rebuild this agent’s sandbox "
            + "(Settings ▸ Sandboxes ▸ Rebuild) and restart the chat."
        switch agent {
        case .claude:
            return "Claude isn’t signed in for this sandbox. Run `sbx secret set anthropic --oauth` in Terminal "
                + "(or sign in to Claude Code on this Mac)." + rebuild
        case .codex:
            return "Codex has no OpenAI credential for this sandbox. Run `sbx secret set openai --oauth` in Terminal "
                + "to sign in with ChatGPT, or `sbx secret set openai` to store an API key." + rebuild
        case .gemini:
            return "Gemini has no Google credential for this sandbox. Run `sbx secret set google` in Terminal "
                + "and paste a Gemini API key (aistudio.google.com/apikey)." + rebuild
        default:
            return nil
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
        isClosed = true
        stopFollowing()
        pumpTask?.cancel()
        let wasRunning = connection != nil
        connection?.terminate()
        connection = nil
        // The adapter exits on stdin EOF; reap anyway (its claude child, tools).
        if wasRunning { SbxClient.reapSessionProcesses(container: containerName, match: tag.pairs[1]) }
    }

    // MARK: User actions

    func send(text: String, attachments: [ChatAttachment]) {
        guard phase == .ready, let conn = connection, let sid = sessionID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if agentIsBehind {
            // The agent loaded the conversation before another app added to it:
            // reload so the reply sees those turns (and the transcript stays one line).
            catchUp(thenSend: (text, attachments))
            return
        }
        inExternalRun = false
        sawOwnTurn = true   // however short the turn, the follower skips past it
        items.append(.user(id: UUID(), text: trimmed, attachments: attachments.map(\.displayName)))
        if !trimmed.isEmpty { onPrompt?(trimmed) }
        stopped = false

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
                if agent != .claude, Self.isAuthRequired(error) || Self.isCredentialRejection(message),
                   let help = Self.credentialHelp(for: agent) {
                    // e.g. Gemini's raw 400 "API key not valid" JSON: say how to fix it.
                    notice(help, isError: true)
                } else if case .agentText(_, let said)? = items.last,
                   message.hasSuffix(said.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    // already shown as the reply
                } else {
                    notice(message, isError: true)
                }
            }
            if case .running = phase { phase = .ready }
        }
    }

    /// Send `text` as soon as the session is ready (Shortcuts / Services
    /// "send now"); sends immediately if it already is.
    func sendWhenReady(text: String, attachments: [ChatAttachment]) {
        if phase == .ready { send(text: text, attachments: attachments); return }
        if let (earlier, files) = queued {
            queued = ([earlier, text].filter { !$0.isEmpty }.joined(separator: "\n\n"), files + attachments)
        } else {
            queued = (text, attachments)
        }
    }
    private var queued: (String, [ChatAttachment])?

    /// The user stopped the current turn. The adapter answers the prompt as
    /// cancelled before it has flushed the text it already had buffered; those
    /// late chunks are dropped (until the next prompt) instead of streaming in
    /// under "Stopped: cancelled".
    private var stopped = false

    func cancel() {
        guard case .running = phase, let sid = sessionID else { return }
        stopped = true
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
                if modelViaSetModel {
                    _ = try await conn.request("session/set_model", ["sessionId": .string(sid), "modelId": .string(id)])
                    return
                }
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

    // MARK: Following other writers

    /// Another app is mid-turn in this conversation (wrote in the last two
    /// minutes and hasn't finished): sending now would fork it.
    var otherAppIsWorking: Bool {
        otherWriterWorking && (otherWriterLastWrite.map { Date().timeIntervalSince($0) < 120 } ?? false)
    }

    /// Who else is writing, for messages ("the Claude app").
    private(set) var otherWriterName = "another app"

    private func startFollowing() {
        guard agent == .claude, follower == nil, let sid = sessionID else { return }
        let url = URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/projects/\(TranscriptReader.claudeEncodedDir(for: workdir))/\(sid).jsonl")
        followURL = url
        followOffset = ClaudeTranscriptTail.fileSize(url)
        ownTurnEnded = nil
        sawOwnTurn = false
        follower = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await self.followTick()
            }
        }
    }

    private func stopFollowing() {
        follower?.cancel()
        follower = nil
    }

    private func followTick() async {
        guard let url = followURL else { return }
        // Our own turns are written to the same file: skip past them, with a
        // moment after each for its last lines to land.
        if phase == .running { sawOwnTurn = true; return }
        if sawOwnTurn { sawOwnTurn = false; ownTurnEnded = Date(); return }
        if let ended = ownTurnEnded {
            guard Date().timeIntervalSince(ended) >= 2 else { return }
            ownTurnEnded = nil
            followOffset = ClaudeTranscriptTail.fileSize(url)
            return
        }
        guard phase == .ready else { return }
        let offset = followOffset
        guard let (text, newOffset) = await Task.detached(priority: .utility, operation: {
            ClaudeTranscriptTail.readLines(url, from: offset)
        }).value, phase == .ready, followOffset == offset else { return }
        followOffset = newOffset
        // Lines our own agent writes (sdk-ts) between turns — background-task
        // notices and the like — aren't another app's.
        applyExternal(ClaudeTranscriptTail.parse(text, skippingEntrypoint: "sdk-ts"))
    }

    /// Show what another app added, as if it had happened here.
    func applyExternal(_ batch: ClaudeTranscriptTail.Batch) {
        guard batch.sawConversation else { return }
        agentIsBehind = true
        otherWriterLastWrite = Date()
        if let working = batch.working { otherWriterWorking = working }
        if let e = batch.entrypoint { otherWriterName = ClaudeTranscriptTail.writerName(e) }
        guard !batch.events.isEmpty else { return }
        if !inExternalRun {
            inExternalRun = true
            notice("Continued in \(otherWriterName)", isError: false)
        }
        for event in batch.events {
            switch event {
            case .user(let text):
                items.append(.user(id: UUID(), text: text, attachments: []))
            case .text(let mid, let text):
                let id = "ext-" + mid
                if case .agentText(id, let t)? = items.last {
                    items[items.count - 1] = .agentText(id: id, text: t + "\n\n" + text)
                } else {
                    items.append(.agentText(id: id, text: text))
                }
            case .thought(let mid, let text):
                items.append(.thought(id: "ext-\(mid)-\(items.count)", text: text))
            case .toolUse(let call):
                upsert(.tool(call))
            case .toolResult(let id, let output, let images, let failed):
                guard var call = toolCall(id: id) else { continue }
                call.status = failed ? "failed" : "completed"
                call.output = output
                call.images = images
                upsert(.tool(call))
            }
        }
    }

    /// Restart the agent on the same conversation (`session/load` replays it,
    /// now with the other app's turns), then send.
    private func catchUp(thenSend message: (String, [ChatAttachment])) {
        guard let sid = sessionID else { return }
        Log.info(.sbx, "chat: \(sid) changed in \(otherWriterName); reloading before sending")
        agentIsBehind = false
        inExternalRun = false
        stopFollowing()
        queued = message
        isCatchingUp = true
        pumpTask?.cancel()
        connection?.terminate()
        connection = nil
        resumeID = sid
        items = []
        phase = .starting
        let container = containerName, match = tag.pairs[1]
        Task { [weak self] in
            await SbxClient.reapSessionProcessesAndWait(container: container, match: match)
            // Closed meanwhile (Restart, Terminal, deleted): start nothing.
            self?.start()
        }
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
            if line.hasPrefix("sandshell: ") { launchError = String(line.dropFirst("sandshell: ".count)) }
        case .closed(let status):
            permission = nil
            if case .closed = phase { return }   // already explained (e.g. not signed in)
            let wasUp = phase == .ready || phase == .running
            canReconnect = true
            if let launchError {
                phase = .closed(launchError.prefix(1).uppercased() + launchError.dropFirst())
            } else {
                phase = .closed(status == 0 ? "The agent exited." : "The agent exited (\(status)).")
            }
            if wasUp, !isClosed {
                Log.info(.sbx, "chat: agent for \(sessionID ?? "?") exited unexpectedly (\(status))")
                onUnexpectedExit?()
            }
        }
    }

    private func apply(_ u: JSONValue) {
        switch u["sessionUpdate"]?.string ?? "" {
        case "agent_message_chunk":
            if !stopped { appendText(u, thought: false) }
        case "agent_thought_chunk":
            if !stopped { appendText(u, thought: true) }
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
            if let raw = u["rawInput"]?.object, let summary = Self.inputSummary(raw) { call.input = summary }
            if let content = u["content"]?.array {
                call.output = content.compactMap { $0["content"]?["text"]?.string }.joined(separator: "\n")
                call.images = content.compactMap { block -> Data? in
                    let inner = block["content"] ?? block
                    guard inner["type"]?.string == "image", let b64 = inner["data"]?.string else { return nil }
                    return Data(base64Encoded: b64)
                }
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
            commands = (u["availableCommands"]?.array ?? []).compactMap {
                guard let name = $0["name"]?.string else { return nil }
                return Command(name: name, description: $0["description"]?.string ?? "",
                               hint: $0["input"]?["hint"]?.string)
            }
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
        if u["content"]?["type"]?.string == "image", let b64 = u["content"]?["data"]?.string,
           let data = Data(base64Encoded: b64) {
            items.append(.image(id: UUID(), data: data))
            return
        }
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

    /// The most telling field of a tool's raw input, for display.
    private static func inputSummary(_ raw: [String: JSONValue]) -> String? {
        for key in ["command", "file_path", "path", "pattern", "url", "query", "description"] {
            if let v = raw[key]?.string, !v.isEmpty { return v }
        }
        return nil
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

    /// ACP's older session `models` field (`availableModels` + `currentModelId`),
    /// still what Gemini CLI sends; a `model` config option, when present, wins.
    private func applyModels(_ m: JSONValue?) {
        guard let list = m?["availableModels"]?.array, !list.isEmpty else { return }
        models = list.compactMap {
            guard let id = $0["modelId"]?.string else { return nil }
            return Choice(id: id, name: $0["name"]?.string ?? id)
        }
        currentModel = m?["currentModelId"]?.string
        modelViaSetModel = true
    }

    /// Session config options (ACP); only the model selector is surfaced so far.
    private func applyConfig(_ options: JSONValue?) {
        guard let model = options?.array?.first(where: { $0["id"]?.string == "model" }) else { return }
        models = (model["options"]?.array ?? []).compactMap {
            guard let id = $0["value"]?.string else { return nil }
            return Choice(id: id, name: $0["name"]?.string ?? id)
        }
        currentModel = model["currentValue"]?.string
        modelViaSetModel = false
    }
}

private extension JSONValue {
    func merging(_ other: [String: JSONValue]) -> JSONValue {
        guard case .object(var o) = self else { return self }
        for (k, v) in other { o[k] = v }
        return .object(o)
    }
}
