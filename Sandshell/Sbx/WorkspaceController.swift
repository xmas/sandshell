import AppKit
import Combine
import Foundation

/// Owns a single workspace and the `sbx` container(s) behind its window.
///
/// Per SPIKE-1 (GA plan §2) a sandbox is one container = one image, and
/// credential injection is fixed at create time — so a window hosts **one
/// container per agent kind**, created lazily when a session of that kind is
/// first opened. claude and claude-bedrock share a base *image* but remain
/// distinct containers (different credential service + env). Phase 1 exercises
/// only the primary agent's container; the keyed map generalizes to N.
@MainActor
final class WorkspaceController: ObservableObject {
    @Committed private(set) var workspace: Workspace
    /// Last-known container status per agent kind (nil entry = not created).
    @Committed private(set) var containers: [AgentKind: Sandbox] = [:]
    @Committed private(set) var busy = false
    @Committed private(set) var lastError: String?
    /// Human-readable description of an in-flight container build/rebuild, or nil
    /// when idle. Drives the progress banner and disables "New Session".
    @Committed private(set) var activity: String?

    /// Whether any container is currently being built or rebuilt.
    var isBuilding: Bool { containerPhases.values.contains { $0.isBuilding } }
    /// The sidebar's current selection (drives the Phase 3 terminal host).
    @Committed var selection: SidebarSelection? {
        didSet {
            if case let .session(id) = selection, var rt = runtimes[id] {
                rt.isUnread = false
                runtimes[id] = rt
            }
        }
    }
    /// Live per-session status + work-time (from the agent transcript).
    @Committed private(set) var runtimes: [UUID: SessionRuntime] = [:]
    /// Each Claude session's background tasks (subagents, background shells,
    /// Monitors), kept current by the window's `BackgroundTaskMonitor`.
    @Committed private(set) var backgroundTasks: [UUID: [BackgroundTask]] = [:]
    /// Each Claude session's subagents (the sidebar shows them under it).
    @Committed private(set) var subagents: [UUID: [SubagentInfo]] = [:]
    /// Each Claude session's workflows (the Workflow tool's runs), newest last.
    @Committed private(set) var workflows: [UUID: [WorkflowRun]] = [:]
    private var subagentPollTask: Task<Void, Never>?
    /// What each sandbox is (kernel, distribution, mount types), asked once.
    @Committed private(set) var sandboxSystems: [String: SandboxSystem] = [:]
    private var probingSandboxes: Set<String> = []
    /// Authoritative lifecycle phase per agent container — the single source of
    /// truth for creation, build, running, stopped, and rebuild state.
    @Committed private(set) var containerPhases: [AgentKind: ContainerPhase] = [:]
    /// What sbx printed while (re)making each agent's sandbox — the latest
    /// build's, kept until the next (a failed one's shows beside its error).
    @Committed private(set) var buildLogs: [AgentKind: BuildLog] = [:]
    /// Bumped only on **structural** project/session changes (not selection or
    /// busy/error). The sidebar reloads on this, so opening an inline editor or
    /// changing selection doesn't tear the outline down.
    @Committed private(set) var revision = 0
    /// Fires every second — the single shared clock for all work-timer displays
    /// (replaying the latest tick on subscribe). Deliberately not `@Committed`:
    /// a tick mustn't send `objectWillChange` and re-render every SwiftUI view
    /// observing the controller. SwiftUI timers use a `TimelineView` instead.
    var clockTick: AnyPublisher<Date, Never> { clockSubject.eraseToAnyPublisher() }
    private let clockSubject = CurrentValueSubject<Date, Never>(.now)

    /// Kit startup outcome per agent container, read from the sandbox's
    /// dispatcher log after the container comes up (see `KitStartup.swift`).
    /// Absent until the first read; the UI shows nothing for an absent entry.
    /// Written only by the kit-startup extension (`WorkspaceController+KitStartup.swift`).
    @Committed var kitStartup: [AgentKind: KitStartupStatus] = [:]
    var kitStartupTasks: [AgentKind: Task<Void, Never>] = [:]
    var kitLogWindows: [AgentKind: HostTerminalWindowController] = [:]
    /// Per agent container: kits it actually has (`sbx inspect`) that differ
    /// from the workspace config — e.g. one added by hand with `sbx kit add`.
    /// Absent = in sync, not checked yet, or a rebuild is already pending.
    @Committed private(set) var kitDrift: [AgentKind: KitDrift] = [:]

    let home = URL.homeDirectory
    /// The folder's persisted state and config, shared with any other window
    /// open on it (see `WorkspaceStore`).
    private let store: WorkspaceStore
    private var state: WorkspaceState {
        get { store.state }
        set { store.setState(newValue, by: self) }
    }
    private var config: WorkspaceConfig {
        get { store.config }
        set { store.setConfig(newValue, by: self) }
    }
    /// The window's undo manager: closing, renaming… sessions can be undone.
    weak var undoManager: UndoManager?
    /// Sessions closed in this window, most recent last (Reopen Closed Session).
    var recentlyClosed: [Session] = []
    private var containerPollTask: Task<Void, Never>?
    /// The container sync running now, and whether another was asked for meanwhile.
    private var containerSyncTask: Task<Void, Never>?
    private var containerSyncQueued = false
    private var clockCancellable: AnyCancellable?
    private var statusFeedCancellable: AnyCancellable?
    private var statusFeedMTime: Date?

    /// This window's appearance controller. Owns the per-root `ThemePreferences`
    /// (seeded from the global default), persists them to this root's config, and
    /// publishes the resolved palette for this window's chrome/terminals.
    let theme: ThemeController

    /// This folder's identity (icon, color, sidebar background). Drives the
    /// sidebar header/background; editable in General.
    @Committed private(set) var rootProfile: RootProfile
    /// Custom (kit-defined) agents this workspace offers (see `availableAgents`).
    @Committed private(set) var customAgents: [AgentKind] = []
    nonisolated(unsafe) private var agentProfileObserver: NSObjectProtocol?
    nonisolated(unsafe) private var rootProfileObserver: NSObjectProtocol?
    /// The window closed. Work it started may still finish, but asks nothing.
    private(set) var isClosed = false

    /// Whether the mount-config UI should be shown before creating a container
    /// (true until the user confirms mounts for this workspace).
    var needsConfiguration: Bool { !config.configured }

    /// What couldn't be read when the folder opened (config.json: it runs on
    /// defaults; state.json: on a fresh session list), for the first window
    /// on it to say; empty after that.
    func takeOpenProblems() -> [UnreadableWorkspaceFile] { store.takeOpenProblems() }

    /// Current mount policy (for the mount-config UI to edit).
    var policy: MountPolicy { workspace.policy }

    init(workspace: Workspace, store: WorkspaceStore) {
        let config = store.config
        self.workspace = workspace
        self.store = store
        self.rootProfile = RootFolderStore.profile(for: workspace.rootURL.path)
        self.theme = ThemeController(prefs: config.theme ?? ThemeDefaults.prefs)
        self.theme.persist = { [weak self] prefs in
            guard let self else { return }
            self.config.theme = prefs
            self.saveConfig()
        }
        self.customAgents = config.customAgents
        // A custom agent's name/icon/color changed (any window): redraw rows.
        agentProfileObserver = NotificationCenter.default.addObserver(
            forName: AgentProfileStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
        // The folder's look changed (in any window on it): show it here too.
        rootProfileObserver = NotificationCenter.default.addObserver(
            forName: RootFolderStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let profile = RootFolderStore.profile(for: self.workspace.rootURL.path)
                if profile != self.rootProfile { self.rootProfile = profile }
            }
        }
        startStatusFeedPolling()
        // Another window on this folder changed it: show that here.
        store.observe(self) { [weak self] parts in self?.sharedStoreChanged(parts) }
    }

    deinit {
        if let agentProfileObserver { NotificationCenter.default.removeObserver(agentProfileObserver) }
        if let rootProfileObserver { NotificationCenter.default.removeObserver(rootProfileObserver) }
        containerPollTask?.cancel()
        subagentPollTask?.cancel()
    }

    /// Its window closed: stop polling, and ask nothing from here on (a
    /// bring-up still running declines a rebuild rather than prompt).
    func windowClosed() {
        isClosed = true
        containerPollTask?.cancel()
        subagentPollTask?.cancel()
    }

    // MARK: Claude model/effort + status feed

    /// `claude --model` id used for this workspace's Claude sessions (nil = default).
    var claudeModel: String? { config.claudeModel }

    /// Persist the model choice. Takes effect for sessions launched afterwards
    /// (callers restart a live session to apply it there).
    func setClaudeModel(_ id: String?) {
        let normalized = (id?.isEmpty ?? true) ? nil : id
        guard normalized != config.claudeModel else { return }
        config.claudeModel = normalized
        saveConfig()
    }

    /// `claude --effort` level used for this workspace's Claude sessions (nil = default).
    var claudeEffort: String? { config.claudeEffort }

    /// Persist the effort choice; like the model, it applies at launch.
    func setClaudeEffort(_ level: String?) {
        let normalized = (level?.isEmpty ?? true) ? nil : level
        guard normalized != config.claudeEffort else { return }
        config.claudeEffort = normalized
        saveConfig()
    }

    func claudeStatus(_ id: UUID) -> ClaudeSessionStatus? { runtimes[id]?.claudeStatus }

    /// Forget a session's status (its terminal went away) and drop the feed file
    /// so a relaunch starts clean.
    func clearClaudeStatus(_ id: UUID) {
        ClaudeStatusFeed.removeStatusFile(root: workspace.rootURL, sessionID: id)
        guard var rt = runtimes[id], rt.claudeStatus != nil else { return }
        rt.claudeStatus = nil
        runtimes[id] = rt
    }

    /// Poll the feed dir once a second while any session is live. The feed
    /// script `mv`s each report into place, which bumps the dir's mtime, so a
    /// single stat tells us whether anything changed. (Polling rather than a
    /// vnode DispatchSource: cheaper to reason about under strict concurrency,
    /// and status reports arrive at most once per assistant message.)
    private func startStatusFeedPolling() {
        guard statusFeedCancellable == nil else { return }
        statusFeedCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.pollStatusFeed() }
    }

    private func pollStatusFeed() {
        guard runtimes.values.contains(where: { $0.isLive }) else { return }
        let dir = ClaudeStatusFeed.statusDir(root: workspace.rootURL)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path),
              let mtime = attrs[.modificationDate] as? Date else { return }
        guard mtime != statusFeedMTime else { return }
        statusFeedMTime = mtime
        reloadClaudeStatuses(from: dir)
    }

    private func reloadClaudeStatuses(from dir: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let decoder = JSONDecoder()
        for name in names where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.dropLast(5))), session(id: id) != nil,
                  let data = try? Data(contentsOf: dir.appending(path: name)),
                  let status = try? decoder.decode(ClaudeSessionStatus.self, from: data) else { continue }
            var rt = runtimes[id] ?? SessionRuntime()
            if rt.claudeStatus != status {
                rt.claudeStatus = status
                runtimes[id] = rt
            }
            // Claude names its own transcript: no need to infer it from the
            // projects dir. Makes "restart with model" resume the right conversation.
            if let sid = status.sessionID, !sid.isEmpty { setTranscriptID(id, sid) }
        }
    }

    /// Bootstrap (or load) the workspace at `root` and return a controller for
    /// a window on it (sharing the folder's store with any other window on it).
    static func open(root: URL = WorkspaceBootstrap.defaultRoot) throws -> WorkspaceController {
        let store = try WorkspaceStore.shared(root: root)
        let config = store.config
        var workspace = Workspace(
            rootURL: root, containerName: slug(for: root), policy: config.policy,
            mcpServers: config.mcpServers, mcpURL: config.mcpURL, primaryAgent: config.primaryAgent,
            kits: config.kits.filter { !KitStore.isSandshellKit($0) })
        workspace.imageChannel = config.imageChannel
        workspace.customImage = config.customImage
        workspace.cloneRepo = config.cloneRepo ?? false
        return WorkspaceController(workspace: workspace, store: store)
    }

    /// Another window on this folder saved: take its config (mounts, agents,
    /// kits, MCP, theme) and redraw the session list from its state.
    private func sharedStoreChanged(_ parts: Set<WorkspaceStore.Part>) {
        if parts.contains(.config) {
            var w = workspace
            w.policy = config.policy
            w.mcpServers = config.mcpServers
            w.mcpURL = config.mcpURL
            w.primaryAgent = config.primaryAgent
            w.kits = config.kits.filter { !KitStore.isSandshellKit($0) }
            w.imageChannel = config.imageChannel
            w.customImage = config.customImage
            w.cloneRepo = config.cloneRepo ?? false
            if w != workspace { workspace = w }
            if customAgents != config.customAgents { customAgents = config.customAgents }
            if let prefs = config.theme, prefs != theme.prefs { theme.prefs = prefs }
        }
        // It closed the session selected here: nothing is selected now (⌘N, ⌘W
        // and the Session menu would act on a session that's gone).
        if parts.contains(.state) { clearSelectionIfGone() }
        // It may have adopted or ignored the kit drift shown here.
        for agent in kitDrift.keys { refreshKitDrift(for: agent) }
        // The session list (and anything drawn from config) redraws.
        revision += 1
    }

    // Current durable settings (for the Settings UI).
    var primaryAgent: AgentKind { workspace.primaryAgent }
    var archiveInterval: TimeInterval { config.archiveInterval }
    var rootURL: URL { workspace.rootURL }
    var mcpServers: [String] { workspace.mcpServers }
    var mcpURL: URL { workspace.mcpURL }
    /// Host paths the workspace mounts — the only dirs a restored session can use
    /// as its working directory (History is limited to conversations within them).
    var mountRoots: [String] { resolvedMounts().map { $0.path.path } }

    /// Apply an edited mount policy (from the mount-config UI / Settings),
    /// persist it, mark configured, and (re)build every existing container so
    /// they all pick up the new mounts.
    func applyConfiguration(policy: MountPolicy) {
        workspace.policy = policy
        config.policy = policy
        config.configured = true
        saveConfig()
        // Rebuild the primary plus any other agent that already has a container.
        // No prompt — the caller (first-run / Settings ▸ Apply & Rebuild) already
        // confirmed via its own UI.
        var agents = Set(containers.keys)
        agents.insert(workspace.primaryAgent)
        for agent in agents { rebuildContainer(for: agent) }
    }

    /// Take mounts set from outside (`sandshell://open`) into this open
    /// workspace (and so every window on it), and offer to rebuild each of its
    /// sandboxes whose mounts no longer match: a session launch attaches as-is,
    /// so nothing else would.
    func adoptPolicy(_ policy: MountPolicy) {
        workspace.policy = policy
        config.policy = policy
        config.configured = true
        saveConfig()
        // Each sandbox it has, or is bringing up. One in flight read the old
        // mounts: compare the new ones once it's done, rather than take its result.
        let inflight = (availableAgents + containerPhases.keys).filter { Self.bringUps[containerName(for: $0)] != nil }
        for agent in Set(containers.keys).union(inflight) {
            runAction { @MainActor in try await self.bringUpContainer(for: agent, onMismatch: .prompt, recheck: true) }
        }
    }

    /// Change the workspace's primary agent (default for the quick "+ New
    /// Session" action). Persisted. Sandboxes keep their names: the one with
    /// the bare slug stays the old primary's (`WorkspaceState.slugAgent`).
    func setPrimaryAgent(_ agent: AgentKind) {
        guard agent != workspace.primaryAgent else { return }
        // Whether or not its sandbox exists yet: one being made right now
        // records nothing until it's up, and gets the bare slug all the same.
        if state.pinSlugAgent(workspace.primaryAgent) {
            writeState()
        }
        workspace.primaryAgent = agent
        config.primaryAgent = agent
        saveConfig()
    }

    // MARK: Custom agents

    /// Every agent this workspace offers: the builtins plus its registered
    /// custom (kit-defined) agents.
    var availableAgents: [AgentKind] { AgentKind.builtins + customAgents.filter { !$0.isBuiltin } }

    /// Choose which registered custom agents this workspace offers. Persisted;
    /// no rebuild — each agent gets its own container when first used.
    func setCustomAgents(_ agents: [AgentKind]) {
        var seen = Set<AgentKind>()
        let cleaned = agents.filter { !$0.isBuiltin && seen.insert($0).inserted }
        guard cleaned != customAgents else { return }
        customAgents = cleaned
        config.customAgents = cleaned
        saveConfig()
        revision += 1
    }

    /// Apply edited MCP settings (server set + gateway URL), persist, and live-load
    /// enabled servers into running containers via `sbx mcp load`. Newly-enabled
    /// servers appear immediately; de-selecting one takes effect when the container
    /// is next recreated (sbx has no live "unload"). Servers must already be
    /// authenticated/registered (via `authenticateMCP`).
    func applyMCP(servers: [String], url: URL) {
        workspace.mcpServers = servers
        workspace.mcpURL = url
        config.mcpServers = servers
        config.mcpURL = url
        saveConfig()
        // Attach the (registered) enabled servers to running containers live via
        // `sbx mcp load` — no rebuild needed. Newly-enabled servers appear
        // immediately; de-selecting one takes effect when the sandbox is next
        // recreated (sbx has no live "unload").
        Task {
            let valid = await effectiveMCPServers()
            for agent in containers.keys where containers[agent]?.isRunning == true {
                await loadMCPServers(valid, into: containerName(for: agent))
            }
        }
    }

    /// Attach each registered MCP server to a running sandbox (best-effort).
    private func loadMCPServers(_ servers: [String], into sandbox: String) async {
        for server in servers {
            do {
                try await SbxClient.shared.loadMCP(server: server, sandbox: sandbox, mcpURL: workspace.mcpURL)
            } catch {
                Log.error(.workspace, "mcp load \(server) → \(sandbox) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: MCP registration / hosted-OAuth status

    /// Registered servers (`sbx mcp ls`) → name : isRemote.
    @Committed private(set) var mcpRegistered: [String: Bool] = [:]
    /// Hosted-OAuth status per server (`authorized` / `unauthorized` / `expired`).
    @Committed private(set) var mcpAuth: [String: String] = [:]
    /// Servers with an in-flight authenticate/unauthorize/remove action.
    @Committed private(set) var mcpBusy: Set<String> = []
    /// Servers freshly authenticated/added, in order, for Settings ▸ MCP to
    /// auto-enable. It enables and clears them when it next shows, so a list:
    /// several can finish while it's closed.
    @Committed var mcpPendingEnable: [String] = []
    /// Why the last authenticate/unauthorize/remove of a server failed (shown on its row).
    @Committed private(set) var mcpErrors: [String: String] = [:]
    /// Why the last "Add from JSON" failed (shown under the JSON field): a
    /// server that failed to add never registers, so it has no row to show it on.
    @Committed private(set) var mcpAddError: String?

    /// Refresh the registered set + OAuth status from `sbx mcp`.
    func refreshMCPStatus() {
        let url = workspace.mcpURL
        Task {
            self.mcpRegistered = await SbxClient.shared.listMCPServers(mcpURL: url)
            self.mcpAuth = await SbxClient.shared.mcpAuthStatus(mcpURL: url)
        }
    }

    /// Authenticate a server in-app (real hosted OAuth — opens the browser). If
    /// already registered, re-auth via `sbx mcp auth`; otherwise register +
    /// authorize with `sbx mcp add <name> <addArgs>`. On success flags it for
    /// auto-enable.
    func authenticateMCP(name: String, addArgs: [String]?) {
        let url = workspace.mcpURL
        let registered = mcpRegistered.keys.contains(name)
        mcpAction(name, "authenticate") {
            if registered {
                try await SbxClient.shared.authMCP(name: name, mcpURL: url)
            } else if let addArgs {
                try await SbxClient.shared.addMCP(name: name, args: addArgs, mcpURL: url)
            }
            self.mcpPendingEnable.append(name)   // auto-enable
        }
    }

    /// Register servers from a standard MCP JSON document (`{ "mcpServers": { … } }`)
    /// via `sbx mcp add` — each entry maps to `--command/--args` or `--url`.
    /// Whether every server in it was added: false when the text holds none or
    /// an add failed (`mcpAddError` says why; the caller keeps the text to fix).
    @discardableResult
    func addMCPFromJSON(_ json: String) async -> Bool {
        let parsed = Self.parseMCPJSON(json)
        guard !parsed.isEmpty else {
            mcpAddError = "No servers found — expected { \"mcpServers\": { … } }."
            return false
        }
        mcpAddError = nil
        let url = workspace.mcpURL
        for (name, _) in parsed { mcpBusy.insert(name) }
        var failures: [String] = []
        for (name, args) in parsed {
            do {
                try await SbxClient.shared.addMCP(name: name, args: args, mcpURL: url)
                mcpPendingEnable.append(name)   // auto-enable
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
                Log.error(.workspace, "mcp add \(name) failed: \(error.localizedDescription)")
            }
            mcpBusy.remove(name)
        }
        mcpAddError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        refreshMCPStatus()
        return failures.isEmpty
    }

    /// Revoke a server's hosted OAuth credential (keeps registration).
    func unauthorizeMCP(_ name: String) {
        let url = workspace.mcpURL
        mcpAction(name, "unauthorize") { try await SbxClient.shared.unauthorizeMCP(name: name, mcpURL: url) }
    }

    /// Remove a registered server entirely (`sbx mcp rm`).
    func removeMCP(_ name: String) {
        let url = workspace.mcpURL
        mcpAction(name, "remove") { try await SbxClient.shared.removeMCP(name: name, mcpURL: url) }
    }

    /// Run an action on a server: busy meanwhile, a failure shown on its row
    /// (cleared by the next try), then a status refresh.
    private func mcpAction(_ name: String, _ verb: String, _ work: @escaping @MainActor () async throws -> Void) {
        mcpBusy.insert(name)
        mcpErrors[name] = nil
        Task {
            defer { self.mcpBusy.remove(name) }
            do {
                try await work()
            } catch {
                self.mcpErrors[name] = error.localizedDescription
                Log.error(.workspace, "mcp \(verb) \(name) failed: \(error.localizedDescription)")
            }
            self.refreshMCPStatus()
        }
    }

    /// Parse `{ "mcpServers": { name: {command,args} | {url} } }` → add-args per
    /// server. `mcp-remote` command entries register as local stdio servers.
    static func parseMCPJSON(_ json: String) -> [(name: String, args: [String])] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else { return [] }
        var result: [(String, [String])] = []
        for (name, value) in servers {
            guard let entry = value as? [String: Any] else { continue }
            var args: [String] = []
            if let url = entry["url"] as? String {
                args = ["--url", url]
            } else if let command = entry["command"] as? String {
                let cmdArgs = (entry["args"] as? [String]) ?? []
                // `npx mcp-remote <url>` is a stdio↔remote bridge — register it as a
                // native remote server so it gets gateway hosted OAuth and can be
                // loaded via sbx mcp load (a local --command server can't auth and
                // isn't reachable by the cloud gateway).
                if let bridged = bridgedRemoteURL(command: command, args: cmdArgs) {
                    args = ["--url", bridged]
                } else {
                    args = ["--command", command]
                    for a in cmdArgs { args += ["--args", a] }
                }
            } else { continue }
            result.append((name, args))
        }
        return result
    }

    /// If a `command`/`args` entry is an `npx mcp-remote <url>` bridge, return the
    /// remote URL it proxies to (so we register it as a real remote server).
    private static func bridgedRemoteURL(command: String, args: [String]) -> String? {
        let isNpx = command == "npx" || command.hasSuffix("/npx")
        guard isNpx, args.contains(where: { $0 == "mcp-remote" || $0.hasPrefix("mcp-remote@") })
        else { return nil }
        return args.first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
    }

    // MARK: All sandboxes (Settings ▸ Sandboxes — global, not just this workspace)

    @Committed private(set) var allSandboxes: [Sandbox] = []
    /// Sandboxes with an in-flight lifecycle action (run/stop/delete/rebuild).
    @Committed private(set) var sandboxBusy: Set<String> = []
    /// Why the last Settings ▸ Sandboxes action on a sandbox failed (shown on its row).
    @Committed private(set) var sandboxErrors: [String: String] = [:]
    /// True while `sbx ls` is being scanned (so the pane shows "Loading…", not
    /// a premature "no sandboxes" empty state).
    @Committed private(set) var sandboxesLoading = false
    /// Why the last `sbx ls` for Settings ▸ Sandboxes failed (nil once one works).
    /// The list keeps what it last showed.
    @Committed private(set) var sandboxesError: String?

    func refreshSandboxes() {
        sandboxesLoading = true
        Task {
            do {
                self.allSandboxes = try await SbxClient.shared.list()
                self.sandboxesError = nil
            } catch {
                self.sandboxesError = error.localizedDescription
                Log.error(.workspace, "sbx ls failed: \(error.localizedDescription)")
            }
            self.sandboxesLoading = false
        }
    }

    private func sandboxAction(_ name: String, _ work: @escaping () async throws -> Void) {
        sandboxBusy.insert(name)
        sandboxErrors[name] = nil
        Task {
            defer { self.sandboxBusy.remove(name) }
            do { try await work() } catch {
                self.lastError = error.localizedDescription
                self.sandboxErrors[name] = error.localizedDescription
                Log.error(.workspace, "sandbox action \(name) failed: \(error.localizedDescription)")
            }
            self.refreshSandboxes()
            self.syncContainers()
        }
    }

    /// `sbx run` is detached: stay busy until `sbx ls` says it's running (or 30 s
    /// pass), so the row flips to Stop instead of waiting for a manual refresh.
    func startSandbox(_ name: String) {
        sandboxAction(name) {
            try await SbxClient.shared.start(name)
            for _ in 0..<30 {
                let list = (try? await SbxClient.shared.list()) ?? []
                if list.contains(where: { $0.name == name && $0.isRunning }) { return }
                try? await Task.sleep(for: .seconds(1))
            }
            throw SbxError.command("“\(name)” didn’t report running within 30 seconds — check `sbx ls`.")
        }
    }
    func stopSandbox(_ name: String) { sandboxAction(name) { _ = try await SbxClient.shared.stop(name) } }
    func deleteSandbox(_ name: String) { sandboxAction(name) { _ = try await SbxClient.shared.remove(name) } }

    /// Rebuild a listed sandbox. If it's one of *this* workspace's containers,
    /// go through the workspace path so it keeps the resolved mounts + MCP load;
    /// otherwise fall back to a generic recreate from what `sbx ls` reports (no
    /// MCP info available for foreign sandboxes).
    func rebuildSandbox(_ sandbox: Sandbox) {
        if let agent = agentForContainer(named: sandbox.name) {
            sandboxBusy.insert(sandbox.name)   // its row's buttons wait for it
            runAction { @MainActor in
                defer { self.sandboxBusy.remove(sandbox.name) }
                try await self.bringUpContainer(for: agent, onMismatch: .rebuild, force: true)
                self.refreshSandboxes()
                self.syncContainers()
            }
        } else {
            sandboxAction(sandbox.name) { _ = try await SbxClient.shared.rebuildSandbox(sandbox) }
        }
    }

    /// The workspace agent whose container has this name, if any. Searches
    /// every agent the workspace offers (builtins + registered custom agents),
    /// plus any identity it has sessions or containers for — a session may
    /// outlive its agent's registration.
    func agentForContainer(named name: String) -> AgentKind? {
        (availableAgents + state.sessions.flatMap { [$0.agent, $0.containerAgentKind] } + containers.keys)
            .first { containerName(for: $0) == name }
    }

    /// Display-only `sbx create …` for a sandbox (Sandboxes inspector / debug).
    func createCommandDisplay(for sandbox: Sandbox) -> String {
        var parts = ["sbx", "create", "--no-progress", "--name", sandbox.name]
        if let agent = agentForContainer(named: sandbox.name), let t = workspace.templateImage(for: agent) {
            parts += ["-t", t]
        }
        parts.append(sandbox.agent)
        parts += sandbox.workspaces
        return parts.joined(separator: " ")
    }

    /// Display-only post-launch `sbx exec …` one-liner for a sandbox.
    func launchCommandDisplay(for sandbox: Sandbox) -> String {
        let agent = AgentKind(rawValue: sandbox.agent)
        let usesMCP = agentForContainer(named: sandbox.name) != nil && !workspace.mcpServers.isEmpty
        return SbxCommand.launchCommand(
            containerName: sandbox.name,
            workdir: sandbox.primaryWorkdir ?? "",
            agent: agent,
            sbxPath: PathFixer.sbxPath(),
            home: home.path,
            mcpURL: usesMCP ? workspace.mcpURL : nil)
    }

    /// Re-sync the workspace's own container map after a global sandbox action
    /// may have changed one of them. One pass at a time: asked again while one
    /// runs, it runs once more after it, so an older `sbx ls` never lands last
    /// (and slow ones don't pile up behind the poll).
    private func syncContainers() {
        guard containerSyncTask == nil else { containerSyncQueued = true; return }
        containerSyncTask = Task {
            repeat {
                containerSyncQueued = false
                await syncContainersPass()
            } while containerSyncQueued
            containerSyncTask = nil
        }
    }

    /// One `sbx ls` for every agent's container.
    private func syncContainersPass() async {
        // Also a sandbox shown building: with no bring-up of it left in
        // any window, nothing else would say it's done.
        let building = containerPhases.filter { $0.value.isBuilding }.map(\.key)
        // A bring-up sets the container itself: an answer from before it (or
        // from while it rebuilt) would put back what it replaced.
        let targets = Set(containers.keys).union(building).compactMap { agent -> (AgentKind, String, Int?)? in
            let name = containerName(for: agent)
            return Self.bringUps[name] == nil ? (agent, name, Self.bringUpsStarted[name]) : nil
        }
        guard !targets.isEmpty else { return }
        // sbx didn't answer this time: that isn't "gone".
        guard let list = try? await SbxClient.shared.list() else { return }
        for (agent, name, started) in targets {
            // No bring-up ran meanwhile, so a building phase is left over.
            guard Self.bringUps[name] == nil, Self.bringUpsStarted[name] == started else { continue }
            let sb = list.first { $0.name == name }
            containers[agent] = sb
            containerPhases[agent] = sb.map { $0.isRunning ? .running : .stopped } ?? .absent
            // A container that (re)started outside our create path (e.g.
            // Settings ▸ Run) re-runs its startup dispatcher — follow it.
            if sb?.isRunning == true { refreshKitStartupIfNeeded(for: agent) }
            else if sb == nil { resetKitStartup(for: agent); kitDrift[agent] = nil }
        }
    }

    /// Set the auto-archive interval (seconds). Persisted; used in Phase 7.
    func setArchiveInterval(_ interval: TimeInterval) {
        guard interval != config.archiveInterval else { return }
        config.archiveInterval = interval
        saveConfig()
    }

    // MARK: - Naming & mounts

    /// `sbx`-safe container name derived from the workspace root folder
    /// (letters, numbers, `-`, `.`, `+` only; others → `-`).
    static func slug(for root: URL) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.+")
        let lowered = root.lastPathComponent.lowercased()
        let mapped = lowered.map { allowed.contains($0) ? $0 : "-" }
        let slug = String(mapped)
        return slug.isEmpty ? "sandshell" : slug
    }

    /// Container name for an agent: the bare workspace slug for the primary
    /// agent (or the one that was primary when its sandbox was made, see
    /// `WorkspaceState.slugAgent`), `<slug>-<agent>` for the rest.
    func containerName(for agent: AgentKind) -> String {
        Self.containerName(for: agent, slug: workspace.containerName,
                           slugAgent: state.slugAgent ?? workspace.primaryAgent)
    }

    /// The sandbox name of `agent` when `slugAgent`'s has the bare `slug`.
    static func containerName(for agent: AgentKind, slug: String, slugAgent: AgentKind) -> String {
        agent == slugAgent ? slug : "\(slug)-\(agent.rawValue)"
    }

    /// The full ordered mount set for the workspace under the current policy,
    /// capped at the sbx mount limit. Logs any folders dropped by the cap.
    func resolvedMounts() -> [MountSpec] {
        let (mounts, dropped) = workspace.policy.resolved(home: home, root: workspace.rootURL)
        if !dropped.isEmpty {
            let names = dropped.map { $0.path.lastPathComponent }.joined(separator: ", ")
            Log.info(.workspace, "mount limit (\(MountPolicy.mountLimit)) reached — dropped \(dropped.count): \(names)")
        }
        return mounts
    }

    /// A deterministic signature of a mount set; a change drives a rebuild.
    func mountSignature(_ mounts: [MountSpec]) -> String {
        mounts.map(\.spec).joined(separator: "\n")
    }

    /// The kit references applied to this workspace's sandboxes (dropping blanks).
    func resolvedKits() -> [String] {
        workspace.kits.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !KitStore.isSandshellKit($0) } + sandshellKits
    }

    /// Sandshell's own kits that are on for this workspace.
    var sandshellKits: [String] { config.sandshellKits ?? KitStore.defaultSandshellRefs }

    /// Store a full kit list: Sandshell's own apart from the rest (see
    /// `WorkspaceConfig.sandshellKits`).
    private func storeKits(_ kits: [String]) {
        workspace.kits = kits.filter { !KitStore.isSandshellKit($0) }
        config.kits = workspace.kits
        config.sandshellKits = kits.filter(KitStore.isSandshellKit)
        saveConfig()
    }

    /// Look up (with `sbx kit inspect`) which agent each kit is made for, where
    /// not known yet, so a sandbox only gets the kits it can take.
    func learnKitRequirements(_ refs: [String]) async {
        for ref in refs where KitStore.requiredAgent(ref) == nil {
            if let info = await SbxClient.shared.kitInspect(ref) { KitStore.learn(ref, from: info) }
        }
    }

    /// The workspace's kits a sandbox for `agent` takes, logging any left out.
    func kits(for agent: AgentKind, from refs: [String]) -> [String] {
        let kept = KitStore.kits(refs, for: agent)
        let skipped = refs.filter { !kept.contains($0) }
        if !skipped.isEmpty {
            Log.info(.workspace, "\(agent.rawValue) sandbox: skipping kit(s) made for another agent: \(skipped.joined(separator: ", "))")
        }
        return kept
    }

    /// Combined create-time signature (mounts + kits + base image). A change in
    /// any drives a container rebuild, since all are fixed at `sbx create`.
    /// A custom agent ignores the base-image channel (its kit names the image),
    /// so a channel change doesn't rebuild it.
    func configSignature(mounts: [MountSpec], kits: [String], agent: AgentKind) -> String {
        // Sandshell's own kits don't count: an existing sandbox picks them up
        // at its next rebuild instead of being rebuilt for them on open.
        mountSignature(mounts) + "\n--kits--\n"
            + KitStore.kits(kits, for: agent).filter { !KitStore.isSandshellKit($0) }.joined(separator: "\n")
            + "\n--image--\n" + (agent.isBuiltin ? imageSignature : "")
            + (workspace.cloneRepo ? "\n--clone--" : "")
    }

    /// Agents on a private clone of the repo (`sbx create --clone`) or on the
    /// folder itself. Takes effect at the next (re)build, like the image.
    func setCloneRepo(_ on: Bool) {
        guard on != workspace.cloneRepo else { return }
        workspace.cloneRepo = on
        config.cloneRepo = on ? true : nil
        saveConfig()
        Log.info(.workspace, "clone mode → \(on)")
    }

    /// Whether the workspace folder is a git repository (clone mode needs one).
    var isGitRepository: Bool {
        FileManager.default.fileExists(atPath: workspace.rootURL.appending(path: ".git").path)
    }

    /// Base-image part of the signature. Empty whenever sbx's default image is
    /// used — including Custom with a blank field — so picking a channel that
    /// resolves to the same image doesn't prompt a pointless rebuild.
    private var imageSignature: String {
        let channel = workspace.imageChannel
        if channel == .stable || (channel == .custom && workspace.customImage.isEmpty) { return "" }
        return "\(channel.rawValue):\(workspace.customImage)"
    }

    // MARK: - Base image channel

    var imageChannel: ImageChannel { workspace.imageChannel }
    var customImage: String { workspace.customImage }

    /// Change which template tag this workspace's sandboxes are created from.
    /// Persisted; takes effect on the next (re)build — the create-time signature
    /// changes, so opening the workspace offers a rebuild, and `rebuildAll()`
    /// does it right away.
    func setImageChannel(_ channel: ImageChannel, customImage: String) {
        let custom = customImage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard channel != workspace.imageChannel || custom != workspace.customImage else { return }
        workspace.imageChannel = channel
        workspace.customImage = custom
        config.imageChannel = channel
        config.customImage = custom
        saveConfig()
        Log.info(.workspace, "image channel → \(channel.rawValue)\(custom.isEmpty ? "" : " (\(custom))")")
    }

    /// Force-rebuild every container this workspace has (plus the primary).
    func rebuildAll() {
        var agents = Set(containers.keys)
        agents.insert(workspace.primaryAgent)
        for agent in agents { rebuildContainer(for: agent, force: true) }
    }

    /// Apply an edited kit set (from the Kits inspector) and persist it. When
    /// the only change is added kits, each container gets them in place via
    /// `sbx kit add` (falling back to a rebuild where sbx refuses); anything
    /// else — or `rebuild` — stops and recreates every container.
    func applyKits(_ kits: [String], rebuild: Bool = false) {
        let cleaned = kits.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let previous = resolvedKits()
        let added = rebuild ? nil : KitDrift.additionsOnly(from: previous, to: cleaned)
        // `sbx kit add` appends, so keep the config in the container's order —
        // a later rebuild then composes the kits the same way.
        let final = added.map { previous + $0 } ?? cleaned
        storeKits(final)
        var agents = Set(containers.keys)
        agents.insert(workspace.primaryAgent)
        for agent in agents {
            if let added {
                runAction { @MainActor in
                    try await self.serializedBringUp(for: agent, joinInflight: false) {
                        try await self.performKitAdd(added, previousKits: previous, for: agent)
                    }
                }
            } else {
                // Force: also the path for reloading a kit whose *contents*
                // changed, where the kit ref set (and thus the create-time
                // signature) is identical and the unchanged-config shortcut
                // would otherwise just re-attach.
                rebuildContainer(for: agent, force: true)
            }
        }
    }

    /// Current kit set (for the Kits inspector to edit).
    var kits: [String] { resolvedKits() }

    // MARK: - Kit drift

    /// Compare the container's actual kit list (`sbx inspect --json`) with the
    /// workspace config and publish the difference in `kitDrift`. Only while
    /// the container is believed in sync: with a create-time change pending
    /// (declined rebuild prompt), a mismatch is expected and the rebuild settles it.
    /// Asked once any session launching has its `sbx exec` in.
    func refreshKitDrift(for agent: AgentKind) {
        let name = containerName(for: agent)
        let configured = KitStore.kits(resolvedKits(), for: agent)
        let expected = configSignature(mounts: resolvedMounts(), kits: configured, agent: agent)
        let root = workspace.rootURL
        Task { @MainActor in
            await SbxClient.afterLaunches()
            guard let actual = await SbxClient.shared.inspect(name)?.kits else { return }
            guard self.state.appliedMountSignatures[name] == expected,
                  KitStore.kits(self.resolvedKits(), for: agent) == configured else {
                self.kitDrift[agent] = nil
                return
            }
            // Nor are they drift, either way (they come and go with rebuilds).
            var drift = KitDrift.compute(containerName: name, actual: actual.filter { !KitStore.isSandshellKit($0) },
                                         configured: configured.filter { !KitStore.isSandshellKit($0) }, root: root)
            // The kit that defines this sandbox's agent isn't drift: it's how
            // the sandbox was made, and adopting it would hand it to every agent.
            drift.extra.removeAll { ref in AgentProfileStore.all.contains { $0.kitRef == ref && $0.agent == agent.rawValue } }
            let ignored = Set((self.state.ignoredKitDrift[name] ?? []).map { KitDrift.normalize($0, root: root) })
            drift.extra.removeAll { ignored.contains(KitDrift.normalize($0, root: root)) }
            let value: KitDrift? = drift.isEmpty ? nil : drift
            guard value != self.kitDrift[agent] else { return }
            self.kitDrift[agent] = value
            if let value {
                Log.info(.workspace, "kit drift in '\(name)': extra [\(value.extra.joined(separator: ", "))], missing [\(value.missing.joined(separator: ", "))]")
            }
        }
    }

    /// Make a container's extra kits part of the workspace config. The container
    /// already has them, so it stays as is; the next rebuild keeps them.
    func adoptKitDrift(for agent: AgentKind) {
        guard let drift = kitDrift[agent], !drift.extra.isEmpty else { return }
        let name = drift.containerName
        // Not those another window on the folder adopted already.
        let extra = drift.extra(notIn: resolvedKits(), root: workspace.rootURL)
        guard !extra.isEmpty else {
            kitDrift[agent] = nil
            return refreshKitDrift(for: agent)
        }
        let mounts = resolvedMounts()
        let wasInSync = state.appliedMountSignatures[name] == configSignature(mounts: mounts, kits: resolvedKits(), agent: agent)
        let registered = Set(KitStore.all.map(\.ref))
        for ref in extra where !registered.contains(ref) {
            KitStore.add(ref)
            Task {
                guard let info = await SbxClient.shared.kitInspect(ref) else { return }
                KitStore.update(ref, displayName: info.title, summary: info.description)
            }
        }
        let kits = resolvedKits() + extra
        storeKits(kits)
        if wasInSync { recordSignature(configSignature(mounts: mounts, kits: kits, agent: agent), for: name) }
        Log.info(.workspace, "adopted kit(s) from '\(name)' into the workspace: \(extra.joined(separator: ", "))")
        kitDrift[agent] = nil
        refreshKitDrift(for: agent)
    }

    /// Leave a container's extra kits alone and stop reporting them; the next
    /// rebuild (which uses the workspace config) drops them.
    func ignoreKitDrift(for agent: AgentKind) {
        guard let drift = kitDrift[agent] else { return }
        state.ignoredKitDrift[drift.containerName, default: []] += drift.extra
        writeState()
        kitDrift[agent] = nil
    }

    /// Edit this folder's identity (icon/color/sidebar bg) — applied to the
    /// registry's copy (another window may have changed another part of it),
    /// persisted, and republished so the sidebar re-renders live.
    func updateRootProfile(_ edit: (inout RootProfile) -> Void) {
        var profile = RootFolderStore.profile(for: workspace.rootURL.path)
        edit(&profile)
        RootFolderStore.upsert(profile)
        rootProfile = profile
    }

    // MARK: - Lifecycle

    /// Ensure the primary agent's container exists with the current mounts.
    func openPrimaryContainer() {
        ensureContainer(for: workspace.primaryAgent)
    }

    /// Keep the window's live state current: container phases, subagents and
    /// the work timers' clock. Started once per window, whether its folder is
    /// configured yet or not (each poller starts only once).
    func startMonitoring() {
        startContainerPolling()
        startSubagentPolling()
        startClock()
    }

    /// Every few seconds: the subagents each Claude session's transcript has
    /// (its `subagents/` folder), with the states the task monitor knows.
    private func startSubagentPolling() {
        guard subagentPollTask == nil else { return }
        subagentPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshSubagents()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refreshSubagents() async {
        var targets: [(UUID, URL, [String: BackgroundTask.State], Date?)] = []
        for session in state.sessions where session.agent == .claude {
            // Looked up each time (a stat): a folder rename moves conversations.
            guard let tid = session.transcriptID,
                  let url = TranscriptReader.transcriptURL(agent: .claude, workdir: session.conversationWorkdir,
                                                           home: home, id: tid) else { continue }
            let known = Dictionary((backgroundTasks[session.id] ?? []).filter { $0.kind == .agent }.map { ($0.id, $0.state) },
                                   uniquingKeysWith: { a, _ in a })
            // A foreground subagent runs while the turn that started it does (set only while working).
            targets.append((session.id, url, known, runtimes[session.id]?.workingSince))
        }
        let (found, runs) = await Task.detached(priority: .utility) { () -> ([UUID: [SubagentInfo]], [UUID: [WorkflowRun]]) in
            var out: [UUID: [SubagentInfo]] = [:], runs: [UUID: [WorkflowRun]] = [:]
            for (id, url, known, since) in targets {
                let list = SubagentScanner.scan(sessionID: id, transcript: url, known: known, parentWorkingSince: since)
                if !list.isEmpty { out[id] = Array(list.suffix(12)) }
                let wf = WorkflowScanner.scan(transcript: url)
                if !wf.isEmpty { runs[id] = Array(wf.suffix(12)) }
            }
            return (out, runs)
        }.value
        if found != subagents { subagents = found }
        if runs != workflows { workflows = runs }
    }

    /// Poll workspace container status every 5 s so `containerPhases` stays
    /// accurate without requiring explicit actions to trigger `syncContainers`.
    private func startContainerPolling() {
        guard containerPollTask == nil else { return }
        containerPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }   // the window closed
                self.syncContainers()
            }
        }
    }

    /// Start the shared 1-second clock that drives all work-timer displays.
    private func startClock() {
        guard clockCancellable == nil else { return }
        clockCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in self?.clockSubject.send(date) }
    }

    /// What to do when an existing container's mounts no longer match the policy.
    private enum MismatchAction {
        case prompt    // ask before destroying (launch / open)
        case attach    // leave as-is (session launch shouldn't surprise-rebuild)
        case rebuild   // rebuild without asking (user already chose Apply)
    }

    /// Create the agent's container if absent; attach if present and its mounts
    /// are unchanged; otherwise prompt and rebuild. Fire-and-forget.
    func ensureContainer(for agent: AgentKind) {
        runAction { @MainActor in try await self.bringUpContainer(for: agent, onMismatch: .prompt) }
    }

    /// Rebuild the agent's container to match the current policy without asking
    /// (the caller, e.g. Settings ▸ Apply & Rebuild, already confirmed).
    func rebuildContainer(for agent: AgentKind, force: Bool = false) {
        runAction { @MainActor in try await self.bringUpContainer(for: agent, onMismatch: .rebuild, force: force) }
    }

    /// Bring the agent's container up and return its name once ready (for
    /// launching a session). Attaches as-is on a mount mismatch — a session
    /// launch shouldn't trigger a surprise rebuild. Returns nil on failure.
    func ensureContainerReady(for agent: AgentKind) async -> String? {
        busy = true
        defer { busy = false }
        defer { activity = nil }
        do {
            try await bringUpContainer(for: agent, onMismatch: .attach)
            lastError = nil
            return containerName(for: agent)
        } catch {
            lastError = error.localizedDescription
            Log.error(.workspace, "ensureContainerReady(\(agent.rawValue)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The enabled MCP servers that are actually **registered** — intersect
    /// workspace.mcpServers with `sbx mcp ls` and drop (logging) any that aren't.
    private func effectiveMCPServers() async -> [String] {
        guard !workspace.mcpServers.isEmpty else { return [] }
        let registered = await SbxClient.shared.listMCPServers(mcpURL: workspace.mcpURL)
        let valid = workspace.mcpServers.filter { registered.keys.contains($0) }
        let dropped = workspace.mcpServers.filter { !registered.keys.contains($0) }
        if !dropped.isEmpty {
            Log.info(.workspace, "mcp load: skipping unregistered server(s): \(dropped.joined(separator: ", "))")
        }
        return valid
    }

    /// An in-flight bring-up, and the window (controller) that started it.
    private struct BringUp {
        let task: Task<Void, Error>
        let owner: ObjectIdentifier
    }

    /// In-flight bring-ups by container name, across every window: sbx names are
    /// global, and the windows on one folder share its sandboxes. Opening a
    /// workspace (startup `ensureContainer`) and launching its selected session
    /// (`ensureContainerReady`) — or two windows on one folder — bring the same
    /// container up at once; without this each saw "no sandbox" and ran its own
    /// `sbx create`, or each rebuilt it (one removing what the other was making).
    private static var bringUps: [String: BringUp] = [:]
    /// How many bring-ups each container name has had (a status poll that
    /// spans one drops its answer).
    private static var bringUpsStarted: [String: Int] = [:]

    /// Bring a container up, joining one already in flight for it when that
    /// one's result will do. A forced rebuild, or a check against a config
    /// that just changed (`recheck`, and every rebuild to match the config —
    /// the in-flight one may have read the old one), waits for it, then runs its own.
    private func bringUpContainer(for agent: AgentKind, onMismatch: MismatchAction,
                                  force: Bool = false, recheck: Bool = false) async throws {
        try await serializedBringUp(for: agent, joinInflight: !force && !recheck && onMismatch != .rebuild) {
            try await self.performBringUp(for: agent, onMismatch: onMismatch, force: force)
        }
    }

    /// Run `work` as the container's only bring-up. With `joinInflight`, an
    /// in-flight one is the result; otherwise wait it out, then run `work`.
    private func serializedBringUp(for agent: AgentKind, joinInflight: Bool,
                                   _ work: @escaping @MainActor () async throws -> Void) async throws {
        let name = containerName(for: agent)
        // Again after each wait: another waiter may have started its own meanwhile.
        while let inflight = Self.bringUps[name] {
            if joinInflight { return try await join(inflight, for: agent) }
            _ = try? await inflight.task.value
        }
        let task = Task { @MainActor in try await work() }
        Self.bringUps[name] = BringUp(task: task, owner: ObjectIdentifier(self))
        Self.bringUpsStarted[name, default: 0] += 1
        defer { if Self.bringUps[name]?.task == task { Self.bringUps[name] = nil } }
        try await task.value
    }

    /// Wait for an in-flight bring-up. One another window started set that
    /// window's view of the container, so take this one's from sbx once no
    /// other window is bringing it up: that window's session launch often
    /// attaches right after its rebuild, and an attach says nothing here (this
    /// window would keep showing "Rebuilding…" for good).
    private func join(_ inflight: BringUp, for agent: AgentKind) async throws {
        guard inflight.owner != ObjectIdentifier(self) else { return try await inflight.task.value }
        do {
            try await inflight.task.value
        } catch {
            containerPhases[agent] = .failed(error.localizedDescription)
            throw error
        }
        let name = containerName(for: agent)
        while true {
            while let next = Self.bringUps[name] {
                // This window's own sets the container here itself.
                if next.owner == ObjectIdentifier(self) { return try await next.task.value }
                _ = try? await next.task.value
            }
            let started = Self.bringUpsStarted[name]
            let sandbox: Sandbox?
            do {
                sandbox = try await SbxClient.shared.status(name: name)
            } catch {
                // sbx didn't answer: the bring-up is over all the same, so
                // don't leave this window building (its panes wait on that).
                if containerPhases[agent]?.isBuilding == true {
                    containerPhases[agent] = .failed(error.localizedDescription)
                }
                throw error
            }
            // One started while sbx answered: take the container after it.
            guard Self.bringUps[name] == nil, Self.bringUpsStarted[name] == started else { continue }
            containers[agent] = sandbox
            containerPhases[agent] = sandbox.map { $0.isRunning ? .running : .stopped } ?? .absent
            guard sandbox != nil else { return }
            refreshKitStartupIfNeeded(for: agent)
            refreshKitDrift(for: agent)
            return
        }
    }

    /// A bring-up is (re)making `agent`'s sandbox: say so here and in the other
    /// windows on the folder, which drop their sessions in a sandbox being
    /// rebuilt (as this one's panes do) and take the new one when it's up.
    private func beginBuilding(_ agent: AgentKind, _ phase: ContainerPhase, _ activity: String) {
        func show(in window: WorkspaceController) {
            // Phase first: the activity's observers read which sandbox it is.
            window.containerPhases[agent] = phase
            window.activity = activity
            window.resetKitStartup(for: agent)
            window.kitDrift[agent] = nil
            window.buildLogs[agent] = BuildLog()
        }
        show(in: self)
        let name = containerName(for: agent)
        for window in store.others(than: self) where !window.isClosed && window.containerName(for: agent) == name {
            show(in: window)
            window.runAction { @MainActor in try await window.bringUpContainer(for: agent, onMismatch: .attach) }
        }
    }

    /// Where a build of `agent`'s sandbox reports sbx's progress: its log here
    /// and in the other windows on the folder (they show the build too).
    private func buildProgress(for agent: AgentKind) -> SbxClient.ProgressHandler {
        let name = containerName(for: agent)
        return { [weak self] lines in
            guard let self else { return }
            for window in [self] + self.store.others(than: self)
            where !window.isClosed && window.containerName(for: agent) == name {
                window.buildLogs[agent, default: BuildLog()].append(lines)
            }
        }
    }

    /// Add kits to an existing container with `sbx kit add`, one ref at a time.
    /// Falls back to a full rebuild when the container is absent, has other
    /// create-time changes pending (mounts, image), or sbx refuses a kit.
    private func performKitAdd(_ refs: [String], previousKits: [String], for agent: AgentKind) async throws {
        let name = containerName(for: agent)
        let mounts = resolvedMounts()
        guard try await SbxClient.shared.status(name: name) != nil,
              state.appliedMountSignatures[name] == configSignature(mounts: mounts, kits: previousKits, agent: agent) else {
            return try await performBringUp(for: agent, onMismatch: .rebuild, force: true)
        }
        await learnKitRequirements(refs)
        let refs = kits(for: agent, from: refs)
        guard !refs.isEmpty else {
            // None of them is for this agent's sandbox: it's already as configured.
            recordSignature(configSignature(mounts: mounts, kits: resolvedKits(), agent: agent), for: name)
            return
        }
        Log.info(.workspace, "adding \(refs.count) kit(s) to '\(name)' with sbx kit add")
        // "Rebuilding…": the recreate swaps the container, so its sessions end
        // just as in a rebuild (the detail pane drops their terminals on this prefix).
        beginBuilding(agent, .rebuilding, "Rebuilding \(name) — adding \(refs.count == 1 ? "a kit" : "\(refs.count) kits")…")
        for ref in refs {
            let reason: String
            do {
                let out = try await SbxClient.shared.kitAdd(sandbox: name, ref: ref, cwd: workspace.rootURL.path,
                                                            mcpURL: workspace.mcpURL, onProgress: buildProgress(for: agent))
                if out.ok { continue }
                reason = out.stderr.isEmpty ? out.stdout : out.stderr
            } catch {
                reason = error.localizedDescription
            }
            Log.info(.workspace, "sbx kit add \(ref) → '\(name)' not applied (\(reason)); rebuilding instead")
            return try await performBringUp(for: agent, onMismatch: .rebuild, force: true)
        }
        recordSignature(configSignature(mounts: mounts, kits: resolvedKits(), agent: agent), for: name)
        let sandbox: Sandbox
        do {
            sandbox = try await SbxClient.shared.waitUntilRunning(name: name, timeout: 60)
        } catch {
            containerPhases[agent] = .failed(error.localizedDescription)
            throw error
        }
        containers[agent] = sandbox
        containerPhases[agent] = .running
        refreshKitStartup(for: agent)
        refreshKitDrift(for: agent)
        // The swap container's gateway may not carry dynamically loaded servers over.
        await loadMCPServers(await effectiveMCPServers(), into: name)
    }

    /// Shared create/attach/rebuild core for an agent's container. `force`
    /// rebuilds even when the mounts are unchanged.
    private func performBringUp(for agent: AgentKind, onMismatch: MismatchAction,
                                force: Bool) async throws {
        // Mirror host MCP configs and OAuth tokens into the bind-mounted claude
        // config dir before the container starts (ported from sbx-ui projects.rs).
        // When sbx's proxy holds the Claude login, sandboxes authenticate through
        // it, so the Keychain login stays out of the file (a sandbox refreshing
        // from it would rotate the host's refresh token).
        let name = containerName(for: agent)
        let homeURL = home
        // Nothing below changes what `sbx ls` says: ask while the rest runs.
        async let listing = SbxClient.shared.status(name: name)
        let proxied = await SbxClient.shared.hasAnthropicSecret(sandbox: name)
        await Task.detached(priority: .utility) {
            ClaudeConfigSync.syncMCPServers(home: homeURL)
            ClaudeConfigSync.syncCredentialsFromKeychain(home: homeURL, includeClaudeLogin: !proxied)
        }.value

        let mounts = resolvedMounts()
        await learnKitRequirements(resolvedKits())
        let kits = kits(for: agent, from: resolvedKits())
        let signature = configSignature(mounts: mounts, kits: kits, agent: agent)

        let existing = try await listing
        let built: Sandbox
        // The servers to load once it's built — asked before the build starts
        // (an `sbx` call spawned as `sbx create` winds down can wedge), and
        // only then: attaching to a sandbox loads nothing.
        let mcp: [String]
        if let existing {
            // A custom agent whose kit is no longer registered can't be
            // recreated: its sandbox is kept as it is — not offered a rebuild,
            // and a requested one fails saying why.
            let cannotRecreate = SbxClient.cannotRecreate(agent, sandbox: name)
            // Decide whether to rebuild. `force` skips the unchanged-mounts
            // shortcut (e.g. an MCP change that doesn't alter mounts).
            if !force {
                if state.appliedMountSignatures[name] == signature {
                    Log.info(.workspace, "attached to existing container '\(name)' (\(mounts.count) mounts)")
                    containers[agent] = existing
                    containerPhases[agent] = existing.isRunning ? .running : .stopped
                    refreshKitStartupIfNeeded(for: agent)
                    refreshKitDrift(for: agent)
                    return
                }
                switch onMismatch {
                case .attach:
                    containers[agent] = existing
                    containerPhases[agent] = existing.isRunning ? .running : .stopped
                    refreshKitStartupIfNeeded(for: agent)
                    refreshKitDrift(for: agent)
                    return
                case .prompt:
                    guard cannotRecreate == nil, await confirmRebuild(name: name, killsRunning: existing.isRunning) else {
                        containers[agent] = existing
                        containerPhases[agent] = existing.isRunning ? .running : .stopped
                        refreshKitStartupIfNeeded(for: agent)
                        refreshKitDrift(for: agent)
                        return
                    }
                case .rebuild:
                    break   // fall through to rebuild
                }
            }
            if let error = cannotRecreate {
                containers[agent] = existing
                containerPhases[agent] = existing.isRunning ? .running : .stopped
                refreshKitStartupIfNeeded(for: agent)
                refreshKitDrift(for: agent)
                throw error
            }
            mcp = await effectiveMCPServers()
            Log.info(.workspace, "rebuilding container '\(name)' (\(mounts.count) mounts, \(kits.count) kits, force=\(force))")
            beginBuilding(agent, .rebuilding, "Rebuilding \(name)…")
            do {
                built = try await SbxClient.shared.rebuild(workspace: workspace, agent: agent, name: name, mounts: mounts, kits: kits,
                                                           onProgress: buildProgress(for: agent))
            } catch {
                containerPhases[agent] = .failed(error.localizedDescription)
                throw error
            }
        } else {
            mcp = await effectiveMCPServers()
            Log.info(.workspace, "creating container '\(name)' for \(agent.rawValue) (\(mounts.count) mounts, \(kits.count) kits)")
            beginBuilding(agent, .creating, "Building \(name)…")
            do {
                built = try await SbxClient.shared.create(workspace: workspace, agent: agent, name: name, mounts: mounts, kits: kits,
                                                          onProgress: buildProgress(for: agent)) { [weak self] in
                    // Recorded once it exists: quitting during kit setup mustn't
                    // read as a changed config next time.
                    self?.recordSignature(signature, for: name)
                }
            } catch {
                containerPhases[agent] = .failed(error.localizedDescription)
                throw error
            }
        }
        // A fresh container has exactly the configured kits; nothing left to ignore.
        state.ignoredKitDrift[name] = nil
        recordSignature(signature, for: name)
        // This root now has a created sandbox — track it (General list + default).
        RootFolderStore.ensureRegistered(workspace.rootURL.path)
        // Use the sandbox create/rebuild already returned rather than re-fetching
        // with another `sbx ls`: that extra call, spawned while `sbx create` is
        // still winding down, is the one whose termination delivery wedges and
        // hangs the launch (see SbxClient.run timeout note).
        containers[agent] = built
        containerPhases[agent] = built.isRunning ? .running : .stopped
        // Kits run their startup steps in the background after create returns
        // (the dispatcher waits on hosts, downloads binaries…) — start following
        // the log now so failures/warnings surface as they happen.
        refreshKitStartup(for: agent)
        refreshKitDrift(for: agent)
        // Dynamic MCP: attach the user's checked servers to the now-running
        // sandbox via `sbx mcp load` (discovery stays on for everything else).
        await loadMCPServers(mcp, into: name)
    }

    private func recordSignature(_ signature: String, for name: String) {
        state.appliedMountSignatures[name] = signature
        writeState()
    }

    // MARK: - Confirmation

    /// Modal confirmation before a rebuild that would kill running sessions.
    private func confirmRebuild(name: String, killsRunning: Bool) async -> Bool {
        // The window it was for closed meanwhile: no question with nothing to
        // show it for (and no rebuild under another window's sessions).
        if isClosed {
            Log.info(.workspace, "not rebuilding “\(name)”: its window closed")
            return false
        }
        if AutomatedRun.isActive {
            let ok = AutomatedRun.isScratch(workspace.rootURL)
            Log.info(.workspace, "automated run: \(ok ? "rebuilding" : "not rebuilding") “\(name)” (mounts changed)")
            return ok
        }
        return Alerts.confirm("Rebuild “\(name)”?", killsRunning
            ? "The workspace mounts changed. Rebuilding stops and recreates the container, ending any running sessions in it."
            : "The workspace mounts changed. Rebuilding recreates the container with the new mounts.",
                              confirm: "Rebuild", destructive: killsRunning)
    }

    // MARK: - Persisting

    /// Write the folder's config (`config.json`) after a change to it.
    private func saveConfig() {
        do {
            try config.save(root: workspace.rootURL)
            store.saveFailureReported = false
        } catch {
            persistFailed("settings", error)
        }
    }

    /// Write the folder's session list (`state.json`); `saveState` also
    /// reloads the sidebar.
    private func writeState() {
        do {
            try state.save(root: workspace.rootURL)
            store.saveFailureReported = false
        } catch {
            persistFailed("session list", error)
        }
    }

    /// Log every failed write; tell the person once per folder until a write
    /// works again (not on each Stepper tick or synced theme change).
    private func persistFailed(_ what: String, _ error: any Error) {
        let reason = error.localizedDescription
        let root = workspace.rootURL
        Log.error(.workspace, "saving \(what) in \(root.path(percentEncoded: false)) failed: \(reason)")
        guard !store.saveFailureReported else { return }
        store.saveFailureReported = true
        // Named: it can come from background work in a window that isn't in
        // front, with other workspaces open.
        warn("Couldn’t save the \(what) for “\(root.lastPathComponent)”",
             "\(root.path(percentEncoded: false).tildeAbbreviated): \(reason)\n\n"
                + "Changes made now won’t be there after Sandshell restarts.")
    }

    /// A warning for the person, on the next turn: not from inside the SwiftUI
    /// action, binding or `onDisappear` (or the didSet) that ran into it.
    private func warn(_ title: String, _ info: String) {
        Task { Alerts.inform(title, info, style: .warning) }
    }

    // MARK: - Action plumbing

    /// `work` is `@MainActor`-isolated so the awaited body runs entirely on the
    /// main actor with no executor hop. (A non-isolated closure here hopped
    /// MainActor→generic→MainActor; on the create path — where `sbx create` leaves
    /// a child process running past `bringUpContainer`'s return — the hop back to
    /// the main actor never resumed, wedging the build with the spinner stuck on.)
    private func runAction(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { @MainActor in
            do {
                try await work()
                self.lastError = nil
            } catch {
                self.lastError = error.localizedDescription
                Log.error(.workspace, "workspace action failed: \(error.localizedDescription)")
            }
            self.busy = false
            self.activity = nil
        }
    }
}

/// Identifies what is selected in the sidebar. A single-case enum (rather than
/// a bare `UUID?`) deliberately — the sidebar no longer has folder rows to
/// select, but this leaves room for a future non-session selection (e.g. a
/// pinned filter) without another type change.
enum SidebarSelection: Equatable {
    case session(UUID)
}

/// Whether a session's agent is actively working or idle.
enum SessionStatus: Equatable { case working, ready }

/// Runtime transition produced by a transcript activity update.
struct SessionActivityTransition: Equatable {
    var finishedWork: Bool
    var workSeconds: TimeInterval
}

/// Live status + work-time for a session, derived from its agent transcript.
/// All per-session reactive state lives here — the single source of truth for
/// session live-ness, work status, timing, and unread indicator.
struct SessionRuntime: Equatable {
    var status: SessionStatus = .ready
    var workingSince: Date?
    /// Snapshot work time (updated by reportActivity; use liveWorkSeconds for display).
    var workSeconds: TimeInterval = 0
    /// Total of fully-completed working bursts; current burst adds on top.
    var workSecondsCompleted: TimeInterval = 0
    /// When the agent last wrote to its transcript (drives "2m ago").
    var lastActivityAt: Date?
    /// A live terminal is open for this session (drives bold name weight).
    var isLive: Bool = false
    /// The agent is waiting on the person (a question or a permission prompt).
    var isWaiting: Bool = false
    /// What it's waiting for, in the sidebar row's words ("permission to run
    /// swift test", "a question"; `WaitingFor`). Nil when not waiting.
    var waitingFor: String?
    /// The session's agent stopped and can't go on (a chat that isn't signed
    /// in, or whose agent exited): why, shown instead of "Ready".
    var stoppedReason: String?
    /// Session finished a working burst in the background; user hasn't looked.
    var isUnread: Bool = false
    /// Latest status Claude Code reported for this session (model, context,
    /// tokens, cost) via the Sandshell status feed. `nil` until the first report.
    var claudeStatus: ClaudeSessionStatus?

    /// Real-time work total: completed bursts + elapsed in the current burst.
    /// Pass `at:` from a `TimelineView` context for SwiftUI; defaults to `Date.now`.
    func liveWorkSeconds(at now: Date = .now) -> TimeInterval {
        if status == .working, let since = workingSince {
            return workSecondsCompleted + now.timeIntervalSince(since)
        }
        return workSecondsCompleted
    }
}

/// Lifecycle phase of a workspace container — the single typed source of truth
/// covering creation, rebuild, running, stopped, and failure state.
enum ContainerPhase: Equatable {
    case absent       // not yet created (or removed)
    case creating     // sbx create in flight
    case rebuilding   // sbx remove + recreate in flight
    case running      // container exists and sbx reports it running
    case stopped      // container exists but is not running
    case failed(String) // last create/rebuild errored

    var isBuilding: Bool { self == .creating || self == .rebuilding }

    var displayLabel: String {
        switch self {
        case .absent:           "absent"
        case .creating:         "creating"
        case .rebuilding:       "rebuilding"
        case .running:          "running"
        case .stopped:          "stopped"
        case .failed(let msg):  "failed: \(msg.prefix(60))"
        }
    }
}

// MARK: - Folders & sessions

extension WorkspaceController {
    /// Folders in display order (the root folder sorts first).
    var folders: [Folder] {
        state.folders.sorted { $0.order < $1.order }
    }

    /// The workspace root folder row (always present).
    var rootFolder: Folder? { state.folders.first { $0.isRoot } }

    /// Sessions of a folder in display order.
    func sessions(in folderID: UUID) -> [Session] {
        state.sessions.filter { $0.folderID == folderID }.sorted { $0.order < $1.order }
    }

    func folder(id: UUID) -> Folder? { state.folders.first { $0.id == id } }
    func session(id: UUID) -> Session? { state.sessions.first { $0.id == id } }

    /// Sidebar display label for a folder: the root shows the workspace folder
    /// name; others show their relative path (head-truncated by the cell).
    func displayName(for folder: Folder) -> String {
        folder.isRoot ? workspace.rootURL.lastPathComponent : folder.relativePath
    }

    // MARK: Session runtime (status / work-time)

    func runtime(_ id: UUID) -> SessionRuntime? { runtimes[id] }

    func backgroundTasks(_ id: UUID) -> [BackgroundTask] { backgroundTasks[id] ?? [] }
    func runningBackgroundTasks(_ id: UUID) -> Int { backgroundTasks[id]?.count(where: \.isRunning) ?? 0 }

    /// Ask a running sandbox what it is (cached; one probe at a time), once
    /// any session launching has its `sbx exec` in.
    func probeSandboxSystem(_ name: String) {
        guard sandboxSystems[name] == nil, !probingSandboxes.contains(name) else { return }
        probingSandboxes.insert(name)
        Task {
            await SbxClient.afterLaunches()
            let output = await SbxClient.shared.exec(inSandbox: name, script: SandboxSystem.probe)
            probingSandboxes.remove(name)
            if let output, let system = SandboxSystem(probeOutput: output) { sandboxSystems[name] = system }
        }
    }

    /// How `folder` is shared with `agent`'s sandbox: its real mounts once it
    /// exists, else what the workspace's mount policy will give it.
    func sandboxAccess(for folder: URL, agent: AgentKind) -> SandboxAccess {
        let name = containerName(for: agent)
        if containers[agent]?.isRunning == true { probeSandboxSystem(name) }
        return SandboxAccess(folder: folder, sandbox: name, mounts: sandboxMounts(agent), created: containers[agent] != nil,
                             system: sandboxSystems[name])
    }

    /// Where a session's folder is inside its sandbox: what its launch runs in.
    /// (A folder saved as /private/tmp/x is at /tmp/x in a sandbox that mounted that.)
    func sandboxWorkdir(_ workdir: String, agent: AgentKind) -> String {
        workdir.isEmpty ? workdir : SandboxAccess.sandboxPath(for: workdir, mounts: sandboxMounts(agent))
    }

    /// The agent's sandbox's mounts: its real ones once it exists, else the planned ones.
    private func sandboxMounts(_ agent: AgentKind) -> [SandboxAccess.Mount] {
        if let sandbox = containers[agent], !sandbox.workspaces.isEmpty {
            return sandbox.workspaces.map {
                let spec = MountSpec(spec: $0)
                return .init(path: spec.path.standardizedFileURL.path, readOnly: spec.readonly)
            }
        }
        return resolvedMounts().map { .init(path: $0.path.standardizedFileURL.path, readOnly: $0.readonly) }
    }

    /// The tail of a background command's output file, read inside its sandbox.
    func backgroundOutput(_ sessionID: UUID, _ task: BackgroundTask) async -> String? {
        guard let path = task.outputPath, let session = session(id: sessionID) else { return nil }
        let name = containerName(for: session.containerAgentKind)
        guard let text = try? await SbxClient.shared.readFile(inSandbox: name, path: path) else { return nil }
        return text.count > 6000 ? "…" + String(text.suffix(6000)) : text
    }

    /// A background task finished while the user was elsewhere: the row gets
    /// its unread dot, like a finished turn.
    func markBackgroundTaskSeenLater(_ id: UUID) {
        guard selection != .session(id), var rt = runtimes[id], !rt.isUnread else { return }
        rt.isUnread = true
        runtimes[id] = rt
    }

    func setBackgroundTasks(_ id: UUID, _ tasks: [BackgroundTask]) {
        guard backgroundTasks[id] != tasks else { return }
        backgroundTasks[id] = tasks.isEmpty ? nil : tasks
    }

    /// Whether a session has a live terminal (set by the detail pane).
    func isLive(_ id: UUID) -> Bool { runtimes[id]?.isLive ?? false }
    func setWaiting(_ id: UUID, _ waiting: Bool, for what: String? = nil) {
        var rt = runtimes[id] ?? SessionRuntime()
        let what = waiting ? what : nil
        guard rt.isWaiting != waiting || rt.waitingFor != what else { return }
        rt.isWaiting = waiting
        rt.waitingFor = what
        runtimes[id] = rt
    }

    #if DEBUG
    /// Self-tests: put a session's row in a state without running anything.
    func debugSetRuntime(_ id: UUID, _ runtime: SessionRuntime?) {
        runtimes[id] = runtime
    }
    #endif

    func setStopped(_ id: UUID, _ reason: String?) {
        var rt = runtimes[id] ?? SessionRuntime()
        guard rt.stoppedReason != reason else { return }
        rt.stoppedReason = reason
        if reason != nil { rt.status = .ready; rt.workingSince = nil }
        runtimes[id] = rt
    }

    /// A pane started launching a session: it's used now (see `addSession`).
    func markLaunched(_ id: UUID) { store.markLaunched(id) }

    func setLive(_ id: UUID, _ live: Bool) {
        if live { markLaunched(id) }
        var rt = runtimes[id] ?? SessionRuntime()
        guard rt.isLive != live else { return }
        rt.isLive = live
        runtimes[id] = rt
        // A live terminal means sbx exec succeeded → container is running.
        // (The sandbox it runs in: a shell in Claude's sandbox is Claude's.)
        if live, let kind = session(id: id)?.containerAgentKind,
           containerPhases[kind]?.isBuilding != true {
            containerPhases[kind] = .running
        }
    }

    /// Report whether a session's agent is currently working (from transcript
    /// activity). Tracks the current working burst for the live timer and
    /// maintains the unread flag in the session's `SessionRuntime`.
    @discardableResult
    func reportActivity(_ id: UUID, working: Bool, lastWrite: Date? = nil,
                        at now: Date) -> SessionActivityTransition {
        var rt = runtimes[id] ?? SessionRuntime()
        let wasWorking = rt.status == .working
        if let lastWrite { rt.lastActivityAt = lastWrite }
        if working {
            rt.isUnread = false  // clear dot while actively working; re-flags on completion
            if rt.workingSince == nil { rt.workingSince = now }
            rt.status = .working
            // Accumulate: completed bursts + elapsed in this burst.
            rt.workSeconds = rt.workSecondsCompleted + now.timeIntervalSince(rt.workingSince ?? now)
        } else {
            if rt.status == .working, let since = rt.workingSince {
                // Bank the completed burst so the next one adds on top.
                rt.workSecondsCompleted += now.timeIntervalSince(since)
                rt.workSeconds = rt.workSecondsCompleted
            }
            rt.status = .ready
            rt.workingSince = nil
            // Flag unread only if the session finished in the background.
            if selection != .session(id) { rt.isUnread = true }
            // Remember when, for the list's order and "Xm ago" after a relaunch
            // (once per finished turn, not on every poll).
            if wasWorking, let idx = state.sessions.firstIndex(where: { $0.id == id }) {
                state.sessions[idx].lastActiveAt = rt.lastActivityAt ?? now
                writeState()
                adoptGeneratedName(id)
            }
        }
        if runtimes[id] != rt { runtimes[id] = rt }   // publish only on change
        return SessionActivityTransition(finishedWork: wasWorking && !working,
                                         workSeconds: rt.workSeconds)
    }

    /// All sessions, most-recently-active first, each followed by its forks —
    /// the sidebar's list (`SessionOrder`). Falls back to `createdAt` until a
    /// session has any real activity (the last turn's time persists in
    /// `Session.lastActiveAt`). Not
    /// re-derived on every runtime tick from the caller's side (see
    /// `SidebarListController.runtimesChanged`) — only when a session is
    /// created/closed or transitions working↔ready — so rows don't jump around
    /// while a timer or "Xm ago" label is merely ticking in place.
    var orderedSessions: [Session] {
        let byID = Dictionary(state.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return sessionOrder.compactMap { byID[$0.id] }
    }

    /// `orderedSessions` as ids, with which of them are forks nested under
    /// their group's top session.
    var sessionOrder: [SessionOrder.Entry] {
        // Whatever needs the person first, then what's working, then by activity.
        SessionOrder.arrange(state.sessions, lastActivity: sortKey,
                             rank: { [runtimes] in SessionRowStatus.rank(runtimes[$0.id]) })
    }

    private func sortKey(_ session: Session) -> Date {
        max(runtimes[session.id]?.lastActivityAt ?? .distantPast, session.lastActiveAt ?? .distantPast,
            session.createdAt)
    }

    /// When the session's agent last wrote: this run's activity, else the last
    /// turn before (`Session.lastActiveAt`). Nil if it never has.
    func lastActivity(_ id: UUID) -> Date? {
        runtimes[id]?.lastActivityAt ?? session(id: id)?.lastActiveAt
    }

    /// Cycle the selection to the next (`+1`) / previous (`-1`) of `ids` (the
    /// sessions the sidebar lists, in its order).
    func selectAdjacentSession(_ delta: Int, in ids: [UUID]) {
        let current: UUID? = if case let .session(id) = selection { id } else { nil }
        guard let next = Self.adjacentSession(to: current, in: ids, delta) else { return }
        selection = .session(next)
    }

    /// The session `delta` places after `current` in `ids`, wrapping around;
    /// from none (or one not in `ids`), the first (forward) or last (back).
    static func adjacentSession(to current: UUID?, in ids: [UUID], _ delta: Int) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return delta >= 0 ? ids.first : ids.last }
        let count = ids.count
        return ids[((index + delta) % count + count) % count]
    }

    var expandedFolderIDs: Set<UUID> { Set(state.expandedFolderIDs) }

    /// Persist expansion only — not a structural change, so it must NOT bump
    /// `revision` (which would reload the outline mid-interaction).
    func setFolder(_ id: UUID, expanded: Bool) {
        var ids = Set(state.expandedFolderIDs)
        if expanded { ids.insert(id) } else { ids.remove(id) }
        state.expandedFolderIDs = Array(ids)
        writeState()
    }

    /// Persist a structural change and signal the sidebar to reload.
    private func saveState() {
        revision += 1
        writeState()
    }

    /// Host URL for a folder (the workspace root itself for the root folder).
    func folderURL(for folder: Folder) -> URL {
        folder.isRoot ? workspace.rootURL
            : workspace.rootURL.appending(path: folder.relativePath, directoryHint: .isDirectory)
    }

    /// Container-side workdir for a folder (mounts land at the host path).
    private func workdir(for folder: Folder) -> String {
        folderURL(for: folder).path
    }

    // MARK: Folder ops

    /// Make `name` a filesystem-safe relative path that is unique within root.
    /// Single-segment input only (the inline "New Folder" rename); slashes are
    /// flattened to `-`. Use `addExistingFolder` to register nested folders.
    private func uniqueRelativePath(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = trimmed.replacing("/", with: "-")
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "New Folder" }
        let existing = Set(state.folders.map { $0.relativePath })
        let fm = FileManager.default
        func taken(_ n: String) -> Bool {
            existing.contains(n) || fm.fileExists(atPath: workspace.rootURL.appending(path: n).path)
        }
        guard taken(base) else { return base }
        var i = 2
        while taken("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    private func nextFolderOrder() -> Int { (state.folders.map(\.order).max() ?? -1) + 1 }

    /// Create a new (single-segment) subfolder under the root and add its row.
    @discardableResult
    func addFolder(name: String) -> Folder? {
        let relativePath = uniqueRelativePath(from: name)
        let dir = workspace.rootURL.appending(path: relativePath, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.error(.workspace, "addFolder failed: \(error.localizedDescription)")
            warn("Couldn’t create “\(relativePath)”", error.localizedDescription)
            return nil
        }
        return registerFolder(relativePath: relativePath)
    }

    /// "Add Folder…": pick an existing folder inside the workspace and add it.
    func chooseExistingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = workspace.rootURL
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder inside \(workspace.rootURL.lastPathComponent)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addExistingFolder(at: url)
    }

    /// Register an existing directory (possibly nested) as a folder row. Returns
    /// nil if the directory is not under the workspace root or is already a row.
    @discardableResult
    func addExistingFolder(at url: URL) -> Folder? {
        let rootPath = workspace.rootURL.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target != rootPath else { return rootFolder }   // the root is already a row
        guard target.hasPrefix(rootPath + "/") else {
            let name = workspace.rootURL.lastPathComponent
            warn("Folders must live inside “\(name)”", "“\(url.lastPathComponent)” isn’t in \(name). Choose a folder inside it.")
            return nil
        }
        let relativePath = String(target.dropFirst(rootPath.count + 1))
        if let existing = state.folders.first(where: { $0.relativePath == relativePath }) {
            return existing
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return registerFolder(relativePath: relativePath)
    }

    private func registerFolder(relativePath: String) -> Folder {
        let folder = Folder(relativePath: relativePath, order: nextFolderOrder())
        state.folders.append(folder)
        state.expandedFolderIDs.append(folder.id)   // start expanded so "New Session" shows
        saveState()
        return folder
    }

    /// Rename a folder on disk and update the rows nested in it and the
    /// workdirs (and Claude conversations) of the sessions working in it. The
    /// root folder is not renameable (its name is the workspace root). Throws
    /// when the move on disk fails; a name it rejects outright changes nothing.
    func renameFolder(_ id: UUID, to newName: String) throws {
        guard let idx = state.folders.firstIndex(where: { $0.id == id }) else { return }
        let old = state.folders[idx]
        guard !old.isRoot else { return }
        // No-op when the field commits unchanged (end-editing fires regardless).
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old.relativePath else { return }
        // Rename within the same parent directory (single-segment rename).
        let parent = (old.relativePath as NSString).deletingLastPathComponent
        var leaf = trimmed.replacing("/", with: "-")
        while leaf.hasPrefix(".") { leaf.removeFirst() }
        let newRelative = parent.isEmpty ? leaf : "\(parent)/\(leaf)"
        guard newRelative != old.relativePath else { return }
        let src = workspace.rootURL.appending(path: old.relativePath, directoryHint: .isDirectory)
        let dst = workspace.rootURL.appending(path: newRelative, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.moveItem(at: src, to: dst)
            } else {
                try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            }
        } catch {
            Log.error(.workspace, "renameFolder failed: \(error.localizedDescription)")
            throw error
        }
        // Claude files conversations by their cwd: take those of the sessions
        // working in the folder (open, or closed here and reopenable) along —
        // except a running session's, which its agent keeps writing under the
        // cwd it started in: its next launch takes that one (`settleConversation`).
        let workdirs = Set((state.sessions + recentlyClosed).map(\.workdir) + [src.path])
        let running = runningSessionIDs()
        TranscriptReader.moveClaudeProjects(workdirs.compactMap { from in
            Session.workdir(from, movedFrom: src.path, to: dst.path).map { (from, $0) }
        }, home: home, keeping: Set(state.sessions.filter { running.contains($0.id) }.compactMap(\.transcriptID)))
        // Rows nested in it, and sessions working in it or below, follow it.
        state.moveFolder(id, to: newRelative, root: workspace.rootURL, running: running)
        for i in recentlyClosed.indices {
            if let moved = Session.workdir(recentlyClosed[i].workdir, movedFrom: src.path, to: dst.path) {
                recentlyClosed[i].workdir = moved
            }
        }
        saveState()
    }

    /// Sessions running in any window on the folder.
    private func runningSessionIDs() -> Set<UUID> {
        Set(([self] + store.others(than: self)).flatMap { window in
            window.runtimes.filter { $0.value.isLive }.map(\.key)
        })
    }

    /// A session about to launch whose folder moved while it last ran: its
    /// agent filed the conversation under the old cwd. It starts in the new
    /// one now, so take the conversation there first (or resuming finds nothing).
    func settleConversation(_ id: UUID) {
        guard let idx = state.sessions.firstIndex(where: { $0.id == id }),
              let from = state.sessions[idx].transcriptWorkdir else { return }
        let session = state.sessions[idx]
        if let tid = session.transcriptID {
            TranscriptReader.moveClaudeConversation(tid, from: from, to: session.workdir, home: home)
        }
        state.sessions[idx].transcriptWorkdir = nil
        saveState()
    }

    /// Remove a folder from the sidebar (the directory stays on disk). The root
    /// folder cannot be removed.
    func hideFolder(_ id: UUID) {
        guard folder(id: id)?.isRoot != true else { return }
        removeFolders([id])
    }

    /// Move a folder's directory to the Trash, then remove it from the sidebar
    /// (with the rows nested in it: their directories went too, and the next
    /// open would recreate them empty). The root folder cannot be trashed. When
    /// the Trash refuses it, say why and keep the rows (it's still on disk).
    func trashFolder(_ id: UUID) {
        guard let folder = folder(id: id), !folder.isRoot else { return }
        let dir = folderURL(for: folder)
        let rows = [id] + state.folders(nestedIn: id).map(\.id)
        // Already gone from disk (deleted in Finder): just drop its rows.
        guard FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) else { return removeFolders(rows) }
        do {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        } catch {
            Log.error(.workspace, "trashFolder failed: \(error.localizedDescription)")
            warn("Couldn’t move “\(displayName(for: folder))” to the Trash", error.localizedDescription)
            return
        }
        removeFolders(rows)
    }

    /// Drop folder rows and their sessions from the sidebar.
    private func removeFolders(_ ids: [UUID]) {
        let ids = Set(ids)
        state.sessions.removeAll { ids.contains($0.folderID) }
        state.folders.removeAll { ids.contains($0.id) }
        clearSelectionIfGone()
        saveState()
    }

    // MARK: Session ops

    private func nextSessionOrder(in folderID: UUID) -> Int {
        (state.sessions.filter { $0.folderID == folderID }.map(\.order).max() ?? -1) + 1
    }

    /// Default name for a fresh session, e.g. "New Claude Session". A shell
    /// attached to another agent's sandbox reads "Shell in Claude", etc.
    static func defaultSessionName(for agent: AgentKind, containerAgent: AgentKind? = nil) -> String {
        Session.defaultName(for: agent, containerAgent: containerAgent)
    }

    /// The default names before agents had brand spellings (the raw id,
    /// capitalized: "New Docker-Agent Session", "New Opencode Session").
    private static func legacyDefaultSessionName(for agent: AgentKind, containerAgent: AgentKind? = nil) -> String {
        Session.legacyDefaultName(for: agent, containerAgent: containerAgent)
    }

    /// Add a session, or reuse an existing **pristine** one (same project +
    /// agent + container, never used: still showing its default name and not
    /// manually renamed) so repeatedly asking for a new session doesn't pile up
    /// duplicates. Pass an explicit `name` to always create. `containerAgent`
    /// (when it differs from `agent`) attaches this session to another agent's
    /// sandbox — e.g. a shell inside the claude/codex container.
    @discardableResult
    func addSession(folderID: UUID, agent: AgentKind, name: String? = nil,
                    containerAgent: AgentKind? = nil, chat: Bool = false) -> Session? {
        guard let folder = folder(id: folderID) else { return nil }
        // Normalize away a no-op override so it doesn't split reuse buckets.
        let override = (containerAgent == agent) ? nil : containerAgent
        let defaultName = Self.defaultSessionName(for: agent, containerAgent: override)
        let defaultNames: Set = [defaultName, Self.legacyDefaultSessionName(for: agent, containerAgent: override)]
        if name == nil,
           let index = state.sessions.firstIndex(where: {
               $0.folderID == folderID && $0.agent == agent
                   && $0.containerAgent == override && defaultNames.contains($0.name) && $0.isChat == chat
                   // (Prompts no longer rename it: nothing asked, not a fork.)
                   && $0.firstPrompt == nil && $0.generatedName == nil && !$0.isFork
                   // Never launched, here or in another window on the folder
                   // (shells keep their default name).
                   && runtimes[$0.id] == nil && !store.launched.contains($0.id)
           }) {
            // Reuse the pristine "New … Session" (no prompts yet), under today's spelling.
            if state.sessions[index].name != defaultName {
                state.sessions[index].name = defaultName
                saveState()
            }
            return state.sessions[index]
        }
        let session = Session(
            folderID: folderID,
            agent: agent,
            name: name ?? defaultName,
            order: nextSessionOrder(in: folderID),
            workdir: workdir(for: folder),
            containerAgent: override,
            isChat: chat)
        SbxClient.sessionCreated(session.id)
        state.sessions.append(session)
        saveState()
        return session
    }

    /// ⌘N: new session in the current context. Same folder + same agent as the
    /// selected session; falls back to the selected/first folder's primary agent.
    @discardableResult
    func newSessionInCurrentContext() -> Session? {
        let folderID: UUID
        let agent: AgentKind
        var containerAgent: AgentKind? = nil
        if case .session(let id) = selection, let s = session(id: id) {
            folderID = s.folderID; agent = s.agent; containerAgent = s.containerAgent
        } else {
            guard let first = folders.first else { return nil }
            folderID = first.id; agent = primaryAgent
        }
        setFolder(folderID, expanded: true)
        // Chat is the default for agents that have one; the pane's switch flips it.
        let chat = containerAgent == nil && SbxCommand.supportsACP(agent)
        guard let s = addSession(folderID: folderID, agent: agent,
                                 containerAgent: containerAgent, chat: chat) else { return nil }
        selection = .session(s.id)
        return s
    }

    /// Fork a chat at one of its replies: a copy of its Claude transcript up to
    /// and including the line holding `replyText`, under a new session id, opened
    /// as a new chat that resumes from there. Nil if the reply can't be found.
    @discardableResult
    func forkChat(_ id: UUID, upTo replyText: String) -> Session? {
        guard let source = session(id: id), source.agent == .claude, let tid = source.transcriptID,
              let url = TranscriptReader.transcriptURL(agent: .claude, workdir: source.conversationWorkdir,
                                                       home: home, id: tid),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let newID = UUID().uuidString.lowercased()
        guard let copy = ClaudeTranscriptTail.fork(text, upTo: replyText, newID: newID) else { return nil }
        // Filed under the cwd the fork runs in (its folder's), which needn't be
        // where the source's conversation is (a session in a subdirectory, or
        // one that ran on while its folder moved).
        guard let folder = folder(id: source.folderID) else { return nil }
        let forkFolder = TranscriptReader.claudeProjectFolder(for: workdir(for: folder), home: home)
        let forkURL = forkFolder.appending(path: "\(newID).jsonl")
        guard (try? FileManager.default.createDirectory(at: forkFolder, withIntermediateDirectories: true)) != nil,
              (try? copy.text.write(to: forkURL, atomically: true, encoding: .utf8)) != nil else { return nil }
        // Named by its own first prompt; until then "Fork of <source>" (this
        // spelling once the source is gone).
        let sourceName = displayName(of: source)
        var fork = Session.fork(of: source, name: "Fork of \(sourceName)", order: nextSessionOrder(in: source.folderID),
                                workdir: workdir(for: folder), at: .now)
        fork.transcriptID = newID
        state.sessions.append(fork)
        saveState()
        selection = .session(fork.id)
        Log.info(.workspace, "forked chat “\(sourceName)” at \(copy.cut + 1) of \(copy.lines) transcript lines → \(newID)")
        return fork
    }

    /// ⌃⌘N: new native chat (Claude unless another ACP agent is asked for) in
    /// the selected session's folder (else the first folder), selected right
    /// away. The chat runs in that agent's own sandbox.
    @discardableResult
    func newChatInCurrentContext(agent: AgentKind = .claude) -> Session? {
        guard SbxCommand.supportsACP(agent) else { return nil }
        let folderID: UUID
        if case .session(let id) = selection, let s = session(id: id) {
            folderID = s.folderID
        } else if let first = folders.first {
            folderID = first.id
        } else {
            return nil
        }
        guard let s = addSession(folderID: folderID, agent: agent, chat: true) else { return nil }
        selection = .session(s.id)
        return s
    }

    /// A prompt was sent in a session (seen in its chat or its agent's
    /// transcript): the first one names it (`Session.firstPrompt`), until the
    /// agent titles it or the person renames it. Called with every prompt; only
    /// the first changes anything.
    func autoName(_ id: UUID, from prompt: String) {
        guard let idx = state.sessions.firstIndex(where: { $0.id == id }),
              state.sessions[idx].recordPrompt(prompt) else { return }
        saveState()
    }

    /// What a session is called (`Session.displayName`; a fork's source looked
    /// up here).
    func displayName(of session: Session) -> String {
        session.displayName { self.session(id: $0) }
    }

    /// `displayName(of:)` by id; nil when there's no such session.
    func displayName(_ id: UUID) -> String? {
        session(id: id).map(displayName(of:))
    }

    /// Claude titles a conversation during its first turn (an `ai-title` line
    /// in its transcript): once a turn has finished, take that title, once.
    /// Other agents have none: their first prompt stands.
    func adoptGeneratedName(_ id: UUID) {
        guard let s = session(id: id), s.generatedName == nil, s.agent == .claude, let tid = s.transcriptID,
              let url = TranscriptReader.transcriptURL(agent: .claude, workdir: s.conversationWorkdir,
                                                       home: home, id: tid) else { return }
        Task { [weak self] in
            let title = await Task.detached(priority: .utility) { ClaudeTranscriptTail.title(at: url) }.value
            guard let self, let title,
                  let idx = self.state.sessions.firstIndex(where: { $0.id == id }),
                  self.state.sessions[idx].transcriptID == tid,
                  self.state.sessions[idx].adoptGeneratedName(title) else { return }
            self.saveState()
        }
    }

    /// Create a session that resumes a past conversation (from the History
    /// browser). Uses the conversation's own cwd as the workdir so the agent can
    /// resume it, and carries its transcript id. The caller selects it (→ resume).
    @discardableResult
    func restoreSession(_ record: ConversationRecord, into preferredFolder: UUID?) -> Session? {
        // Route to the folder that owns the conversation's cwd, so the restored
        // session lands in the right place regardless of where History was opened
        // from; fall back to the preferred/first folder.
        let target = folderForCwd(record.cwd) ?? preferredFolder ?? folders.first?.id
        guard let target, let folder = folder(id: target) else { return nil }
        var session = Session(
            folderID: target,
            agent: record.agent,
            name: record.title,
            order: nextSessionOrder(in: target),
            workdir: record.cwd ?? workdir(for: folder),
            transcriptID: record.id,
            // A conversation from a chat (or the Claude app) comes back as one.
            isChat: SbxCommand.supportsACP(record.agent)
                && TranscriptReader.startedAsChat(at: record.url, agent: record.agent))
        SbxClient.sessionCreated(session.id)
        // Its title is its first prompt; Claude's own title for it, if it has one, wins.
        session.firstPrompt = record.title
        state.sessions.append(session)
        saveState()
        adoptGeneratedName(session.id)
        return session
    }

    /// The folder that contains `cwd` (its own dir or a subdir). Prefers the
    /// deepest (most specific) match so a subfolder wins over the root.
    func folderForCwd(_ cwd: String?) -> UUID? {
        guard let cwd else { return nil }
        return folders
            .filter { cwd == workdir(for: $0) || cwd.hasPrefix(workdir(for: $0) + "/") }
            .max { workdir(for: $0).count < workdir(for: $1).count }?.id
    }

    /// Record the agent conversation id a session is running as, so re-activating
    /// it later can resume that history.
    func setTranscriptID(_ id: UUID, _ transcriptID: String) {
        guard let idx = state.sessions.firstIndex(where: { $0.id == id }),
              state.sessions[idx].transcriptID != transcriptID else { return }
        state.sessions[idx].transcriptID = transcriptID
        saveState()
    }

    /// Switch a session between the terminal and the native chat view. The
    /// detail pane tears down the old surface and resumes the same conversation.
    func setChat(_ id: UUID, _ chat: Bool) {
        guard let idx = state.sessions.firstIndex(where: { $0.id == id }),
              state.sessions[idx].isChat != chat else { return }
        state.sessions[idx].isChat = chat
        saveState()
    }

    /// Clear a session's stored history id (e.g. after the user opts to start
    /// fresh because the prior transcript is gone).
    func clearTranscriptID(_ id: UUID) {
        guard let idx = state.sessions.firstIndex(where: { $0.id == id }),
              state.sessions[idx].transcriptID != nil else { return }
        state.sessions[idx].transcriptID = nil
        saveState()
    }

    func closeSession(_ id: UUID) {
        guard let index = state.sessions.firstIndex(where: { $0.id == id }) else { return }
        let closed = state.sessions.remove(at: index)
        recentlyClosed.append(closed)
        if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
        clearSelectionIfGone()
        saveState()
        // Undo puts it back where it was (it resumes its conversation when shown).
        undoManager?.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated { _ = controller.reopenSession(closed, at: index) }
        }
        // Undoing a reopen closes it: then this is what Redo reopens.
        undoManager?.setActionName(undoManager?.isUndoing == true ? "Reopen Closed Session" : "Close Session")
    }

    /// Close several at once: one undo puts them all back.
    func closeSessions(_ ids: [UUID]) {
        guard ids.count > 1 else { return ids.first.map(closeSession) ?? () }
        undoManager?.beginUndoGrouping()
        for id in ids { closeSession(id) }
        undoManager?.setActionName("Close Sessions")
        undoManager?.endUndoGrouping()
    }

    /// Session ▸ Rename: the person's name sticks (prompts no longer rename it).
    /// Empty puts automatic naming back.
    func renameSession(_ id: UUID, to name: String) {
        guard let idx = state.sessions.firstIndex(where: { $0.id == id }) else { return }
        let old = state.sessions[idx]
        guard let renamed = old.renamed(to: name) else { return }
        state.sessions[idx] = renamed
        saveState()
        undoManager?.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                controller.renameSession(id, to: old.isNamedByUser ? old.name : "")
                if !old.isNamedByUser, let i = controller.state.sessions.firstIndex(where: { $0.id == id }) {
                    controller.state.sessions[i].name = old.name
                    controller.saveState()
                }
            }
        }
        undoManager?.setActionName("Rename Session")
    }


    /// File ▸ Reopen Closed Session (⇧⌘T): the last one closed, selected.
    @discardableResult
    func reopenLastClosed() -> Session? {
        while let last = recentlyClosed.popLast() {
            if session(id: last.id) == nil { return reopenSession(last, at: 0) }
        }
        return nil
    }

    @discardableResult
    private func reopenSession(_ session: Session, at index: Int) -> Session? {
        guard self.session(id: session.id) == nil else { return nil }
        // The copy kept for Reopen Closed follows folder renames (an undo's doesn't).
        var restored = recentlyClosed.last { $0.id == session.id } ?? session
        recentlyClosed.removeAll { $0.id == session.id }
        // Its folder went meanwhile: the root folder holds it.
        if folder(id: restored.folderID) == nil, let root = folders.first { restored.folderID = root.id }
        // Its directory went too (renamed, trashed): it works in its folder's.
        if !FileManager.default.fileExists(atPath: restored.workdir), let folder = folder(id: restored.folderID) {
            restored.workdir = workdir(for: folder)
        }
        state.sessions.insert(restored, at: min(index, state.sessions.count))
        saveState()
        selection = .session(restored.id)
        undoManager?.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated { controller.closeSession(restored.id) }
        }
        // Undoing a close reopens it: then this is what Redo closes.
        undoManager?.setActionName(undoManager?.isUndoing == true ? "Close Session" : "Reopen Closed Session")
        return restored
    }

    private func clearSelectionIfGone() {
        switch selection {
        case let .session(id) where session(id: id) == nil: selection = nil
        default: break
        }
    }
}
