import Foundation

/// A single bind-mount passed positionally to `sbx create`, rendered as
/// `"<path>"` (read-write) or `"<path>:ro"` (read-only).
///
/// Replaces the Milestone-1 `Workspace` mount-spec parser: it both parses the
/// `path[:ro]` strings emitted by `sbx ls` and produces the positional args for
/// `sbx create` (see `MountPolicy.resolved`).
struct MountSpec: Codable, Hashable, Identifiable {
    var path: URL
    var readonly: Bool
    var id: String { spec }

    init(path: URL, readonly: Bool = false) {
        self.path = path
        self.readonly = readonly
    }

    /// Parse an `sbx`-style mount string (`"/abs/path"` or `"/abs/path:ro"`).
    init(spec: String) {
        if spec.hasSuffix(":ro") {
            self.path = URL(fileURLWithPath: String(spec.dropLast(3)))
            self.readonly = true
        } else {
            self.path = URL(fileURLWithPath: spec)
            self.readonly = false
        }
    }

    /// Positional argument for `sbx create` (`"path"` or `"path:ro"`).
    var spec: String { readonly ? "\(path.path):ro" : path.path }

    /// Collapse `$HOME` to `~` for compact display. Mirrors SandboxList.vue.
    func shortPath(home: String) -> String {
        let p = path.path
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }
}

/// A workspace: one host root folder backed (in later phases) by one or more
/// `sbx` containers. The durable settings (`policy`, `mcpServers`, `mcpURL`,
/// `primaryAgent`) live in `<root>/.sandshell/config.json`; the projects and
/// sessions live in `WorkspaceState` (`state.json`). See GA plan §5.
struct Workspace: Codable, Hashable {
    var rootURL: URL
    var containerName: String
    var policy: MountPolicy
    var mcpServers: [String]
    var mcpURL: URL
    var primaryAgent: AgentKind
    /// Kit references applied to this workspace's sandboxes (`sbx create --kit`).
    var kits: [String]
    /// Template tag channel + custom `-t` reference (see `ImageChannel`).
    var imageChannel: ImageChannel = .stable
    var customImage: String = ""

    /// The `-t` template reference for an agent's sandbox, or nil for sbx's default.
    func templateImage(for agent: AgentKind) -> String? {
        imageChannel.templateImage(for: agent, custom: customImage)
    }

    static let defaultMCPURL = URL(string: "https://gateway.docker.com")!

    init(rootURL: URL,
         containerName: String,
         policy: MountPolicy = MountPolicy(),
         mcpServers: [String] = [],
         mcpURL: URL = Workspace.defaultMCPURL,
         primaryAgent: AgentKind = .claude,
         kits: [String] = []) {
        self.rootURL = rootURL
        self.containerName = containerName
        self.policy = policy
        self.mcpServers = mcpServers
        self.mcpURL = mcpURL
        self.primaryAgent = primaryAgent
        self.kits = kits
    }
}
