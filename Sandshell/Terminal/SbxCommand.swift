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

    /// Env pairs passed through `sbx exec ... env K=V ...`. Mirrors
    /// `sbx.rs::sandbox_shell_env`, plus `SBX_MCP_URL` when the workspace has an
    /// MCP gateway configured.
    private static func envPairs(home: String, mcpURL: URL?, claude: ClaudeOptions?) -> [String] {
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
            "CODEX_HOME=\(home)/.codex",
        ]
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
        default: return agent.rawValue
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
                              claude: ClaudeOptions? = nil) -> String {
        // `exec` so the sbx process replaces the shell, keeping signal semantics.
        return "#!/bin/sh\nexec " + launchCommand(
            containerName: containerName, workdir: workdir, agent: agent,
            sbxPath: sbxPath, home: home, mcpURL: mcpURL, resumeID: resumeID, claude: claude) + "\n"
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
                              claude: ClaudeOptions? = nil) -> String {
        // program(...) already returns a properly-quoted command line (incl. any
        // `--resume <id>`), so it's not re-quoted here.
        let auth = agent == .claude && useProxyAuth(claude?.sbxProxyAuth ?? false) ? " \(proxyAuthSetup)" : ""
        let bashc = "\(pathSetup)\(auth) exec \(program(for: agent, resumeID: resumeID, claude: claude))"
        var parts: [String] = [shellQuote(sbxPath), "exec", "-it"]
        if !workdir.isEmpty { parts += ["-w", shellQuote(workdir)] }
        parts.append(shellQuote(containerName))
        parts += ["env", "-u", "MCP_GATEWAY_URL"]
        parts += envPairs(home: home, mcpURL: mcpURL, claude: claude).map(shellQuote)
        parts += ["bash", "-c", shellQuote(bashc)]
        return parts.joined(separator: " ")
    }

    /// Pinned ACP adapter for Claude chat sessions (built on the Claude Agent SDK).
    static let claudeACPPackage = "@agentclientprotocol/claude-agent-acp@0.90.0"

    /// `sbx` argv for a chat session: the ACP adapter over plain stdio (`-i`, no
    /// TTY). `CLAUDE_CODE_EXECUTABLE` points the adapter at the image's own
    /// claude instead of the SDK's bundled copy, so the base-image channel still
    /// decides the Claude Code version.
    static func acpArguments(containerName: String, workdir: String, home: String, mcpURL: URL?,
                             sbxProxyAuth: Bool = false) -> [String] {
        var args = ["exec", "-i"]
        if !workdir.isEmpty { args += ["-w", workdir] }
        args += [containerName, "env", "-u", "MCP_GATEWAY_URL"]
        args += envPairs(home: home, mcpURL: mcpURL, claude: nil)
        let auth = useProxyAuth(sbxProxyAuth) ? " " + proxyAuthSetup : ""
        args += ["bash", "-c",
                 #"\#(pathSetup)\#(auth) export CLAUDE_CODE_EXECUTABLE="$(command -v claude)"; exec npx -y \#(claudeACPPackage)"#]
        return args
    }

    /// POSIX single-quote a token. Mirrors sbx.rs `shell_escape`.
    static func shellQuote(_ s: String) -> String {
        let safe = !s.isEmpty && s.unicodeScalars.allSatisfy { sc in
            let c = Character(sc)
            return c.isLetter || c.isNumber || "/._-:+@=,".contains(c)
        }
        if safe { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
