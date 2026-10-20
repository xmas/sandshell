import Foundation
import Testing
@testable import Sandshell

/// Unsaved edits count as changes: diffed against git, and shown as modified.
struct BufferDiffTests {
    /// A repo with one committed file, `notes.txt`.
    private func repo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bufferdiff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "one\ntwo\nthree\n".write(to: dir.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]] {
            _ = GitStatus.git(["-C", dir.path] + args)
        }
        return dir
    }

    @Test func theBufferIsDiffedAgainstTheIndexWithGitsHeaders() throws {
        let dir = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let diff = GitStatus.bufferDiff(path: dir.appending(path: "notes.txt").path, text: "one\nTWO\nthree\n", against: "")
        #expect(diff.hasPrefix("--- a/notes.txt\n+++ b/notes.txt\n@@ "))
        #expect(diff.contains("\n-two\n+TWO\n"))
        #expect(LineChanges(unifiedDiff: GitStatus.bufferDiff(path: dir.appending(path: "notes.txt").path,
                                                             text: "one\nTWO\nthree\n", against: "HEAD", context: 0)).modified == [2])
    }

    @Test(.tags(.edgeCase))
    func theSameTextHasNoDiffAndANewFileIsAllAdded() throws {
        let dir = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GitStatus.bufferDiff(path: dir.appending(path: "notes.txt").path, text: "one\ntwo\nthree\n", against: "").isEmpty)
        let fresh = GitStatus.bufferDiff(path: dir.appending(path: "new.txt").path, text: "a\nb\n", against: "HEAD", context: 0)
        #expect(LineChanges(unifiedDiff: fresh).added == [1, 2])
    }

    @Test func editedFilesCountAsModifiedWhereGitHasNothingForThem() {
        var status = GitStatus(repoRoot: "/r")
        status.changes["/r/a/b.txt"] = .untracked
        let shown = status.with(edited: ["/r/a/b.txt", "/r/c/d.txt", "/elsewhere/e.txt"])
        #expect(shown.changes == ["/r/a/b.txt": .untracked, "/r/c/d.txt": .modified])
        #expect(shown.dirtyFolders.isSuperset(of: ["/r/c", "/r"]))
        #expect(status.with(edited: []) == status)
    }
}
