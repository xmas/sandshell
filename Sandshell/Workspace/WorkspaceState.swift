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
    /// The session this one was forked from (`WorkspaceController.forkChat`),
    /// kept even once that one is closed (it then lists as a session of its own).
    var forkedFrom: UUID?
    /// When it was forked: orders a parent's forks oldest-first.
    var forkedAt: Date?
    /// The first thing asked here (a fork's: the first after the fork), set
    /// once: what it's called until the agent titles it.
    var firstPrompt: String?
    /// The agent's own title for the conversation (Claude's `ai-title`), set
    /// once, after its first turn.
    var generatedName: String?

    /// The agent whose container this session runs in: the override when present,
    /// otherwise the session's own agent.
    var containerAgentKind: AgentKind { containerAgent ?? agent }

    /// Where to look for its conversation (see `transcriptWorkdir`).
    var conversationWorkdir: String { transcriptWorkdir ?? workdir }

    var isFork: Bool { forkedFrom != nil }

    /// What it's called: the person's name, else the agent's title for it,
    /// else its first prompt, else "Fork of <its source>" / "New session".
    /// Without its source at hand (see `displayName(parent:)`) a fork reads as
    /// it was named when it was made. `name` is only the person's name (and
    /// that fallback): automatic naming never shows it.
    var displayName: String { displayName(parent: { _ in nil }) }

    /// `displayName`, looking a fork's source up with `parent` (nil: it's gone).
    func displayName(parent: (UUID) -> Session?) -> String {
        Self.resolveName(self, parent: parent, depth: 0)
    }

    private static func resolveName(_ s: Session, parent: (UUID) -> Session?, depth: Int) -> String {
        if s.isNamedByUser, !s.name.isEmpty { return s.name }
        if let name = s.generatedName, !name.isEmpty { return name }
        if let prompt = s.firstPrompt, !prompt.isEmpty { return prompt }
        if let source = s.forkedFrom {
            // (Fork chains are short: the cap only guards a corrupt loop.)
            if depth < 16, let p = parent(source), p.id != s.id {
                return "Fork of \(resolveName(p, parent: parent, depth: depth + 1))"
            }
            return s.name.isEmpty ? "Fork" : s.name
        }
        // A shell is never asked anything: it keeps reading as what it is.
        return s.agent == .shell ? defaultName(for: s.agent, containerAgent: s.containerAgent) : "New session"
    }

    /// Default name for a fresh session, e.g. "New Claude Session". A shell
    /// attached to another agent's sandbox reads "Shell in Claude", etc.
    static func defaultName(for agent: AgentKind, containerAgent: AgentKind? = nil) -> String {
        if let containerAgent, containerAgent != agent {
            return "\(agent.displayName) in \(containerAgent.displayName)"
        }
        return "New \(agent.displayName) Session"
    }

    /// The default names before agents had brand spellings (the raw id,
    /// capitalized: "New Docker-Agent Session", "New Opencode Session").
    static func legacyDefaultName(for agent: AgentKind, containerAgent: AgentKind? = nil) -> String {
        if let containerAgent, containerAgent != agent {
            return "\(agent.rawValue.capitalized) in \(containerAgent.rawValue.capitalized)"
        }
        return "New \(agent.rawValue.capitalized) Session"
    }

    /// Whether `name` is one a session has before anything's asked in it.
    var hasDefaultName: Bool {
        name == Self.defaultName(for: agent, containerAgent: containerAgent)
            || name == Self.legacyDefaultName(for: agent, containerAgent: containerAgent)
            || (name.hasPrefix("New ") && name.hasSuffix(" Session"))
    }

    /// Something was asked here: the first time, that's its first prompt,
    /// which then never changes. Whether it changed anything.
    mutating func recordPrompt(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard firstPrompt == nil, !trimmed.isEmpty else { return false }
        firstPrompt = trimmed
        return true
    }

    /// The agent titled the conversation: the first title sticks. Whether it
    /// changed anything.
    mutating func adoptGeneratedName(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard generatedName == nil, !trimmed.isEmpty else { return false }
        generatedName = trimmed
        return true
    }

    /// A chat forked from `source` at `date`: its folder and agent, nothing
    /// asked in it yet (it's named by its own first prompt, not the source's).
    /// `name` is what it reads as once `source` is gone.
    static func fork(of source: Session, name: String, order: Int, workdir: String, at date: Date) -> Session {
        var fork = Session(folderID: source.folderID, agent: source.agent, name: name, order: order,
                           workdir: workdir, createdAt: date, isChat: true)
        fork.forkedFrom = source.id
        fork.forkedAt = date
        return fork
    }

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
         createdAt: Date = .now,
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
        case transcriptWorkdir, forkedFrom, forkedAt, firstPrompt, generatedName
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
        forkedFrom = try c.decodeIfPresent(UUID.self, forKey: .forkedFrom)
        forkedAt = try c.decodeIfPresent(Date.self, forKey: .forkedAt)
        firstPrompt = try c.decodeIfPresent(String.self, forKey: .firstPrompt)
        generatedName = try c.decodeIfPresent(String.self, forKey: .generatedName)
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
        try c.encodeIfPresent(forkedFrom, forKey: .forkedFrom)
        try c.encodeIfPresent(forkedAt, forKey: .forkedAt)
        try c.encodeIfPresent(firstPrompt, forKey: .firstPrompt)
        try c.encodeIfPresent(generatedName, forKey: .generatedName)
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

    /// The schema new states are made with (older ones migrate in
    /// `WorkspaceBootstrap.openReportingProblems`).
    static let currentSchemaVersion = 3

    init(schemaVersion: Int = WorkspaceState.currentSchemaVersion,
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

    /// Schema 3 names a session by its first prompt (`Session.firstPrompt`)
    /// where `name` used to follow its latest one: a session named that way
    /// keeps the name it shows, as its first prompt. Default names, the
    /// person's names and forks (named apart) are left as they are.
    mutating func migrateLegacyNames() {
        for i in sessions.indices {
            let s = sessions[i]
            let name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isNamedByUser, s.firstPrompt == nil, !s.isFork,
                  !name.isEmpty, !s.hasDefaultName else { continue }
            sessions[i].firstPrompt = name
        }
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
        let from = root.appending(path: old, directoryHint: .isDirectory).path
        let to = root.appending(path: newRelative, directoryHint: .isDirectory).path
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
        root.appending(path: ".sandshell", directoryHint: .isDirectory)
    }

    static func stateURL(root: URL) -> URL {
        controlDir(root: root).appending(path: "state.json")
    }

    /// Load persisted state, or `nil` if no state file exists yet.
    static func load(root: URL) throws -> WorkspaceState? {
        let url = stateURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkspaceState.self, from: data)
    }

    /// Copy a control file that couldn't be read (a merge conflict, a typo, a
    /// newer build's format) aside as `<name>.unreadable-<time>.<ext>`, before
    /// anything saves a fresh one over it. The copy, or nil when that failed too.
    static func keepUnreadableCopy(of url: URL) -> URL? {
        let name = url.deletingPathExtension().lastPathComponent
        let copy = url.deletingLastPathComponent()
            .appending(path: "\(name).unreadable-\(Int(Date.now.timeIntervalSince1970)).\(url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            Log.error(.workspace, "couldn't keep a copy of \(url.path(percentEncoded: false)): \(error.localizedDescription)")
            return nil
        }
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

/// A control file (`state.json`, `config.json`) that was there when its folder
/// opened but couldn't be read: it was copied aside and the folder runs on a
/// fresh one, which the first window on the folder says
/// (`WorkspaceStore.takeOpenProblems`).
struct UnreadableWorkspaceFile: Equatable, Sendable {
    enum Kind: Sendable { case state, config }
    let kind: Kind
    let file: URL
    /// The copy kept of it; nil when that failed too.
    let keptAs: URL?
    let reason: String

    /// Keep a copy of `file` (`WorkspaceState.keepUnreadableCopy`) before
    /// anything saves a fresh one over it, and log why it couldn't be read.
    static func setAside(_ kind: Kind, file: URL, _ error: any Error) -> Self {
        let copy = WorkspaceState.keepUnreadableCopy(of: file)
        let fallback = kind == .state ? "starting a fresh one" : "using defaults"
        Log.error(.workspace, "\(file.path(percentEncoded: false)) couldn't be read (\(error.localizedDescription)); "
                  + fallback + (copy.map { ", the original is kept as \($0.lastPathComponent)" } ?? ""))
        return Self(kind: kind, file: file, keptAs: copy, reason: error.localizedDescription)
    }

    /// The warning a window opening on the folder shows for `problems` (both
    /// files in one alert, the first problem of each), or nil for none.
    static func warning(for problems: [Self]) -> (title: String, message: String)? {
        let shown = [Kind.config, .state].compactMap { kind in problems.first { $0.kind == kind } }
        guard !shown.isEmpty else { return nil }
        let what = shown.map { $0.kind == .config ? "settings" : "session list" }.joined(separator: " and ")
        return ("This workspace’s \(what) couldn’t be read", shown.map(\.explanation).joined(separator: "\n\n"))
    }

    /// The file and why, then what Sandshell runs on instead and where the original went.
    private var explanation: String {
        let instead = switch (kind, keptAs) {
        case (.config, let copy?):
            "Sandshell is using default settings. The original is kept as \(copy.lastPathComponent)."
        case (.config, nil):
            "Sandshell is using default settings and couldn’t keep a copy of the original: "
                + "fix or move it before changing settings."
        case (.state, let copy?):
            "Sandshell started a new session list, so the sidebar’s folders and sessions are missing. "
                + "The original is kept as \(copy.lastPathComponent)."
        case (.state, nil):
            "Sandshell started a new session list (the sidebar’s folders and sessions are missing) "
                + "and couldn’t keep a copy of the original."
        }
        return "\(file.path(percentEncoded: false).tildeAbbreviated): \(reason)\n\n\(instead)"
    }
}

/// Opens or bootstraps a workspace root: ensures the root, the `.sandshell/`
/// control dir (+ its `.gitignore`), the root folder row, and each non-root
/// folder's directory. Pure filesystem + state seeding — no container behavior.
enum WorkspaceBootstrap {
    /// Default workspace root: `~/Sandshell`.
    static var defaultRoot: URL {
        URL.homeDirectory.appending(path: "Sandshell", directoryHint: .isDirectory)
    }

    /// Files under `.sandshell/` that are volatile and must not be committed
    /// (an unreadable state.json's copies are as per-user as it is).
    private static let gitignoredControlFiles = ["state.json", "status/", "statusline.sh", "state.unreadable-*.json"]

    /// Ensure the workspace exists on disk and return its (seeded) state.
    @discardableResult
    static func openOrCreate(root: URL = defaultRoot) throws -> WorkspaceState {
        try openReportingProblems(root: root).state
    }

    /// `openOrCreate`, also saying when state.json was there but couldn't be
    /// read (it was copied aside and a fresh one started).
    static func openReportingProblems(root: URL = defaultRoot) throws
        -> (state: WorkspaceState, unreadable: UnreadableWorkspaceFile?) {
        let fm = FileManager.default

        // 1. Root + control dir.
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let control = WorkspaceState.controlDir(root: root)
        try fm.createDirectory(at: control, withIntermediateDirectories: true)

        // 2. `.sandshell/.gitignore` — keep volatile state out of git.
        let gitignore = control.appending(path: ".gitignore")
        let existing = (try? String(contentsOf: gitignore, encoding: .utf8)) ?? ""
        // Lines end in "\n" or "\r\n", as git reads them ("\r\n" is one
        // Character, never equal to "\n").
        let isLineEnd: (Character) -> Bool = { $0 == "\n" || $0 == "\r\n" }
        let present = Set(existing.split(whereSeparator: isLineEnd).map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = gitignoredControlFiles.filter { !present.contains($0) }
        if !missing.isEmpty {
            var body = existing
            if let last = body.last, !isLineEnd(last) { body += "\n" }
            body += missing.joined(separator: "\n") + "\n"
            try body.write(to: gitignore, atomically: true, encoding: .utf8)
        }

        // 3. Load existing state or start fresh (legacy projects migrate here).
        //    One that can't be read is kept beside it: step 6 saves over it.
        var state: WorkspaceState
        var unreadable: UnreadableWorkspaceFile?
        do {
            state = try WorkspaceState.load(root: root) ?? WorkspaceState()
        } catch {
            unreadable = .setAside(.state, file: WorkspaceState.stateURL(root: root), error)
            state = WorkspaceState()
        }

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
            let dir = root.appending(path: folder.relativePath, directoryHint: .isDirectory)
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
            let base = Date.now
            for (index, session) in oldOrder.enumerated() {
                guard let idx = state.sessions.firstIndex(where: { $0.id == session.id }) else { continue }
                state.sessions[idx].createdAt = base.addingTimeInterval(-Double(index))
            }
            state.schemaVersion = 2
        }

        // 5c. Migrate to schemaVersion 3: sessions are named by their first
        // prompt, not their latest (`WorkspaceState.migrateLegacyNames`).
        if state.schemaVersion < 3 {
            state.migrateLegacyNames()
            state.schemaVersion = 3
        }

        // 6. Persist (creates state.json on first run; idempotent thereafter).
        try state.save(root: root)
        return (state, unreadable)
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
            .map { URL(filePath: $0, directoryHint: .checkFileSystem) }
    }

    /// Record `root` as the most recently opened workspace.
    static func record(_ root: URL) {
        let path = root.standardizedPath
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > maxCount { paths = Array(paths.prefix(maxCount)) }
        UserDefaults.standard.set(paths, forKey: key)
    }
}

/// App-global list of currently-open workspace roots, stored in `UserDefaults`,
/// with multiplicity (a root open in N windows appears N times), and each
/// window's instance index. Restored on launch so every open window re-opens
/// as itself: its frame, split, Files visibility and pane layout are saved
/// under its index.
enum OpenWindows {
    private static let key = "openWindowRoots"
    /// The windows' instance indexes, beside the roots they were saved with
    /// (`["roots": […], "indexes": […]]`). They're used only while those roots
    /// are `key`'s, so roots set another way (the self-tests'
    /// `-openWindowRoots` argument) never take another list's indexes.
    private static let indexesKey = "openWindowIndexes"
    /// A defaults suite to keep the list in instead of the app's own (a test
    /// binds its own).
    @TaskLocal static var suiteName: String? = nil
    private static var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    /// A window to reopen: its folder and the instance index it had (nil when
    /// none was saved for it).
    struct Window: Equatable {
        var root: URL
        var instanceIndex: Int?
    }

    /// The windows to restore on launch, in order, including several on one
    /// root. Filtered to roots that still exist on disk.
    static var windows: [Window] {
        let paths = defaults.stringArray(forKey: key) ?? []
        let saved = defaults.dictionary(forKey: indexesKey)
        var indexes: [Int?] = Array(repeating: nil, count: paths.count)
        if saved?["roots"] as? [String] == paths, let stored = saved?["indexes"] as? [Int],
           stored.count == paths.count {
            indexes = stored
        }
        return zip(paths, indexes)
            .filter { FileManager.default.fileExists(atPath: $0.0) }
            .map { Window(root: URL(filePath: $0.0, directoryHint: .checkFileSystem), instanceIndex: $0.1) }
    }

    /// Replace the persisted set with the given windows (call whenever windows change).
    static func replace(with windows: [Window]) {
        let paths = windows.map(\.root.standardizedPath)
        defaults.set(paths, forKey: key)
        if windows.allSatisfy({ $0.instanceIndex != nil }) {
            defaults.set(["roots": paths, "indexes": windows.compactMap(\.instanceIndex)], forKey: indexesKey)
        } else {
            defaults.removeObject(forKey: indexesKey)
        }
    }
}

extension URL {
    /// The standardized path with no trailing slash, as `URL.path` spelled it:
    /// one folder's every spelling is one string (how workspace roots are
    /// stored and matched — "/x/proj/" and "/x/proj" are the same folder).
    var standardizedPath: String {
        let path = standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
