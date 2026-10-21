import Foundation
import Testing
@testable import Sandshell

/// A workspace folder renamed or moved on disk: its sessions follow it.
struct MovedWorkspaceTests {
    static let root = URL(filePath: "/Users/me/Code/sandshell", directoryHint: .isDirectory)

    static func state(_ workdirs: [String], folders extra: [Folder] = []) -> WorkspaceState {
        var state = WorkspaceState()
        let rootFolder = Folder(relativePath: "", order: 0)
        state.folders = [rootFolder] + extra
        state.sessions = workdirs.enumerated().map { i, dir in
            Session(folderID: (extra.first { dir.contains("/" + $0.relativePath) } ?? rootFolder).id,
                    agent: .claude, name: "s\(i)", order: i, workdir: dir)
        }
        return state
    }

    @Test func aRenamedRootTakesItsSessionsAlongAndRemembersWhereTheirConversationsAre() {
        let existing: Set<String> = ["/Users/me/Code/sandshell", "/Users/me/Code/sandshell/app"]
        var state = Self.state(["/Users/me/Code/xmas-sandshell", "/Users/me/Code/xmas-sandshell/app",
                                "/Users/me/Code/sandshell"])
        #expect(state.rebaseMissingWorkdirs(root: Self.root) { existing.contains($0) })
        #expect(state.sessions.map(\.workdir) == ["/Users/me/Code/sandshell", "/Users/me/Code/sandshell/app",
                                                  "/Users/me/Code/sandshell"])
        #expect(state.sessions.map(\.transcriptWorkdir) == ["/Users/me/Code/xmas-sandshell",
                                                           "/Users/me/Code/xmas-sandshell/app", nil])
    }

    @Test func aSessionInAFolderMovesUnderThatFolder() {
        let docs = Folder(relativePath: "docs", order: 1)
        let existing: Set<String> = ["/Users/me/Code/sandshell", "/Users/me/Code/sandshell/docs"]
        var state = Self.state(["/old/place/docs"], folders: [docs])
        state.rebaseMissingWorkdirs(root: Self.root) { existing.contains($0) }
        #expect(state.sessions[0].workdir == "/Users/me/Code/sandshell/docs")
    }

    @Test(.tags(.edgeCase))
    func nothingMovesWhileTheOldPathIsThereOrTheFolderIsGoneToo() {
        var here = Self.state(["/Users/me/Code/xmas-sandshell"])
        #expect(!here.rebaseMissingWorkdirs(root: Self.root) { _ in true })
        var gone = Self.state(["/Users/me/Code/xmas-sandshell"])
        #expect(!gone.rebaseMissingWorkdirs(root: Self.root) { _ in false })
        #expect(gone.sessions[0].workdir == "/Users/me/Code/xmas-sandshell" && gone.sessions[0].transcriptWorkdir == nil)
    }
}
