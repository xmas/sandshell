import Foundation

/// A folder: a subfolder of the workspace root (possibly nested, so it carries a
/// relative path, not just a name). The empty string `""` denotes the **root
/// folder** itself. Sidebar order is stored here, not derived from the
/// filesystem. (Formerly "Project"; renamed in the folders model.)
struct Folder: Identifiable, Codable, Hashable {
    var id: UUID
    /// Path relative to the workspace root (may contain `/`). `""` = the root.
    var relativePath: String
    var order: Int

    /// Whether this is the workspace root folder (always present, not removable).
    var isRoot: Bool { relativePath.isEmpty }

    init(id: UUID = UUID(), relativePath: String, order: Int) {
        self.id = id
        self.relativePath = relativePath
        self.order = order
    }

    enum CodingKeys: String, CodingKey {
        case id, relativePath, order
        case folderName   // legacy key (pre-folders model)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        // Migrate: old states stored a single-segment `folderName`.
        relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath)
            ?? c.decodeIfPresent(String.self, forKey: .folderName)
            ?? ""
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(relativePath, forKey: .relativePath)
        try c.encode(order, forKey: .order)
    }
}

/// A session: an agent terminal run via `sbx exec -w <folder> <agent>`.
struct Session: Identifiable, Codable, Hashable {
    var id: UUID
    /// The folder this session belongs to. (Formerly `projectID`.)
    var folderID: UUID
    var agent: AgentKind
    var name: String
    var order: Int
    /// Container-side working directory (the mount path inside the container).
    var workdir: String
    /// The agent conversation id this session last ran as (claude session UUID),
    /// so re-activating it can resume the prior history. Optional → older
    /// `state.json` without the key still decodes.
    var transcriptID: String?
    /// When set, this session attaches to another agent's container instead of
    /// its own — e.g. a `.shell` session opened *inside* the claude/codex
    /// sandbox. `nil` (the common case) means "use my own agent's container".
    var containerAgent: AgentKind?
    /// When this session was created — the fallback half of the sidebar's
    /// chronological sort key (`max(last activity, createdAt)`), used
    /// until the session has any real activity. Decoded leniently (falls back
    /// to `.distantPast`) because older `state.json` files predate this field;
    /// `WorkspaceBootstrap.openOrCreate`'s schemaVersion-2 migration then stamps
    /// every pre-existing session with a synthetic value that preserves its old
    /// visual order, so upgrading never causes a visible jump.
    var createdAt: Date
    /// When the agent last finished a turn here (its transcript's last write),
    /// so the sidebar's order and "Xm ago" survive a relaunch. Nil until then.
    var lastActiveAt: Date?
    /// Shown as a native chat (ACP) instead of a terminal. Both drive the same
    /// agent conversation (`transcriptID`), so switching keeps the history.
    var isChat: Bool
    /// Named by the person (Rename): automatic naming leaves it alone.
    var isNamedByUser = false
    /// The cwd its agent files the conversation under, when that isn't
    /// `workdir`: its folder moved while it ran, and a running agent keeps the
    /// cwd it started in (Claude: `~/.claude/projects/<encoded cwd>`). Its next
    /// launch takes the conversation to `workdir` and clears this.
    var transcriptWorkdir: String?

    /// The agent whose container this session runs in: the override when present,
    /// otherwise the session's own agent.
    var containerAgentKind: AgentKind { containerAgent ?? agent }

    /// Where to look for its conversation (see `transcriptWorkdir`).
    var conversationWorkdir: String { transcriptWorkdir ?? workdir }

    /// Renamed by the person: their name sticks (prompts no longer rename it);
    /// empty puts automatic naming back. Nil when that changes nothing.
    func renamed(to name: String) -> Session? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var renamed = self
        renamed.name = trimmed.isEmpty ? self.name : trimmed
        renamed.isNamedByUser = !trimmed.isEmpty
        return renamed == self ? nil : renamed
    }

    init(id: UUID = UUID(),
         folderID: UUID,
         agent: AgentKind,
         name: String,
         order: Int,
         workdir: String,
         transcriptID: String? = nil,
         createdAt: Date = Date(),
         containerAgent: AgentKind? = nil,
         isChat: Bool = false) {
        self.id = id
        self.folderID = folderID
        self.agent = agent
        self.name = name
        self.order = order
        self.workdir = workdir
        self.transcriptID = transcriptID
        self.createdAt = createdAt
        self.containerAgent = containerAgent
        self.isChat = isChat
    }

    enum CodingKeys: String, CodingKey {
        case id, folderID, agent, name, order, workdir, transcriptID, createdAt, lastActiveAt, containerAgent
        case transcriptWorkdir
        case isChat = "chat"
        case isNamedByUser = "namedByUser"
        case projectID   // legacy key (pre-folders model)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
            ?? c.decodeIfPresent(UUID.self, forKey: .projectID)
            ?? UUID()
        agent = try c.decode(AgentKind.self, forKey: .agent)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        workdir = try c.decodeIfPresent(String.self, forKey: .workdir) ?? ""
        transcriptID = try c.decodeIfPresent(String.self, forKey: .transcriptID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        lastActiveAt = try c.decodeIfPresent(Date.self, forKey: .lastActiveAt)
        containerAgent = try c.decodeIfPresent(AgentKind.self, forKey: .containerAgent)
        isChat = try c.decodeIfPresent(Bool.self, forKey: .isChat) ?? false
        isNamedByUser = try c.decodeIfPresent(Bool.self, forKey: .isNamedByUser) ?? false
        transcriptWorkdir = try c.decodeIfPresent(String.self, forKey: .transcriptWorkdir)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(folderID, forKey: .folderID)
        try c.encode(agent, forKey: .agent)
        try c.encode(name, forKey: .name)
        try c.encode(order, forKey: .order)
        try c.encode(workdir, forKey: .workdir)
        try c.encodeIfPresent(transcriptID, forKey: .transcriptID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastActiveAt, forKey: .lastActiveAt)
        try c.encodeIfPresent(containerAgent, forKey: .containerAgent)
        if isChat { try c.encode(true, forKey: .isChat) }
        if isNamedByUser { try c.encode(true, forKey: .isNamedByUser) }
        try c.encodeIfPresent(transcriptWorkdir, forKey: .transcriptWorkdir)
    }

    /// A workdir once the directory at `from` has moved to `to`: nil unless
    /// it is that directory or inside it.
    static func workdir(_ workdir: String, movedFrom from: String, to: String) -> String? {
        if workdir == from { return to }
        guard workdir.hasPrefix(from + "/") else { return nil }
        return to + workdir.dropFirst(from.count)
    }
}

/// Volatile, workspace-scoped state persisted at `<root>/.sandshell/state.json`.
/// Holds the sidebar folders/sessions, their order, expansion, and per-session
/// archive watermarks. Git-ignored (see `.sandshell/.gitignore`).
struct WorkspaceState: Codable {
    var schemaVersion: Int
    var folders: [Folder]
    var sessions: [Session]
    /// IDs of folders whose sidebar disclosure is expanded.
    var expandedFolderIDs: [UUID]
    /// Archive collector cursor per session, keyed by `session.id.uuidString`.
    var archiveWatermarks: [String: Date]
    /// The mount signature last applied to each container, keyed by container
    /// name. A mismatch with the freshly-resolved signature drives a rebuild.
    var appliedMountSignatures: [String: String]
    /// Kits found in a container but not in the workspace config that the user
    /// chose to leave for the next rebuild to drop, keyed by container name.
    /// Cleared when that container is (re)created.
    var ignoredKitDrift: [String: [String]]
    /// The agent whose sandbox has the bare workspace slug as its name, once
    /// the primary agent changed (sandboxes keep their names). Nil: the
    /// primary agent's.
    var slugAgent: AgentKind?

    /// The primary agent is changing from `primary`: the bare slug stays its —
    /// its sandbox may exist, or be being made. Only the first change pins it.
    /// Whether anything changed.
    mutating func pinSlugAgent(_ primary: AgentKind) -> Bool {
        guard slugAgent == nil else { return false }
        slugAgent = primary
        return true
    }

    init(schemaVersion: Int = 2,
         folders: [Folder] = [],
         sessions: [Session] = [],
         expandedFolderIDs: [UUID] = [],
         archiveWatermarks: [String: Date] = [:],
         appliedMountSignatures: [String: String] = [:],
         ignoredKitDrift: [String: [String]] = [:],
         slugAgent: AgentKind? = nil) {
        self.schemaVersion = schemaVersion
        self.folders = folders
        self.sessions = sessions
        self.expandedFolderIDs = expandedFolderIDs
        self.archiveWatermarks = archiveWatermarks
        self.appliedMountSignatures = appliedMountSignatures
        self.ignoredKitDrift = ignoredKitDrift
        self.slugAgent = slugAgent
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, folders, sessions, expandedFolderIDs
        case archiveWatermarks, appliedMountSignatures, ignoredKitDrift, slugAgent
        // Legacy keys (pre-folders model).
        case projects, expandedProjectIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        folders = try c.decodeIfPresent([Folder].self, forKey: .folders)
            ?? c.decodeIfPresent([Folder].self, forKey: .projects) ?? []
        sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        expandedFolderIDs = try c.decodeIfPresent([UUID].self, forKey: .expandedFolderIDs)
            ?? c.decodeIfPresent([UUID].self, forKey: .expandedProjectIDs) ?? []
        archiveWatermarks = try c.decodeIfPresent([String: Date].self, forKey: .archiveWatermarks) ?? [:]
        appliedMountSignatures = try c.decodeIfPresent([String: String].self, forKey: .appliedMountSignatures) ?? [:]
        ignoredKitDrift = try c.decodeIfPresent([String: [String]].self, forKey: .ignoredKitDrift) ?? [:]
        slugAgent = try c.decodeIfPresent(AgentKind.self, forKey: .slugAgent)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(folders, forKey: .folders)
        try c.encode(sessions, forKey: .sessions)
        try c.encode(expandedFolderIDs, forKey: .expandedFolderIDs)
        try c.encode(archiveWatermarks, forKey: .archiveWatermarks)
        try c.encode(appliedMountSignatures, forKey: .appliedMountSignatures)
        if !ignoredKitDrift.isEmpty { try c.encode(ignoredKitDrift, forKey: .ignoredKitDrift) }
        try c.encodeIfPresent(slugAgent, forKey: .slugAgent)
    }

    // MARK: - Folder moves

    /// The folder rows inside a folder's directory (registered on their own,
    /// e.g. `proj/web` inside `proj`).
    func folders(nestedIn id: UUID) -> [Folder] {
        guard let folder = folders.first(where: { $0.id == id }), !folder.isRoot else { return [] }
        return folders.filter { $0.relativePath.hasPrefix(folder.relativePath + "/") }
    }

    /// Point a folder row at `newRelative` after its directory moved there:
    /// the rows nested in it follow, and every session working in it (or below)
    /// gets the moved path. The `running` ones' agents keep filing their
    /// conversations under the old cwd (`Session.transcriptWorkdir`).
    mutating func moveFolder(_ id: UUID, to newRelative: String, root: URL, running: Set<UUID> = []) {
        guard let folder = folders.first(where: { $0.id == id }), !folder.isRoot else { return }
        let old = folder.relativePath
        let moving = Set(folders(nestedIn: id).map(\.id) + [id])
        for i in folders.indices where moving.contains(folders[i].id) {
            folders[i].relativePath = newRelative + folders[i].relativePath.dropFirst(old.count)
        }
        let from = root.appendingPathComponent(old, isDirectory: true).path
        let to = root.appendingPathComponent(newRelative, isDirectory: true).path
        for i in sessions.indices {
            guard let moved = Session.workdir(sessions[i].workdir, movedFrom: from, to: to) else { continue }
            if running.contains(sessions[i].id), sessions[i].transcriptWorkdir == nil {
                sessions[i].transcriptWorkdir = sessions[i].workdir
            }
            sessions[i].workdir = moved
            if sessions[i].transcriptWorkdir == moved { sessions[i].transcriptWorkdir = nil }   // moved back
        }
    }

    // MARK: - Persistence

    /// Control directory holding Sandshell's per-workspace files.
    static func controlDir(root: URL) -> URL {
        root.appendingPathComponent(".sandshell", isDirectory: true)
    }

    static func stateURL(root: URL) -> URL {
        controlDir(root: root).appendingPathComponent("state.json")
    }

    /// Load persisted state, or `nil` if no state file exists yet.
    static func load(root: URL) throws -> WorkspaceState? {
        let url = stateURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkspaceState.self, from: data)
    }

    /// Atomically write state to `<root>/.sandshell/state.json`.
    func save(root: URL) throws {
        try FileManager.default.createDirectory(
            at: Self.controlDir(root: root), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.stateURL(root: root), options: .atomic)
    }
}

/// Opens or bootstraps a workspace root: ensures the root, the `.sandshell/`
/// control dir (+ its `.gitignore`), the root folder row, and each non-root
/// folder's directory. Pure filesystem + state seeding — no container behavior.
enum WorkspaceBootstrap {
    /// Default workspace root: `~/Sandshell`.
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Sandshell", isDirectory: true)
    }

    /// Files under `.sandshell/` that are volatile and must not be committed.
    private static let gitignoredControlFiles = ["state.json", "status/", "statusline.sh"]

    /// Ensure the workspace exists on disk and return its (seeded) state.
    @discardableResult
    static func openOrCreate(root: URL = defaultRoot) throws -> WorkspaceState {
        let fm = FileManager.default

        // 1. Root + control dir.
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let control = WorkspaceState.controlDir(root: root)
        try fm.createDirectory(at: control, withIntermediateDirectories: true)

        // 2. `.sandshell/.gitignore` — keep volatile state out of git.
        let gitignore = control.appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: gitignore, encoding: .utf8)) ?? ""
        let present = Set(existing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = gitignoredControlFiles.filter { !present.contains($0) }
        if !missing.isEmpty {
            var body = existing
            if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
            body += missing.joined(separator: "\n") + "\n"
            try body.write(to: gitignore, atomically: true, encoding: .utf8)
        }

        // 3. Load existing state or start fresh (legacy projects migrate here).
        var state = (try? WorkspaceState.load(root: root)) ?? WorkspaceState()

        // 4. Always ensure the root folder exists as the first row. Migrated
        //    workspaces keep their existing (former project) folders below it.
        if !state.folders.contains(where: { $0.isRoot }) {
            let minOrder = state.folders.map(\.order).min() ?? 0
            let rootFolder = Folder(relativePath: "", order: minOrder - 1)
            state.folders.insert(rootFolder, at: 0)
            state.expandedFolderIDs.append(rootFolder.id)
        }

        // 5. Ensure each non-root folder's directory exists on disk.
        for folder in state.folders where !folder.isRoot {
            let dir = root.appendingPathComponent(folder.relativePath, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 5b. Migrate to schemaVersion 2: the sidebar dropped its Folder→Session
        // tree for one chronological list (sorted by createdAt/last activity),
        // so every pre-existing session needs a `createdAt`. Stamp synthetic,
        // strictly-decreasing timestamps in today's exact visual order (folder
        // order, then session order within each folder) so the new list renders
        // identically to the old tree the instant after upgrading — real
        // activity takes over from there.
        if state.schemaVersion < 2 {
            let orderedFolders = state.folders.sorted { $0.order < $1.order }
            let oldOrder = orderedFolders.flatMap { folder in
                state.sessions.filter { $0.folderID == folder.id }.sorted { $0.order < $1.order }
            }
            let base = Date()
            for (index, session) in oldOrder.enumerated() {
                guard let idx = state.sessions.firstIndex(where: { $0.id == session.id }) else { continue }
                state.sessions[idx].createdAt = base.addingTimeInterval(-Double(index))
            }
            state.schemaVersion = 2
        }

        // 6. Persist (creates state.json on first run; idempotent thereafter).
        try state.save(root: root)
        return state
    }
}

/// App-global list of recently opened workspace roots, stored in `UserDefaults`.
enum RecentRoots {
    private static let key = "recentWorkspaceRoots"
    private static let maxCount = 10

    /// Most-recent-first list of roots that still exist on disk.
    static var all: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Record `root` as the most recently opened workspace.
    static func record(_ root: URL) {
        let path = root.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > maxCount { paths = Array(paths.prefix(maxCount)) }
        UserDefaults.standard.set(paths, forKey: key)
    }
}

/// App-global list of currently-open workspace roots, stored in `UserDefaults`,
/// with multiplicity (a root open in N windows appears N times). Restored on
/// launch so every open window re-opens.
enum OpenWindows {
    private static let key = "openWindowRoots"

    /// The roots to restore on launch, in order, including duplicates. Filtered
    /// to those that still exist on disk.
    static var all: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Replace the persisted set with the given roots (call whenever windows change).
    static func replace(with roots: [URL]) {
        let paths = roots.map { $0.standardizedFileURL.path }
        UserDefaults.standard.set(paths, forKey: key)
    }
}
