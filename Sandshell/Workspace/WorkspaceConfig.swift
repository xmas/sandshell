import Foundation

/// Durable, workspace-scoped configuration persisted at
/// `<root>/.sandshell/config.json`: the mount policy, kits, primary agent,
/// and whether the user has confirmed the mount setup yet. Unlike `state.json`
/// (volatile, git-ignored) this is durable and tracked. See GA plan §5.
struct WorkspaceConfig: Codable {
    var schemaVersion: Int
    var policy: MountPolicy
    var primaryAgent: AgentKind
    /// Set once the user has reviewed/confirmed mounts in the mount-config UI.
    /// Drives whether that UI is shown on opening the workspace.
    var configured: Bool
    /// Auto-archive debounce/interval in seconds (consumed in Phase 7).
    var archiveInterval: TimeInterval
    /// Per-root appearance/terminal preferences. `nil` means this root has never
    /// customized its look and should inherit the global default (`ThemeDefaults`).
    var theme: ThemePreferences?
    /// Kit references applied to this workspace's sandboxes (`sbx create --kit`).
    var kits: [String]
    /// Which of Sandshell's own kits are on (`KitStore.sandshellKits`); nil =
    /// the registry's defaults. Kept apart from `kits` so an older Sandshell,
    /// which doesn't know them, never passes their bare names to sbx.
    var sandshellKits: [String]?
    /// Which template tag sandboxes are created from (see `ImageChannel`).
    var imageChannel: ImageChannel
    /// `-t` reference when `imageChannel == .custom`.
    var customImage: String
    /// `claude --model` id for this workspace's Claude sessions; `nil` = Claude's default.
    var claudeModel: String?
    /// `claude --effort` level for this workspace's Claude sessions; `nil` = Claude's default.
    var claudeEffort: String?
    /// Custom (kit-defined) agents this workspace offers next to the builtins;
    /// their display identity lives app-globally in `AgentProfileStore`.
    var customAgents: [AgentKind] = []
    /// Agents work on a private clone of the repo inside the sandbox
    /// (`sbx create --clone`) instead of the folder itself; their commits come
    /// back through the `sandbox-<name>` git remote. nil = off.
    var cloneRepo: Bool?
    /// A Claude account of this workspace's own (`ClaudeAccounts`): its
    /// sandboxes' Claude uses that folder instead of this Mac's `~/.claude`.
    /// nil = this Mac's.
    var claudeAccount: String?

    static let defaultArchiveInterval: TimeInterval = 1800   // 30 min

    init(policy: MountPolicy,
         primaryAgent: AgentKind = .claude,
         configured: Bool = false,
         archiveInterval: TimeInterval = WorkspaceConfig.defaultArchiveInterval,
         theme: ThemePreferences? = nil,
         kits: [String] = [],
         imageChannel: ImageChannel = .stable,
         customImage: String = "",
         claudeModel: String? = nil,
         claudeEffort: String? = nil,
         schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion
        self.policy = policy
        self.primaryAgent = primaryAgent
        self.configured = configured
        self.archiveInterval = archiveInterval
        self.theme = theme
        self.kits = kits
        self.imageChannel = imageChannel
        self.customImage = customImage
        self.claudeModel = claudeModel
        self.claudeEffort = claudeEffort
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, policy, primaryAgent, configured, archiveInterval, theme, kits
        case imageChannel, customImage, claudeModel, claudeEffort, customAgents, sandshellKits, cloneRepo, claudeAccount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Older configs' `mcpServers`/`mcpURL` (the sbx MCP gateway, since
        // removed) are left unread, and go at the next save.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        policy = try c.decode(MountPolicy.self, forKey: .policy)
        primaryAgent = try c.decodeIfPresent(AgentKind.self, forKey: .primaryAgent) ?? .claude
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        archiveInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .archiveInterval)
            ?? WorkspaceConfig.defaultArchiveInterval
        theme = try c.decodeIfPresent(ThemePreferences.self, forKey: .theme)
        // An official kit's v2 name becomes its v3 successor's.
        var current: [String] = []
        for kit in try c.decodeIfPresent([String].self, forKey: .kits) ?? [] where !current.contains(KitStore.current(kit)) {
            current.append(KitStore.current(kit))
        }
        kits = current
        imageChannel = try c.decodeIfPresent(ImageChannel.self, forKey: .imageChannel) ?? .stable
        customImage = try c.decodeIfPresent(String.self, forKey: .customImage) ?? ""
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel)
        claudeEffort = try c.decodeIfPresent(String.self, forKey: .claudeEffort)
        customAgents = try c.decodeIfPresent([AgentKind].self, forKey: .customAgents) ?? []
        sandshellKits = try c.decodeIfPresent([String].self, forKey: .sandshellKits)
        cloneRepo = try c.decodeIfPresent(Bool.self, forKey: .cloneRepo)
        claudeAccount = try c.decodeIfPresent(String.self, forKey: .claudeAccount).flatMap { ClaudeAccounts.isValid($0) ? $0 : nil }
        // Builds before this field kept them in `kits`: move them over.
        let own = kits.filter(KitStore.isSandshellKit)
        if !own.isEmpty {
            kits.removeAll(where: KitStore.isSandshellKit)
            var moved = sandshellKits ?? []
            for kit in own where !moved.contains(kit) { moved.append(kit) }
            sandshellKits = moved
        }
    }

    // MARK: - Persistence

    static func url(root: URL) -> URL {
        WorkspaceState.controlDir(root: root).appending(path: "config.json")
    }

    /// Load persisted config, or `nil` if none exists yet.
    static func load(root: URL) throws -> WorkspaceConfig? {
        let url = url(root: root)
        DebugProfile.seedConfig(root: root, into: url)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try JSONDecoder().decode(WorkspaceConfig.self, from: Data(contentsOf: url))
    }

    /// Load the config or build a default one seeded from `home` — and, for a
    /// root that has never been configured, with the registry's default kits —
    /// also saying when config.json was there but couldn't be read. Pass that
    /// on (`WorkspaceStore.report`) for the window to say.
    static func loadReportingProblems(root: URL, home: URL) -> (config: WorkspaceConfig, unreadable: UnreadableWorkspaceFile?) {
        do {
            return (try load(root: root) ?? makeDefault(home: home), nil)
        } catch {
            return (makeDefault(home: home), setAside(root: root, error))
        }
    }

    /// config.json couldn't be read (a merge conflict, a typo): keep a copy
    /// before anything can save defaults over it, and say so.
    static func setAside(root: URL, _ error: any Error) -> UnreadableWorkspaceFile {
        .setAside(.config, file: url(root: root), error)
    }

    private static func makeDefault(home: URL) -> WorkspaceConfig {
        WorkspaceConfig(policy: .makeDefault(home: home), kits: KitStore.defaultRefs.filter { !KitStore.isSandshellKit($0) })
    }

    /// Atomically write to `<root>/.sandshell/config.json`.
    func save(root: URL) throws {
        try FileManager.default.createDirectory(
            at: WorkspaceState.controlDir(root: root), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(root: root), options: .atomic)
    }
}

/// Claude accounts a workspace's sandboxes can use instead of this Mac's
/// `~/.claude` — say a personal one on a work Mac whose own Claude is managed:
/// each a folder of its own (`~/.sandshell/claude-accounts/<name>/.claude`)
/// mounted into those sandboxes as Claude's config (`CLAUDE_CONFIG_DIR`), so
/// its sign-in, settings and transcripts stay there. The Mac's own Claude
/// never uses it. Sign in once inside the sandbox (`/login`).
enum ClaudeAccounts {
    /// Where the accounts' folders are.
    static func root(home: URL) -> URL {
        home.appending(path: ".sandshell/claude-accounts", directoryHint: .isDirectory)
    }

    /// The folder standing for `$HOME` in Claude's paths (its `.claude` inside):
    /// `home` itself for this Mac's account.
    static func claudeHome(_ account: String?, home: URL) -> URL {
        account.map { root(home: home).appending(path: $0, directoryHint: .isDirectory) } ?? home
    }

    /// The accounts made so far, by name.
    static func names(home: URL) -> [String] {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root(home: home).path(percentEncoded: false))) ?? []
        return dirs.filter(isValid).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A name that's a plain folder name: letters, digits, `.`, `_`, `-`; not hidden.
    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && !name.hasPrefix(".")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// What to say when sbx's global Anthropic credential would stand in for
    /// the account's own sign-in (its proxy overwrites the sign-in on every
    /// request to Anthropic; a credential scoped to the sandbox wins over it).
    static func overriddenWarning(account: String, sandbox: String) -> String {
        "This workspace uses its own Claude account (“\(account)”), but sbx holds an Anthropic credential for every "
            + "sandbox, and its proxy puts that on this sandbox's requests — so Claude here runs as that account, not "
            + "its own. Give this sandbox its own credential on the Mac: sbx secret set anthropic --sandbox \(sandbox)"
    }

    /// Make `name`'s folder (and its `.claude`), ready to mount.
    static func make(_ name: String, home: URL) {
        try? FileManager.default.createDirectory(
            at: claudeHome(name, home: home).appending(path: ".claude", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
    }
}
