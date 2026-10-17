import Foundation
import SQLite3
import Synchronization

/// How strongly a search query matched a conversation or session — lower ranks
/// first: the title beats the folder, which beats a hit in the body text.
enum MatchTier: Int, Comparable, Sendable {
    case title, folder, body
    static func < (a: MatchTier, b: MatchTier) -> Bool { a.rawValue < b.rawValue }
}

/// SQLite-backed cache for agent conversation metadata. Stores `searchText`
/// on disk rather than in-process RAM, and avoids re-parsing transcript files
/// whose mtime hasn't changed since the last scan.
///
/// All SQLite operations run holding the database's lock, making the cache
/// safe to use from any thread or concurrency context.
final class HistoryCache: Sendable {
    private let db: Mutex<OpaquePointer?>

    // SQLITE_TRANSIENT sentinel: tells SQLite to copy the string before returning.
    private static var transient: sqlite3_destructor_type? { unsafeBitCast(-1 as Int, to: sqlite3_destructor_type?.self) }

    struct CachedRecord {
        let id: String
        let agent: AgentKind
        let title: String?
        let cwd: String?
        let messageCount: Int
        let date: Date
        let sessionID: String?
    }

    init?(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "history-cache.sqlite").path(percentEncoded: false)
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else { return nil }
        db = Mutex(handle)
        db.withLock { Self.setupSchema($0) }
    }

    deinit { db.withLock { _ = sqlite3_close($0) } }

    // MARK: - Public API

    func lookup(url: URL, mtime: Date) -> CachedRecord? {
        db.withLock { Self._lookup($0, url: url, mtime: mtime) }
    }

    func upsert(url: URL, mtime: Date, record: CachedRecord, searchText: String) {
        db.withLock { Self._upsert($0, url: url, mtime: mtime, record: record, searchText: searchText) }
    }

    /// One ranked hit: the transcript path, its best tier, and (for body hits)
    /// the text around the first occurrence.
    struct Match: Sendable {
        let path: String
        let tier: MatchTier
        let snippet: String?
    }

    /// Records whose title, cwd, or full text contains `query` (substring,
    /// case-insensitive), best tier first, then newest.
    func search(query: String) -> [Match] {
        db.withLock { Self._search($0, query: query) }
    }

    // MARK: - Schema

    private static func setupSchema(_ db: OpaquePointer?) {
        let sql = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS records (
                url          TEXT PRIMARY KEY,
                mtime        REAL NOT NULL,
                record_id    TEXT NOT NULL,
                agent        TEXT NOT NULL,
                title        TEXT,
                cwd          TEXT,
                message_count INTEGER NOT NULL DEFAULT 0,
                recorded_date REAL NOT NULL,
                session_id   TEXT,
                search_text  TEXT
            );
            CREATE INDEX IF NOT EXISTS records_mtime ON records(mtime DESC);
        """
        var err: UnsafeMutablePointer<Int8>?
        sqlite3_exec(db, sql, nil, nil, &err)
        // v2 stores search_text in its original case (for display snippets);
        // v3 keeps the conversation's latest stretch too, not just its first 60 KB;
        // v4 re-titles Claude conversations that opened with injected <…> context
        // (a slash command's <command-name>, a <system-reminder> block).
        // Drop older rows so they're re-parsed on the next scan.
        if userVersion(db) < schemaVersion {
            sqlite3_exec(db, "DELETE FROM records; PRAGMA user_version = \(schemaVersion);", nil, nil, &err)
        }
    }

    /// Bumped whenever a parse change makes cached rows wrong: older rows are dropped.
    static let schemaVersion: Int32 = 4

    private static func userVersion(_ db: OpaquePointer?) -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
    }

    // MARK: - Queries

    private static func _lookup(_ db: OpaquePointer?, url: URL, mtime: Date) -> CachedRecord? {
        let sql = """
            SELECT mtime, record_id, agent, title, cwd, message_count, recorded_date, session_id
            FROM records WHERE url = ?1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, url.path(percentEncoded: false), -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let storedMtime = sqlite3_column_double(stmt, 0)
        guard abs(storedMtime - mtime.timeIntervalSince1970) < 0.001 else { return nil }
        let id = String(cString: sqlite3_column_text(stmt, 1))
        let agentRaw = String(cString: sqlite3_column_text(stmt, 2))
        let agent = AgentKind(rawValue: agentRaw)
        let title = sqlite3_column_type(stmt, 3) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 3)) : nil
        let cwd = sqlite3_column_type(stmt, 4) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 4)) : nil
        let messageCount = Int(sqlite3_column_int(stmt, 5))
        let recordedDate = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        let sessionID = sqlite3_column_type(stmt, 7) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 7)) : nil
        return CachedRecord(id: id, agent: agent, title: title, cwd: cwd,
                            messageCount: messageCount, date: recordedDate, sessionID: sessionID)
    }

    private static func _upsert(_ db: OpaquePointer?, url: URL, mtime: Date, record: CachedRecord, searchText: String) {
        let sql = """
            INSERT OR REPLACE INTO records
                (url, mtime, record_id, agent, title, cwd, message_count,
                 recorded_date, session_id, search_text)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, url.path(percentEncoded: false), -1, transient)
        sqlite3_bind_double(stmt, 2, mtime.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, record.id, -1, transient)
        sqlite3_bind_text(stmt, 4, record.agent.rawValue, -1, transient)
        if let t = record.title { sqlite3_bind_text(stmt, 5, t, -1, transient) }
        else { sqlite3_bind_null(stmt, 5) }
        if let c = record.cwd { sqlite3_bind_text(stmt, 6, c, -1, transient) }
        else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_int(stmt, 7, Int32(record.messageCount))
        sqlite3_bind_double(stmt, 8, record.date.timeIntervalSince1970)
        if let s = record.sessionID { sqlite3_bind_text(stmt, 9, s, -1, transient) }
        else { sqlite3_bind_null(stmt, 9) }
        sqlite3_bind_text(stmt, 10, searchText, -1, transient)
        sqlite3_step(stmt)
    }

    private static func _search(_ db: OpaquePointer?, query: String) -> [Match] {
        let needle = query.lowercased()
        // LIKE is already ASCII case-insensitive; escape its wildcards so a
        // literal `%`, `_` or `\` in the query matches itself.
        let escaped = needle.replacing("\\", with: "\\\\")
            .replacing("%", with: "\\%")
            .replacing("_", with: "\\_")
        let sql = """
            SELECT url, tier,
                   CASE WHEN tier = 2 THEN instr(lower(search_text), ?2) END AS pos,
                   CASE WHEN tier = 2 THEN substr(search_text,
                        max(1, instr(lower(search_text), ?2) - \(snippetLead)), \(snippetLength)) END
            FROM (
                SELECT url, recorded_date, search_text,
                       CASE WHEN COALESCE(title, '') LIKE ?1 ESCAPE '\\' THEN 0
                            WHEN COALESCE(cwd, '')   LIKE ?1 ESCAPE '\\' THEN 1
                            ELSE 2 END AS tier
                FROM records
                WHERE COALESCE(title, '')       LIKE ?1 ESCAPE '\\'
                   OR COALESCE(cwd, '')         LIKE ?1 ESCAPE '\\'
                   OR COALESCE(search_text, '') LIKE ?1 ESCAPE '\\'
            )
            ORDER BY tier, recorded_date DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "%" + escaped + "%", -1, transient)
        sqlite3_bind_text(stmt, 2, needle, -1, transient)
        var matches: [Match] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ptr = sqlite3_column_text(stmt, 0) else { continue }
            let tier = MatchTier(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .body
            var snippet: String?
            if sqlite3_column_type(stmt, 3) != SQLITE_NULL, let text = sqlite3_column_text(stmt, 3) {
                let pos = Int(sqlite3_column_int(stmt, 2))
                snippet = tidySnippet(String(cString: text), truncatedStart: pos > snippetLead + 1)
            }
            matches.append(Match(path: String(cString: ptr), tier: tier, snippet: snippet))
        }
        return matches
    }

    /// Characters of context kept before the match, and the snippet's length.
    private static let snippetLead = 50
    private static let snippetLength = 220

    /// One line of display text: whitespace runs collapsed, a partial leading
    /// word dropped, and ellipses where the text was cut.
    static func tidySnippet(_ raw: String, truncatedStart: Bool) -> String {
        var text = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if truncatedStart, let space = text.firstIndex(of: " "),
           text.distance(from: text.startIndex, to: space) < 20 {
            text = String(text[text.index(after: space)...])
        }
        let cutEnd = raw.count >= snippetLength
        return (truncatedStart ? "…" : "") + text + (cutEnd ? "…" : "")
    }
}
