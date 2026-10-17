import Foundation
import SQLite3
import Testing
@testable import Sandshell

/// `HistoryCache` (Sandshell/Workspace/HistoryCache.swift): cached History rows are
/// served while a transcript is unchanged, and dropped when the cache's version is
/// older than the parsing that made them. Every test works in its own folder under
/// the temporary directory.
struct HistoryCacheTests {
    private let folder: HistoryCacheFolder
    private let transcript = URL(filePath: "/Users/test/.claude/projects/-Users-test-Code-project/history.jsonl")
    private let mtime = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        folder = try HistoryCacheFolder()
    }

    private func record(title: String = "Fix the login bug") -> HistoryCache.CachedRecord {
        HistoryCache.CachedRecord(id: "history", agent: .claude, title: title, cwd: "/Users/test/Code/project",
                                  messageCount: 2, date: mtime, sessionID: nil)
    }

    /// Opens a cache on the folder, stores one row, and closes it again.
    private func storeOneRow() throws {
        let cache = try #require(HistoryCache(directory: folder.url))
        cache.upsert(url: transcript, mtime: mtime, record: record(), searchText: "Fix the login bug")
    }

    @Test func rowIsServedWhileTheTranscriptIsUnchanged() throws {
        let cache = try #require(HistoryCache(directory: folder.url))
        cache.upsert(url: transcript, mtime: mtime, record: record(), searchText: "Fix the login bug")
        #expect(cache.lookup(url: transcript, mtime: mtime)?.title == "Fix the login bug")
        #expect(cache.lookup(url: transcript, mtime: mtime.addingTimeInterval(1)) == nil,
                "A changed transcript is parsed again")
    }

    @Test func rowsSurviveReopeningAtTheCurrentVersion() throws {
        try storeOneRow()
        let reopened = try #require(HistoryCache(directory: folder.url))
        #expect(reopened.lookup(url: transcript, mtime: mtime)?.title == "Fix the login bug")
    }

    @Test(arguments: [1, 2, 3] as [Int32])
    func rowsFromAnOlderVersionAreDropped(version: Int32) throws {
        try storeOneRow()
        try folder.setUserVersion(version)
        let reopened = try #require(HistoryCache(directory: folder.url))
        #expect(reopened.lookup(url: transcript, mtime: mtime) == nil,
                "Rows an older parse made (v3: titles from injected <…> context) are parsed again")
        #expect(try folder.userVersion() == HistoryCache.schemaVersion)
    }

    /// `%`, `_` and `\` in a query match themselves, not as LIKE wildcards.
    @Test(arguments: [("100%", "100% done"), ("a_b", "rename a_b"), ("C:\\x", "open C:\\x")])
    func wildcardsInTheQueryMatchLiterally(query: String, matching title: String) throws {
        let cache = try #require(HistoryCache(directory: folder.url))
        let decoy = URL(filePath: "/Users/test/.claude/projects/-Users-test-Code-project/decoy.jsonl")
        cache.upsert(url: transcript, mtime: mtime, record: record(title: title), searchText: title)
        // What each query would match as a pattern: `%` any run, `_` any
        // character, `\x` a plain x.
        cache.upsert(url: decoy, mtime: mtime, record: record(title: "100 dollars, axb, C:x"),
                     searchText: "100 dollars, axb, C:x")
        let hits = cache.search(query: query)
        #expect(hits.map(\.path) == [transcript.path(percentEncoded: false)])
        #expect(hits.first?.tier == .title)
    }

    @Test func usableFromManyTasksAtOnce() async throws {
        let cache = try #require(HistoryCache(directory: folder.url))
        let base = URL(filePath: "/Users/test/.claude/projects/-Users-test-Code-project")
        let record = record(), mtime = mtime
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let url = base.appending(path: "\(i).jsonl")
                    cache.upsert(url: url, mtime: mtime, record: record, searchText: "task \(i)")
                    _ = cache.lookup(url: url, mtime: mtime)
                    _ = cache.search(query: "task")
                }
            }
        }
        #expect(cache.search(query: "task").count == 20)
    }
}

/// A fresh folder for one test's cache file, removed when the test ends.
fileprivate final class HistoryCacheFolder: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(component: "SandshellHistoryCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    private var databasePath: String { url.appending(component: "history-cache.sqlite").path }

    func setUserVersion(_ version: Int32) throws {
        try withDatabase { db in
            try #require(sqlite3_exec(db, "PRAGMA user_version = \(version);", nil, nil, nil) == SQLITE_OK)
        }
    }

    func userVersion() throws -> Int32 {
        try withDatabase { db in
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            try #require(sqlite3_step(statement) == SQLITE_ROW)
            return sqlite3_column_int(statement, 0)
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        try #require(sqlite3_open(databasePath, &db) == SQLITE_OK)
        return try body(db)
    }
}
