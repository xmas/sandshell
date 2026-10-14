import Foundation

/// One Docker-backed sandbox as reported by `sbx ls --json`.
///
/// Mirrors the shape emitted by the sbx CLI (see sbx.rs `Sandbox`). The CLI
/// also emits an `id` field which we keep for stable identity.
struct Sandbox: Identifiable, Codable, Hashable {
    var name: String
    var id: String
    var agent: String
    var status: String
    var workspaces: [String]

    enum CodingKeys: String, CodingKey {
        case name, id, agent, status, workspaces
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        // `id` may be absent on older CLIs; fall back to the (unique) name.
        id = (try? c.decode(String.self, forKey: .id)) ?? name
        agent = (try? c.decode(String.self, forKey: .agent)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? ""
        workspaces = (try? c.decode([String].self, forKey: .workspaces)) ?? []
    }

    /// Whether the sandbox is currently running.
    var isRunning: Bool { status.lowercased() == "running" }

    /// First read-write workspace (the primary mount / agent working dir),
    /// falling back to the first workspace of any kind. Mirrors
    /// `sbx.rs::sandbox_workdir`.
    var primaryWorkdir: String? {
        if let rw = workspaces.first(where: { !$0.hasSuffix(":ro") }) {
            return MountSpec(spec: rw).path.path
        }
        return workspaces.first.map { MountSpec(spec: $0).path.path }
    }
}

/// Agents supported by `sbx create`, plus any identity a `kind: sandbox` kit
/// introduces at creation time. Not a closed set — sbx itself lets a kit
/// register an arbitrary agent name (see the kit spec's `kind: sandbox`), so
/// this is a thin string wrapper rather than a fixed enum: any raw value
/// decodes/encodes losslessly and construction never fails.
///
/// `Codable` is hand-written (single-value string container) rather than
/// synthesized, so the wire format stays byte-identical to the enum this
/// replaces — both round-trip to a bare JSON string like `"claude"`, so
/// existing `state.json`/`config.json` files need no migration. That
/// non-failable construction is also the fix for a real bug: with the old
/// enum, decoding a session whose `agent` was any string outside the 10
/// fixed cases *threw*, and `WorkspaceState.load()`'s `try? ... ??
/// WorkspaceState()` swallowed that into a silent full reset of the
/// workspace's entire folder/session list.
struct AgentKind: RawRepresentable, Hashable, Codable, Identifiable {
    var rawValue: String
    var id: String { rawValue }
    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let claude = AgentKind(rawValue: "claude")
    static let codex = AgentKind(rawValue: "codex")
    static let copilot = AgentKind(rawValue: "copilot")
    static let cursor = AgentKind(rawValue: "cursor")
    static let devin = AgentKind(rawValue: "devin")
    static let dockerAgent = AgentKind(rawValue: "docker-agent")
    static let droid = AgentKind(rawValue: "droid")
    static let gemini = AgentKind(rawValue: "gemini")
    static let kiro = AgentKind(rawValue: "kiro")
    static let opencode = AgentKind(rawValue: "opencode")
    static let shell = AgentKind(rawValue: "shell")

    /// The kinds `sbx` ships built-in support for. NOT exhaustive — a
    /// workspace may reference an agent identity outside this list via a
    /// `kind: sandbox` kit. Named deliberately unlike the old `allCases` so
    /// nothing reads this as "every possible agent."
    static let builtins: [AgentKind] = [.claude, .codex, .copilot, .cursor, .devin, .dockerAgent,
                                        .droid, .gemini, .kiro, .opencode, .shell]
    var isBuiltin: Bool { Self.builtins.contains(self) }

    /// Human-facing name: the brand spelling for a builtin, else the custom
    /// agent's registered profile name (`AgentProfileStore`), else the raw id.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .copilot: return "Copilot"
        case .cursor: return "Cursor"
        case .devin: return "Devin"
        case .dockerAgent: return "Docker Agent"
        case .droid: return "Droid"
        case .gemini: return "Gemini"
        case .kiro: return "Kiro"
        case .opencode: return "OpenCode"
        case .shell: return "Shell"
        default: return AgentProfileStore.profile(for: self)?.displayName ?? rawValue
        }
    }

    /// The first positional argument to `sbx create`: the agent name for a
    /// builtin, the defining `kind: sandbox` kit for a custom agent (sbx can't
    /// create a kit agent from its name alone).
    var createReference: String {
        if isBuiltin { return rawValue }
        return AgentProfileStore.profile(for: self)?.kitRef ?? rawValue
    }
}

/// Options for `sbx create`. Mirrors sbx.rs `CreateOpts`.
struct CreateOptions {
    var agent: String = AgentKind.claude.rawValue
    var workspace: String = ""
    var name: String = ""
    var branch: String = ""
    var cpus: Int? = nil
    var memory: String = ""
}

/// Result of running an `sbx` command.
/// The parts of `sbx inspect <name> --json` Sandshell reads. `kits` lists the
/// kit references the container was built with, in order, as sbx recorded
/// them (relative paths made absolute; symlinks and registry refs kept as given).
struct SandboxInspection: Decodable {
    var name: String
    var agent: String?
    var kits: [String]?
    var state: String?
}

struct CommandOutput {
    var stdout: String
    var stderr: String
    var status: Int32
    var ok: Bool { status == 0 }
}

#if DEBUG
extension Sandbox {
    /// Memberwise initializer for previews/tests (the production path decodes
    /// from `sbx ls --json`).
    init(name: String, id: String, agent: String, status: String, workspaces: [String]) {
        self.name = name
        self.id = id
        self.agent = agent
        self.status = status
        self.workspaces = workspaces
    }

    static let previewRunning = Sandbox(
        name: "ui-rewrite", id: "sb_001", agent: "claude", status: "running",
        workspaces: ["/Users/xmas/Code/xmas-sandshell", "/Users/xmas/Code/sbx-ui:ro"]
    )
    static let previewStopped = Sandbox(
        name: "api-spike", id: "sb_002", agent: "codex", status: "stopped",
        workspaces: ["/Users/xmas/Code/api"]
    )
    static let previewSamples = [previewRunning, previewStopped]
}
#endif


/// Which `docker/sandbox-templates` tag a workspace's sandboxes are created
/// from. `sbx` pulls the tag fresh on every create (`--pull always`), but the
/// **stable** tag only moves when Docker cuts a template release (weeks), so it
/// carries an old Claude Code; **nightly** is rebuilt from `main` every day and
/// installs the current Claude Code release.
enum ImageChannel: String, Codable, CaseIterable, Identifiable {
    case stable, nightly, custom
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable:  return "Stable (Docker release)"
        case .nightly: return "Nightly (current Claude Code)"
        case .custom:  return "Custom image…"
        }
    }

    /// Template flavor per agent — the `-docker` variants `sbx` itself uses
    /// (`sbx inspect` shows e.g. `docker/sandbox-templates:claude-code-docker`).
    /// Only flavors whose `-nightly` tag is actively rebuilt are listed (checked
    /// on Docker Hub 2026-09-21: these refreshed that morning; copilot, droid
    /// and kiro nightlies were last built in August, so those agents fall back
    /// to sbx's default image on every channel rather than get an *older*
    /// image from "nightly").
    static func flavor(for agent: AgentKind) -> String? {
        switch agent {
        case .claude:      return "claude-code-docker"
        case .codex:       return "codex-docker"
        case .shell:       return "shell-docker"
        case .gemini:      return "gemini-docker"
        case .dockerAgent: return "docker-agent-docker"
        case .opencode:    return "opencode-docker"
        case .cursor:      return "cursor-agent-docker"
        case .copilot, .droid, .kiro: return nil
        default: return nil   // any custom/kit-introduced agent identity
        }
    }

    /// The `-t/--template` reference to pass to `sbx create`, or nil to let
    /// sbx pick its default (stable) image.
    func templateImage(for agent: AgentKind, custom: String) -> String? {
        // A custom agent's image is its kit's `sandbox.image`, and `-t` silently
        // replaces it (spike, sbx 0.48: the sandbox keeps the kit's agent
        // identity but runs the -t image, which lacks the kit's agent binary).
        guard agent.isBuiltin else { return nil }
        switch self {
        case .stable:  return nil
        case .nightly: return Self.flavor(for: agent).map { "docker/sandbox-templates:\($0)-nightly" }
        case .custom:
            let t = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }
}
