import Combine
import Foundation

/// One row in the Search window: an open session in this workspace (`.live`)
/// or a past agent conversation that can be restored (`.past`).
struct SearchResult: Identifiable, Hashable {
    enum Source: Hashable {
        case live(UUID)
        case past(ConversationRecord)
    }

    let id: String
    let source: Source
    let agent: AgentKind
    let title: String
    /// Host path the session runs in / the conversation's cwd.
    let folder: String?
    /// Last activity (live) or the transcript's modification date (past).
    let date: Date
    let isChat: Bool
    /// How the query matched; nil when the query is empty.
    let tier: MatchTier?
    /// Text around a body match.
    let snippet: String?
    /// The conversation's id, and its transcript when already known (the
    /// preview resolves an open session's lazily — Codex lookups scan files).
    let transcriptID: String?
    let transcriptURL: URL?

    var isLive: Bool { if case .live = source { true } else { false } }
}

/// The Search window's model: the workspace's open sessions merged with the
/// past conversations `HistoryStore` finds under its mounts, filtered and
/// ranked by `query` (title > folder > body text, then most recent). Open
/// sessions come first; a past conversation an open session is already
/// running (same transcript id) is folded into that session instead of being
/// listed twice.
@MainActor
final class SearchStore: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch(debounce: 0.12) } }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedID: SearchResult.ID?
    /// Scanning transcripts or running a query.
    @Published private(set) var busy = false
    /// Bumped to (re)focus the search field when the window is shown again.
    @Published var focusRequest = 0

    private(set) var history: HistoryStore
    private let workspace: WorkspaceController
    let home: URL
    private let cacheDirectory: URL?
    /// Cache hits for `matchedQuery` (the query `results` reflect).
    private var pastMatches: [String: HistoryCache.Match] = [:]
    private(set) var matchedQuery = ""
    private var searchTask: Task<Void, Never>?
    private var historyObservers: Set<AnyCancellable> = []
    private var revisionObserver: AnyCancellable?

    /// `home` / `cacheDirectory` override where transcripts and the search
    /// cache live (self-tests); the defaults are the user's.
    init(workspace: WorkspaceController, home: URL? = nil, cacheDirectory: URL? = nil) {
        self.workspace = workspace
        self.home = home ?? workspace.home
        self.cacheDirectory = cacheDirectory
        self.history = HistoryStore(home: self.home, roots: workspace.mountRoots, cacheDirectory: cacheDirectory)
        observeHistory()
        // Sessions opened, closed, renamed or resumed: re-merge (no new query).
        revisionObserver = workspace.$revision.dropFirst().sink { [weak self] _ in
            self?.refresh(keepSelection: true)
        }
        refresh(keepSelection: false)
    }

    /// Rescan past conversations (each time the window opens). Rebuilds the
    /// history source when the workspace's mounts changed since last time.
    func reload() {
        if history.roots != workspace.mountRoots {
            history = HistoryStore(home: home, roots: workspace.mountRoots, cacheDirectory: cacheDirectory)
            observeHistory()
        }
        history.load()
        refresh(keepSelection: true)
    }

    private func observeHistory() {
        historyObservers = []
        // @Published emits before the store's value changes; hop a turn so the
        // new records are readable. New rows may also be new cache entries, so
        // re-run the query rather than just re-merging.
        history.$records.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.scheduleSearch(debounce: 0, keepSelection: true)
        }.store(in: &historyObservers)
        history.$loading.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateBusy()
        }.store(in: &historyObservers)
    }

    private func updateBusy() {
        let value = history.loading || searchTask != nil
        if busy != value { busy = value }
    }

    /// Wait for `query` to settle, then fetch body matches off the main thread.
    private func scheduleSearch(debounce: Double, keepSelection: Bool = false) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            searchTask = nil
            pastMatches = [:]
            matchedQuery = ""
            refresh(keepSelection: keepSelection)
            updateBusy()
            return
        }
        searchTask = Task { [weak self] in
            if debounce > 0 { try? await Task.sleep(for: .seconds(debounce)) }
            guard !Task.isCancelled, let self else { return }
            let matches = await self.history.matches(for: q)
            guard !Task.isCancelled else { return }
            self.pastMatches = matches
            self.matchedQuery = q
            self.searchTask = nil
            self.refresh(keepSelection: keepSelection)
            self.updateBusy()
        }
        updateBusy()
    }

    /// Re-merge from current sessions + records. Keeps the selected row when
    /// asked and it's still listed; otherwise selects the top hit.
    private func refresh(keepSelection: Bool) {
        let sessions = workspace.orderedSessions
        var activity: [UUID: Date] = [:]
        for s in sessions { activity[s.id] = workspace.runtime(s.id)?.lastActivityAt ?? s.lastActiveAt }
        results = Self.rank(sessions: sessions, activity: activity, records: history.records,
                            matches: pastMatches, query: matchedQuery)
        if !keepSelection || !results.contains(where: { $0.id == selectedID }) {
            selectedID = results.first?.id
        }
    }

    // MARK: Selection (arrow keys)

    var selected: SearchResult? { results.first { $0.id == selectedID } }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : results.count)
        selectedID = results[min(max(current + delta, 0), results.count - 1)].id
    }

    var liveCount: Int { results.count(where: \.isLive) }
    var pastCount: Int { results.count - liveCount }

    // MARK: Ranking

    /// Merge + rank. Pure, so it can be checked without a window: sessions in
    /// the given (most-recent-first) order, records newest first; `matches`
    /// are the cache's hits by transcript path; `query` is lowercased.
    nonisolated static func rank(sessions: [Session], activity: [UUID: Date],
                                 records: [ConversationRecord],
                                 matches: [String: HistoryCache.Match],
                                 query: String) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var recordByID: [String: ConversationRecord] = [:]
        for r in records where recordByID[r.id] == nil { recordByID[r.id] = r }

        func tier(title: String, folder: String?, hit: HistoryCache.Match?) -> MatchTier? {
            var best = hit?.tier
            if title.localizedStandardContains(q) { best = .title }
            else if let folder, folder.localizedStandardContains(q) { best = min(best ?? .folder, .folder) }
            return best
        }

        var live: [(SearchResult, Int)] = []
        var openTranscripts: Set<String> = []
        for (order, s) in sessions.enumerated() {
            let record = s.transcriptID.flatMap { recordByID[$0] }
            if let id = s.transcriptID { openTranscripts.insert(id) }
            let hit = record.flatMap { matches[$0.url.path(percentEncoded: false)] }
            let t = q.isEmpty ? nil : tier(title: s.name, folder: s.workdir, hit: hit)
            if !q.isEmpty, t == nil { continue }
            live.append((SearchResult(
                id: "live:" + s.id.uuidString, source: .live(s.id), agent: s.agent,
                title: s.name, folder: s.workdir,
                date: max(activity[s.id] ?? .distantPast, s.createdAt),
                isChat: s.isChat, tier: t, snippet: t == .body ? hit?.snippet : nil,
                transcriptID: s.transcriptID, transcriptURL: record?.url), order))
        }

        var past: [SearchResult] = []
        for r in records where !openTranscripts.contains(r.id) {
            let hit = matches[r.url.path(percentEncoded: false)]
            let t = q.isEmpty ? nil : tier(title: r.title, folder: r.cwd, hit: hit)
            if !q.isEmpty, t == nil { continue }
            past.append(SearchResult(
                id: "past:" + r.id, source: .past(r), agent: r.agent, title: r.title,
                folder: r.cwd, date: r.date, isChat: false, tier: t,
                snippet: t == .body ? hit?.snippet : nil, transcriptID: r.id, transcriptURL: r.url))
        }

        // Empty query: sidebar order for sessions, newest first for the past.
        // Otherwise best tier first, then most recent.
        func ranked(_ a: SearchResult, _ b: SearchResult) -> Bool {
            let ta = a.tier ?? .body, tb = b.tier ?? .body
            return ta != tb ? ta < tb : a.date > b.date
        }
        let liveSorted = q.isEmpty ? live.sorted { $0.1 < $1.1 }.map(\.0)
                                   : live.map(\.0).sorted(by: ranked)
        let pastSorted = q.isEmpty ? past.sorted { $0.date > $1.date } : past.sorted(by: ranked)
        return liveSorted + pastSorted
    }
}
