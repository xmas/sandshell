import Foundation
import Testing
@testable import Sandshell

// Tests for `ClaudeSessionRegistry` (Chat/ClaudeSessionRegistry.swift): Claude
// Code's registry of running sessions, one `~/.claude/sessions/<pid>.json` per
// live `claude` process.
//
// Every filesystem test works in its own scratch `$HOME` under the temporary
// directory (never the real `~/.claude`), removed when the test ends.
//
// No test launches a process:
// - `processStart` runs `/bin/ps`, so it isn't tested directly. `isAlive` only
//   calls it for a running pid on this Mac that recorded a start time, so every
//   on-Mac entry here either has a pid no process can have or no `procStart`.
// - `sandboxedProcessIsAlive` asks `sbx` once its guards pass, so only the
//   guard paths (which answer nil before touching `sbx`) are tested, and
//   `verdict`, which reads the sandboxes' answers.

extension Tag {
    @Tag static var claudeRegistryEdgeCase: Self
    @Tag static var claudeRegistryFileSystem: Self
}

// MARK: - Fixtures

fileprivate typealias RegistryEntry = ClaudeSessionRegistry.Entry

fileprivate enum RegistryIDs {
    /// The conversation the tests look for.
    static let session = "3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b"
    /// Some other conversation.
    static let otherSession = "9e8d7c6b-5a49-4382-a1b0-c9d8e7f6a5b4"
}

fileprivate enum RegistryPIDs {
    /// This test process: certainly running, and ours to signal.
    static var current: Int32 { ProcessInfo.processInfo.processIdentifier }
    /// launchd: always running and owned by root, so an unprivileged `kill(1, 0)` fails with EPERM.
    static let launchd: Int32 = 1
    /// Above macOS's PID_MAX (99 999): no process can have it, so `kill` fails with ESRCH.
    static let impossible: Int32 = 999_999
}

fileprivate enum RegistryTime {
    /// A fixed "now" (2023-11-14 22:13:20 UTC) whose arithmetic stays exact in `Double`.
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// The registry's timestamp (milliseconds since 1970) for `seconds` before `date`.
    static func ms(_ seconds: TimeInterval, before date: Date = RegistryTime.now) -> Double {
        (date.timeIntervalSince1970 - seconds) * 1000
    }
}

fileprivate enum RegistryEntries {
    /// A writer inside a sandbox (its pid lives in the sandbox's VM), last heard from at `lastUpdateMs`.
    static func sandboxed(pid: Int32 = 4242, status: String?, lastUpdateMs: Double?) -> RegistryEntry {
        RegistryEntry(pid: pid, sessionId: RegistryIDs.session, entrypoint: "cli", status: status,
                      pidDomain: "linux::pid:[1]", updatedAt: lastUpdateMs, statusUpdatedAt: lastUpdateMs)
    }
}

/// One registry file's contents, as Claude Code writes it. Optional fields left nil are omitted.
fileprivate struct RegistryRecord: Encodable {
    var pid: Int32
    var sessionId: String
    var entrypoint: String? = "cli"
    var status: String? = "idle"
    var pidDomain: String? = "darwin"
    var procStart: String?
    var updatedAt: Double?
    var statusUpdatedAt: Double?
    /// A field Claude Code writes that the app doesn't read.
    var cwd = "/Users/someone/project"

    /// A writer inside a sandbox, last heard from `secondsAgo` before the real current time.
    static func sandboxed(pid: Int32, sessionId: String, entrypoint: String = "cli", status: String,
                          secondsAgo: TimeInterval, procStart: String? = nil) -> RegistryRecord {
        let ms = RegistryTime.ms(secondsAgo, before: Date())
        return RegistryRecord(pid: pid, sessionId: sessionId, entrypoint: entrypoint, status: status,
                              pidDomain: "linux::pid:[1]", procStart: procStart, updatedAt: ms, statusUpdatedAt: ms)
    }

    /// A writer on this Mac with no recorded start time, so its liveness is only "does the pid exist" (no `ps`).
    static func onThisMac(pid: Int32, sessionId: String, entrypoint: String = "cli", status: String,
                          secondsAgo: TimeInterval? = nil) -> RegistryRecord {
        let ms = secondsAgo.map { RegistryTime.ms($0, before: Date()) }
        return RegistryRecord(pid: pid, sessionId: sessionId, entrypoint: entrypoint, status: status,
                              pidDomain: "darwin", procStart: nil, updatedAt: ms, statusUpdatedAt: ms)
    }
}

/// A throwaway `$HOME` with an empty `.claude/sessions`, deleted when the owning suite instance goes away.
fileprivate final class ScratchClaudeHome {
    let url: URL

    var path: String { url.path }
    var sessions: URL { url.appendingPathComponent(".claude/sessions", isDirectory: true) }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionRegistryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Leaves `~/.claude` in place but takes away its `sessions` directory.
    func removeSessionsDirectory() throws {
        try FileManager.default.removeItem(at: sessions)
    }

    /// Writes `text` verbatim as `sessions/<name>`.
    func write(_ text: String, named name: String) throws {
        try Data(text.utf8).write(to: sessions.appendingPathComponent(name))
    }

    /// Registers a writer the way Claude Code does: one JSON file per process.
    func register(_ record: RegistryRecord, named name: String = "\(UUID().uuidString).json") throws {
        try JSONEncoder().encode(record).write(to: sessions.appendingPathComponent(name))
    }
}

// MARK: - Entry's derived fields

struct ClaudeSessionRegistryEntryTests {
    @Test("Only the exact status \"busy\" counts as mid-turn", arguments: [
        ("busy", true), ("idle", false), ("Busy", false), ("BUSY", false), ("busy ", false), ("", false), (nil, false),
    ] as [(String?, Bool)])
    func busyStatus(status: String?, expected: Bool) {
        let entry = RegistryEntry(pid: 1, sessionId: "s", status: status)
        #expect(entry.isBusy == expected)
    }

    @Test("A process is on this Mac when the registry names no domain or exactly \"darwin\"", arguments: [
        (nil, true), ("darwin", true), ("linux", false), ("linux::pid:[1]", false), ("Darwin", false), ("", false),
    ] as [(String?, Bool)])
    func pidDomain(domain: String?, expected: Bool) {
        let entry = RegistryEntry(pid: 1, sessionId: "s", pidDomain: domain)
        #expect(entry.isOnThisMac == expected)
    }

    @Test("lastUpdate reads the registry's milliseconds since 1970", arguments: [
        (0.0, 0.0), (1_000.0, 1.0), (1_700_000_000_000.0, 1_700_000_000.0), (1_700_000_000_500.0, 1_700_000_000.5),
    ])
    func lastUpdateIsMilliseconds(ms: Double, seconds: Double) {
        let entry = RegistryEntry(pid: 1, sessionId: "s", updatedAt: ms)
        #expect(entry.lastUpdate == Date(timeIntervalSince1970: seconds))
    }

    @Test("lastUpdate uses statusUpdatedAt when present (even when updatedAt is later), else updatedAt, else nothing",
          arguments: [
        (updatedAt: 2_000_000, statusUpdatedAt: 1_000_000, expectedSeconds: 1_000),
        (updatedAt: 1_000_000, statusUpdatedAt: 2_000_000, expectedSeconds: 2_000),
        (updatedAt: 5_000, statusUpdatedAt: nil, expectedSeconds: 5),
        (updatedAt: nil, statusUpdatedAt: 7_000, expectedSeconds: 7),
        (updatedAt: nil, statusUpdatedAt: nil, expectedSeconds: nil),
    ] as [(updatedAt: Double?, statusUpdatedAt: Double?, expectedSeconds: TimeInterval?)])
    func lastUpdateSource(example: (updatedAt: Double?, statusUpdatedAt: Double?, expectedSeconds: TimeInterval?)) {
        let entry = RegistryEntry(pid: 1, sessionId: "s", updatedAt: example.updatedAt,
                                  statusUpdatedAt: example.statusUpdatedAt)
        #expect(entry.lastUpdate == example.expectedSeconds.map { Date(timeIntervalSince1970: $0) })
    }
}

// MARK: - Decoding registry files

struct ClaudeSessionRegistryEntryDecodingTests {
    @Test("A registry file as Claude Code writes it decodes every field the app reads and ignores the rest")
    func decodesFullFile() throws {
        let json = """
            {"pid":51234,"sessionId":"3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b","cwd":"/Users/someone/project",
             "startedAt":1760650000000,"kind":"interactive","entrypoint":"claude-desktop","status":"busy",
             "pidDomain":"darwin","procStart":"Thu Oct 16 21:03:11 2026",
             "updatedAt":1760650000000,"statusUpdatedAt":1760650004321}
            """
        let entry = try JSONDecoder().decode(RegistryEntry.self, from: Data(json.utf8))
        let expected = RegistryEntry(
            pid: 51234, sessionId: RegistryIDs.session, entrypoint: "claude-desktop", status: "busy",
            pidDomain: "darwin", procStart: "Thu Oct 16 21:03:11 2026",
            updatedAt: 1_760_650_000_000, statusUpdatedAt: 1_760_650_004_321)
        #expect(entry == expected)
    }

    @Test("Only pid and sessionId are required: missing or null fields decode as nil", arguments: [
        #"{"pid":7,"sessionId":"abc"}"#,
        #"{"pid":7,"sessionId":"abc","entrypoint":null,"status":null,"pidDomain":null,"procStart":null,"updatedAt":null,"statusUpdatedAt":null}"#,
    ])
    func optionalFields(json: String) throws {
        let entry = try JSONDecoder().decode(RegistryEntry.self, from: Data(json.utf8))
        #expect(entry == RegistryEntry(pid: 7, sessionId: "abc"))
    }

    @Test("Files that don't describe a registry entry fail to decode", .tags(.claudeRegistryEdgeCase), arguments: [
        #"{"sessionId":"abc"}"#,                                   // no pid
        #"{"pid":7}"#,                                            // no sessionId
        #"{"pid":7,"sessionId":null}"#,
        #"{"pid":7,"sessionId":42}"#,
        #"{"pid":"7","sessionId":"abc"}"#,                        // pid as a string
        #"{"pid":7.5,"sessionId":"abc"}"#,                        // not a whole number
        #"{"pid":3000000000,"sessionId":"abc"}"#,                 // beyond Int32
        #"{"pid":7,"sessionId":"abc","updatedAt":"yesterday"}"#,
        #"[{"pid":7,"sessionId":"abc"}]"#,                        // not an object
        #"{"pid":7,"sessionId":"abc""#,                            // truncated mid-write
        "",
    ])
    func invalidFiles(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RegistryEntry.self, from: Data(json.utf8))
        }
    }
}

// MARK: - key(_:)

struct ClaudeSessionRegistryKeyTests {
    @Test("An entry's key is \"<pid>:<procStart>\", with an empty start time when none was recorded", arguments: [
        (pid: 42, procStart: "Thu Oct 16 21:03:11 2026", expected: "42:Thu Oct 16 21:03:11 2026"),
        (pid: 7, procStart: "123456", expected: "7:123456"),
        (pid: 42, procStart: nil, expected: "42:"),
        (pid: 42, procStart: "", expected: "42:"),
        (pid: -1, procStart: nil, expected: "-1:"),
    ] as [(pid: Int32, procStart: String?, expected: String)])
    func keyFormat(example: (pid: Int32, procStart: String?, expected: String)) {
        let entry = RegistryEntry(pid: example.pid, sessionId: "s", procStart: example.procStart)
        #expect(ClaudeSessionRegistry.key(entry) == example.expected)
    }

    @Test("A reused pid with a different start time gets a different key")
    func reusedPidIsDistinct() {
        let earlier = RegistryEntry(pid: 501, sessionId: "s", procStart: "Mon Oct 13 09:00:00 2026")
        let later = RegistryEntry(pid: 501, sessionId: "s", procStart: "Thu Oct 16 21:03:11 2026")
        #expect(ClaudeSessionRegistry.key(earlier) != ClaudeSessionRegistry.key(later))
    }

    @Test("The key ignores everything but pid and start time")
    func keyIgnoresOtherFields() {
        let first = RegistryEntry(pid: 9, sessionId: "one", entrypoint: "cli", status: "busy", pidDomain: "darwin",
                                  procStart: "100", updatedAt: 1, statusUpdatedAt: 2)
        let second = RegistryEntry(pid: 9, sessionId: "two", entrypoint: "sdk-ts", status: "idle",
                                   pidDomain: "linux", procStart: "100")
        #expect(ClaudeSessionRegistry.key(first) == ClaudeSessionRegistry.key(second))
    }
}

// MARK: - isAlive(_:now:)

struct ClaudeSessionRegistryIsAliveTests {
    // In a sandbox: judged only by how recently it was heard from.

    @Test("A sandboxed writer is trusted for 30 minutes while busy and 6 hours otherwise", arguments: [
        (status: "busy", secondsAgo: 0, expected: true),
        (status: "busy", secondsAgo: 600, expected: true),
        (status: "busy", secondsAgo: 7_200, expected: false),
        (status: "idle", secondsAgo: 1_800, expected: true),
        (status: "idle", secondsAgo: 3 * 3_600, expected: true),
        (status: "idle", secondsAgo: 86_400, expected: false),
        (status: nil, secondsAgo: 3_600, expected: true),
        (status: nil, secondsAgo: 86_400, expected: false),
    ] as [(status: String?, secondsAgo: TimeInterval, expected: Bool)])
    func sandboxedAge(example: (status: String?, secondsAgo: TimeInterval, expected: Bool)) {
        let entry = RegistryEntries.sandboxed(status: example.status, lastUpdateMs: RegistryTime.ms(example.secondsAgo))
        #expect(ClaudeSessionRegistry.isAlive(entry, now: RegistryTime.now) == example.expected)
    }

    @Test("The age limits are exclusive: a millisecond short is alive, the limit itself is gone",
          .tags(.claudeRegistryEdgeCase), arguments: [
        ("busy", 1_800_000.0), ("idle", 21_600_000.0),
    ])
    func ageLimitsAreExclusive(status: String, limitMs: Double) {
        let nowMs = RegistryTime.now.timeIntervalSince1970 * 1000
        let justInside = RegistryEntries.sandboxed(status: status, lastUpdateMs: nowMs - limitMs + 1)
        let atLimit = RegistryEntries.sandboxed(status: status, lastUpdateMs: nowMs - limitMs)
        #expect(ClaudeSessionRegistry.isAlive(justInside, now: RegistryTime.now), "one millisecond inside the limit")
        #expect(ClaudeSessionRegistry.isAlive(atLimit, now: RegistryTime.now) == false, "exactly at the limit")
    }

    @Test("A sandboxed writer that never recorded a time isn't trusted", arguments: ["busy", "idle", nil] as [String?])
    func sandboxedWithoutTimestamp(status: String?) {
        let entry = RegistryEntries.sandboxed(status: status, lastUpdateMs: nil)
        #expect(ClaudeSessionRegistry.isAlive(entry, now: RegistryTime.now) == false)
    }

    @Test("A timestamp ahead of now (clock skew between sandbox and Mac) still counts as recent",
          .tags(.claudeRegistryEdgeCase))
    func futureTimestamp() {
        let entry = RegistryEntries.sandboxed(status: "busy", lastUpdateMs: RegistryTime.ms(-3_600))
        #expect(ClaudeSessionRegistry.isAlive(entry, now: RegistryTime.now))
    }

    @Test("A sandboxed writer's age comes from statusUpdatedAt, falling back to updatedAt")
    func sandboxedAgeSource() {
        let freshStatus = RegistryEntry(pid: 1, sessionId: "s", status: "busy", pidDomain: "linux",
                                        updatedAt: RegistryTime.ms(7_200), statusUpdatedAt: RegistryTime.ms(60))
        let onlyUpdatedAt = RegistryEntry(pid: 1, sessionId: "s", status: "busy", pidDomain: "linux",
                                          updatedAt: RegistryTime.ms(60))
        #expect(ClaudeSessionRegistry.isAlive(freshStatus, now: RegistryTime.now), "a stale updatedAt is overridden")
        #expect(ClaudeSessionRegistry.isAlive(onlyUpdatedAt, now: RegistryTime.now))
    }

    @Test("A sandboxed writer's pid isn't looked up on the Mac")
    func sandboxedPidIsNotChecked() {
        // No Mac process can have this pid, but it lives in the sandbox's VM.
        let entry = RegistryEntries.sandboxed(pid: RegistryPIDs.impossible, status: "busy",
                                              lastUpdateMs: RegistryTime.ms(60))
        #expect(ClaudeSessionRegistry.isAlive(entry, now: RegistryTime.now))
    }

    // On this Mac: judged by the process, never by age.

    @Test("On this Mac, a running process with no recorded start time (or an empty one) is alive",
          arguments: [nil, "darwin"] as [String?], [nil, ""] as [String?])
    func runningProcessOnThisMac(domain: String?, procStart: String?) {
        let entry = RegistryEntry(pid: RegistryPIDs.current, sessionId: "s", pidDomain: domain, procStart: procStart)
        #expect(ClaudeSessionRegistry.isAlive(entry), "the test's own process is running")
    }

    @Test("A process we aren't allowed to signal (EPERM) still exists, so it's alive")
    func processOwnedBySomeoneElse() {
        let entry = RegistryEntry(pid: RegistryPIDs.launchd, sessionId: "s", pidDomain: "darwin")
        #expect(ClaudeSessionRegistry.isAlive(entry), "launchd (pid 1) always exists; kill(1, 0) fails with EPERM")
    }

    @Test("On this Mac, a pid with no process is dead whatever start time it recorded", arguments: [
        nil, "", "Thu Oct 16 21:03:11 2026",
    ] as [String?])
    func missingProcessOnThisMac(procStart: String?) {
        let entry = RegistryEntry(pid: RegistryPIDs.impossible, sessionId: "s", status: "busy",
                                  pidDomain: "darwin", procStart: procStart)
        #expect(ClaudeSessionRegistry.isAlive(entry) == false)
    }

    @Test("On this Mac, how long ago it was heard from doesn't matter, only the process")
    func staleButRunningOnThisMac() {
        let entry = RegistryEntry(pid: RegistryPIDs.current, sessionId: "s", status: "busy", pidDomain: "darwin",
                                  updatedAt: 0, statusUpdatedAt: 0)
        #expect(ClaudeSessionRegistry.isAlive(entry, now: RegistryTime.now))
    }

    /// pid 0 and minus our own process group both name the test's process group (which it's in), so `kill`
    /// succeeds deterministically; other negative pids name some process group, or (-1) every process we own.
    @Test("A malformed entry with pid 0 or a negative pid isn't a live process", .tags(.claudeRegistryEdgeCase),
          arguments: [0, -getpgrp()] as [Int32])
    func nonPositivePidIsNotAlive(pid: Int32) {
        let entry = RegistryEntry(pid: pid, sessionId: "s", pidDomain: "darwin")
        #expect(ClaudeSessionRegistry.isAlive(entry) == false)
    }
}

// MARK: - verdict(_:)

struct ClaudeSessionRegistryProbeVerdictTests {
    @Test("Any sandbox holding the process makes it alive, whatever the others said", arguments: [
        ["alive"], ["gone", "alive"], [nil, "alive"], ["alive", "gone", nil, "error"],
    ] as [[String?]])
    func aliveAnywhere(answers: [String?]) {
        #expect(ClaudeSessionRegistry.verdict(answers) == true)
    }

    @Test("It's gone only when every running sandbox said so", arguments: [
        ["gone"], ["gone", "gone", "gone"],
    ] as [[String?]])
    func goneEverywhere(answers: [String?]) {
        #expect(ClaudeSessionRegistry.verdict(answers) == false)
    }

    @Test("A sandbox that didn't answer (busy, timed out) or answered nonsense could hold it: can't tell",
          .tags(.claudeRegistryEdgeCase), arguments: [
        [nil], ["gone", nil], [nil, "gone", "gone"], ["gone", ""], ["gone", "sh: sed: not found"],
    ] as [[String?]])
    func someSandboxUnheard(answers: [String?]) {
        #expect(ClaudeSessionRegistry.verdict(answers) == nil)
    }
}

// MARK: - sandboxedProcessIsAlive(_:) guards

struct ClaudeSessionRegistrySandboxProbeTests {
    @Test("Writers on this Mac are never probed inside sandboxes", arguments: [nil, "darwin"] as [String?])
    func writersOnThisMacAreNotProbed(domain: String?) async {
        let entry = RegistryEntry(pid: 4242, sessionId: "s", status: "busy", pidDomain: domain, procStart: "123456")
        let answer = await ClaudeSessionRegistry.sandboxedProcessIsAlive(entry)
        #expect(answer == nil)
    }

    @Test("Without a numeric start time there's nothing to compare, so the probe can't tell",
          .tags(.claudeRegistryEdgeCase), arguments: [
        nil, "", "Thu Oct 16 21:03:11 2026", " 123456", "123456 ", "12.5", "0x1F", "123abc",
    ] as [String?])
    func nonNumericStartTime(procStart: String?) async {
        let entry = RegistryEntry(pid: 4242, sessionId: "s", status: "busy", pidDomain: "linux::pid:[1]",
                                  procStart: procStart)
        let answer = await ClaudeSessionRegistry.sandboxedProcessIsAlive(entry)
        #expect(answer == nil)
    }
}

// MARK: - entries(home:sessionID:)

@Suite(.tags(.claudeRegistryFileSystem))
struct ClaudeSessionRegistryEntriesTests {
    private let home: ScratchClaudeHome
    private let session = RegistryIDs.session

    init() throws {
        home = try ScratchClaudeHome()
    }

    private func found(_ sessionID: String? = nil) -> [RegistryEntry] {
        ClaudeSessionRegistry.entries(home: home.path, sessionID: sessionID ?? session)
    }

    @Test("A home that doesn't exist has no entries")
    func missingHome() {
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionRegistryTests-missing-\(UUID().uuidString)").path
        #expect(ClaudeSessionRegistry.entries(home: nowhere, sessionID: session).isEmpty)
    }

    @Test("A home with ~/.claude but no sessions directory has no entries")
    func noSessionsDirectory() throws {
        try home.removeSessionsDirectory()
        #expect(found().isEmpty)
    }

    @Test("An empty sessions directory has no entries")
    func emptySessionsDirectory() {
        #expect(found().isEmpty)
    }

    @Test("Every registered writer of the session is returned, and no writer of another")
    func everyWriterOfTheSession() throws {
        try home.register(RegistryRecord(pid: 101, sessionId: session, entrypoint: "cli"))
        try home.register(RegistryRecord(pid: 102, sessionId: session, entrypoint: "claude-desktop"))
        try home.register(RegistryRecord(pid: 103, sessionId: RegistryIDs.otherSession, entrypoint: "cli"))
        #expect(found().map(\.pid).sorted() == [101, 102])
    }

    @Test("Each entry carries every field from its file")
    func entryFieldsComeFromTheFile() throws {
        try home.register(RegistryRecord(
            pid: 51234, sessionId: session, entrypoint: "claude-desktop", status: "busy", pidDomain: "darwin",
            procStart: "Thu Oct 16 21:03:11 2026", updatedAt: 1_760_650_000_000, statusUpdatedAt: 1_760_650_004_321))
        let expected = RegistryEntry(
            pid: 51234, sessionId: session, entrypoint: "claude-desktop", status: "busy", pidDomain: "darwin",
            procStart: "Thu Oct 16 21:03:11 2026", updatedAt: 1_760_650_000_000, statusUpdatedAt: 1_760_650_004_321)
        #expect(found() == [expected])
    }

    @Test("Entries are listed whether or not their process is still running")
    func includesDeadWriters() throws {
        try home.register(RegistryRecord(pid: RegistryPIDs.impossible, sessionId: session, status: "busy",
                                         procStart: "Mon Jan 1 00:00:00 2001"))
        try home.register(.sandboxed(pid: 8, sessionId: session, status: "idle", secondsAgo: 30 * 86_400))
        #expect(found().map(\.pid).sorted() == [8, RegistryPIDs.impossible])
    }

    @Test("A file for another session is skipped even when its ID contains this one",
          .tags(.claudeRegistryEdgeCase), arguments: [
        RegistryIDs.session + "-fork", "x" + RegistryIDs.session, RegistryIDs.session.uppercased(),
    ])
    func sessionIDMustMatchExactly(decoy: String) throws {
        try home.register(RegistryRecord(pid: 104, sessionId: decoy))
        #expect(found().isEmpty)
    }

    @Test("Mentioning the session in another field doesn't make a file one of its writers",
          .tags(.claudeRegistryEdgeCase))
    func sessionMentionedElsewhere() throws {
        try home.register(RegistryRecord(pid: 105, sessionId: RegistryIDs.otherSession,
                                         procStart: session, cwd: "/Users/someone/\(session)"))
        #expect(found().isEmpty)
    }

    @Test("Only files ending in .json are read", .tags(.claudeRegistryEdgeCase), arguments: [
        "51234.json.tmp", "51234.jsonl", "51234.json~", "51234.txt", "51234", "51234.JSON",
    ])
    func onlyJSONFiles(name: String) throws {
        try home.register(RegistryRecord(pid: 51234, sessionId: session), named: name)
        #expect(found().isEmpty)
    }

    @Test("Malformed files are skipped without hiding the valid ones", .tags(.claudeRegistryEdgeCase))
    func malformedFilesAreSkipped() throws {
        try home.write(#"{"pid":201,"sessionId":"\#(session)""#, named: "truncated.json")
        try home.write(#"{"pid":"202","sessionId":"\#(session)"}"#, named: "string-pid.json")
        try home.write(#"{"sessionId":"\#(session)"}"#, named: "no-pid.json")
        try home.write("", named: "empty.json")
        try home.write("not json at all \(session)", named: "garbage.json")
        try home.register(RegistryRecord(pid: 203, sessionId: session))
        #expect(found().map(\.pid) == [203])
    }

    @Test("An empty session ID matches nothing", .tags(.claudeRegistryEdgeCase))
    func emptySessionID() throws {
        try home.register(RegistryRecord(pid: 301, sessionId: session))
        #expect(found("").isEmpty)
    }
}

// MARK: - otherWriter(home:sessionID:gone:)

@Suite(.tags(.claudeRegistryFileSystem))
struct ClaudeSessionRegistryOtherWriterTests {
    private let home: ScratchClaudeHome
    private let session = RegistryIDs.session

    init() throws {
        home = try ScratchClaudeHome()
    }

    private func currentOtherWriter(gone: Set<String> = []) -> RegistryEntry? {
        ClaudeSessionRegistry.otherWriter(home: home.path, sessionID: session, gone: gone)
    }

    @Test("Without a registry there's no other writer")
    func noRegistry() throws {
        try home.removeSessionsDirectory()
        #expect(currentOtherWriter() == nil)
    }

    @Test("An empty registry has no other writer")
    func emptyRegistry() {
        #expect(currentOtherWriter() == nil)
    }

    @Test("Our own chat agent (sdk-ts in a sandbox) isn't another writer", arguments: ["busy", "idle"])
    func ownSandboxedAgentIsIgnored(status: String) throws {
        try home.register(.sandboxed(pid: 7, sessionId: session, entrypoint: "sdk-ts", status: status, secondsAgo: 0))
        #expect(currentOtherWriter() == nil)
    }

    @Test("Skipping our own busier agent still finds the other writer")
    func ownAgentDoesNotHideOthers() throws {
        try home.register(.sandboxed(pid: 7, sessionId: session, entrypoint: "sdk-ts", status: "busy", secondsAgo: 0))
        try home.register(.sandboxed(pid: 8, sessionId: session, entrypoint: "cli", status: "idle", secondsAgo: 3_600))
        let writer = try #require(currentOtherWriter())
        #expect(writer.pid == 8)
        #expect(writer.entrypoint == "cli")
    }

    @Test("Other clients in a sandbox are other writers", arguments: ["cli", "claude-vscode", "sdk-py"])
    func sandboxedClientsCount(entrypoint: String) throws {
        try home.register(.sandboxed(pid: 9, sessionId: session, entrypoint: entrypoint, status: "busy", secondsAgo: 60))
        #expect(currentOtherWriter()?.entrypoint == entrypoint)
    }

    @Test("An SDK client on this Mac (sdk-ts outside a sandbox) is another writer")
    func sdkClientOnThisMacCounts() throws {
        try home.register(.onThisMac(pid: RegistryPIDs.current, sessionId: session, entrypoint: "sdk-ts", status: "busy"))
        #expect(currentOtherWriter()?.entrypoint == "sdk-ts")
    }

    @Test("Writers that aren't alive are never reported")
    func deadWritersAreIgnored() throws {
        // On this Mac, a pid no process can have (found dead before `ps` would be asked).
        try home.register(RegistryRecord(pid: RegistryPIDs.impossible, sessionId: session, status: "busy",
                                         procStart: "Thu Oct 16 21:03:11 2026"))
        // In sandboxes: busy but silent for 31 minutes, idle and silent for 7 hours, never heard from.
        try home.register(.sandboxed(pid: 71, sessionId: session, status: "busy", secondsAgo: 31 * 60))
        try home.register(.sandboxed(pid: 72, sessionId: session, status: "idle", secondsAgo: 7 * 3_600))
        try home.register(RegistryRecord(pid: 73, sessionId: session, status: "busy", pidDomain: "linux::pid:[1]"))
        #expect(currentOtherWriter() == nil)
    }

    @Test("A dead writer doesn't outrank a live one, however recent and busy")
    func deadWriterDoesNotOutrankLiveOne() throws {
        let justNow = RegistryTime.ms(0, before: Date())
        try home.register(RegistryRecord(pid: RegistryPIDs.impossible, sessionId: session, entrypoint: "claude-desktop",
                                         status: "busy", procStart: "Thu Oct 16 21:03:11 2026",
                                         updatedAt: justNow, statusUpdatedAt: justNow))
        try home.register(.sandboxed(pid: 61, sessionId: session, status: "idle", secondsAgo: 600))
        #expect(currentOtherWriter()?.pid == 61)
    }

    @Test("Live writers of other sessions are ignored")
    func otherSessionsAreIgnored() throws {
        try home.register(.onThisMac(pid: RegistryPIDs.current, sessionId: RegistryIDs.otherSession, status: "busy"))
        try home.register(.sandboxed(pid: 81, sessionId: RegistryIDs.otherSession, status: "busy", secondsAgo: 0))
        #expect(currentOtherWriter() == nil)
    }

    @Test("A busy writer outranks a more recently heard-from idle one")
    func busyWriterComesFirst() throws {
        try home.register(.sandboxed(pid: 11, sessionId: session, status: "busy", secondsAgo: 20 * 60))
        try home.register(.sandboxed(pid: 12, sessionId: session, status: "idle", secondsAgo: 10))
        #expect(currentOtherWriter()?.pid == 11)
    }

    @Test("Among equally busy writers, the most recently heard from comes first", arguments: ["busy", "idle"])
    func mostRecentWriterComesFirst(status: String) throws {
        try home.register(.sandboxed(pid: 21, sessionId: session, status: status, secondsAgo: 600))
        try home.register(.sandboxed(pid: 22, sessionId: session, status: status, secondsAgo: 30))
        try home.register(.sandboxed(pid: 23, sessionId: session, status: status, secondsAgo: 300))
        #expect(currentOtherWriter()?.pid == 22)
    }

    @Test("Busy outranks recency even for a writer on this Mac that never recorded a time")
    func busyWithoutTimestampStillComesFirst() throws {
        try home.register(.onThisMac(pid: RegistryPIDs.current, sessionId: session, entrypoint: "claude-desktop",
                                     status: "busy"))
        try home.register(.sandboxed(pid: 52, sessionId: session, status: "idle", secondsAgo: 1))
        #expect(currentOtherWriter()?.entrypoint == "claude-desktop")
    }

    @Test("Among idle writers, one that never recorded a time ranks last")
    func idleWithoutTimestampRanksLast() throws {
        try home.register(.onThisMac(pid: RegistryPIDs.current, sessionId: session, entrypoint: "claude-desktop",
                                     status: "idle"))
        try home.register(.sandboxed(pid: 53, sessionId: session, status: "idle", secondsAgo: 5 * 3_600))
        #expect(currentOtherWriter()?.pid == 53)
    }

    @Test("Writers already found gone are skipped, falling back to the next best")
    func goneWritersAreSkipped() throws {
        try home.register(.sandboxed(pid: 31, sessionId: session, status: "busy", secondsAgo: 30))
        try home.register(.sandboxed(pid: 32, sessionId: session, status: "busy", secondsAgo: 120))
        let first = try #require(currentOtherWriter(), "the fresher busy writer should be found first")
        try #require(first.pid == 31)
        let second = try #require(currentOtherWriter(gone: [ClaudeSessionRegistry.key(first)]))
        #expect(second.pid == 32)
        let gone: Set = [ClaudeSessionRegistry.key(first), ClaudeSessionRegistry.key(second)]
        #expect(currentOtherWriter(gone: gone) == nil, "every writer is gone")
    }

    @Test("A gone key only matches the same pid with the same start time", .tags(.claudeRegistryEdgeCase))
    func goneKeyMustMatchExactly() throws {
        try home.register(.sandboxed(pid: 41, sessionId: session, status: "busy", secondsAgo: 30, procStart: "1000"))
        let writer = currentOtherWriter(gone: ["41:999", "42:1000", "41:"])
        #expect(writer?.pid == 41)
        #expect(writer?.procStart == "1000")
    }
}
