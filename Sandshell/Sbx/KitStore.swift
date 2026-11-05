import Foundation
import Synchronization

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
    private static let codeServerOffKey = "kitRegistryCodeServerNotDefault.v1"
    private static let v3Key = "kitRegistryV3.v1"
    static let codeServerRef = "docker.io/sbx/code-server:latest"

    /// sbx 0.51 made every built-in agent a v3 kit, and a sandbox can't mix v3
    /// kits with v1/v2 ones: the official v2 kits' v3 successors.
    static let renamedKits = [
        "docker.io/sbx/git-ssh-sign-kit:latest": "docker.io/sbx/git-ssh-sign:latest",
        "docker.io/sbx/github-ssh-kit:latest": "docker.io/sbx/github-ssh:latest",
        "docker.io/sbx/code-server-kit:latest": "docker.io/sbx/code-server:latest",
        "docker.io/sbx/claude-sbx-statusline-kit:latest": "docker.io/sbx/claude-sbx-statusline:latest",
    ]

    /// `ref`, or the v3 kit that replaced it.
    static func current(_ ref: String) -> String { renamedKits[ref] ?? ref }

    /// Once: the registry's official kits move to their v3 names, and
    /// Sandshell's own leave it (they're always on now: a chat can't run without
    /// one — the agents' images have no Node for the adapter).
    static func migrateToV3IfNeeded() {
        guard !UserDefaults.standard.bool(forKey: v3Key) else { return }
        var kits: [KitRef] = []
        for var kit in all where !isSandshellKit(kit.ref) {
            kit.ref = current(kit.ref)
            if !kits.contains(where: { $0.ref == kit.ref }) { kits.append(kit) }
        }
        save(kits)
        UserDefaults.standard.set(true, forKey: v3Key)
    }

    /// Sandshell's own kits (`kits/` in the repo, bundled in the app, published
    /// at github.com/xmas/sandshell-kits): each carries its agent's chat adapter
    /// with the Node it runs on, and Claude's the wrapper behind Undo and MCP
    /// status. Always on — chats need them. Referred to by name, resolved to
    /// the app's bundled copy when sbx is called (`resolve`), which sbx builds.
    static let sandshellKits: [KitRef] = [
        KitRef(ref: "sandshell-claude", displayName: "Sandshell chats for Claude",
               summary: "The Claude chat adapter, with Undo for a turn's file edits and MCP server status.",
               isDefault: true),
        KitRef(ref: "sandshell-codex", displayName: "Sandshell chats for Codex",
               summary: "The Codex chat adapter.",
               isDefault: true),
    ]

    /// Sandshell's kits a workspace turns on (Settings ▸ Kits, or the kit
    /// browser): bundled and published like the ones above, referred to by
    /// name the same way, but off until chosen.
    static let optionalSandshellKits: [KitRef] = [
        KitRef(ref: BergHub.kitName, displayName: "berg",
               summary: "berg (Iceberg's CLI) and bd, signed in to the hub this Mac's berg uses, through sbx's proxy; "
                   + "git commits made as you."),
    ]

    /// Every kit in the app's `kits/`, by name.
    static var bundledKitNames: [String] { (sandshellKits + optionalSandshellKits).map(\.ref) }

    /// The bundled kit `ref` is, however sbx spells it: its name, its bundled
    /// folder, or its published image.
    static func bundledKitName(_ ref: String) -> String? {
        let t = ref.hasSuffix("/") ? String(ref.dropLast()) : ref
        return bundledKitNames.first { name in
            t == name || t.hasSuffix("/kits/\(name)")
                || t.hasPrefix("\(publishedRepository)/\(name):") || t.hasPrefix("\(publishedRepository)/\(name)@")
        }
    }

    /// `--kit-arg`s the given kits take from this Mac (the berg kit's hub).
    static func kitArguments(for kits: [String], hub: BergHub? = BergHub.current()) -> [String] {
        guard kits.contains(where: { bundledKitName($0) == BergHub.kitName }), let hub else { return [] }
        return hub.kitArguments
    }

    /// Bumped when Sandshell's kits change what a sandbox must have built in
    /// (an adapter version, the entry points): sandboxes made with an older
    /// generation are rebuilt (`WorkspaceController.configSignature`).
    static let sandshellKitGeneration = 4

    static func isSandshellKit(_ ref: String) -> Bool {
        sandshellKits.contains { kit in
            ref == kit.ref || ref.hasSuffix("/kits/\(kit.ref)")
                || ref.hasPrefix("\(publishedRepository)/\(kit.ref):") || ref.hasPrefix("\(publishedRepository)/\(kit.ref)@")
        }
    }

    /// Where each release's own kits are published, built (the kits repo's
    /// workflow, `scripts/kits-repo/publish.yml`): `<repository>/<kit>:<version>`.
    static let publishedRepository = "ghcr.io/xmas"

    /// Whether this app's published kits answered (`checkPublishedKits`): until
    /// then, and offline, sbx builds the bundled copies instead.
    private static let publishedAvailable = Mutex(false)

    /// The published kit this app version uses for `name`, or nil where it
    /// builds its bundled copy: a Debug build (its kits may hold changes not
    /// published yet), or the published ones weren't reachable.
    static func publishedRef(_ name: String) -> String? {
        #if DEBUG
        return nil
        #else
        guard publishedAvailable.withLock({ $0 }), let version = appVersion else { return nil }
        return "\(publishedRepository)/\(name):\(version)"
        #endif
    }

    private static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Whether this version's kits are published, asked once (started at
    /// launch; a bring-up awaits it before handing sbx the kits).
    static let publishedKitsChecked = Task { await checkPublishedKits() }

    /// Ask whether this version's kits are published: then sandboxes take
    /// them as built images, not built from source on this Mac.
    private static func checkPublishedKits() async {
        #if !DEBUG
        guard let version = appVersion else { return }
        var reachable = true
        for kit in sandshellKits + optionalSandshellKits {
            let ref = "\(publishedRepository)/\(kit.ref):\(version)"
            let info = await SbxClient.shared.kitInspect(ref)
            if info?.schemaVersion != "3" { reachable = false; break }
        }
        Log.info(.workspace, reachable ? "Sandshell's kits: the published \(version) ones (\(publishedRepository))"
                                       : "Sandshell's kits: \(version) isn't published or reachable; building the bundled ones")
        publishedAvailable.withLock { $0 = reachable }
        #endif
    }

    /// What sbx is given for `ref`: Sandshell's own kits are this version's
    /// published ones, else the app's bundled copies.
    static func resolve(_ ref: String) -> String {
        guard bundledKitNames.contains(ref) else { return ref }
        if let published = publishedRef(ref) { return published }
        guard let dir = SbxCommand.bundledKits?.appending(path: ref) else { return ref }
        return dir.path(percentEncoded: false)
    }

    /// Official kits seeded into the registry once; removing or (un)defaulting
    /// them sticks. The two defaults are worth having in every sandbox: cheap,
    /// no ports, and they fix real gaps (unsigned in-sandbox commits, SSH
    /// host-key prompts). code-server is listed but off: its install takes
    /// minutes, which every new sandbox would wait on.
    static let officialKits: [KitRef] = [
        KitRef(ref: "docker.io/sbx/git-ssh-sign:latest", displayName: "Git SSH Commit Signing",
               summary: "Signs commits with the SSH key forwarded from your Mac's agent, so in-sandbox commits are Verified like host commits.",
               isDefault: true),
        KitRef(ref: "docker.io/sbx/github-ssh:latest", displayName: "GitHub SSH",
               summary: "Pre-populates GitHub's SSH host keys so clone/push/pull over SSH never stops on a host-verification prompt.",
               isDefault: true),
        KitRef(ref: codeServerRef, displayName: "code-server (web VS Code)",
               summary: "VS Code in the browser on port 8080, opened on the workspace, with the Claude Code extension preinstalled. "
                   + "Installing it adds a few minutes to making a sandbox.",
               isDefault: false),
    ]

    // MARK: Agent requirements

    /// v3: one entry per kit holds both what `sbx kit inspect` said it is
    /// and the agent it's for — `sandbox:droid` (it defines that agent),
    /// `mixin:claude` (made for Claude), `mixin:` (any agent). Earlier caches
    /// kept the agent alone (v1 even said "any agent" for agent kits, which
    /// sent them to other sandboxes as `--kit`; sbx refuses), so every kit is
    /// asked again.
    private static let requirementsKey = "kitRequirements.v3"
    private static let staleRequirementsKeys = ["kitRequiredAgents", "kitRequiredAgents.v2", "kitDefinesAgent"]
    /// Known up front, so the official kit works offline.
    private static let knownRequirements = [codeServerRef: "claude",
                                            "sandshell-claude": "claude", "sandshell-codex": "codex",
                                            BergHub.kitName: ""]

    /// What's cached for `ref`: its kind and the agent it's for ("" = any).
    private static func cached(_ ref: String) -> (kind: String, agent: String)? {
        _ = dropStaleRequirements
        let cache = UserDefaults.standard.dictionary(forKey: requirementsKey) as? [String: String] ?? [:]
        guard let entry = cache[ref], let colon = entry.firstIndex(of: ":") else { return nil }
        return (String(entry[..<colon]), String(entry[entry.index(after: colon)...]))
    }

    /// The agent a kit is made for (`requires.agent` in its spec, or the agent
    /// a `kind: sandbox` kit defines): `.some(nil)` for any agent, `nil` while
    /// not yet known.
    static func requiredAgent(_ ref: String) -> String?? {
        if let known = knownRequirements[ref] { return .some(known.isEmpty ? nil : known) }
        // An agent kit is its own agent's: sbx refuses it as another's --kit.
        if let profile = AgentProfileStore.all.first(where: { $0.kitRef == ref }) { return .some(profile.agent) }
        guard let entry = cached(ref) else { return nil }
        return .some(entry.agent.isEmpty ? nil : entry.agent)
    }

    private static let dropStaleRequirements: Void = {
        for key in staleRequirementsKeys { UserDefaults.standard.removeObject(forKey: key) }
    }()

    /// Remember what `sbx kit inspect` said a kit is and requires.
    static func learn(_ ref: String, from info: KitInspection) {
        _ = dropStaleRequirements
        var cache = UserDefaults.standard.dictionary(forKey: requirementsKey) as? [String: String] ?? [:]
        cache[ref] = requirementEntry(info)
        UserDefaults.standard.set(cache, forKey: requirementsKey)
        setLegacy([ref], info.isLegacy)
        var formats = UserDefaults.standard.dictionary(forKey: formatKey) as? [String: String] ?? [:]
        formats[ref] = "\(info.schemaVersion ?? "")|\(info.name ?? "")"
        UserDefaults.standard.set(formats, forKey: formatKey)
    }

    /// Kits `sbx kit inspect` said are v1/v2: no sandbox can take them now
    /// (every agent is a v3 kit, and sbx won't mix the two).
    private static let legacyKey = "kitLegacy.v1"
    static func isLegacy(_ ref: String) -> Bool {
        UserDefaults.standard.stringArray(forKey: legacyKey)?.contains(ref) ?? false
    }

    /// Mark kits as v1/v2 (or not): sbx refused them beside v3 kits.
    static func setLegacy(_ refs: [String], _ isLegacy: Bool = true) {
        var legacy = Set(UserDefaults.standard.stringArray(forKey: legacyKey) ?? [])
        for ref in refs { if isLegacy { legacy.insert(ref) } else { legacy.remove(ref) } }
        UserDefaults.standard.set(legacy.sorted(), forKey: legacyKey)
    }

    /// Per kit, `<schemaVersion>|<spec name>` as `sbx kit inspect` said. The
    /// format was learned only from 0.2.41 on: a kit whose agent was cached
    /// before then was never asked its format (and went to sbx beside v3 kits).
    private static let formatKey = "kitFormat.v1"

    /// Whether `sbx kit inspect` should be asked about `ref` before a sandbox
    /// is made with it: what it's for or its format isn't known yet — or it's
    /// an older-format kit on disk, which its author may have moved to v3 since.
    static func needsInspection(_ ref: String) -> Bool {
        if isSandshellKit(ref) { return false }
        if requiredAgent(ref) == nil { return true }
        if officialKits.contains(where: { $0.ref == ref }) { return false }
        let formats = UserDefaults.standard.dictionary(forKey: formatKey) as? [String: String] ?? [:]
        if formats[ref] == nil { return true }
        return isLegacy(ref) && isLocal(ref)
    }

    /// A kit in a folder on this Mac (not a registry or git reference).
    static func isLocal(_ ref: String) -> Bool {
        ref.hasPrefix("/") || ref.hasPrefix("~") || ref.hasPrefix(".")
    }

    /// The name sbx calls a kit by in its messages: its spec's `name` where
    /// inspected, else the last part of its reference without tag, digest or
    /// the `-kit` suffix (`docker.io/sbx/claude-sbx-statusline-kit:latest` →
    /// `claude-sbx-statusline`; a git ref's `dir=`).
    static func sbxName(_ ref: String) -> String {
        let formats = UserDefaults.standard.dictionary(forKey: formatKey) as? [String: String] ?? [:]
        if let entry = formats[ref], let bar = entry.firstIndex(of: "|"), entry.index(after: bar) < entry.endIndex {
            return String(entry[entry.index(after: bar)...])
        }
        return derivedName(ref)
    }

    static func derivedName(_ ref: String) -> String {
        if let hash = ref.firstIndex(of: "#") {
            let fragment = ref[ref.index(after: hash)...]
            if let dir = fragment.split(separator: "&").first(where: { $0.hasPrefix("dir=") }) {
                return String(dir.dropFirst(4).split(separator: "/").last ?? "")
            }
        }
        var base = ref.split(separator: "#").first.map(String.init) ?? ref
        while base.hasSuffix("/") { base.removeLast() }
        var last = String(base.split(separator: "/").last ?? Substring(base))
        if let at = last.firstIndex(of: "@") { last = String(last[..<at]) }
        if let colon = last.firstIndex(of: ":") { last = String(last[..<colon]) }
        if last.hasSuffix(".git") { last.removeLast(4) }
        if last.hasSuffix("-kit") && last.count > 4 { last.removeLast(4) }
        return last
    }

    /// What a kit is called to a person: its registry display name, else its sbx name.
    static func displayName(_ ref: String) -> String {
        all.first(where: { $0.ref == ref })?.displayName ?? sbxName(ref)
    }

    /// The kits among `refs` a sandbox for `agent` would take but for their
    /// format: v1/v2 kits sbx refuses beside the agent's own v3 kit.
    static func legacyKits(_ refs: [String], for agent: AgentKind) -> [String] {
        guard takesV3Kits(agent) else { return [] }
        return refs.filter { ref in
            guard isLegacy(ref), ref != agent.createReference, !definesAgent(ref) else { return false }
            guard let required = requiredAgent(ref), let agentName = required else { return true }
            return agentName == agent.rawValue
        }
    }

    /// The cache entry for an inspected kit: `sandbox:<agent>` or `mixin:<agent or "">`.
    static func requirementEntry(_ info: KitInspection) -> String {
        info.kind == "sandbox" ? "sandbox:\(info.name ?? "")" : "mixin:\(info.requires?.agent ?? "")"
    }

    /// A `kind: sandbox` kit: it defines an agent, so it's only ever the create
    /// positional (`createReference`), never anyone's `--kit` — not even its own agent's.
    static func definesAgent(_ ref: String) -> Bool {
        AgentProfileStore.all.contains { $0.kitRef == ref } || cached(ref)?.kind == "sandbox"
    }

    /// Which of `refs` a sandbox for `agent` can take as `--kit`: a kit made for
    /// another agent is left out (sbx refuses to compose it), and so is any
    /// agent kit, its own included. Unknown ones stay in.
    static func kits(_ refs: [String], for agent: AgentKind) -> [String] {
        guard takesV3Kits(agent) else { return [] }
        return refs.filter { ref in
            guard ref != agent.createReference, !definesAgent(ref), !isLegacy(ref) else { return false }
            guard let required = requiredAgent(ref), let agentName = required else { return true }
            return agentName == agent.rawValue
        }
    }

    /// Whether a sandbox for `agent` can take kits at all: every kit is v3 now,
    /// and sbx composes v3 kits only onto a v3 agent. Gemini is still sbx's
    /// embedded (pre-kit) agent, and so is a custom agent from a v1/v2 kit.
    static func takesV3Kits(_ agent: AgentKind) -> Bool {
        if agent == .gemini { return false }
        if let ref = AgentProfileStore.profile(for: agent)?.kitRef { return !isLegacy(ref) }
        return true
    }

    /// Kits flagged as defaults for new workspaces, in registry order.
    static var defaults: [KitRef] { all.filter(\.isDefault) }
    static var defaultRefs: [String] { defaults.map(\.ref) }

    static func seedOfficialDefaultsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        var kits = all
        for kit in officialKits where !kits.contains(where: { $0.ref == kit.ref }) {
            kits.append(kit)
        }
        save(kits)
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    /// Once: code-server was seeded as a default until 0.2.38, and its
    /// minutes-long install held up every new sandbox. Turned off where it's
    /// still on (a workspace that has it keeps it); starring it again sticks.
    static func undefaultCodeServerIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: codeServerOffKey) else { return }
        setDefault(codeServerRef, false)
        UserDefaults.standard.set(true, forKey: codeServerOffKey)
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

    /// The registry's entry for `old` now refers to `new` (its v3 version),
    /// keeping its name, summary and default.
    static func replace(_ old: String, with new: String) {
        var kits: [KitRef] = []
        for var kit in all {
            if kit.ref == old { kit.ref = new }
            if !kits.contains(where: { $0.ref == kit.ref }) { kits.append(kit) }
        }
        save(kits)
    }

    /// Where Docker publishes the v3 version of one of its v1/v2 kits: under
    /// the kit's own name (`docker.io/sbx/claude-sbx-statusline-kit:latest` →
    /// `docker.io/sbx/claude-sbx-statusline:latest`), as sbx's refusal says.
    /// Nil for anyone else's kit.
    static func v3Candidate(_ ref: String) -> String? {
        guard ref.hasPrefix("docker.io/sbx/") || ref.hasPrefix("sbx/") else { return nil }
        let candidate = "docker.io/sbx/\(sbxName(ref)):latest"
        return candidate == ref ? nil : candidate
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
    static func parseSpec(at dir: String) -> (displayName: String?, summary: String?) {
        let url = URL(filePath: dir).appending(path: "spec.yaml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }
        var displayName: String?
        var summary: String?
        // Any line ending: "\r\n" is one Character, never equal to "\n".
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
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
