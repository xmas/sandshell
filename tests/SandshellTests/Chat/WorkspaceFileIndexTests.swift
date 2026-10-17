import Foundation
import Testing
@testable import Sandshell

/// The `@` completion / Open Quickly file index: what it lists under a folder,
/// and how it ranks files against what's typed.
struct WorkspaceFileIndexTests {
    private static let files = [
        "Sandshell/Chat/ChatTranscriptView.swift",
        "docs/chat-notes.md",
        "Chat/README.md",
        "Sandshell/UI/MyChatView.swift",
        "docs/Résumé.md",
    ]

    /// File name first, then a file name containing it, then a path containing
    /// it, then the letters in order in the file name; shorter first in a tier.
    @Test(arguments: [
        ("chat", ["docs/chat-notes.md", "Sandshell/Chat/ChatTranscriptView.swift", "Sandshell/UI/MyChatView.swift",
                  "Chat/README.md"]),
        ("chtv", ["Sandshell/UI/MyChatView.swift", "Sandshell/Chat/ChatTranscriptView.swift"]),
        ("readme", ["Chat/README.md"]),
    ])
    func ranksNameThenPathThenLetters(query: String, expected: [String]) {
        #expect(WorkspaceFileIndex.match(Self.files, query: query) == expected)
    }

    @Test(arguments: ["resume", "RESUME", "résumé"])
    func matchesWhateverTheCaseAndAccents(query: String) {
        #expect(WorkspaceFileIndex.match(Self.files, query: query) == ["docs/Résumé.md"])
    }

    @Test func anEmptyQueryListsTheShortestFirst() {
        #expect(Set(WorkspaceFileIndex.match(Self.files, query: "", limit: 2)) == ["Chat/README.md", "docs/Résumé.md"])
    }

    /// Paths relative to the folder however it's written (the temp folder is
    /// under /var, which the enumerator reports as /private/var), skipping
    /// VCS and dependency folders and the folders themselves.
    @Test(arguments: [false, true])
    func listsFilesRelativeToTheFolder(trailingSlash: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: "file-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        for dir in ["src/deep", ".git", "node_modules/pkg"] {
            try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        for file in ["a.txt", "src/b.swift", "src/deep/My File.md", ".git/HEAD", "node_modules/pkg/index.js"] {
            try Data("x".utf8).write(to: root.appending(path: file))
        }
        var path = root.path(percentEncoded: false)
        if !trailingSlash { path.removeLast() }
        let files = await WorkspaceFileIndex().files(under: path)
        #expect(Set(files) == ["a.txt", "src/b.swift", "src/deep/My File.md"])
    }
}
