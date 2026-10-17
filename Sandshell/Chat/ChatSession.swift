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
    /// The files a turn changed (Claude's checkpoints), with Undo; `restored`
    /// once they've been put back.
    case fileChanges(turn: String, paths: [String], restored: Bool)

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
        case .fileChanges(let turn, _, _): return "changes-\(turn)"
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
            if (oldValue == .running) != (phase == .running), !retryingTurn { onWorkingChange?(phase == .running) }
            if phase != .starting { isCatchingUp = false }
            if oldValue == .running, phase == .ready, let next = afterTurn {
                afterTurn = nil
                DispatchQueue.main.async { next() }
            } else if oldValue == .running, phase == .ready, queued != nil {
                // A message sent while the turn ran goes now.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.phase == .ready, let (text, files) = self.queued else { return }
                    self.queued = nil
                    self.send(text: text, attachments: files)
                }
            }
            if case .closed(let why) = phase, oldValue != phase { onClosed?(why) }
        }
    }
    @Published private(set) var permission: PendingPermission? { didSet { reportWaiting() } }
    /// A question the agent is waiting on (AskUserQuestion, Codex's
    /// request_user_input, an MCP server's form or sign-in link).
    @Published private(set) var question: AgentQuestion? { didSet { reportWaiting() } }
    /// Waiting on the person (a question or a permission is up), or not.
    var onWaitingChange: ((Bool) -> Void)?
    private var wasWaiting = false
    private func reportWaiting() {
        let waiting = question != nil || permission != nil
        guard waiting != wasWaiting else { return }
        wasWaiting = waiting
        onWaitingChange?(waiting)
    }
    private var waitingQuestions: [AgentQuestion] = []
    /// The agent needs the person (a question or a permission): for a notification.
    var onNeedsInput: ((String) -> Void)?
    /// Permission requests that came in while one was already being asked:
    /// each gets its turn (an unanswered one would hang the agent's turn).
    private var waitingPermissions: [PendingPermission] = []
    @Published private(set) var modes: [Choice] = []
    @Published private(set) var currentMode: String?
    @Published private(set) var models: [Choice] = []
    @Published private(set) var currentModel: String?
    /// Context window fill and session cost, from `usage_update`.
    @Published private(set) var usage: Usage? { didSet { onUsage?() } }
    /// The model the agent last answered with (the adapter's `_claude/model`).
    private(set) var liveModel: String?
    /// The workspace's model and effort this agent was launched with (Claude).
    let launchModel: String?
    private(set) var launchEffort: String?
    /// Usage or the live model changed (the pane's Claude readout follows).
    var onUsage: (() -> Void)?
    /// Run once when the current turn ends (a model change waiting to relaunch).
    var afterTurn: (() -> Void)?
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
    /// Seconds from launch to ready, and whether it started from a warm spare.
    private(set) var readyAfter: TimeInterval?
    private(set) var startedWarm = false
    /// What its processes carry in their environment, to reap them by (a
    /// claimed spare's tag, which isn't the session's own).
    var processMatch: String { tag.pairs[1] }
    /// Tags the agent's processes for reaping (a claimed spare brings its own).
    private var tag: SbxCommand.ProcessTag
    /// The session's own id (`tag` is a warm spare's once one is claimed).
    private let ownSessionID: UUID
    /// A fresh launch tag for a relaunch, so a reap of the last launch can't reach it.
    private func newLaunchTag() { tag = SbxCommand.ProcessTag(session: ownSessionID) }
    let containerName: String
    /// Host path of the session's working directory (mounted at the same path).
    let workdir: String
    private let home: String
    private let mcpURL: URL?
    private var connection: ACPConnection?
    private(set) var sessionID: String?
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
    /// Another live writer of this conversation, from Claude Code's session
    /// registry (nil: none, or no registry to read).
    @Published private(set) var otherWriter: ClaudeSessionRegistry.Entry?
    /// The registry could be read at all (else fall back to the transcript's word).
    private var registryReadable = false
    /// Where to read the registry from (self-tests point it at a scratch copy).
    var registryHome: String?
    /// Called when another app that was mid-turn here finishes (or quits).
    var onOtherAppIdle: (() -> Void)?
    /// Wakes the follower as soon as the transcript changes on disk.
    private var fileWatch: DispatchSourceFileSystemObject?
    private var followFileID: UInt64?
    private var tickScheduled = false

    init(title: String, agent: AgentKind = .claude, containerName: String, workdir: String, home: String,
         mcpURL: URL?, resumeID: String? = nil, sbxProxyAuth: Bool = false, sessionID: UUID = UUID(),
         unavailable: String? = nil, model: String? = nil, effort: String? = nil) {
        self.launchModel = model
        self.launchEffort = effort
        self.title = title
        self.agent = agent
        self.unavailable = unavailable
        self.tag = SbxCommand.ProcessTag(session: sessionID)
        self.ownSessionID = sessionID
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
        stopped = false   // a reload after a stopped turn replays every reply
        if let unavailable {
            notice(unavailable, isError: true)
            phase = .closed("\(title) can’t start — see above.")
            return
        }
        guard let args = SbxCommand.acpArguments(agent: agent, containerName: containerName, workdir: workdir,
                                                 home: home, mcpURL: mcpURL, sbxProxyAuth: sbxProxyAuth, tag: tag,
                                                 claudeModel: agent == .claude ? launchModel : nil)
        else {
            phase = .closed("\(title) can’t run as a chat (no ACP support).")
            return
        }
        // A warm spare for the same sandbox, folder and settings, if one's ready
        // — for new conversations only: a spare started before another app
        // wrote to a conversation can load a stale copy of it.
        let spare = resumeID == nil ? ACPSparePool.shared.claim(args) : nil
        let conn: ACPConnection
        if let spare {
            conn = spare.connection
            tag = spare.tag
        } else {
            conn = ACPConnection(executable: PathFixer.sbxPath(), arguments: args)
            do { try conn.start() } catch {
                phase = .closed("Couldn’t launch sbx: \(error.localizedDescription)")
                return
            }
        }
        connection = conn
        let auth = agent == .claude ? (sbxProxyAuth ? "sbx proxy" : "~/.claude credentials") : "sbx proxy"
        Log.info(.sbx, "chat: launched \(agent.rawValue) ACP agent in “\(containerName)” at \(workdir) (auth: \(auth))")
        let launchedAt = Date()
        // An agent that never answers (its sandbox restarted under it, say)
        // would leave the chat "Starting…" forever: give up on it, so the
        // pane offers Reconnect. The first start may install the adapter.
        installingAdapter = false
        launchSeen = false
        Task { [weak self, weak conn] in
            // 4 minutes, or 12 while it installs the adapter first (slow networks).
            var waited = 0
            while waited < 12 * 60 {
                try? await Task.sleep(for: .seconds(10))
                waited += 10
                guard let self, let conn, self.connection === conn, self.phase == .starting else { return }
                // Not even the launch script's first line: `sbx exec` never got
                // in (seen right after a sandbox's kit setup). Try once more.
                if waited == 50, !self.launchSeen, self.stuckLaunchRetries == 0 {
                    self.stuckLaunchRetries += 1
                    Log.error(.sbx, "chat: sbx exec into “\(self.containerName)” hasn't started; launching again")
                    self.pumpTask?.cancel()
                    self.connection = nil
                    conn.terminate()
                    let container = self.containerName, match = self.tag.pairs[1]
                    // The relaunch gets its own launch tag, so this reap can't reach it.
                    self.newLaunchTag()
                    await SbxClient.reapSessionProcessesAndWait(container: container, match: match)
                    self.start()
                    return
                }
                if waited >= 4 * 60, !self.installingAdapter { break }
            }
            guard let self, let conn, self.connection === conn, self.phase == .starting else { return }
            Log.error(.sbx, "chat: \(self.agent.rawValue) agent didn't answer; giving up on it")
            self.launchError = "The agent didn’t start (no answer in \(waited / 60) minutes)."
            conn.terminate()
        }
        pumpTask = Task { [weak self] in
            for await event in conn.incoming { self?.handle(event) }
        }
        Task {
            do {
                if spare == nil { _ = try await conn.request("initialize", Self.initializeParams) }
                let result = try await openSession(conn)
                applyModes(result["modes"])
                // New conversations start in Auto where the agent offers it;
                // a resumed one keeps the mode it was in.
                if sessionID != resumeID, modes.contains(where: { $0.id == "auto" }),
                   currentMode != "auto", let sid = sessionID {
                    do {
                        _ = try await conn.request("session/set_mode", ["sessionId": .string(sid), "modeId": "auto"])
                        currentMode = "auto"
                    } catch {
                        Log.info(.sbx, "chat: couldn't start in Auto mode: \(error.localizedDescription)")
                    }
                }
                applyModels(result["models"])
                applyConfig(result["configOptions"])
                await applyRememberedCodexModel()
                // The workspace's effort, like a terminal's `--effort` (Claude).
                if agent == .claude, let effort = launchEffort, let sid = sessionID {
                    do {
                        let r = try await conn.request("session/set_config_option", [
                            "sessionId": .string(sid), "configId": "effort", "value": .string(effort)])
                        applyConfig(r["configOptions"])
                    } catch {
                        Log.info(.sbx, "chat: couldn't set effort \(effort): \(error.localizedDescription)")
                    }
                }
                // Closed (or relaunched) while it was starting: it isn't ours any more.
                guard !isClosed, connection === conn else { conn.terminate(); return }
                // Died during the optional requests above (they only log): the
                // exit path says so; a waiting message stays queued for a reconnect.
                if case .closed = phase { return }
                guard conn.isRunning else { return }
                if catchUpMissedTurn() { return }
                if let sid = sessionID { onSessionID?(sid) }
                readyAfter = Date().timeIntervalSince(launchedAt)
                startedWarm = spare != nil
                Log.info(.sbx, String(format: "chat: %@ ready %.1fs after launch%@", agent.rawValue,
                                      Date().timeIntervalSince(launchedAt), spare != nil ? " (warm)" : ""))
                phase = .ready
                warmSpare()
                startFollowing()
                if let (text, attachments) = queued {
                    queued = nil
                    send(text: text, attachments: attachments)
                }
            } catch {
                guard !isClosed, connection === conn else { return }
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

    /// We declare two of the JetBrains AIR extensions the Claude adapter
    /// implements: background-task updates (to list and stop them) and per-turn
    /// file-change reports (which also turn on Claude Code's file checkpoints,
    /// what Undo rewinds to). Other agents ignore the `_meta`.
    static let initializeParams: JSONValue = [
        "protocolVersion": 1,
        "clientCapabilities": [
            "fs": ["readTextFile": false, "writeTextFile": false], "terminal": false,
            // Questions from the agent: forms (AskUserQuestion, Codex's
            // request_user_input, MCP forms) and links (an MCP server's sign-in).
            "elicitation": ["form": [:], "url": [:]],
            "_meta": ["jetbrains": ["air": ["version": 1, "capabilities": ["asyncTasks", "agentFileChangeReport"]]]],
        ],
    ]

    /// Have the next chat like this one start warm.
    private func warmSpare() {
        let spareTag = SbxCommand.ProcessTag(session: UUID())
        guard !isClosed, let args = SbxCommand.acpArguments(
            agent: agent, containerName: containerName, workdir: workdir, home: home, mcpURL: mcpURL,
            sbxProxyAuth: sbxProxyAuth, tag: spareTag, claudeModel: agent == .claude ? launchModel : nil) else { return }
        ACPSparePool.shared.warm(args, tag: spareTag, container: containerName)
    }

    func close() {
        isClosed = true
        // Nothing it does from here on is news to anyone (a send or a start
        // still finishing would otherwise report "finished" or "stopped").
        onUsage = nil; onSessionID = nil; onWorkingChange = nil; onPrompt = nil
        onClosed = nil; onUnexpectedExit = nil; onOtherAppIdle = nil; onNeedsInput = nil; onWaitingChange = nil
        queued = nil
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
        if !trimmed.isEmpty, !retryingTurn { onPrompt?(trimmed) }
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
        var params: JSONValue = ["sessionId": .string(sid), "prompt": .array(blocks)]
        if agent == .claude {
            // Ask for the turn's file-change report, keyed by our own id.
            let turn = "t" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            turns[turn] = Turn(id: turn, prompt: trimmed,
                               transcriptOffset: transcriptURL.map(ClaudeTranscriptTail.fileSize) ?? 0)
            params = ["sessionId": .string(sid), "prompt": .array(blocks),
                      "_meta": ["jetbrains": ["air": ["version": 1,
                                "agentFileChangeReportRequest": ["version": 1, "requestId": .string(turn)]]]]]
        }
        Task {
            do {
                let result = try await conn.request("session/prompt", params)
                // Codex on a model this sign-in can't use: try the next one.
                if case .agentText(let id, let said)? = items.last, codexRetries < 4,
                   let next = codexFallbackModel(after: said), !isClosed, connection === conn {
                    codexRetries += 1
                    let refused = currentModel.map(Self.modelBase) ?? "That model"
                    // Switch first: if that fails, the refusal and the prompt stay as they are.
                    if await switchModel(next), !isClosed, connection === conn {
                        items.removeAll { $0.id == ChatItem.agentText(id: id, text: "").id }
                        if case .user? = items.last { items.removeLast() }
                        var run = codexNotice ?? (UUID(), [])
                        run.refused.append(refused)
                        codexNotice = run
                        let names = run.refused.count == 1 ? run.refused[0]
                            : run.refused.dropLast().joined(separator: ", ") + " and " + run.refused.last!
                        upsert(.notice(id: run.id, text: "\(names) \(run.refused.count == 1 ? "isn’t" : "aren’t") available "
                                       + "with a ChatGPT sign-in — using \(Self.modelBase(next)).", isError: false))
                        UserDefaults.standard.set(next, forKey: Self.codexModelKey)
                        retryingTurn = true
                        phase = .ready
                        send(text: text, attachments: attachments)
                        retryingTurn = false
                        return
                    }
                }
                codexRetries = 0
                codexNotice = nil
                if let reason = result["stopReason"]?.string, reason != "end_turn" {
                    notice("Stopped: \(reason)", isError: false)
                }
            } catch {
                guard !isClosed, connection === conn else { return }
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
            guard !isClosed, connection === conn else { return }
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
    private var queued: (String, [ChatAttachment])? { didSet { hasQueued = queued != nil } }
    /// Hand over the message waiting to be sent (a reconnect carries it over).
    func takeQueued() -> (text: String, attachments: [ChatAttachment])? {
        guard let (text, attachments) = queued else { return nil }
        queued = nil
        return (text, attachments)
    }

    /// A message is waiting for the turn (or the start) to finish.
    @Published private(set) var hasQueued = false

    /// From the composer: send now, or queue it behind the running turn (or a
    /// start); false when the chat can't take it (closed), so the draft stays.
    func submit(text: String, attachments: [ChatAttachment]) -> Bool {
        switch phase {
        case .ready:
            // A message still waiting to go (its drain is a tick behind) goes
            // first, with this one after it in the same prompt.
            if let (earlier, files) = queued {
                queued = nil
                send(text: [earlier, text].filter { !$0.isEmpty }.joined(separator: "\n\n"), attachments: files + attachments)
            } else {
                send(text: text, attachments: attachments)
            }
            return true
        case .running, .starting: sendWhenReady(text: text, attachments: attachments); return true
        case .closed: return false
        }
    }

    /// The user stopped the current turn. The adapter answers the prompt as
    /// cancelled before it has flushed the text it already had buffered; those
    /// late chunks are dropped (until the next prompt) instead of streaming in
    /// under "Stopped: cancelled".
    private var stopped = false

    func cancel() {
        guard case .running = phase, let sid = sessionID else { return }
        stopped = true
        connection?.notify("session/cancel", ["sessionId": .string(sid)])
        // Every question the stopped turn was waiting on is answered "cancelled".
        for p in waitingPermissions { connection?.respond(id: p.id, result: ["outcome": ["outcome": "cancelled"]]) }
        waitingPermissions = []
        if let p = permission { answerPermission(p, optionID: nil) }
        for q in waitingQuestions { connection?.respond(id: q.rpcID, result: AgentQuestion.Answer.cancel.result) }
        waitingQuestions = []
        if let q = question { answerQuestion(q, .cancel) }
    }

    /// Answer the agent's question (and keep the exchange in the transcript).
    func answerQuestion(_ q: AgentQuestion, _ answer: AgentQuestion.Answer) {
        if case .url(let url, _) = q.mode, case .accept = answer { NSWorkspace.shared.open(url) }
        connection?.respond(id: q.rpcID, result: answer.result)
        notice(q.summary(of: answer), isError: false)
        waitingQuestions.removeAll { $0 == q }
        if question == q { question = waitingQuestions.isEmpty ? nil : waitingQuestions.removeFirst() }
    }

    /// Answer the pending permission prompt; nil = cancelled.
    func answerPermission(_ p: PendingPermission, optionID: String?) {
        let outcome: JSONValue = optionID.map { ["outcome": "selected", "optionId": .string($0)] }
            ?? ["outcome": "cancelled"]
        connection?.respond(id: p.id, result: ["outcome": outcome])
        waitingPermissions.removeAll { $0 == p }
        if permission == p { permission = waitingPermissions.isEmpty ? nil : waitingPermissions.removeFirst() }
    }

    func setModel(_ id: String) {
        Task { _ = await switchModel(id) }
    }

    /// Switch the session's model; false (with a notice) if the agent refused.
    @discardableResult
    private func switchModel(_ id: String) async -> Bool {
        guard let conn = connection, let sid = sessionID, id != currentModel else { return true }
        let previous = currentModel
        currentModel = id
        do {
            if modelViaSetModel {
                _ = try await conn.request("session/set_model", ["sessionId": .string(sid), "modelId": .string(id)])
                return true
            }
            let result = try await conn.request("session/set_config_option", [
                "sessionId": .string(sid), "configId": "model", "value": .string(id)])
            applyConfig(result["configOptions"])
            return true
        } catch {
            if currentModel == id { currentModel = previous }   // still on the old one
            notice("Couldn’t switch model: \(error.localizedDescription)", isError: true)
            return false
        }
    }

    // MARK: Codex models a ChatGPT sign-in can use

    /// Codex chats run the adapter's own (newer) codex, whose default model can
    /// be one a ChatGPT sign-in can't use. The model that worked is remembered,
    /// and models that refused are skipped.
    private static let codexModelKey = "codexChatModel"
    private static let codexRefusedKey = "codexChatRefusedModels"
    private var codexRetries = 0
    /// Re-sending a turn on another model: still the same turn to everyone else.
    private var retryingTurn = false
    /// One notice for a run of refusals, updated as it goes.
    private var codexNotice: (id: UUID, refused: [String])?

    /// "gpt-6.1-sol[medium]" → "gpt-6.1-sol".
    private static func modelBase(_ id: String) -> String { id.split(separator: "[").first.map(String.init) ?? id }

    /// Start a Codex chat on the model that worked before (if it's offered),
    /// or off one known to refuse this sign-in.
    private func applyRememberedCodexModel() async {
        guard agent == .codex else { return }
        let refused = Set(UserDefaults.standard.stringArray(forKey: Self.codexRefusedKey) ?? [])
        if let saved = UserDefaults.standard.string(forKey: Self.codexModelKey), models.contains(where: { $0.id == saved }) {
            await switchModel(saved)
        } else if let current = currentModel, refused.contains(Self.modelBase(current)), let next = codexCandidate(refused: refused) {
            await switchModel(next)
        }
    }

    private func codexCandidate(refused: Set<String>) -> String? {
        let level = currentModel.flatMap { m in m.firstIndex(of: "[").map { String(m[$0...]) } } ?? ""
        let candidates = models.map(\.id).filter { !refused.contains(Self.modelBase($0)) }
        return candidates.first { !level.isEmpty && $0.hasSuffix(level) } ?? candidates.first
    }

    /// The reply was Codex saying the model isn't available with a ChatGPT
    /// account: the next model it offers (same reasoning level where it can),
    /// or nil when it's another reply or nothing's left to try.
    private func codexFallbackModel(after reply: String) -> String? {
        guard agent == .codex, reply.contains("not supported when using Codex with a ChatGPT account") else { return nil }
        var refused = Set(UserDefaults.standard.stringArray(forKey: Self.codexRefusedKey) ?? [])
        if let current = currentModel { refused.insert(Self.modelBase(current)) }
        UserDefaults.standard.set(Array(refused), forKey: Self.codexRefusedKey)
        return codexCandidate(refused: refused)
    }

    /// Claude's effort level, live (`nil` = Claude's default).
    func setEffort(_ level: String?) {
        launchEffort = level
        onUsage?()
        guard let conn = connection, let sid = sessionID else { return }
        Task {
            do {
                let r = try await conn.request("session/set_config_option", [
                    "sessionId": .string(sid), "configId": "effort", "value": .string(level ?? "default")])
                applyConfig(r["configOptions"])
            } catch {
                notice("Couldn’t change the effort level: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func setMode(_ id: String) {
        guard let conn = connection, let sid = sessionID else { return }
        currentMode = id
        Task { _ = try? await conn.request("session/set_mode", ["sessionId": .string(sid), "modeId": .string(id)]) }
    }

    // MARK: Turns: Undo (rewind), background tasks, MCP — Claude, via the adapter wrapper

    /// One prompt we sent: our file-report id, its text (to find its uuid in
    /// the transcript, which is what Claude Code rewinds to).
    struct Turn { let id: String; let prompt: String; var transcriptOffset: UInt64 = 0; var uuid: String? }
    private var turns: [String: Turn] = [:]

    /// A background task the agent reported (shell, subagent, monitor).
    struct BackgroundTaskState: Equatable {
        let id: String
        var name = ""
        var description = ""
        var state = "running"
        var summary = ""
        var canStop = false
        var isRunning: Bool { !["completed", "failed", "stopped", "killed", "cancelled"].contains(state) }
    }
    @Published private(set) var backgroundTasks: [String: BackgroundTaskState] = [:]

    /// An MCP server as Claude Code sees it in this session.
    struct MCPServer: Equatable, Identifiable {
        var name: String
        var status: String          // connected | failed | needs-auth | pending | disabled
        var error: String?
        var scope: String?
        var source: String?
        var detail: String?         // command or URL
        var version: String?
        var tools: [String]
        var id: String { name }
    }
    @Published private(set) var mcpServers: [MCPServer]?

    struct RewindResult { var canRewind: Bool; var error: String?; var files: [String]; var insertions: Int; var deletions: Int }

    /// The sandshell-claude kit's wrapper is running this chat's agent: Undo
    /// and MCP status work (the launch says so on stderr).
    @Published private(set) var hasExtras = false
    /// The launch is installing the adapter first (the start deadline waits longer).
    private var installingAdapter = false
    /// The launch script has said its first line (the exec got into the sandbox).
    private var launchSeen = false
    private var stuckLaunchRetries = 0

    /// One request to the adapter wrapper (in the sandshell-claude kit).
    private func extra(_ request: [String: JSONValue]) async throws -> JSONValue {
        guard let conn = connection, let sid = sessionID else { throw ExtraError("The chat isn’t connected.") }
        let json = try JSONEncoder().encode(JSONValue.object(request))
        let b64 = json.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let result = try await conn.request("_session/async_task/stop",
                                            ["sessionId": .string(sid), "asyncTaskId": .string("sandshell:" + b64)])
        return result["_meta"]?["sandshell"] ?? .null
    }
    struct ExtraError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// Stop a background task (the adapter's own request).
    func stopBackgroundTask(_ id: String) async -> Bool {
        guard let conn = connection, let sid = sessionID else { return false }
        let result = try? await conn.request("_session/async_task/stop",
                                             ["sessionId": .string(sid), "asyncTaskId": .string(id)])
        let stopped = result?["stopped"]?.bool ?? false
        if stopped, var task = backgroundTasks[id] { task.state = "stopped"; backgroundTasks[id] = task }
        return stopped
    }

    /// What undoing `turn` would put back (nothing changes yet).
    func previewRewind(_ turn: String) async throws -> RewindResult {
        try await rewind(turn, dryRun: true)
    }

    /// Put the files `turn` changed back as they were before it.
    func rewind(_ turn: String) async throws -> RewindResult {
        let result = try await rewind(turn, dryRun: false)
        if result.canRewind, case .fileChanges(turn, let paths, _)? = items.first(where: { $0.id == "changes-\(turn)" }) {
            upsert(.fileChanges(turn: turn, paths: paths, restored: true))
        }
        return result
    }

    private func rewind(_ turn: String, dryRun: Bool) async throws -> RewindResult {
        guard let uuid = await promptUUID(turn) else {
            throw ExtraError("Couldn’t find that message in the conversation’s transcript.")
        }
        let r = try await extra(["op": "rewind", "uuid": .string(uuid), "dryRun": .bool(dryRun)])
        return RewindResult(canRewind: r["canRewind"]?.bool ?? false, error: r["error"]?.string,
                            files: r["filesChanged"]?.array?.compactMap(\.string) ?? [],
                            insertions: r["insertions"]?.int ?? 0, deletions: r["deletions"]?.int ?? 0)
    }

    /// The transcript's uuid for the prompt of `turn` (the adapter stamps each
    /// prompt with one; Claude Code checkpoints files per prompt uuid).
    private func promptUUID(_ turn: String) async -> String? {
        guard var t = turns[turn], let url = transcriptURL else { return nil }
        if let uuid = t.uuid { return uuid }
        let taken = Set(turns.values.compactMap(\.uuid))
        let (prompt, offset) = (t.prompt, t.transcriptOffset)
        let uuid = await Task.detached(priority: .utility) { () -> String? in
            // The prompt's line comes after where the transcript ended when it
            // was sent: the first user line there that's a prompt (not a tool
            // result or meta), matching its text when it has some.
            // (Else, from the start — Claude rewrites its last line in place,
            // so the file can shift a little — the matching prompt nearest that
            // offset: a repeated "continue" mustn't pick an earlier turn's.)
            func promptLines(from start: UInt64) -> [(id: String, said: String, at: UInt64)] {
                guard let (text, _) = ClaudeTranscriptTail.readLines(url, from: start) else { return [] }
                var found: [(String, String, UInt64)] = []
                var at = start
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    defer { at += UInt64(line.utf8.count + 1) }
                    guard line.contains("\"type\":\"user\""),
                          let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          o["isMeta"] as? Bool != true, let id = o["uuid"] as? String, !taken.contains(id),
                          let message = o["message"] as? [String: Any] else { continue }
                    let content: String
                    if let s = message["content"] as? String { content = s }
                    else if let blocks = message["content"] as? [[String: Any]] {
                        if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { continue }
                        content = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                    } else { continue }
                    found.append((id, content.trimmingCharacters(in: .whitespacesAndNewlines), at))
                }
                return found
            }
            func matches(_ said: String) -> Bool { prompt.isEmpty || said.hasPrefix(String(prompt.prefix(200))) }
            if offset > 0, let hit = promptLines(from: offset).first(where: { matches($0.said) }) { return hit.id }
            // An attachment-only prompt has no text to find it by away from its offset.
            guard !prompt.isEmpty || offset == 0 else { return nil }
            return promptLines(from: 0).filter { matches($0.said) }
                .min { $0.at.distance(to: offset).magnitude < $1.at.distance(to: offset).magnitude }?.id
        }.value
        t.uuid = uuid
        turns[turn] = t
        return uuid
    }

    /// This conversation's Claude transcript on the host.
    private var transcriptURL: URL? {
        sessionID.map { URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/projects/\(TranscriptReader.claudeEncodedDir(for: workdir))/\($0).jsonl") }
    }

    /// Ask Claude Code which MCP servers this session has, and how they're doing.
    /// Claude Code's /context breakdown (nil until asked, or when the
    /// sandbox's kit predates it — then `contextUsageUnavailable` says why).
    @Published private(set) var contextUsage: ContextUsage?
    @Published private(set) var contextUsageUnavailable: String?

    func refreshContextUsage(detail: String = "full") async {
        guard hasExtras else {
            contextUsageUnavailable = "Needs the sandshell-claude kit (Settings ▸ Kits)."
            return
        }
        do {
            let v = try await extra(["op": "contextUsage", "detail": .string(detail)])
            if let usage = ContextUsage(v) {
                if usage != contextUsage { contextUsage = usage }
                contextUsageUnavailable = nil
            }
        } catch {
            // An older wrapper (sandbox not rebuilt since): it answers "Unknown Sandshell request".
            contextUsageUnavailable = error.localizedDescription.contains("Unknown Sandshell request")
                ? "Rebuild this sandbox to see the breakdown (its kit predates it)." : error.localizedDescription
        }
    }

    /// Compact the conversation now (Claude Code's /compact).
    func compact() {
        guard phase == .ready else { return }
        send(text: "/compact", attachments: [])
    }

    func refreshMCP() async throws {
        mcpServers = Self.mcpServers(try await extra(["op": "mcpStatus"]))
    }

    func reconnectMCP(_ name: String) async throws {
        mcpServers = Self.mcpServers(try await extra(["op": "mcpReconnect", "name": .string(name)]))
    }

    func setMCP(_ name: String, enabled: Bool) async throws {
        mcpServers = Self.mcpServers(try await extra(["op": "mcpToggle", "name": .string(name), "enabled": .bool(enabled)]))
    }

    static func mcpServers(_ value: JSONValue) -> [MCPServer] {
        (value.array ?? []).compactMap { s in
            guard let name = s["name"]?.string else { return nil }
            let config = s["config"]
            let detail = config?["url"]?.string
                ?? config?["command"]?.string.map { ([$0] + (config?["args"]?.array?.compactMap(\.string) ?? [])).joined(separator: " ") }
            return MCPServer(name: name, status: s["status"]?.string ?? "pending", error: s["error"]?.string,
                             scope: s["scope"]?.string, source: s["source"]?.string, detail: detail,
                             version: s["serverInfo"]?["version"]?.string,
                             tools: s["tools"]?.array?.compactMap { $0["name"]?.string } ?? [])
        }
    }

    // MARK: Following other writers

    /// Another app is mid-turn in this conversation (wrote in the last two
    /// minutes and hasn't finished): sending now would fork it.
    var otherAppIsWorking: Bool {
        // The registry knows; the transcript only hints (it said "working" and
        // wrote in the last two minutes).
        if registryReadable { return otherWriter?.isBusy ?? false }
        return otherWriterWorking && (otherWriterLastWrite.map { Date().timeIntervalSince($0) < 120 } ?? false)
    }

    /// Who else is writing, for messages ("the Claude app").
    private(set) var otherWriterName = "another app"

    private func startFollowing() {
        guard agent == .claude, follower == nil, let sid = sessionID else { return }
        let url = URL(fileURLWithPath: home)
            .appendingPathComponent(".claude/projects/\(TranscriptReader.claudeEncodedDir(for: workdir))/\(sid).jsonl")
        followURL = url
        followOffset = ClaudeTranscriptTail.fileSize(url)
        followFileID = ClaudeTranscriptTail.fileID(url)
        ownTurnEnded = nil
        sawOwnTurn = false
        watchTranscript()
        // A steady poll under the file watch: it also reads the registry, and
        // covers changes a watch can miss.
        follower = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                await self.followTick()
                await self.refreshOtherWriter()
            }
        }
    }

    private func stopFollowing() {
        follower?.cancel()
        follower = nil
        fileWatch?.cancel()
        fileWatch = nil
    }

    /// Tick (coalesced over 250 ms) whenever the transcript is written; follow
    /// it to a new file if it's replaced.
    private func watchTranscript() {
        fileWatch?.cancel()
        fileWatch = nil
        guard let url = followURL else { return }
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let replaced = !source.data.isDisjoint(with: [.delete, .rename])
            MainActor.assumeIsolated {
                if replaced {
                    // Rewritten by rename: watch the new file once it's there.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self, self.follower != nil else { return }
                        self.watchTranscript()
                        self.scheduleTick()
                    }
                } else {
                    self.scheduleTick()
                }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        fileWatch = source
    }

    private func scheduleTick() {
        guard !tickScheduled else { return }
        tickScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.tickScheduled = false
            Task { await self.followTick() }
        }
    }

    /// Sandboxed writers found gone (killed mid-turn: their entry still says busy).
    private var goneWriters: Set<String> = []
    private var lastProbe: [String: Date] = [:]
    /// How long a busy sandboxed writer may stay silent before we look inside
    /// the sandbox for it (`registryProbeAfter` for tests).
    var registryProbeAfter: TimeInterval = 120

    /// A busy writer in a sandbox that's been silent a while: is its process
    /// still there? (At most once a minute per writer.)
    private func probeIfQuiet(_ writer: ClaudeSessionRegistry.Entry?) {
        guard let w = writer, !w.isOnThisMac, w.isBusy, let last = w.lastUpdate,
              Date().timeIntervalSince(last) > registryProbeAfter else { return }
        let key = ClaudeSessionRegistry.key(w)
        if let t = lastProbe[key], Date().timeIntervalSince(t) < 60 { return }
        lastProbe[key] = Date()
        Task { [weak self] in
            guard await ClaudeSessionRegistry.sandboxedProcessIsAlive(w) == false, let self else { return }
            Log.info(.sbx, "chat: \(self.otherWriterName) (pid \(w.pid) in a sandbox) is gone; not waiting on it")
            self.goneWriters.insert(key)
            await self.refreshOtherWriter()
        }
    }

    /// Who else has this conversation open, from the registry.
    private func refreshOtherWriter() async {
        guard let sid = sessionID else { return }
        let home = registryHome ?? home
        let gone = goneWriters
        let (readable, writer) = await Task.detached(priority: .utility) {
            let dir = URL(fileURLWithPath: home).appendingPathComponent(".claude/sessions").path
            let readable = FileManager.default.fileExists(atPath: dir)
            return (readable, readable ? ClaudeSessionRegistry.otherWriter(home: home, sessionID: sid, gone: gone) : nil)
        }.value
        probeIfQuiet(writer)
        registryReadable = readable
        let wasBusy = otherWriter?.isBusy ?? false
        if writer != otherWriter { otherWriter = writer }
        if let e = writer?.entrypoint { otherWriterName = ClaudeTranscriptTail.writerName(e) }
        if wasBusy, !(writer?.isBusy ?? false) { onOtherAppIdle?() }
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
        // A new conversation's transcript appears with its first turn: watch it then.
        if fileWatch == nil, FileManager.default.fileExists(atPath: url.path) {
            watchTranscript()
            followFileID = ClaudeTranscriptTail.fileID(url)
        }
        // Replaced, or rewritten shorter (Claude rewrites its trailing
        // cost-state line in place): pick up from the end of what's there now.
        let size = ClaudeTranscriptTail.fileSize(url), fileID = ClaudeTranscriptTail.fileID(url)
        if size < followOffset || (fileID != nil && followFileID != nil && fileID != followFileID) {
            Log.info(.sbx, "chat: transcript replaced or shrank; resyncing at \(size)")
            followOffset = size
            followFileID = fileID
            return
        }
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
        if let working = batch.working {
            // Without a registry to say so, the transcript's turn end is the signal.
            if otherWriterWorking, !working, !registryReadable { onOtherAppIdle?() }
            otherWriterWorking = working
        }
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
                lastExternalPrompt = text
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
        // What the reload must replay: the other app's last prompt.
        catchUpExpect = lastExternalPrompt.map { String($0.prefix(40)) }
        lastExternalPrompt = nil
        catchUpRetries = 0
        reload(sid)
    }

    private var catchUpExpect: String?
    private var lastExternalPrompt: String?
    private var catchUpRetries = 0

    /// The reload didn't replay the other app's turn (Claude Code resumed
    /// from an earlier leaf): load once more before sending.
    private func catchUpMissedTurn() -> Bool {
        // (A conversation that wouldn't load at all started fresh: nothing to retry.)
        guard isCatchingUp, let expect = catchUpExpect, let sid = sessionID, sid == resumeID else { return false }
        let replayed = items.contains { if case .user(_, let t, _) = $0 { t.contains(expect) } else { false } }
        guard !replayed, catchUpRetries < 2 else { catchUpExpect = nil; return false }
        catchUpRetries += 1
        Log.info(.sbx, "chat: \(sid) reload didn't replay the other app's last turn; loading again")
        reload(sid)
        return true
    }

    private func reload(_ sid: String) {
        pumpTask?.cancel()
        let old = connection
        connection = nil
        resumeID = sid
        items = []
        phase = .starting
        let container = containerName, match = tag.pairs[1]
        newLaunchTag()   // the reap below can't reach the relaunch
        Task { [weak self] in
            // KILL first, before it sees its stdin close: a Claude Code process
            // that's allowed to exit rewrites its transcript's cost-state line
            // in place — over turns another app appended after it.
            await SbxClient.reapSessionProcessesAndWait(container: container, match: match, immediate: true)
            old?.terminate()
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
            let request = PendingPermission(id: id, title: title, options: opts)
            if permission == nil { permission = request } else { waitingPermissions.append(request) }
            onNeedsInput?(title)
        case .request(let id, "elicitation/create", let params):
            guard let q = AgentQuestion.parse(id: id, params: params) else {
                connection?.respondError(id: id, code: -32602, message: "Sandshell can't show this question")
                return
            }
            if question == nil { question = q } else { waitingQuestions.append(q) }
            onNeedsInput?(q.message)
        case .notification("elicitation/complete", _):
            break   // an MCP sign-in finished in the browser: nothing waits on it here
        case .request(let id, let method, _):
            connection?.respondError(id: id, code: -32601, message: "\(method) is not supported by Sandshell")
        case .stderr(let line):
            Log.info(.sbx, "chat[acp]: \(line)")
            if line == SbxCommand.extrasMarker { hasExtras = true; return }
            if line == SbxCommand.installingMarker { installingAdapter = true; return }
            if line == SbxCommand.launchMarker { launchSeen = true; return }
            if line.hasPrefix("sandshell: ") { launchError = String(line.dropFirst("sandshell: ".count)) }
        case .closed(let status):
            permission = nil; waitingPermissions = []
            question = nil; waitingQuestions = []
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

    /// The kind of the update before this one (consecutive user chunks are
    /// one prompt; a user chunk after anything else starts a new one).
    private var lastUpdateKind = ""

    private func apply(_ u: JSONValue) {
        let kind = u["sessionUpdate"]?.string ?? ""
        let previousKind = lastUpdateKind
        lastUpdateKind = kind
        switch kind {
        case "agent_message_chunk":
            if !stopped { appendText(u, thought: false) }
        case "agent_thought_chunk":
            if !stopped { appendText(u, thought: true) }
        case "user_message_chunk":
            // Our own prompts are shown when sent (and echoed mid-turn); outside a
            // turn these are a `session/load` history replay.
            guard phase != .running, let text = u["content"]?["text"]?.string else { return }
            if previousKind == "user_message_chunk", case .user(let id, let t, let a)? = items.last {
                items[items.count - 1] = .user(id: id, text: t + text, attachments: a)
            } else {
                items.append(.user(id: UUID(), text: text, attachments: []))
            }
        case "session_info_update":
            // A turn's file-change report (AIR): which files it changed.
            if hasExtras, let report = u["_meta"]?["jetbrains"]?["air"]?["agentFileChangeReport"],
               report["status"]?.string == "reported", let turn = report["requestId"]?.string,
               let paths = report["paths"]?.array?.compactMap(\.string), !paths.isEmpty {
                upsert(.fileChanges(turn: turn, paths: paths, restored: false))
            }
        case "async_task_spawned", "async_task_progress", "async_task_state_update":
            guard let id = u["asyncTaskId"]?.string else { return }
            var task = backgroundTasks[id] ?? BackgroundTaskState(id: id)
            if let v = u["name"]?.string { task.name = v }
            if let v = u["description"]?.string { task.description = v }
            if let v = u["canStop"]?.bool { task.canStop = v }
            if let v = u["state"]?.string { task.state = v }
            if let v = u["summary"]?.string { task.summary = v }
            backgroundTasks[id] = task
        case "usage_update":
            if let model = u["_meta"]?["_claude/model"]?.string { liveModel = model }
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

// MARK: - Export

extension ChatSession {
    /// The conversation as Markdown (File ▸ Export Conversation…): prompts,
    /// replies, tool calls by title, plans, notices.
    func markdownExport(sessionName: String) -> String {
        var out = ["# \(sessionName)", ""]
        for item in items {
            switch item {
            case .user(_, let text, let attachments):
                out += ["## You", "", text]
                if !attachments.isEmpty { out += ["", attachments.map { "📎 \($0)" }.joined(separator: "  ")] }
            case .agentText(_, let text): out += ["## \(agent.displayName)", "", text]
            case .thought: continue
            case .tool(let call): out += ["> 🔧 \(call.title)\(call.status == "failed" ? " (failed)" : "")"]
            case .toolGroup(let calls): out += calls.map { "> 🔧 \($0.title)" }
            case .plan(_, let entries):
                out += ["**Plan**", ""] + entries.map { "- [\($0.status == "completed" ? "x" : " ")] \($0.content)" }
            case .notice(_, let text, let isError): out += ["_\(isError ? "⚠️ " : "")\(text)_"]
            case .image: out += ["_(image)_"]
            case .fileChanges(_, let paths, let restored):
                out += ["_\(restored ? "Restored" : "Changed") \(paths.count) file\(paths.count == 1 ? "" : "s"): \(paths.joined(separator: ", "))_"]
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}

