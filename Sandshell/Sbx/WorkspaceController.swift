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
            if case let .session(id) = selection, runtimes[id] != nil {
                runtimes[id]!.isUnread = false
            }
        }
    }
    /// Live per-session status + work-time (from the agent transcript).
    @Committed private(set) var runtimes: [UUID: SessionRuntime] = [:]
    /// Authoritative lifecycle phase per agent container — the single source of
    /// truth for creation, build, running, stopped, and rebuild state.
    @Committed private(set) var containerPhases: [AgentKind: ContainerPhase] = [:]
    /// Bumped only on **structural** project/session changes (not selection or
    /// busy/error). The sidebar reloads on this, so opening an inline editor or
    /// changing selection doesn't tear the outline down.
    @Committed private(set) var revision = 0
    /// Fires every second — the single shared clock for all work-timer displays.
    @Committed private(set) var clockTick: Date = Date()

    /// Kit startup outcome per agent container, read from the sandbox's
    /// dispatcher log after the container comes up (see `KitStartup.swift`).
    /// Absent until the first read; the UI shows nothing for an absent entry.
    /// Written only by the kit-startup extension (`WorkspaceController+KitStartup.swift`).
    @Committed var kitStartup: [AgentKind: KitStartupStatus] = [:]
    var kitStartupTasks: [AgentKind: Task<Void, Never>] = [:]
    var kitLogWindows: [AgentKind: HostTerminalWindowController] = [:]

    let home = FileManager.default.homeDirectoryForCurrentUser
    private var state: WorkspaceState
    private var config: WorkspaceConfig
    private var containerPollTask: Task<Void, Never>?
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

    /// Whether the mount-config UI should be shown before creating a container
    /// (true until the user confirms mounts for this workspace).
    var needsConfiguration: Bool { !config.configured }

    /// Current mount policy (for the mount-config UI to edit).
    var policy: MountPolicy { workspace.policy }

    init(workspace: Workspace, state: WorkspaceState, config: WorkspaceConfig) {
        self.workspace = workspace
        self.state = state
        self.config = config
        self.rootProfile = RootFolderStore.profile(for: workspace.rootURL.path)
        self.theme = ThemeController(prefs: config.theme ?? ThemeDefaults.prefs)
        self.theme.persist = { [weak self] prefs in
            guard let self else { return }
            self.config.theme = prefs
            try? self.config.save(root: self.workspace.rootURL)
        }
        startStatusFeedPolling()
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
        try? config.save(root: workspace.rootURL)
    }

    /// `claude --effort` level used for this workspace's Claude sessions (nil = default).
    var claudeEffort: String? { config.claudeEffort }

    /// Persist the effort choice; like the model, it applies at launch.
    func setClaudeEffort(_ level: String?) {
        let normalized = (level?.isEmpty ?? true) ? nil : level
        guard normalized != config.claudeEffort else { return }
        config.claudeEffort = normalized
        try? config.save(root: workspace.rootURL)
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
                  let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
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

    /// Bootstrap (or load) the workspace at `root` and return its controller.
    static func open(root: URL = WorkspaceBootstrap.defaultRoot) throws -> WorkspaceController {
        let state = try WorkspaceBootstrap.openOrCreate(root: root)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = WorkspaceConfig.loadOrDefault(root: root, home: home)
        var workspace = Workspace(
            rootURL: root, containerName: slug(for: root), policy: config.policy,
            mcpServers: config.mcpServers, mcpURL: config.mcpURL, primaryAgent: config.primaryAgent,
            kits: config.kits)
        workspace.imageChannel = config.imageChannel
        workspace.customImage = config.customImage
        return WorkspaceController(workspace: workspace, state: state, config: config)
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
        try? config.save(root: workspace.rootURL)
        // Rebuild the primary plus any other agent that already has a container.
        // No prompt — the caller (first-run / Settings ▸ Apply & Rebuild) already
        // confirmed via its own UI.
        var agents = Set(containers.keys)
        agents.insert(workspace.primaryAgent)
        for agent in agents { rebuildContainer(for: agent) }
    }

    /// Change the workspace's primary agent (default for the quick "+ New
    /// Session" action and the bare-slug container name). Persisted.
    func setPrimaryAgent(_ agent: AgentKind) {
        guard agent != workspace.primaryAgent else { return }
        workspace.primaryAgent = agent
        config.primaryAgent = agent
        try? config.save(root: workspace.rootURL)
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
        try? config.save(root: workspace.rootURL)
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
    /// Set to a server name when it's freshly authenticated/added, so the UI can
    /// auto-enable it. Cleared after the UI consumes it.
    @Committed var mcpJustAuthenticated: String?

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
        mcpBusy.insert(name)
        Task {
            defer { self.mcpBusy.remove(name) }
            do {
                if registered {
                    try await SbxClient.shared.authMCP(name: name, mcpURL: url)
                } else if let addArgs {
                    try await SbxClient.shared.addMCP(name: name, args: addArgs, mcpURL: url)
                }
                self.mcpJustAuthenticated = name   // auto-enable
            } catch {
                self.lastError = error.localizedDescription
                Log.error(.workspace, "mcp authenticate \(name) failed: \(error.localizedDescription)")
            }
            self.refreshMCPStatus()
        }
    }

    /// Register servers from a standard MCP JSON document (`{ "mcpServers": { … } }`)
    /// via `sbx mcp add` — each entry maps to `--command/--args` or `--url`.
    func addMCPFromJSON(_ json: String) {
        let parsed = Self.parseMCPJSON(json)
        guard !parsed.isEmpty else {
            lastError = "No servers found — expected { \"mcpServers\": { … } }."
            return
        }
        let url = workspace.mcpURL
        for (name, _) in parsed { mcpBusy.insert(name) }
        Task {
            for (name, args) in parsed {
                do {
                    try await SbxClient.shared.addMCP(name: name, args: args, mcpURL: url)
                    self.mcpJustAuthenticated = name   // auto-enable
                } catch {
                    self.lastError = error.localizedDescription
                    Log.error(.workspace, "mcp add \(name) failed: \(error.localizedDescription)")
                }
                self.mcpBusy.remove(name)
            }
            self.refreshMCPStatus()
        }
    }

    /// Revoke a server's hosted OAuth credential (keeps registration).
    func unauthorizeMCP(_ name: String) {
        let url = workspace.mcpURL
        mcpBusy.insert(name)
        Task {
            defer { self.mcpBusy.remove(name) }
            do {
                try await SbxClient.shared.unauthorizeMCP(name: name, mcpURL: url)
            } catch {
                self.lastError = error.localizedDescription
            }
            self.refreshMCPStatus()
        }
    }

    /// Remove a registered server entirely (`sbx mcp rm`).
    func removeMCP(_ name: String) {
        let url = workspace.mcpURL
        mcpBusy.insert(name)
        Task {
            defer { self.mcpBusy.remove(name) }
            do {
                try await SbxClient.shared.removeMCP(name: name, mcpURL: url)
            } catch {
                self.lastError = error.localizedDescription
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
    /// True while `sbx ls` is being scanned (so the pane shows "Loading…", not
    /// a premature "no sandboxes" empty state).
    @Committed private(set) var sandboxesLoading = false

    func refreshSandboxes() {
        sandboxesLoading = true
        Task {
            let list = (try? await SbxClient.shared.list()) ?? []
            self.allSandboxes = list
            self.sandboxesLoading = false
        }
    }

    private func sandboxAction(_ name: String, _ work: @escaping () async throws -> Void) {
        sandboxBusy.insert(name)
        Task {
            defer { self.sandboxBusy.remove(name) }
            do { try await work() } catch {
                self.lastError = error.localizedDescription
                Log.error(.workspace, "sandbox action \(name) failed: \(error.localizedDescription)")
            }
            self.refreshSandboxes()
            self.syncContainers()
        }
    }

    func startSandbox(_ name: String) { sandboxAction(name) { try await SbxClient.shared.start(name) } }
    func stopSandbox(_ name: String) { sandboxAction(name) { _ = try await SbxClient.shared.stop(name) } }
    func deleteSandbox(_ name: String) { sandboxAction(name) { _ = try await SbxClient.shared.remove(name) } }

    /// Rebuild a listed sandbox. If it's one of *this* workspace's containers,
    /// go through the workspace path so it keeps the resolved mounts + MCP load;
    /// otherwise fall back to a generic recreate from what `sbx ls` reports (no
    /// MCP info available for foreign sandboxes).
    func rebuildSandbox(_ sandbox: Sandbox) {
        if let agent = agentForContainer(named: sandbox.name) {
            runAction { @MainActor in
                try await self.bringUpContainer(for: agent, onMismatch: .rebuild, force: true)
                self.refreshSandboxes()
                self.syncContainers()
            }
        } else {
            sandboxAction(sandbox.name) { _ = try await SbxClient.shared.rebuildSandbox(sandbox) }
        }
    }

    /// The workspace agent whose container has this name, if any. Searches the
    /// builtins plus whatever custom agent identities this workspace actually
    /// has sessions for (there's no registry of *possible* custom kinds yet —
    /// just the ones in use — see Sidebar Phase 2 for a real registry).
    private func agentForContainer(named name: String) -> AgentKind? {
        (AgentKind.builtins + state.sessions.map(\.agent)).first { containerName(for: $0) == name }
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
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            mcpURL: usesMCP ? workspace.mcpURL : nil)
    }

    /// Re-sync the workspace's own container map after a global sandbox action
    /// may have changed one of them.
    private func syncContainers() {
        Task {
            for agent in Array(containers.keys) {
                let sb = try? await SbxClient.shared.status(name: containerName(for: agent))
                containers[agent] = sb
                guard containerPhases[agent]?.isBuilding != true else { continue }
                containerPhases[agent] = sb.map { $0.isRunning ? .running : .stopped } ?? .absent
                // A container that (re)started outside our create path (e.g.
                // Settings ▸ Run) re-runs its startup dispatcher — follow it.
                if sb?.isRunning == true { refreshKitStartupIfNeeded(for: agent) }
                else if sb == nil { resetKitStartup(for: agent) }
            }
        }
    }

    /// Set the auto-archive interval (seconds). Persisted; used in Phase 7.
    func setArchiveInterval(_ interval: TimeInterval) {
        guard interval != config.archiveInterval else { return }
        config.archiveInterval = interval
        try? config.save(root: workspace.rootURL)
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
    /// agent, `<slug>-<agent>` for the rest (keeps names unique per window).
    func containerName(for agent: AgentKind) -> String {
        agent == workspace.primaryAgent
            ? workspace.containerName
            : "\(workspace.containerName)-\(agent.rawValue)"
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
        workspace.kits.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Combined create-time signature (mounts + kits + base image). A change in
    /// any drives a container rebuild, since all are fixed at `sbx create`.
    func configSignature(mounts: [MountSpec], kits: [String]) -> String {
        mountSignature(mounts) + "\n--kits--\n" + kits.joined(separator: "\n")
            + "\n--image--\n" + imageSignature
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
        try? config.save(root: workspace.rootURL)
        Log.info(.workspace, "image channel → \(channel.rawValue)\(custom.isEmpty ? "" : " (\(custom))")")
    }

    /// Force-rebuild every container this workspace has (plus the primary).
    func rebuildAll() {
        var agents = Set(containers.keys)
        agents.insert(workspace.primaryAgent)
        for agent in agents { rebuildContainer(for: agent, force: true) }
    }

    /// Apply an edited kit set (from the Kits inspector): persist it and rebuild
    /// every existing container so they pick up the new `--kit` set.
    func applyKits(_ kits: [String]) {
        let cleaned = kits.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        workspace.kits = cleaned
        config.kits = cleaned
        try? config.save(root: workspace.rootURL)
        var agents = Set(containers.keys)
        agents.insert(workspace.primaryAgent)
        // Force: the user chose "Apply & Rebuild" — also the path for reloading a
        // kit whose *contents* changed, where the kit ref set (and thus the
        // create-time signature) is identical and the unchanged-config shortcut
        // would otherwise just re-attach.
        for agent in agents { rebuildContainer(for: agent, force: true) }
    }

    /// Current kit set (for the Kits inspector to edit).
    var kits: [String] { workspace.kits }

    /// Update this folder's identity (icon/color/sidebar bg) — persists to the
    /// global registry and republishes so the sidebar re-renders live.
    func updateRootProfile(_ profile: RootProfile) {
        RootFolderStore.upsert(profile)
        rootProfile = profile
    }

    // MARK: - Lifecycle

    /// Ensure the primary agent's container exists with the current mounts.
    func openPrimaryContainer() {
        ensureContainer(for: workspace.primaryAgent)
        startContainerPolling()
        startClock()
    }

    /// Poll workspace container status every 5 s so `containerPhases` stays
    /// accurate without requiring explicit actions to trigger `syncContainers`.
    private func startContainerPolling() {
        guard containerPollTask == nil else { return }
        containerPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.syncContainers()
            }
        }
    }

    /// Start the shared 1-second clock that drives all work-timer displays.
    private func startClock() {
        guard clockCancellable == nil else { return }
        clockCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in self?.clockTick = date }
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

    /// Shared create/attach/rebuild core for an agent's container. `force`
    /// rebuilds even when the mounts are unchanged.
    /// In-flight bring-ups by container name. Opening a workspace (startup
    /// `ensureContainer`) and launching its selected session
    /// (`ensureContainerReady`) both bring the same container up at once; without
    /// this each saw "no sandbox" and ran its own `sbx create`.
    private var bringUps: [String: Task<Void, Error>] = [:]

    /// Bring a container up, joining one already in flight for it. A forced
    /// rebuild waits for the in-flight one, then runs its own.
    private func bringUpContainer(for agent: AgentKind, onMismatch: MismatchAction,
                                  force: Bool = false) async throws {
        let name = containerName(for: agent)
        if let inflight = bringUps[name] {
            if !force { return try await inflight.value }
            _ = try? await inflight.value
        }
        let task = Task { @MainActor in
            try await self.performBringUp(for: agent, onMismatch: onMismatch, force: force)
        }
        bringUps[name] = task
        defer { if bringUps[name] == task { bringUps[name] = nil } }
        try await task.value
    }

    private func performBringUp(for agent: AgentKind, onMismatch: MismatchAction,
                                force: Bool) async throws {
        // Mirror host MCP configs and OAuth tokens into the bind-mounted claude
        // config dir before the container starts (ported from sbx-ui projects.rs).
        let homeURL = home
        await Task.detached(priority: .utility) {
            ClaudeConfigSync.syncMCPServers(home: homeURL)
            ClaudeConfigSync.syncCredentialsFromKeychain(home: homeURL)
        }.value

        let name = containerName(for: agent)
        let mounts = resolvedMounts()
        let kits = resolvedKits()
        let signature = configSignature(mounts: mounts, kits: kits)
        let mcp = await effectiveMCPServers()

        let existing = try await SbxClient.shared.status(name: name)
        let built: Sandbox
        if let existing {
            // Decide whether to rebuild. `force` skips the unchanged-mounts
            // shortcut (e.g. an MCP change that doesn't alter mounts).
            if !force {
                if state.appliedMountSignatures[name] == signature {
                    Log.info(.workspace, "attached to existing container '\(name)' (\(mounts.count) mounts)")
                    containers[agent] = existing
                    containerPhases[agent] = existing.isRunning ? .running : .stopped
                    refreshKitStartupIfNeeded(for: agent)
                    return
                }
                switch onMismatch {
                case .attach:
                    containers[agent] = existing
                    containerPhases[agent] = existing.isRunning ? .running : .stopped
                    refreshKitStartupIfNeeded(for: agent)
                    return
                case .prompt:
                    guard await confirmRebuild(name: name, killsRunning: existing.isRunning) else {
                        containers[agent] = existing
                        containerPhases[agent] = existing.isRunning ? .running : .stopped
                        refreshKitStartupIfNeeded(for: agent)
                        return
                    }
                case .rebuild:
                    break   // fall through to rebuild
                }
            }
            Log.info(.workspace, "rebuilding container '\(name)' (\(mounts.count) mounts, \(kits.count) kits, force=\(force))")
            activity = "Rebuilding \(name)…"
            containerPhases[agent] = .rebuilding
            resetKitStartup(for: agent)
            do {
                built = try await SbxClient.shared.rebuild(workspace: workspace, agent: agent, name: name, mounts: mounts, kits: kits)
            } catch {
                containerPhases[agent] = .failed(error.localizedDescription)
                throw error
            }
        } else {
            Log.info(.workspace, "creating container '\(name)' for \(agent.rawValue) (\(mounts.count) mounts, \(kits.count) kits)")
            activity = "Building \(name)…"
            containerPhases[agent] = .creating
            resetKitStartup(for: agent)
            do {
                built = try await SbxClient.shared.create(workspace: workspace, agent: agent, name: name, mounts: mounts, kits: kits)
            } catch {
                containerPhases[agent] = .failed(error.localizedDescription)
                throw error
            }
        }
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
        // Dynamic MCP: attach the user's checked servers to the now-running
        // sandbox via `sbx mcp load` (discovery stays on for everything else).
        await loadMCPServers(mcp, into: name)
    }

    private func recordSignature(_ signature: String, for name: String) {
        state.appliedMountSignatures[name] = signature
        try? state.save(root: workspace.rootURL)
    }

    // MARK: - Confirmation

    /// Modal confirmation before a rebuild that would kill running sessions.
    private func confirmRebuild(name: String, killsRunning: Bool) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Rebuild “\(name)”?"
        alert.informativeText = killsRunning
            ? "The workspace mounts changed. Rebuilding stops and recreates the container, ending any running sessions in it."
            : "The workspace mounts changed. Rebuilding recreates the container with the new mounts."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
    /// Session finished a working burst in the background; user hasn't looked.
    var isUnread: Bool = false
    /// Latest status Claude Code reported for this session (model, context,
    /// tokens, cost) via the Sandshell status feed. `nil` until the first report.
    var claudeStatus: ClaudeSessionStatus?

    /// Real-time work total: completed bursts + elapsed in the current burst.
    /// Pass `at:` from a `TimelineView` context for SwiftUI; defaults to `Date()`.
    func liveWorkSeconds(at now: Date = Date()) -> TimeInterval {
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
        case .absent:           return "absent"
        case .creating:         return "creating"
        case .rebuilding:       return "rebuilding"
        case .running:          return "running"
        case .stopped:          return "stopped"
        case .failed(let msg):  return "failed: \(msg.prefix(60))"
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

    /// Whether a session has a live terminal (set by the detail pane).
    func isLive(_ id: UUID) -> Bool { runtimes[id]?.isLive ?? false }
    func setLive(_ id: UUID, _ live: Bool) {
        var rt = runtimes[id] ?? SessionRuntime()
        guard rt.isLive != live else { return }
        rt.isLive = live
        runtimes[id] = rt
        // A live terminal means sbx exec succeeded → container is running.
        if live, let session = session(id: id),
           containerPhases[session.agent]?.isBuilding != true {
            containerPhases[session.agent] = .running
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
        }
        if runtimes[id] != rt { runtimes[id] = rt }   // publish only on change
        return SessionActivityTransition(finishedWork: wasWorking && !working,
                                         workSeconds: rt.workSeconds)
    }

    /// All sessions, most-recently-active first — the sidebar's flat peer list.
    /// Falls back to `createdAt` until a session has any real activity. Not
    /// re-derived on every runtime tick from the caller's side (see
    /// `SidebarListController.runtimesChanged`) — only when a session is
    /// created/closed or transitions working↔ready — so rows don't jump around
    /// while a timer or "Xm ago" label is merely ticking in place.
    var orderedSessions: [Session] {
        state.sessions.sorted { sortKey($0) > sortKey($1) }
    }

    private func sortKey(_ session: Session) -> Date {
        max(runtimes[session.id]?.lastActivityAt ?? .distantPast, session.createdAt)
    }

    /// Cycle the selection to the next (`+1`) / previous (`-1`) session.
    func selectAdjacentSession(_ delta: Int) {
        let all = orderedSessions
        guard !all.isEmpty else { return }
        let next: Int
        if case let .session(id) = selection, let cur = all.firstIndex(where: { $0.id == id }) {
            next = (cur + delta + all.count) % all.count
        } else {
            next = delta >= 0 ? 0 : all.count - 1
        }
        selection = .session(all[next].id)
    }

    var expandedFolderIDs: Set<UUID> { Set(state.expandedFolderIDs) }

    /// Persist expansion only — not a structural change, so it must NOT bump
    /// `revision` (which would reload the outline mid-interaction).
    func setFolder(_ id: UUID, expanded: Bool) {
        var ids = Set(state.expandedFolderIDs)
        if expanded { ids.insert(id) } else { ids.remove(id) }
        state.expandedFolderIDs = Array(ids)
        try? state.save(root: workspace.rootURL)
    }

    /// Persist a structural change and signal the sidebar to reload.
    private func saveState() {
        revision += 1
        try? state.save(root: workspace.rootURL)
    }

    /// Host URL for a folder (the workspace root itself for the root folder).
    func folderURL(for folder: Folder) -> URL {
        folder.isRoot ? workspace.rootURL
            : workspace.rootURL.appendingPathComponent(folder.relativePath, isDirectory: true)
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
        var base = trimmed.replacingOccurrences(of: "/", with: "-")
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "New Folder" }
        let existing = Set(state.folders.map { $0.relativePath })
        let fm = FileManager.default
        func taken(_ n: String) -> Bool {
            existing.contains(n) || fm.fileExists(atPath: workspace.rootURL.appendingPathComponent(n).path)
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
        let dir = workspace.rootURL.appendingPathComponent(relativePath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.error(.workspace, "addFolder failed: \(error.localizedDescription)")
            return nil
        }
        return registerFolder(relativePath: relativePath)
    }

    /// Register an existing directory (possibly nested) as a folder row. Returns
    /// nil if the directory is not under the workspace root or is already a row.
    @discardableResult
    func addExistingFolder(at url: URL) -> Folder? {
        let rootPath = workspace.rootURL.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target != rootPath else { return rootFolder }   // the root is already a row
        guard target.hasPrefix(rootPath + "/") else {
            lastError = "Folders must live inside \(workspace.rootURL.lastPathComponent)."
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

    /// Rename a folder on disk and update its sessions' workdirs. The root folder
    /// is not renameable (its name is the workspace root).
    func renameFolder(_ id: UUID, to newName: String) {
        guard let idx = state.folders.firstIndex(where: { $0.id == id }) else { return }
        let old = state.folders[idx]
        guard !old.isRoot else { return }
        // No-op when the field commits unchanged (end-editing fires regardless).
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old.relativePath else { return }
        // Rename within the same parent directory (single-segment rename).
        let parent = (old.relativePath as NSString).deletingLastPathComponent
        var leaf = trimmed.replacingOccurrences(of: "/", with: "-")
        while leaf.hasPrefix(".") { leaf.removeFirst() }
        let newRelative = parent.isEmpty ? leaf : "\(parent)/\(leaf)"
        guard newRelative != old.relativePath else { return }
        let src = workspace.rootURL.appendingPathComponent(old.relativePath, isDirectory: true)
        let dst = workspace.rootURL.appendingPathComponent(newRelative, isDirectory: true)
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
            return
        }
        state.folders[idx].relativePath = newRelative
        // Re-point sessions' workdirs at the renamed folder.
        for sidx in state.sessions.indices where state.sessions[sidx].folderID == id {
            state.sessions[sidx].workdir = dst.path
        }
        saveState()
    }

    /// Remove a folder from the sidebar (the directory stays on disk). The root
    /// folder cannot be removed.
    func hideFolder(_ id: UUID) {
        guard folder(id: id)?.isRoot != true else { return }
        state.sessions.removeAll { $0.folderID == id }
        state.folders.removeAll { $0.id == id }
        clearSelectionIfGone()
        saveState()
    }

    /// Move a folder's directory to the Trash, then remove it from the sidebar.
    /// The root folder cannot be trashed.
    func trashFolder(_ id: UUID) {
        guard let folder = folder(id: id), !folder.isRoot else { return }
        let dir = folderURL(for: folder)
        try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        hideFolder(id)
    }

    // MARK: Session ops

    private func nextSessionOrder(in folderID: UUID) -> Int {
        (state.sessions.filter { $0.folderID == folderID }.map(\.order).max() ?? -1) + 1
    }

    /// Default name for a fresh session, e.g. "New Claude Session". A shell
    /// attached to another agent's sandbox reads "Shell in Claude", etc.
    static func defaultSessionName(for agent: AgentKind, containerAgent: AgentKind? = nil) -> String {
        if let containerAgent, containerAgent != agent {
            return "\(agent.displayName.capitalized) in \(containerAgent.displayName.capitalized)"
        }
        return "New \(agent.displayName.capitalized) Session"
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
        if name == nil,
           let existing = state.sessions.first(where: {
               $0.folderID == folderID && $0.agent == agent
                   && $0.containerAgent == override && $0.name == defaultName && $0.isChat == chat
           }) {
            return existing   // reuse the pristine "New … Session" (no prompts yet)
        }
        let session = Session(
            folderID: folderID,
            agent: agent,
            name: name ?? defaultName,
            order: nextSessionOrder(in: folderID),
            workdir: workdir(for: folder),
            containerAgent: override,
            isChat: chat)
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
        switch selection {
        case .session(let id):
            guard let s = session(id: id) else { return nil }
            folderID = s.folderID; agent = s.agent; containerAgent = s.containerAgent
        case .none:
            guard let first = folders.first else { return nil }
            folderID = first.id; agent = primaryAgent
        }
        setFolder(folderID, expanded: true)
        guard let s = addSession(folderID: folderID, agent: agent,
                                 containerAgent: containerAgent) else { return nil }
        selection = .session(s.id)
        return s
    }

    /// ⌃⌘N: new native Claude chat in the selected session's folder (else the
    /// first folder), selected right away.
    @discardableResult
    func newChatInCurrentContext() -> Session? {
        let folderID: UUID
        if case .session(let id) = selection, let s = session(id: id) {
            folderID = s.folderID
        } else if let first = folders.first {
            folderID = first.id
        } else {
            return nil
        }
        guard let s = addSession(folderID: folderID, agent: .claude, chat: true) else { return nil }
        selection = .session(s.id)
        return s
    }

    /// Update a session's name to its latest prompt (detected from the agent
    /// transcript). Sessions are auto-named only — there is no manual rename.
    /// Called repeatedly, so it no-ops when the name is unchanged.
    func autoName(_ id: UUID, from prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = state.sessions.firstIndex(where: { $0.id == id }),
              state.sessions[idx].name != trimmed else { return }
        state.sessions[idx].name = trimmed
        saveState()
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
        let session = Session(
            folderID: target,
            agent: record.agent,
            name: record.title,
            order: nextSessionOrder(in: target),
            workdir: record.cwd ?? workdir(for: folder),
            transcriptID: record.id)
        state.sessions.append(session)
        saveState()
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
        state.sessions.removeAll { $0.id == id }
        clearSelectionIfGone()
        saveState()
    }

    private func clearSelectionIfGone() {
        switch selection {
        case let .session(id) where session(id: id) == nil: selection = nil
        default: break
        }
    }
}
