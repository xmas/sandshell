import Foundation
import Synchronization

/// Thin async wrapper around the `sbx` CLI. Each call shells out via `Process`.
/// Ports the invocations proven in the Tauri app's `sbx.rs`.
actor SbxClient {
    static let shared = SbxClient()

    private let sbx: String
    /// `hasServiceSecret` result per service + scope, briefly cached (checked per launch).
    private var secretCache: [String: (Bool, Date)] = [:]

    init() {
        self.sbx = PathFixer.sbxPath()
    }

    // MARK: - Listing

    /// `sbx ls --json`
    /// A sandbox's network policy in brief: hosts allowed and denied
    /// (`sbx policy ls <name> --json`); nil if sbx can't say.
    func networkPolicy(sandbox: String) async -> (allowed: Int, denied: Int)? {
        guard let out = try? await run(["policy", "ls", sandbox, "--json"], routine: true, timeout: 15), out.ok,
              let data = out.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = json["rules"] as? [[String: Any]] else { return nil }
        var allowed = Set<String>(), denied = Set<String>()
        for rule in rules where rule["resource_type"] as? String == "network" && (rule["status"] as? String ?? "active") == "active" {
            let hosts = rule["resources"] as? [String] ?? []
            if rule["decision"] as? String == "deny" { denied.formUnion(hosts) } else { allowed.formUnion(hosts) }
        }
        return (allowed.count, denied.count)
    }

    func list() async throws -> [Sandbox] {
        let out = try await run(["ls", "--json"], routine: true)
        guard out.ok else { throw SbxError.command(out.stderr.isEmpty ? out.stdout : out.stderr) }
        // Older CLIs wrap the list (`{"sandboxes": [...]}`); sbx 0.47+ emits a
        // bare array. Decode whichever top-level value comes first.
        struct ListOutput: Decodable { let sandboxes: [Sandbox] }
        // `sbx` may auto-start the sandboxd daemon on the first cold `ls` and
        // print a startup banner ("Starting sandboxd daemon…") to stdout *before*
        // the JSON. Slice from the first bracket so that preamble doesn't corrupt
        // the decode.
        let stdout = out.stdout
        let isArray = (stdout.firstIndex(of: "[") ?? stdout.endIndex) < (stdout.firstIndex(of: "{") ?? stdout.endIndex)
        guard let json = isArray ? Self.firstJSONArray(in: stdout) : Self.firstJSONObject(in: stdout),
              let data = json.data(using: .utf8) else {
            throw SbxError.parse("ls: no JSON in output: \(out.stdout)")
        }
        do {
            if isArray { return try JSONDecoder().decode([Sandbox].self, from: data) }
            return try JSONDecoder().decode(ListOutput.self, from: data).sandboxes
        } catch {
            throw SbxError.parse("ls json: \(error) (output: \(out.stdout))")
        }
    }

    // MARK: - Daemon health

    /// Version + status of the sandboxd daemon *actually running*, from its
    /// `/daemon/health` endpoint. This can differ from `sbx version` (the CLI
    /// binary): the daemon is long-lived and keeps running whatever binary first
    /// started it, so it may lag the upgraded CLI until restarted.
    struct DaemonHealth: Decodable {
        let version: String
        let apiVersion: String
        let revision: String
        let status: String
        let release: Bool
        enum CodingKeys: String, CodingKey {
            case version, status, release, revision
            case apiVersion = "api_version"
        }
    }

    /// Default location of the sandboxd unix socket.
    static var daemonSocketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/com.docker.sandboxes/sandboxes/sandboxd/sandboxd.sock"
    }

    /// Query the running daemon's `/daemon/health` over its unix socket via
    /// `curl`. Returns nil if the daemon isn't up or the response can't be parsed.
    func daemonHealth() async -> DaemonHealth? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = ["-s", "--max-time", "3", "--unix-socket",
                          Self.daemonSocketPath, "http://localhost/daemon/health"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch {
            Log.error(.sbx, "daemon health: curl spawn failed: \(error.localizedDescription)")
            return nil
        }
        proc.waitUntilExit()
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let json = Self.firstJSONObject(in: raw),
              let data = json.data(using: .utf8),
              let health = try? JSONDecoder().decode(DaemonHealth.self, from: data) else {
            Log.error(.sbx, "daemon health: no parseable response (\(raw.isEmpty ? "empty" : raw))")
            return nil
        }
        return health
    }

    // MARK: - Exec lifecycle socket

    /// Default location of the sbx Moby-compatible lifecycle socket. The socket
    /// filename is `docker.sock`, but this is the sbx/docker-next endpoint, not a
    /// dependency on Docker Desktop or the Docker CLI.
    static var execLifecycleSocketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.sbx/run/d/docker.sock"
    }

    /// Process lifecycle state for an exec created by the sbx socket API.
    /// This tells us whether the terminal process is alive; agent turn-complete
    /// still comes from the agent transcript/protocol.
    struct ExecLifecycleState: Decodable, Equatable {
        var id: String?
        var running: Bool
        var pid: Int
        var exitCode: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case running
            case pid
            case exitCode = "exit_code"
            case mobyID = "ID"
            case mobyRunning = "Running"
            case mobyPid = "Pid"
            case mobyExitCode = "ExitCode"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
                ?? c.decodeIfPresent(String.self, forKey: .mobyID)
            running = try c.decodeIfPresent(Bool.self, forKey: .running)
                ?? c.decodeIfPresent(Bool.self, forKey: .mobyRunning)
                ?? false
            pid = try c.decodeIfPresent(Int.self, forKey: .pid)
                ?? c.decodeIfPresent(Int.self, forKey: .mobyPid)
                ?? 0
            exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
                ?? c.decodeIfPresent(Int.self, forKey: .mobyExitCode)
        }
    }

    /// Inspect an sbx exec id over the lifecycle socket.
    /// Returns nil when the socket is unavailable, the exec id is gone, or the
    /// response is not parseable.
    func inspectExecLifecycle(id: String,
                              socketPath: String = SbxClient.execLifecycleSocketPath) async -> ExecLifecycleState? {
        guard let raw = socketGET(path: "/exec/\(id)/json", socketPath: socketPath),
              let json = Self.firstJSONObject(in: raw),
              let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(ExecLifecycleState.self, from: data)
        else { return nil }
        return state
    }

    /// Active exec IDs currently associated with a container, from the sbx
    /// docker-next socket's container inspect response. Returns nil when the
    /// socket/container is unavailable or the response cannot be parsed.
    func activeExecIDs(containerName: String,
                       socketPath: String = SbxClient.execLifecycleSocketPath) async -> Set<String>? {
        let encoded = Self.pathComponent(containerName)
        guard let raw = socketGET(path: "/containers/\(encoded)/json", socketPath: socketPath),
              let json = Self.firstJSONObject(in: raw),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let ids = obj["ExecIDs"] as? [String] { return Set(ids) }
        if obj.keys.contains("ExecIDs") { return [] }
        return nil
    }

    // MARK: - Lifecycle

    /// `sbx run <name>` — start detached. Returns immediately.
    func start(_ name: String) async throws {
        Log.info(.sbx, "$ sbx run \(name) (detached)")
        let proc = makeProcess(["run", name])
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            Log.error(.sbx, "sbx run \(name) failed to spawn: \(error.localizedDescription)")
            throw error
        }
    }

    /// `sbx stop <name>`
    @discardableResult
    func stop(_ name: String) async throws -> CommandOutput {
        try await run(["stop", name])
    }

    /// `sbx rm -f <name>`
    @discardableResult
    func remove(_ name: String) async throws -> CommandOutput {
        try await run(["rm", "-f", name])
    }

    /// Rebuild an arbitrary listed sandbox from what it was built with: stop →
    /// rm → recreate with the same agent + mounts (the specs from `sbx ls`).
    @discardableResult
    func rebuildSandbox(_ sandbox: Sandbox) async throws -> Sandbox {
        // A kit agent is recreated from its kit, when it's a registered one;
        // sbx can't create one from its bare name, so don't take it down first.
        let kind = AgentKind(rawValue: sandbox.agent)
        if !kind.isBuiltin, AgentProfileStore.profile(for: kind)?.kitRef == nil {
            throw SbxError.command("“\(sandbox.name)” runs the custom agent “\(sandbox.agent)”, whose kit isn’t "
                + "registered here, so it can’t be recreated. Add the agent’s kit under Settings ▸ Agents, then rebuild.")
        }
        Log.info(.sbx, "rebuilding sandbox “\(sandbox.name)” (\(sandbox.agent))")
        _ = try? await stop(sandbox.name)
        _ = try? await remove(sandbox.name)
        let agent = kind.createReference
        let args = ["create", "--no-progress", "--name", sandbox.name, agent] + sandbox.workspaces
        return try await createAndPoll(args, cwd: sandbox.primaryWorkdir, env: nil, name: sandbox.name)
    }

    // MARK: - Create

    /// `sbx create --no-progress [flags] <agent> <workspace> [config mounts...]`
    ///
    /// Run from inside the primary workspace dir so sbx derives a sensible
    /// default name and container working directory. Appends the standard
    /// agent-config + shared mounts (conditional on host existence), mirroring
    /// `sbx.rs::sbx_create_sandbox` + `append_shared_agent_mounts`. Always
    /// injects `~/.mcp` as a rw mount and loads all registered MCP servers
    /// via `sbx mcp load` once the sandbox is running.
    @discardableResult
    func create(_ opts: CreateOptions) async throws -> CommandOutput {
        var args: [String] = ["create", "--no-progress"]

        let name = opts.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { args += ["--name", name] }
        let branch = opts.branch.trimmingCharacters(in: .whitespaces)
        if !branch.isEmpty { args += ["--branch", branch] }
        if let cpus = opts.cpus { args += ["--cpus", String(cpus)] }
        let mem = opts.memory.trimmingCharacters(in: .whitespaces)
        if !mem.isEmpty { args += ["--memory", mem] }

        args.append(opts.agent)

        let workspace = opts.workspace.trimmingCharacters(in: .whitespaces)
        if !workspace.isEmpty { args.append(workspace) }

        // Managed agent config/state mounts. `.claude` is mounted surgically
        // (specific subpaths, some read-only) rather than whole-directory so the
        // container never sees host secrets — see `MountPolicy.agentMounts`.
        let fm = FileManager.default
        let homeURL = fm.homeDirectoryForCurrentUser
        let home = homeURL.path
        MountPolicy.seedAgentMounts(home: homeURL)
        args += MountPolicy.agentMountSpecs(home: homeURL).map(\.spec)
        if fm.fileExists(atPath: "\(home)/.gemini") { args.append("\(home)/.gemini") }
        // Shared mounts created-if-missing then mounted.
        for sub in [".cache", ".local"] {
            let p = "\(home)/\(sub)"
            try? fm.createDirectory(atPath: p, withIntermediateDirectories: true)
            args.append(p)
        }
        for sub in [".rustup"] {
            let p = "\(home)/\(sub)"
            if fm.fileExists(atPath: p) { args.append(p) }
        }
        let gh = "\(home)/.config/gh"
        if fm.fileExists(atPath: gh) { args.append("\(gh):ro") }

        // Shared MCP config dir — created if absent, always rw.
        let mcpDir = "\(home)/.mcp"
        try? fm.createDirectory(atPath: mcpDir, withIntermediateDirectories: true)
        args.append(mcpDir)

        // Snapshot names so we can identify the new sandbox after creation.
        let beforeNames = Set((try? await list().map(\.name)) ?? [])

        let cwd = workspace.isEmpty ? nil : workspace
        let out = try await run(args, cwd: cwd)
        if !out.ok { throw SbxError.command(out.stderr.isEmpty ? out.stdout : out.stderr) }

        // Detect new sandbox name, wait until running, then load MCPs.
        Task {
            let sandboxName: String
            if !name.isEmpty {
                sandboxName = name
            } else if let found = (try? await self.list())?.first(where: { !beforeNames.contains($0.name) })?.name {
                sandboxName = found
            } else {
                Log.error(.sbx, "create: could not identify new sandbox for MCP loading")
                return
            }
            guard (try? await self.waitUntilRunning(name: sandboxName)) != nil else { return }
            await self.loadAllMCPs(into: sandboxName, mcpURL: Workspace.defaultMCPURL)
        }

        return out
    }

    // MARK: - Workspace container lifecycle (Phase 1)

    /// `sbx create --no-progress --name <name> <agent> <mounts…>`
    ///
    /// Builds the container for one agent of a `Workspace` from its
    /// policy-resolved `mounts` (first entry = the rw workspace root). Injects
    /// `SBX_MCP_URL` and loads all registered MCP servers via `sbx mcp load`
    /// after the container is running. Run from the root so `sbx` derives a
    /// sensible workdir.
    @discardableResult
    /// `onExists`: called as soon as the sandbox shows up (before any kit
    /// setup finishes), so a quit meanwhile doesn't leave it unrecorded.
    func create(workspace: Workspace, agent: AgentKind, name: String,
                mounts: [MountSpec], kits: [String] = [],
                onExists: (@MainActor @Sendable () -> Void)? = nil) async throws -> Sandbox {
        var args = ["create", "--no-progress", "--name", name]
        // Base image channel: nil = sbx's default (stable) template; the tag is
        // pulled fresh either way (sbx defaults to --pull always).
        if let template = workspace.templateImage(for: agent) { args += ["-t", template] }
        // A private clone of the repo instead of the folder (only for a repo).
        if workspace.cloneRepo,
           FileManager.default.fileExists(atPath: workspace.rootURL.appendingPathComponent(".git").path) {
            args.append("--clone")
        }
        args += kits.flatMap { ["--kit", KitStore.resolve($0)] }
        args.append(agent.createReference)   // a custom agent is created from its kit
        args += mounts.map(\.spec)
        return try await createAndPoll(args, cwd: workspace.rootURL.path,
                                       env: ["SBX_MCP_URL": workspace.mcpURL.absoluteString],
                                       name: name, waitForKitSetup: !kits.isEmpty, onExists: onExists)
    }

    /// Attach an already-registered MCP server to a running sandbox
    /// (`sbx mcp load <server> --sandbox <name>`). Propagates to connected agent
    /// sessions via a `tools/list_changed` notification — no recreate needed.
    @discardableResult
    func loadMCP(server: String, sandbox: String, mcpURL: URL) async throws -> CommandOutput {
        let out = try await run(["mcp", "load", server, "--sandbox", sandbox],
                                env: ["SBX_MCP_URL": mcpURL.absoluteString])
        if !out.ok { throw SbxError.command(out.stderr.isEmpty ? out.stdout : out.stderr) }
        return out
    }

    /// Load every server returned by `sbx mcp ls` into `sandbox` (best-effort).
    private func loadAllMCPs(into sandbox: String, mcpURL: URL) async {
        let servers = await listMCPServers(mcpURL: mcpURL)
        for serverName in servers.keys {
            Log.info(.sbx, "mcp load \(serverName) → \(sandbox)")
            _ = try? await loadMCP(server: serverName, sandbox: sandbox, mcpURL: mcpURL)
        }
    }

    /// Kick off an `sbx create …` invocation without blocking on it (`sbx create`
    /// doesn't always exit promptly — it can keep its stdio open via the
    /// long-lived daemon), then poll `sbx ls` once a second until the named
    /// sandbox is running. If the create process dies non-zero before the
    /// sandbox appears, its stderr is thrown instead of waiting out the timeout.
    private func createAndPoll(_ args: [String], cwd: String?, env: [String: String]?,
                               name: String, waitForKitSetup: Bool = false,
                               onExists: (@MainActor @Sendable () -> Void)? = nil) async throws -> Sandbox {
        Log.info(.sbx, "creating “\(name)”: sbx \(args.joined(separator: " "))")
        let proc = makeProcess(args, env: env)
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        // Capture stderr to a temp *file*, not a Pipe: `sbx create` starts the
        // long-lived sandboxd daemon, which inherits this process's stderr fd. A
        // pipe write-end held open by the daemon never EOFs and stalls Foundation's
        // shared FileHandle/Process callback queue, which then wedges termination
        // delivery for *other* concurrent `sbx` calls (e.g. the `ls` the launch
        // flow runs right after). A file fd is harmless to inherit.
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sbx-create-\(name)-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        guard let errHandle = try? FileHandle(forWritingTo: errURL) else {
            throw SbxError.spawn("could not open stderr capture for create “\(name)”")
        }
        proc.standardError = errHandle
        let cleanup: @Sendable () -> Void = {
            try? errHandle.close()
            try? FileManager.default.removeItem(at: errURL)
        }

        let state = ProcState()
        proc.terminationHandler = { p in
            Log.info(.sbx, "create “\(name)” process exited \(p.terminationStatus)")
            state.finish(p.terminationStatus)
        }
        do {
            try proc.run()
        } catch {
            cleanup()
            Log.error(.sbx, "create “\(name)” failed to spawn: \(error.localizedDescription)")
            throw SbxError.spawn("\(sbx) \(args.joined(separator: " ")): \(error)")
        }

        let failure: @Sendable () -> String? = {
            guard let code = state.exitCode, code != 0 else { return nil }
            let err = Self.clean((try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
            return err.isEmpty ? "sbx create failed (exit \(code))." : err
        }
        do {
            var sandbox = try await waitUntilRunning(name: name, failureMessage: failure)
            if let onExists { await onExists() }
            // A kit's install steps run after the sandbox first shows as
            // running, and sbx restarts it when they're done: anything started
            // in it before then dies with it. So it's up once `sbx create` is done.
            // (The process check backs up the termination handler.)
            if waitForKitSetup, state.exitCode == nil, proc.isRunning {
                Log.info(.sbx, "“\(name)” is running; waiting for sbx create to finish (kit setup)")
                let deadline = Date().addingTimeInterval(15 * 60)
                while state.exitCode == nil, proc.isRunning, Date() < deadline {
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                if let message = failure() { throw SbxError.command(message) }
                sandbox = try await waitUntilRunning(name: name, failureMessage: failure)
            }
            cleanup()
            return sandbox
        } catch {
            cleanup()
            throw error
        }
    }

    /// Poll `sbx ls` every second until `name` is present and running, returning
    /// it. `failureMessage` is consulted each tick — returning non-nil throws it
    /// (used to bail out early when the create process dies). Times out at 4 min.
    func waitUntilRunning(name: String, timeout: TimeInterval = 240,
                          failureMessage: @escaping () -> String? = { nil }) async throws -> Sandbox {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let sb = try? await status(name: name), sb.isRunning {
                Log.info(.sbx, "sandbox “\(name)” is running")
                return sb
            }
            if let message = failureMessage() {
                Log.error(.sbx, "sandbox “\(name)” create failed: \(message)")
                throw SbxError.command(message)
            }
        }
        Log.error(.sbx, "timed out waiting for sandbox “\(name)” to start")
        throw SbxError.command("Timed out waiting for sandbox “\(name)” to start.")
    }

    /// Registered MCP servers (`sbx mcp ls`) → name : isRemote (TYPE == "remote").
    func listMCPServers(mcpURL: URL) async -> [String: Bool] {
        guard let out = try? await run(["mcp", "ls"], env: ["SBX_MCP_URL": mcpURL.absoluteString]),
              out.ok else { return [:] }
        var map: [String: Bool] = [:]
        for (i, line) in out.stdout.split(separator: "\n").enumerated() {
            if i == 0 { continue }   // header: NAME TYPE URL/COMMAND
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let name = cols.first else { continue }
            map[String(name)] = cols.count > 1 && cols[1] == "remote"
        }
        return map
    }

    /// Register a server: `sbx mcp add <name> <args…>` (no `--skip_auth`; for a
    /// remote `--url` server this runs the hosted OAuth flow).
    @discardableResult
    func addMCP(name: String, args: [String], mcpURL: URL) async throws -> CommandOutput {
        let out = try await run(["mcp", "add", name] + args,
                                env: ["SBX_MCP_URL": mcpURL.absoluteString])
        if !out.ok { throw SbxError.command(out.stderr.isEmpty ? out.stdout : out.stderr) }
        return out
    }

    /// (Re)authorize an already-registered server: `sbx mcp auth <name>`.
    @discardableResult
    func authMCP(name: String, mcpURL: URL) async throws -> CommandOutput {
        let out = try await run(["mcp", "auth", name],
                                env: ["SBX_MCP_URL": mcpURL.absoluteString])
        if !out.ok { throw SbxError.command(out.stderr.isEmpty ? out.stdout : out.stderr) }
        return out
    }

    /// Remove a registered server (`sbx mcp rm <name>`).
    @discardableResult
    func removeMCP(name: String, mcpURL: URL) async throws -> CommandOutput {
        let out = try await run(["mcp", "rm", name],
                                env: ["SBX_MCP_URL": mcpURL.absoluteString])
        if !out.ok { throw SbxError.command(out.stderr.isEmpty ? out.stdout : out.stderr) }
        return out
    }

    /// Hosted-OAuth status per server (`authorized` / `unauthorized` / `expired`).
    func mcpAuthStatus(mcpURL: URL) async -> [String: String] {
        guard let out = try? await run(["mcp", "auth", "status", "--all", "--format=json"],
                                       env: ["SBX_MCP_URL": mcpURL.absoluteString]), out.ok,
              // Tolerate a daemon-startup banner on stdout ahead of the JSON.
              let json = Self.firstJSONArray(in: out.stdout),
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }
        var map: [String: String] = [:]
        for entry in arr {
            if let name = entry["server_name"] as? String, let status = entry["status"] as? String {
                map[name] = status
            }
        }
        return map
    }

    /// Revoke a server's hosted OAuth credential (`sbx mcp auth rm <name>`),
    /// keeping its registration.
    @discardableResult
    func unauthorizeMCP(name: String, mcpURL: URL) async throws -> CommandOutput {
        let out = try await run(["mcp", "auth", "rm", name],
                                env: ["SBX_MCP_URL": mcpURL.absoluteString])
        if !out.ok { throw SbxError.command(out.stderr.isEmpty ? out.stdout : out.stderr) }
        return out
    }

    /// Tear the container down and recreate it: `stop` → `rm -f` → `create`.
    /// Used when the mount set (or other create-time config) changes.
    @discardableResult
    func rebuild(workspace: Workspace, agent: AgentKind, name: String,
                 mounts: [MountSpec], kits: [String] = []) async throws -> Sandbox {
        _ = try? await stop(name)
        _ = try? await remove(name)
        return try await create(workspace: workspace, agent: agent, name: name, mounts: mounts, kits: kits)
    }

    /// Status of a single named container, or `nil` if it does not exist.
    func status(name: String) async throws -> Sandbox? {
        try await list().first { $0.name == name }
    }

    // MARK: - Kits

    /// `sbx kit inspect <ref> --json` — metadata for a directory, zip, or OCI kit
    /// reference (pulls the kit for OCI refs, so this can take a few seconds).
    /// Returns nil when the reference can't be inspected.
    // MARK: - Files into a sandbox

    /// Where pasted images go inside a sandbox: its own /tmp, so nothing lands
    /// in the user's project (gone when the sandbox is recreated).
    nonisolated static let pasteDirectory = "/tmp/sandshell-paste"

    /// Write `data` to `name` in `pasteDirectory` inside `container` (as its
    /// agent user), pruning pastes older than a week. True once it's there.
    /// The bytes go in through a temp file on stdin, not a pipe.
    nonisolated static func writePaste(_ data: Data, named name: String, container: String) async -> Bool {
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("sandshell-paste-\(UUID().uuidString)")
        guard (try? data.write(to: staged)) != nil, let input = try? FileHandle(forReadingFrom: staged) else { return false }
        defer { try? input.close(); try? FileManager.default.removeItem(at: staged) }
        let dir = pasteDirectory
        let script = "mkdir -p \(dir) && find \(dir) -type f -mtime +7 -delete 2>/dev/null; "
            + "cat > \(dir)/\(SbxCommand.shellQuote(name))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: PathFixer.sbxPath())
        p.arguments = ["exec", "-i", container, "sh", "-c", script]
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            p.terminationHandler = { done.resume(returning: $0.terminationStatus == 0) }
            do { try p.run() } catch { done.resume(returning: false) }
        }
    }

    // MARK: - Session process reaping

    /// Kill a session's processes inside its sandbox (by `SbxCommand.ProcessTag`
    /// env), since they outlive the host-side `sbx exec`. Fire-and-forget from
    /// sync teardown paths; `waitForReaps` lets app quit give them a moment.
    @discardableResult
    nonisolated static func reapSessionProcesses(container: String, match: String, immediate: Bool = false) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: PathFixer.sbxPath())
        p.arguments = ["exec", container, "sh", "-c", SbxCommand.reapScript(match: match, immediate: immediate)]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        reaps.withLock { $0.append(p) }
        return p
    }

    /// Same, awaited — used before (re)launching a session so leftovers from a
    /// crash/kill can't share its conversation with the new process. Waits for
    /// this reap itself (a slow `sbx exec` included): one still scanning after
    /// the relaunch would kill the new process too, if it matches it. Past
    /// `timeout` the reap is stopped rather than left to land late.
    nonisolated static func reapSessionProcessesAndWait(container: String, match: String, immediate: Bool = false,
                                                        timeout: TimeInterval = 45) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                if let p = reapSessionProcesses(container: container, match: match, immediate: immediate) {
                    let deadline = Date().addingTimeInterval(timeout)
                    while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                    if p.isRunning {
                        Log.error(.sbx, "reap in \(container) still running after \(Int(timeout))s; stopping it")
                        p.terminate()
                    }
                }
                done.resume()
            }
        }
    }

    /// Block until in-flight reaps finish or `timeout` passes (app quit).
    nonisolated static func waitForReaps(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let running = reaps.withLock { list -> Bool in
                list.removeAll { !$0.isRunning }
                return !list.isEmpty
            }
            if !running { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static let reaps = Mutex<[Process]>([])

    /// Whether sbx holds an Anthropic credential (API key or OAuth) for this
    /// sandbox — global or scoped to it. When it does, sbx's proxy attaches the
    /// real credential to the agent's API requests and refreshes OAuth on the
    /// host, once, for every sandbox.
    func hasAnthropicSecret(sandbox: String) async -> Bool {
        await hasServiceSecret("anthropic", sandbox: sandbox)
    }

    /// Whether sbx holds a credential for `service` (`anthropic`, `openai`,
    /// `google`, …) that applies to this sandbox — global or scoped to it.
    func hasServiceSecret(_ service: String, sandbox: String) async -> Bool {
        let key = "\(service)\u{0}\(sandbox)"
        if let (value, at) = secretCache[key], Date().timeIntervalSince(at) < 30 { return value }
        struct Listing: Decodable {
            struct Secret: Decodable { let scope: String; let name: String }
            let secrets: [Secret]
        }
        var found = false
        if let out = try? await run(["secret", "ls", "--json", "--service", service], routine: true), out.ok,
           let json = Self.firstJSONObject(in: out.stdout), let data = json.data(using: .utf8),
           let listing = try? JSONDecoder().decode(Listing.self, from: data) {
            found = listing.secrets.contains { $0.name == service && ($0.scope == "global" || $0.scope == sandbox) }
        }
        secretCache[key] = (found, Date())
        return found
    }

    func kitInspect(_ ref: String) async -> KitInspection? {
        guard let out = try? await run(["kit", "inspect", KitStore.resolve(ref), "--json"], timeout: 90), out.ok,
              let json = Self.firstJSONObject(in: out.stdout),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(KitInspection.self, from: data)
    }

    /// `sbx inspect <name> --json` — what the sandbox was actually built with
    /// (notably its kit list, which `sbx ls` doesn't report). Nil when the
    /// sandbox doesn't exist or the output can't be read.
    func inspect(_ name: String) async -> SandboxInspection? {
        guard let out = try? await run(["inspect", name, "--json"], routine: true), out.ok,
              let json = Self.firstJSONObject(in: out.stdout),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SandboxInspection.self, from: data)
    }

    /// `sbx kit add <name> <ref>` (experimental): recreates the container with
    /// `ref` appended to its kit list, keeping kit-owned volumes (agent state).
    /// sbx refuses — non-zero exit, sandbox left as it was — for sandboxes that
    /// predate the feature and for kits the recreate can't apply yet (files,
    /// published ports, credentials…); the caller then rebuilds instead.
    /// Output goes to temp files rather than pipes for the same reason as
    /// `createAndPoll`: the recreate (re)starts the sandbox, and a helper that
    /// inherits a pipe fd would stall Foundation's shared callback queue.
    func kitAdd(sandbox name: String, ref: String, cwd: String, mcpURL: URL) async throws -> CommandOutput {
        let args = ["kit", "add", name, KitStore.resolve(ref)]
        Log.info(.sbx, "$ sbx \(args.joined(separator: " "))")
        let started = Date()
        let proc = makeProcess(args, env: ["SBX_MCP_URL": mcpURL.absoluteString])
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.standardInput = FileHandle.nullDevice
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("sbx-kit-add-\(UUID().uuidString).out")
        let errURL = tmp.appendingPathComponent("sbx-kit-add-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            throw SbxError.spawn("could not open output capture for kit add “\(name)”")
        }
        proc.standardOutput = outHandle
        proc.standardError = errHandle
        defer {
            try? outHandle.close()
            try? errHandle.close()
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            let once = ResumeOnce()
            proc.terminationHandler = { p in
                guard once.claim() else { return }
                cont.resume(returning: p.terminationStatus)
            }
            do {
                try proc.run()
            } catch {
                guard once.claim() else { return }
                cont.resume(throwing: SbxError.spawn("\(sbx) \(args.joined(separator: " ")): \(error)"))
            }
            // Backstop: a recreate normally takes seconds; a wedged one shouldn't
            // leave the rebuild spinner up forever.
            Task.detached { [weak proc] in
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                guard once.claim() else { return }
                if proc?.isRunning == true { proc?.terminate() }
                cont.resume(throwing: SbxError.command("sbx kit add timed out after 300s"))
            }
        }
        let out = Self.clean((try? String(contentsOf: outURL, encoding: .utf8)) ?? "")
        let err = Self.clean((try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if status == 0 {
            Log.info(.sbx, "→ sbx kit add ok (\(ms)ms)")
        } else {
            Log.error(.sbx, "→ sbx kit add exit \(status) (\(ms)ms): \(err.isEmpty ? out : err)")
        }
        return CommandOutput(stdout: out, stderr: err, status: status)
    }

    // MARK: - In-sandbox reads

    /// Run a short shell script inside a running sandbox; nil if it fails.
    func exec(inSandbox name: String, script: String) async -> String? {
        guard let out = try? await run(["exec", name, "sh", "-c", script], routine: true, timeout: 20), out.ok
        else { return nil }
        return out.stdout
    }

    /// Read a file from inside a running sandbox (`sbx exec <name> cat <path>`).
    /// Routine (not logged per call, bounded timeout) — used for polling the kit
    /// startup log. Throws if the sandbox isn't running or the file is missing.
    func readFile(inSandbox name: String, path: String) async throws -> String {
        let out = try await run(["exec", name, "cat", path], routine: true, timeout: 20)
        if !out.ok { throw SbxError.command(out.stderr.isEmpty ? out.stdout : out.stderr) }
        return out.stdout
    }

    // MARK: - Process plumbing

    private func socketGET(path: String, socketPath: String) -> String? {
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = ["-s", "--max-time", "3", "--unix-socket",
                          socketPath, "http://localhost\(path)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch {
            Log.error(.sbx, "sbx socket GET \(path) failed to spawn: \(error.localizedDescription)")
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private static func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func makeProcess(_ args: [String], env: [String: String]? = nil) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: sbx)
        proc.arguments = args
        // Inherit the patched process environment (PATH fix from PathFixer).
        var environment = ProcessInfo.processInfo.environment
        // Enable MCP (dynamic discovery: the gateway exposes mcp-find/mcp-add) by
        // default so every sbx call — including the one that starts sandboxd —
        // runs with MCP on. A per-call env (e.g. a workspace's custom gateway) or
        // a value the user already exported takes precedence.
        if environment["SBX_MCP_URL"]?.isEmpty != false {
            environment["SBX_MCP_URL"] = Workspace.defaultMCPURL.absoluteString
        }
        if let env { environment.merge(env) { _, new in new } }
        environment.removeValue(forKey: "MCP_GATEWAY_URL")
        proc.environment = environment
        return proc
    }

    /// Every sbx invocation is logged (start + outcome). `routine` tags the
    /// high-frequency `ls` poll with a "·" marker so it's easy to filter out, but
    /// it is still recorded — every sbx action goes to the Sandshell log.
    /// Runs `sbx`. `routine` reads (ls/status) get a `timeout`: if termination
    /// delivery is wedged — e.g. a daemon a sibling `sbx create` just spawned is
    /// holding one of our pipe fds open, stalling Foundation's shared callback
    /// queue — the call is killed and surfaced as an error rather than hanging the
    /// UI forever. Non-routine calls (mcp auth/OAuth, etc.) may legitimately run
    /// long, so they stay unbounded unless a caller passes `timeout`.
    private func run(_ args: [String], cwd: String? = nil, env: [String: String]? = nil,
                     routine: Bool = false, timeout: TimeInterval? = nil) async throws -> CommandOutput {
        if !routine { Log.info(.sbx, "$ sbx \(args.joined(separator: " "))") }
        let started = Date()
        let proc = makeProcess(args, env: env)
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let limit = timeout ?? (routine ? 30 : nil)

        // Accumulate output incrementally instead of `readDataToEndOfFile()` at
        // exit: commands like `sbx mcp add` (re)start the long-lived daemon, which
        // inherits these pipe fds and never closes them — so a read-to-EOF would
        // block forever even after `sbx` itself exits. We resolve on termination
        // with whatever was streamed by then.
        let outBox = DataBox(), errBox = DataBox()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            d.isEmpty ? (h.readabilityHandler = nil) : outBox.append(d)
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            d.isEmpty ? (h.readabilityHandler = nil) : errBox.append(d)
        }

        let once = ResumeOnce()
        let timeoutHolder = TaskHolder()
        return try await withCheckedThrowingContinuation { cont in
            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                guard once.claim() else { return }
                timeoutHolder.task?.cancel()
                let out = Self.clean(String(data: outBox.data, encoding: .utf8) ?? "")
                let err = Self.clean(String(data: errBox.data, encoding: .utf8) ?? "")
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if p.terminationStatus != 0 {
                    Log.error(.sbx, "→ sbx \(args.first ?? "") exit \(p.terminationStatus) (\(ms)ms): \(err.isEmpty ? out : err)")
                } else if !routine {
                    Log.info(.sbx, "→ sbx \(args.first ?? "") ok (\(ms)ms)")
                }
                cont.resume(returning: CommandOutput(stdout: out, stderr: err, status: p.terminationStatus))
            }
            // Timeout backstop: kill a wedged process and resume with an error so
            // the caller's spinner can't hang indefinitely.
            if let limit {
                timeoutHolder.task = Task.detached { [weak proc] in
                    try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                    guard once.claim() else { return }
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    proc?.terminationHandler = nil
                    if proc?.isRunning == true { proc?.terminate() }
                    Log.error(.sbx, "→ sbx \(args.first ?? "") TIMED OUT after \(Int(limit))s; terminated")
                    cont.resume(throwing: SbxError.command("sbx \(args.first ?? "") timed out after \(Int(limit))s"))
                }
            }
            do {
                try proc.run()
            } catch {
                guard once.claim() else { return }
                timeoutHolder.task?.cancel()
                cont.resume(throwing: SbxError.spawn("\(sbx) \(args.joined(separator: " ")): \(error)"))
            }
        }
    }

    /// Guarantees a continuation is resumed exactly once across the termination
    /// handler, the timeout task, and the spawn-failure path.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
    }

    /// Holds the timeout task so the termination handler can cancel it.
    private final class TaskHolder: @unchecked Sendable {
        var task: Task<Void, Never>?
    }

    /// Thread-safe byte accumulator for async pipe reads (readability handlers
    /// fire on background queues).
    private final class DataBox: @unchecked Sendable {
        private var buffer = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }

    /// Thread-safe exit-status holder for a detached process the poller watches.
    private final class ProcState: @unchecked Sendable {
        private var code: Int32?
        private let lock = NSLock()
        func finish(_ status: Int32) { lock.lock(); code = status; lock.unlock() }
        var exitCode: Int32? { lock.lock(); defer { lock.unlock() }; return code }
    }

    /// Drop interactive-shell session noise that login shells print, mirroring
    /// `sbx.rs::is_shell_session_noise`.
    private static func clean(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let l = line.trimmingCharacters(in: .whitespaces).lowercased()
                return !(l.hasPrefix("restored session:")
                    || l.hasPrefix("saving session")
                    || l.hasPrefix("...copying shared history")
                    || l.hasPrefix("...saving history"))
            }
            .joined(separator: "\n")
    }

    /// Extracts the first balanced top-level JSON object (`{ … }`) from a string,
    /// tolerating any non-JSON preamble (e.g. a daemon-startup banner printed to
    /// stdout) and trailing noise. Returns nil if no object is found.
    static func firstJSONObject(in s: String) -> String? { firstJSONValue(in: s, open: "{", close: "}") }

    /// Like `firstJSONObject`, but for a top-level JSON array (`[ … ]`).
    static func firstJSONArray(in s: String) -> String? { firstJSONValue(in: s, open: "[", close: "]") }

    /// Extracts the first balanced top-level bracketed JSON value, skipping any
    /// non-JSON preamble and trailing noise. Honors string literals and escapes
    /// so brackets inside strings don't throw off the depth count.
    private static func firstJSONValue(in s: String, open: Character, close: Character) -> String? {
        guard let start = s.firstIndex(of: open) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case open: depth += 1
                case close:
                    depth -= 1
                    if depth == 0 { return String(s[start...i]) }
                default: break
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}

enum SbxError: LocalizedError {
    case command(String)
    case parse(String)
    case spawn(String)

    var errorDescription: String? {
        switch self {
        case let .command(m): return m
        case let .parse(m): return m
        case let .spawn(m): return m
        }
    }
}
