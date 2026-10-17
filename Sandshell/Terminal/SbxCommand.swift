import Foundation

/// Builds the host-side command that launches a session's agent inside its
/// container via `sbx exec`. Ported from sbx.rs (`sbx_exec_command`,
/// `sandbox_shell_env`, `sandbox_path_setup_body`).
///
/// We emit a full `/bin/sh` script body. `TerminalSession` writes it to a temp
/// executable and points Ghostty's `command =` config at that single path —
/// sidestepping all config-file quoting concerns.
enum SbxCommand {
    private static let cargoHome = "/home/agent/.cargo"
    private static let cargoBin = "/home/agent/.cargo/bin"
    private static let rustupHome = "/home/agent/.rustup"

    /// Claude-only launch extras: `--model`/`--effort` overrides and Sandshell's status
    /// feed (`--settings` JSON naming the feed script, plus the env it reads).
    struct ClaudeOptions {
        var model: String?
        var effort: String?
        var statusScriptPath: String?
        var statusDir: String?
        var sessionID: String?
        /// Authenticate through sbx's credential proxy (see `proxyAuthSetup`).
        var sbxProxyAuth = false
    }

    /// Host locale forwarded into the container; `C.UTF-8` is universally present
    /// when the host doesn't export a UTF-8 `LANG`.
    private static var hostLang: String {
        let lang = ProcessInfo.processInfo.environment["LANG"] ?? ""
        return lang.uppercased().contains("UTF-8") ? lang : "C.UTF-8"
    }

    /// Base URL of the host's inference-gateway proxy as seen from the container
    /// (e.g. `http://host.docker.internal:3210`). Unset by default:
    /// `defaults write <bundle-id> inferenceGatewayURL http://host.docker.internal:3210`.
    private static var inferenceGatewayURL: String? {
        let v = UserDefaults.standard.string(forKey: "inferenceGatewayURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty ?? true) ? nil : v
    }

    /// In-container PATH setup, run ahead of the target program. Mirrors
    /// `sbx.rs::sandbox_path_setup_body`.
    private static var pathSetup: String {
        #"P="$PATH"; [ -d "\#(cargoBin)" ] && P="\#(cargoBin):$P"; [ -d "$HOME/bin" ] && P="$HOME/bin:$P"; [ -d "$HOME/.local/bin" ] && P="$HOME/.local/bin:$P"; export PATH="$P";"#
    }

    /// Claude auth via sbx's credential proxy. The sandbox's own
    /// `$HOME/.claude/.credentials.json` holds a placeholder token that sbx's
    /// proxy swaps for the real credential (refreshing OAuth on the host, once,
    /// for every sandbox). We keep `CLAUDE_CONFIG_DIR` on the mounted host
    /// `~/.claude` for settings/transcripts, so hand claude the placeholder via
    /// `CLAUDE_CODE_OAUTH_TOKEN` (which outranks the credentials file and is
    /// never refreshed) — otherwise every sandboxed claude refreshes the host
    /// file's token itself and they race (rotating refresh tokens).
    private static var proxyAuthSetup: String {
        #"T=$(sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p' "$HOME/.claude/.credentials.json" 2>/dev/null); [ -n "$T" ] && export CLAUDE_CODE_OAUTH_TOKEN="$T";"#
    }

    /// Whether to use `proxyAuthSetup`: requested, and not overridden by the
    /// opt-in inference gateway (which brings its own auth).
    private static func useProxyAuth(_ requested: Bool) -> Bool { requested && inferenceGatewayURL == nil }

    /// Tags on every session's in-container process (inherited by its children):
    /// `SANDSHELL_SESSION` (the sidebar session) and `SANDSHELL_LAUNCH` (this
    /// launch). `reapScript` kills by them, since processes in the sandbox
    /// outlive the host-side `sbx exec` (quit, crash, restart).
    struct ProcessTag {
        let session: UUID
        let launch = UUID()
        var pairs: [String] { ["SANDSHELL_SESSION=\(session.uuidString)", "SANDSHELL_LAUNCH=\(launch.uuidString)"] }
    }

    /// `sh -c` body run via `sbx exec <container>` that TERMs, then KILLs, every
    /// process whose environment carries `match` (e.g. `SANDSHELL_LAUNCH=<uuid>`).
    /// `immediate`: KILL at once, with no chance to write anything on the way
    /// out (a chat reloading a conversation another app is writing to).
    static func reapScript(match: String, immediate: Bool = false) -> String {
        let scan = #"for d in /proc/[0-9]*; do { tr '\0' '\n' < "$d/environ"; } 2>/dev/null | grep -qxF "$M" && kill -SIG "${d#/proc/}" 2>/dev/null; done"#
        if immediate { return "M=\(shellQuote(match)); " + scan.replacing("SIG", with: "KILL") + "; true" }
        return "M=\(shellQuote(match)); " + scan.replacing("SIG", with: "TERM")
            + "; sleep 1; " + scan.replacing("SIG", with: "KILL") + "; true"
    }

    /// Env pairs passed through `sbx exec ... env K=V ...`. Mirrors
    /// `sbx.rs::sandbox_shell_env`, plus `SBX_MCP_URL` when the workspace has an
    /// MCP gateway configured.
    private static func envPairs(home: String, mcpURL: URL?, claude: ClaudeOptions?, tag: ProcessTag? = nil) -> [String] {
        // NOTE: we deliberately do NOT override HOME. The container's agents are
        // installed under its own home (/home/agent/.local/bin); forcing HOME to
        // the macOS host home made claude look for its install at
        // <hosthome>/.local/bin and warn "native installation … missing or
        // broken". We still point the agents at the **mounted host** config dirs
        // via CLAUDE_CONFIG_DIR/CODEX_HOME (absolute host paths), so credentials,
        // settings, and transcripts live in the user's real ~/.claude / ~/.codex.
        var pairs = [
            "COLORTERM=truecolor",
            "TERM=xterm-256color",
            // Forward the host locale so UTF-8 / box-drawing glyphs render (sbx-ui
            // pty.rs); fall back to a locale every container ships with.
            "LANG=\(hostLang)",
            "CARGO_HOME=\(cargoHome)",
            "RUSTUP_HOME=\(rustupHome)",
            "CLAUDE_CONFIG_DIR=\(home)/.claude",
        ]
        // `~/.codex` is only mounted when it exists on the host (MountPolicy
        // `.ifPresent`); otherwise keep sbx's own in-sandbox CODEX_HOME, which
        // carries its proxy-auth and MCP config, rather than point codex at an
        // unmounted path.
        if FileManager.default.fileExists(atPath: "\(home)/.codex") { pairs.append("CODEX_HOME=\(home)/.codex") }
        if let mcpURL { pairs.append("SBX_MCP_URL=\(mcpURL.absoluteString)") }
        // Opt-in inference gateway: route claude through the host's
        // `inference-gateway-auth proxy`, which attaches the stored OAuth token.
        // The placeholder token only stops claude prompting for a login.
        if let gateway = inferenceGatewayURL {
            pairs += ["ANTHROPIC_BASE_URL=\(gateway)", "ANTHROPIC_AUTH_TOKEN=sandshell-inference-gateway"]
        }
        if let dir = claude?.statusDir, let sid = claude?.sessionID {
            pairs += ["SANDSHELL_STATUS_DIR=\(dir)", "SANDSHELL_SESSION_ID=\(sid)"]
        }
        if let tag { pairs += tag.pairs }
        return pairs
    }

    /// In-container program for an agent kind (`shell` → an interactive bash).
    /// When `resumeID` is set for claude, resume that prior conversation.
    private static func program(for agent: AgentKind, resumeID: String?, claude: ClaudeOptions?) -> String {
        switch agent {
        case .shell: return "bash"
        case .claude:
            var parts = ["claude"]
            if let id = resumeID { parts += ["--resume", shellQuote(id)] }
            if let model = claude?.model, !model.isEmpty { parts += ["--model", shellQuote(model)] }
            if let effort = claude?.effort, !effort.isEmpty { parts += ["--effort", shellQuote(effort)] }
            // Sandshell's status feed rides in as CLI settings (highest non-managed
            // precedence); the feed script chains to the user's own status line.
            if let script = claude?.statusScriptPath {
                parts += ["--settings", shellQuote(ClaudeStatusFeed.settingsJSON(scriptPath: script))]
            }
            return parts.joined(separator: " ")
        case .codex:
            // `codex resume <SESSION_ID>` continues a thread by UUID, skipping the
            // interactive picker. The id is the rollout's session_meta.id.
            if let id = resumeID { return "codex resume \(shellQuote(id))" }
            return "codex"
        default:
            // A kit agent runs its kit's entrypoint (`sbx exec` doesn't apply it).
            if !agent.isBuiltin, let entry = AgentProfileStore.profile(for: agent)?.entrypoint, !entry.isEmpty {
                return entry.map(shellQuote).joined(separator: " ")
            }
            return shellQuote(agent.rawValue)
        }
    }

    /// `/bin/sh` script body that launches `agent` in `containerName`, working
    /// in `workdir` (container-side path). Auto-starts the container if stopped.
    static func sessionScript(containerName: String,
                              workdir: String,
                              agent: AgentKind,
                              sbxPath: String,
                              home: String,
                              mcpURL: URL?,
                              resumeID: String? = nil,
                              claude: ClaudeOptions? = nil,
                              tag: ProcessTag? = nil) -> String {
        // `exec` so the sbx process replaces the shell, keeping signal semantics.
        return "#!/bin/sh\nexec " + launchCommand(
            containerName: containerName, workdir: workdir, agent: agent,
            sbxPath: sbxPath, home: home, mcpURL: mcpURL, resumeID: resumeID, claude: claude, tag: tag) + "\n"
    }

    /// The `sbx exec …` one-liner the session launches with — also shown in the
    /// Sandboxes inspector for copy/debug (mirrors sbx-ui's `sbx_exec_command`).
    static func launchCommand(containerName: String,
                              workdir: String,
                              agent: AgentKind,
                              sbxPath: String,
                              home: String,
                              mcpURL: URL?,
                              resumeID: String? = nil,
                              claude: ClaudeOptions? = nil,
                              tag: ProcessTag? = nil) -> String {
        // program(...) already returns a properly-quoted command line (incl. any
        // `--resume <id>`), so it's not re-quoted here.
        let auth = agent == .claude && useProxyAuth(claude?.sbxProxyAuth ?? false) ? " \(proxyAuthSetup)" : ""
        let bashc = "\(pathSetup)\(auth) exec \(program(for: agent, resumeID: resumeID, claude: claude))"
        var parts: [String] = [shellQuote(sbxPath), "exec", "-it"]
        if !workdir.isEmpty { parts += ["-w", shellQuote(workdir)] }
        parts.append(shellQuote(containerName))
        parts += ["env", "-u", "MCP_GATEWAY_URL"]
        parts += envPairs(home: home, mcpURL: mcpURL, claude: claude, tag: tag).map(shellQuote)
        parts += ["bash", "-c", shellQuote(bashc)]
        return parts.joined(separator: " ")
    }

    /// Pinned ACP adapter for Claude chat sessions (built on the Claude Agent
    /// SDK; releases track Claude Code). Bump deliberately.
    static let claudeACPVersion = "0.90.0"
    static let claudeACPPackage = "@agentclientprotocol/claude-agent-acp@\(claudeACPVersion)"

    /// Pinned ACP adapter for Codex chat sessions (it drives `codex app-server`).
    static let codexACPVersion = "2.2.2"
    static let codexACPPackage = "@agentclientprotocol/codex-acp@\(codexACPVersion)"

    /// Agents a native chat can run: each needs an ACP entry point inside its
    /// sandbox — an adapter (Claude, Codex) or native support (Gemini CLI).
    static let acpAgents: [AgentKind] = [.claude, .codex, .gemini]
    static func supportsACP(_ agent: AgentKind) -> Bool { acpAgents.contains(agent) }

    /// Run an npm-published adapter from a per-version install in the sandbox,
    /// installing it once (Claude's: ≈4s, 67 MB, no network afterwards; ~0.2s to
    /// start vs ~1.3s for npx). Installs into a temp dir then renames into place,
    /// so concurrent first starts can't corrupt it. npm's output goes to stderr:
    /// stdout is the JSON-RPC channel.
    private static func npmAdapterLaunch(dir: String, package: String, bin: String, omitOptional: Bool,
                                         wrapperIfPresent: Bool = false) -> String {
        let omit = omitOptional ? " --omit=optional" : ""
        // A half-finished install (no bin) is cleared before the new one moves
        // in; the marker tells the chat a first start may take a while.
        let install = #"D="$HOME/.sandshell/acp/\#(dir)"; B="$D/node_modules/.bin/\#(bin)"; if [ ! -x "$B" ]; then echo "\#(installingMarker)" >&2; mkdir -p "$HOME/.sandshell/acp"; T=$(mktemp -d "$D.tmp.XXXXXX"); if npm install --silent --no-audit --no-fund\#(omit) --prefix "$T" \#(package) >&2; then [ -x "$B" ] || rm -rf "$D"; mv -T "$T" "$D" 2>/dev/null || rm -rf "$T"; else rm -rf "$T"; echo "sandshell: couldn't install \#(package)" >&2; exit 1; fi; fi; "#
        guard wrapperIfPresent else { return install + #"exec "$B""# }
        // The sandshell-claude kit's wrapper runs whichever adapter version this
        // is; with it, say so (the chat shows Undo and MCP), without it run plain.
        return install + #"W="$HOME/.sandshell/sandshell-acp.mjs"; if [ -f "$W" ]; then echo "\#(extrasMarker)" >&2; export SANDSHELL_ACP_DIR="$D"; exec node "$W"; fi; exec "$B""#
    }

    /// What the launch writes to stderr when the kit's wrapper is there, and
    /// when it's installing the adapter first.
    static let extrasMarker = "sandshell-extras: on"
    static let installingMarker = "sandshell-installing: adapter"
    static let launchMarker = "sandshell-launch: up"

    /// The bundled copy of Sandshell's kits (`kits/` in the repo).
    static var bundledKits: URL? { Bundle.main.url(forResource: "kits", withExtension: nil) }

    // The Claude ACP adapter's wrapper (rewind, MCP status) lives in the
    // sandshell-claude kit: `kits/sandshell-claude/files/home/.sandshell/sandshell-acp.mjs`.

    /// In-sandbox program (a `bash -c` body after PATH setup) that speaks ACP on
    /// stdio for `agent`, or nil when it has none.
    private static func acpProgram(for agent: AgentKind, sbxProxyAuth: Bool) -> String? {
        switch agent {
        case .claude:
            // `--omit=optional` skips the SDK's bundled claude; CLAUDE_CODE_EXECUTABLE
            // points the adapter at the image's own, so the base-image channel still
            // decides the Claude Code version.
            let auth = useProxyAuth(sbxProxyAuth) ? proxyAuthSetup + " " : ""
            return auth + #"export CLAUDE_CODE_EXECUTABLE="$(command -v claude)"; "#
                + npmAdapterLaunch(dir: claudeACPVersion, package: claudeACPPackage,
                                   bin: "claude-agent-acp", omitOptional: true, wrapperIfPresent: true)
        case .codex:
            // The adapter runs its own pinned codex (a regular dependency, not the
            // image's): it talks to `codex app-server`, whose protocol moves with
            // codex releases, and the stable image's codex trails the adapter's.
            // NO_BROWSER hides the ChatGPT browser login, which can't work here.
            // `sbx run codex` writes a placeholder auth.json when it starts (sbx's
            // proxy swaps in the real credential); `sbx exec` doesn't, and without
            // it the adapter reports "Authentication required". Write the same one —
            // only into the sandbox's own ~/.codex, never a mounted host one.
            return "export NO_BROWSER=1; " + #"H="$HOME/.codex"; "#
                + #"if [ "${CODEX_HOME:-$H}" = "$H" ] && [ ! -f "$H/auth.json" ] && [ -n "$SBX_CRED_OPENAI_MODE" ]; then "#
                + #"mkdir -p "$H" && printf '%s' '{"OPENAI_API_KEY":"proxy-managed"}' > "$H/auth.json"; fi; "#
                + npmAdapterLaunch(dir: "codex-acp-\(codexACPVersion)", package: codexACPPackage,
                                   bin: "codex-acp", omitOptional: false)
        case .gemini:
            // Gemini CLI speaks ACP itself (`--acp`; `--experimental-acp` is the
            // deprecated spelling).
            return #"command -v gemini >/dev/null || { echo "sandshell: gemini isn't installed in this sandbox's image" >&2; exit 127; }; exec gemini --acp"#
        default:
            return nil
        }
    }

    /// `sbx` argv for a chat session: the agent's ACP entry point over plain
    /// stdio (`-i`, no TTY). Nil when the agent has no ACP support.
    /// `claudeModel`: the workspace's model for a Claude chat — the adapter
    /// starts on it (`ANTHROPIC_MODEL`) and lists it even when its own catalog
    /// lacks it (`ANTHROPIC_CUSTOM_MODEL_OPTION`), so chats run what terminals do.
    static func acpArguments(agent: AgentKind = .claude, containerName: String, workdir: String,
                             home: String, mcpURL: URL?, sbxProxyAuth: Bool = false,
                             tag: ProcessTag? = nil, claudeModel: String? = nil) -> [String]? {
        guard let program = acpProgram(for: agent, sbxProxyAuth: sbxProxyAuth) else { return nil }
        var args = ["exec", "-i"]
        if !workdir.isEmpty { args += ["-w", workdir] }
        args += [containerName, "env", "-u", "MCP_GATEWAY_URL"]
        args += envPairs(home: home, mcpURL: mcpURL, claude: nil, tag: tag)
        if agent == .claude, let model = claudeModel, !model.isEmpty {
            args += ["ANTHROPIC_MODEL=\(model)", "ANTHROPIC_CUSTOM_MODEL_OPTION=\(model)"]
        }
        // First thing it says: the exec got into the sandbox (see ChatSession).
        args += ["bash", "-c", #"echo "\#(launchMarker)" >&2; "# + pathSetup + " " + program]
        return args
    }

    /// POSIX single-quote a token. Mirrors sbx.rs `shell_escape`.
    static func shellQuote(_ s: String) -> String {
        let safe = !s.isEmpty && s.unicodeScalars.allSatisfy { sc in
            let c = Character(sc)
            return c.isLetter || c.isNumber || "/._-:+@=,".contains(c)
        }
        if safe { return s }
        // Every U+0027 scalar, even one a combining mark joins to the next
        // (' + U+0301 is one Character): matching Characters, or Foundation's
        // non-literal search, skips it and leaves a quote open.
        return "'" + s.replacing(/'/.matchingSemantics(.unicodeScalar), with: "'\\''") + "'"
    }
}
