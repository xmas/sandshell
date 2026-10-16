import Foundation

/// A kit the user has added — the reference passed to `sbx create --kit <ref>`
/// (a directory, ZIP, or OCI reference), plus optional metadata read from a
/// directory kit's `spec.yaml`.
struct KitRef: Codable, Hashable, Identifiable {
    var ref: String
    var displayName: String?
    var summary: String?
    /// Applied to every *new* workspace (setup wizard preselection, and the
    /// default config for roots opened without a wizard). Existing workspaces
    /// keep their own kit set until the user enables it there.
    var isDefault: Bool = false

    var id: String { ref }

    init(ref: String, displayName: String? = nil, summary: String? = nil, isDefault: Bool = false) {
        self.ref = ref
        self.displayName = displayName
        self.summary = summary
        self.isDefault = isDefault
    }

    enum CodingKeys: String, CodingKey { case ref, displayName, summary, isDefault }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(String.self, forKey: .ref)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false   // pre-flag registries
    }

    /// Row label: the spec's displayName, else the last path/ref component.
    var title: String {
        if let displayName, !displayName.isEmpty { return displayName }
        let leaf = (ref as NSString).lastPathComponent
        return leaf.isEmpty ? ref : leaf
    }
}

/// App-global registry of kits the user has added, stored in `UserDefaults`.
/// Which kits apply to a given workspace is a per-workspace choice
/// (`WorkspaceConfig.kits`); this is just the shared catalog they pick from.
enum KitStore {
    private static let key = "kitRegistry"
    private static let seededKey = "kitRegistrySeededOfficialDefaults.v1"

    /// Official kits worth having in every sandbox: cheap, no ports, and they
    /// fix real gaps (unsigned in-sandbox commits, SSH host-key prompts). Seeded
    /// into the registry once, as defaults; removing or un-defaulting them sticks.
    static let officialDefaults: [KitRef] = [
        KitRef(ref: "docker.io/sbx/git-ssh-sign-kit:latest", displayName: "Git SSH Commit Signing",
               summary: "Signs commits with the SSH key forwarded from your Mac's agent, so in-sandbox commits are Verified like host commits.",
               isDefault: true),
        KitRef(ref: "docker.io/sbx/github-ssh-kit:latest", displayName: "GitHub SSH",
               summary: "Pre-populates GitHub's SSH host keys so clone/push/pull over SSH never stops on a host-verification prompt.",
               isDefault: true),
        KitRef(ref: "docker.io/sbx/code-server-kit:latest", displayName: "code-server (web VS Code)",
               summary: "VS Code in the browser on port 8080, opened on the workspace, with the Claude Code extension preinstalled.",
               isDefault: true),
    ]

    // MARK: Agent requirements

    private static let requirementsKey = "kitRequiredAgents"
    /// Known up front, so the official default works offline.
    private static let knownRequirements = ["docker.io/sbx/code-server-kit:latest": "claude"]

    /// The agent a kit is made for (`requires.agent` in its spec, or the agent
    /// a `kind: sandbox` kit defines): `.some(nil)` for any agent, `nil` while
    /// not yet known.
    static func requiredAgent(_ ref: String) -> String?? {
        if let known = knownRequirements[ref] { return .some(known) }
        // An agent kit is its own agent's: sbx refuses it as another's --kit.
        if let profile = AgentProfileStore.all.first(where: { $0.kitRef == ref }) { return .some(profile.agent) }
        let cache = UserDefaults.standard.dictionary(forKey: requirementsKey) as? [String: String] ?? [:]
        guard let agent = cache[ref] else { return nil }
        return .some(agent.isEmpty ? nil : agent)
    }

    /// Remember what `sbx kit inspect` said a kit requires.
    static func learn(_ ref: String, from info: KitInspection) {
        var cache = UserDefaults.standard.dictionary(forKey: requirementsKey) as? [String: String] ?? [:]
        cache[ref] = info.kind == "sandbox" ? (info.name ?? "") : (info.requires?.agent ?? "")
        UserDefaults.standard.set(cache, forKey: requirementsKey)
    }

    /// Which of `refs` a sandbox for `agent` can take: a kit made for another
    /// agent is left out (sbx refuses to compose it). Unknown ones stay in.
    static func kits(_ refs: [String], for agent: AgentKind) -> [String] {
        refs.filter { ref in
            guard let required = requiredAgent(ref), let agentName = required else { return true }
            return agentName == agent.rawValue
        }
    }

    /// Kits flagged as defaults for new workspaces, in registry order.
    static var defaults: [KitRef] { all.filter(\.isDefault) }
    static var defaultRefs: [String] { defaults.map(\.ref) }

    /// One-time: register the official default kits (runs at launch).
    static func seedOfficialDefaultsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        var kits = all
        for kit in officialDefaults where !kits.contains(where: { $0.ref == kit.ref }) {
            kits.append(kit)
        }
        save(kits)
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    static func setDefault(_ ref: String, _ isDefault: Bool) {
        var kits = all
        guard let i = kits.firstIndex(where: { $0.ref == ref }) else { return }
        kits[i].isDefault = isDefault
        save(kits)
    }

    static var all: [KitRef] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let kits = try? JSONDecoder().decode([KitRef].self, from: data) else { return [] }
        return kits
    }

    private static func save(_ kits: [KitRef]) {
        if let data = try? JSONEncoder().encode(kits) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Add (or refresh) a kit by reference, parsing `spec.yaml` for a directory
    /// kit. Returns the resulting entry.
    @discardableResult
    static func add(_ ref: String) -> KitRef {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        var kit = KitRef(ref: trimmed)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir), isDir.boolValue {
            let meta = parseSpec(at: trimmed)
            kit.displayName = meta.displayName
            kit.summary = meta.summary
        }
        save(all.filter { $0.ref != trimmed } + [kit])
        return kit
    }

    static func remove(_ ref: String) {
        save(all.filter { $0.ref != ref })
    }

    /// Fill in display metadata for a registered kit (e.g. from Docker Hub or
    /// `sbx kit inspect` for an OCI reference, which `add` can't read locally).
    static func update(_ ref: String, displayName: String?, summary: String?) {
        var kits = all
        guard let i = kits.firstIndex(where: { $0.ref == ref }) else { return }
        if let displayName, !displayName.isEmpty { kits[i].displayName = displayName }
        if let summary, !summary.isEmpty { kits[i].summary = summary }
        save(kits)
    }

    /// Lightweight `spec.yaml` read (top-level `displayName:` / `description:`),
    /// mirroring the old sbx-ui parser — avoids a YAML dependency.
    private static func parseSpec(at dir: String) -> (displayName: String?, summary: String?) {
        let url = URL(fileURLWithPath: dir).appendingPathComponent("spec.yaml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }
        var displayName: String?
        var summary: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if displayName == nil { displayName = value(line, key: "displayName") }
            if summary == nil { summary = value(line, key: "description") }
        }
        return (displayName, summary)
    }

    private static func value(_ line: String, key: String) -> String? {
        guard line.hasPrefix("\(key):") else { return nil }
        var v = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        // Skip block scalars (">"/"|") — not worth parsing here.
        return (v.isEmpty || v == ">" || v == "|") ? nil : v
    }
}
