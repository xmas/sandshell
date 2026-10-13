import Foundation

/// One past agent conversation, surfaced in the History browser.
struct ConversationRecord: Identifiable, Hashable {
    let id: String          // transcript UUID (= the agent session id)
    let agent: AgentKind
    let url: URL
    let title: String
    let cwd: String?
    let date: Date
    let messageCount: Int

    init?(url: URL, date: Date, agent: AgentKind, cache: HistoryCache? = nil) {
        // Fast path: metadata already cached and file hasn't changed.
        if let cache, let hit = cache.lookup(url: url, mtime: date) {
            if agent == .codex, hit.sessionID == nil { return nil }
            self.id = hit.sessionID ?? url.deletingPathExtension().lastPathComponent
            self.agent = agent
            self.url = url
            self.title = hit.title ?? "Untitled conversation"
            self.cwd = hit.cwd
            self.date = date
            self.messageCount = hit.messageCount
            return
        }
        // Slow path: parse the transcript file.
        guard let s = TranscriptReader.summary(at: url, agent: agent) else { return nil }
        if agent == .codex, s.sessionID == nil { return nil }
        let rid = s.sessionID ?? url.deletingPathExtension().lastPathComponent
        self.id = rid
        self.agent = agent
        self.url = url
        self.title = s.firstPrompt ?? "Untitled conversation"
        self.cwd = s.cwd
        self.date = date
        self.messageCount = s.messageCount
        // Write through to cache so the next scan skips this file.
        if let cache {
            let cached = HistoryCache.CachedRecord(
                id: rid, agent: agent, title: self.title, cwd: s.cwd,
                messageCount: s.messageCount, date: date, sessionID: s.sessionID)
            cache.upsert(url: url, mtime: date, record: cached, searchText: s.searchText)
        }
    }
}

/// Loads + searches every available agent conversation (agent transcripts) for
/// the History browser. Scans on a background task; publishes results on main.
/// Full-text search is delegated to `HistoryCache` (SQLite), so `ConversationRecord`
/// no longer holds a 60 KB `searchText` blob per entry.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [ConversationRecord] = []
    @Published private(set) var loading = false
    @Published var query = ""

    private let home: URL
    private let roots: [String]   // host paths the workspace mounts
    private let cache: HistoryCache?

    init(home: URL, roots: [String]) {
        self.home = home
        self.roots = roots
        let cacheDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Sandshell")
            ?? home.appendingPathComponent(".sandshell")
        self.cache = HistoryCache(directory: cacheDir)
    }

    var filtered: [ConversationRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return records }
        let ql = q.lowercased()
        // Full-text search via SQLite; fall back to title/cwd when cache unavailable.
        let matchingPaths: Set<String>
        if let cache {
            matchingPaths = Set(cache.search(query: ql))
        } else {
            matchingPaths = []
        }
        return records.filter { record in
            matchingPaths.contains(record.url.path)
                || record.title.lowercased().contains(ql)
                || (record.cwd?.lowercased().contains(ql) ?? false)
        }
    }

    func load() {
        guard !loading else { return }
        loading = true
        let home = self.home, roots = self.roots, cache = self.cache
        Task.detached(priority: .userInitiated) {
            let recs = Self.scan(home: home, roots: roots, cache: cache)
            await MainActor.run {
                self.records = recs
                self.loading = false
            }
        }
    }

    /// Whether a conversation's cwd is inside the workspace's mount space (so a
    /// restored session can `-w` into it).
    private nonisolated static func isMounted(_ cwd: String?, in roots: [String]) -> Bool {
        guard let cwd else { return false }
        return roots.contains { cwd == $0 || cwd.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Scan `~/.claude/projects/*/*.jsonl` and `~/.codex/sessions/**/*.jsonl`,
    /// newest first, capped so a machine with thousands of transcripts stays
    /// responsive. Only conversations within the workspace mounts are kept
    /// (others can't be restored). Cache hits avoid re-parsing unchanged files.
    private nonisolated static func scan(home: URL, roots: [String],
                                         cache: HistoryCache?) -> [ConversationRecord] {
        let scanLimit = 400
        let files = claudeFiles(home: home).map { ($0.0, $0.1, AgentKind.claude) }
            + TranscriptReader.codexFiles(home: home).map { ($0.url, $0.date, AgentKind.codex) }
        return files
            .sorted { $0.1 > $1.1 }
            .prefix(scanLimit)
            .compactMap { ConversationRecord(url: $0.0, date: $0.1, agent: $0.2, cache: cache) }
            .filter { isMounted($0.cwd, in: roots) }
    }

    private nonisolated static func claudeFiles(home: URL) -> [(URL, Date)] {
        let fm = FileManager.default
        let projects = home.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil) else { return [] }
        return dirs.flatMap { dir -> [(URL, Date)] in
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
            return entries.compactMap { url -> (URL, Date)? in
                guard url.pathExtension == "jsonl" else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url, date)
            }
        }
    }
}
