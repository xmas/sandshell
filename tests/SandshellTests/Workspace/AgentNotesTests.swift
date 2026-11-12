import Foundation
import Testing
@testable import Sandshell

/// Notes agents leave with `sandshell-notify`, taken from the workspace's
/// `.sandshell/notify`.
struct AgentNotesTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sandshell-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func leave(_ json: String, as name: String, in dir: URL) throws {
        try json.write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
    }

    @Test func notesAreTakenOldestFirstAndRemoved() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = UUID()
        let now = Date.now
        try leave(#"{"session":"\#(session.uuidString)","title":"Build passed","message":"214 tests","at":"\#(now.ISO8601Format())"}"#,
                  as: "1700000000200-b.json", in: dir)
        try leave(#"{"session":null,"title":null,"message":"  first  \n","at":"\#(now.ISO8601Format())"}"#,
                  as: "1700000000100-a.json", in: dir)
        let notes = AgentNotes.take(from: dir, now: now)
        #expect(notes.map(\.message) == ["first", "214 tests"])
        #expect(notes.last?.title == "Build passed")
        #expect(notes.last?.processSession == session)
        #expect(notes.first?.processSession == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty, "taken: gone from the folder")
        #expect(AgentNotes.take(from: dir, now: now).isEmpty, "and not taken twice")
    }

    @Test func fractionalSecondsAreReadToo() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try leave(#"{"message":"hi","at":"2026-11-11T23:53:08.927Z"}"#, as: "1-a.json", in: dir)
        let at = try Date("2026-11-11T23:53:09Z", strategy: .iso8601)
        #expect(AgentNotes.take(from: dir, now: at).map(\.message) == ["hi"])
    }

    @Test func oldNotesAndJunkAreDroppedHalfWrittenOnesLeft() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date.now
        let old = now.addingTimeInterval(-AgentNotes.staleAfter - 60)
        try leave(#"{"message":"old news","at":"\#(old.ISO8601Format())"}"#, as: "1-old.json", in: dir)
        try leave("not json", as: "2-junk.json", in: dir)
        try leave(#"{"message":"   "}"#, as: "3-empty.json", in: dir)
        try leave(#"{"message":"still writing"}"#, as: ".4-tmp.tmp", in: dir)
        #expect(AgentNotes.take(from: dir, now: now).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [".4-tmp.tmp"],
                "sandshell-notify renames it into place when it's whole")
    }

    @Test func aMissingFolderHasNoNotes() {
        #expect(AgentNotes.take(from: URL(filePath: "/nonexistent/\(UUID().uuidString)")).isEmpty)
    }

    @Test func theFolderIsTheWorkspaces() {
        #expect(AgentNotes.directory(root: URL(filePath: "/ws")).path(percentEncoded: false) == "/ws/.sandshell/notify/")
    }
}
