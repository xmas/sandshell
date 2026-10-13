import Foundation
import SQLite3

/// SQLite-backed cache for agent conversation metadata. Stores `searchText`
/// on disk rather than in-process RAM, and avoids re-parsing transcript files
/// whose mtime hasn't changed since the last scan.
///
/// All SQLite operations run on a private serial queue, making the cache
/// safe to use from any thread or concurrency context.
final class HistoryCache: @unchecked Sendable {
    private let q = DispatchQueue(label: "com.xmas.sandshell.historycache", qos: .utility)
    private nonisolated(unsafe) var db: OpaquePointer?

    // SQLITE_TRANSIENT sentinel: tells SQLite to copy the string before returning.
    private let transient = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type?.self)

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
        let path = directory.appendingPathComponent("history-cache.sqlite").path
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else { return nil }
        db = handle
        q.sync { self.setupSchema() }
    }

    deinit { sqlite3_close(db) }

    // MARK: - Public API

    func lookup(url: URL, mtime: Date) -> CachedRecord? {
        q.sync { _lookup(url: url, mtime: mtime) }
    }

    func upsert(url: URL, mtime: Date, record: CachedRecord, searchText: String) {
        q.sync { _upsert(url: url, mtime: mtime, record: record, searchText: searchText) }
    }

    /// Returns URL paths of records whose title, cwd, or full text matches `query`.
    func search(query: String) -> [String] {
        q.sync { _search(query: query) }
    }

    // MARK: - Schema

    private func setupSchema() {
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
    }

    // MARK: - Queries

    private func _lookup(url: URL, mtime: Date) -> CachedRecord? {
        let sql = """
            SELECT mtime, record_id, agent, title, cwd, message_count, recorded_date, session_id
            FROM records WHERE url = ?1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, url.path, -1, transient)
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

    private func _upsert(url: URL, mtime: Date, record: CachedRecord, searchText: String) {
        let sql = """
            INSERT OR REPLACE INTO records
                (url, mtime, record_id, agent, title, cwd, message_count,
                 recorded_date, session_id, search_text)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, url.path, -1, transient)
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

    private func _search(query: String) -> [String] {
        let pattern = "%" + query.lowercased() + "%"
        let sql = """
            SELECT url FROM records
            WHERE lower(COALESCE(search_text, '')) LIKE ?1
               OR lower(COALESCE(title, ''))       LIKE ?1
               OR lower(COALESCE(cwd, ''))         LIKE ?1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pattern, -1, transient)
        var urls: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) { urls.append(String(cString: ptr)) }
        }
        return urls
    }
}
