import AppKit
import Testing
@testable import Sandshell

/// File ▸ Export Conversation… names the conversation after its own session
/// (e7q.96): not after the window's title, which is "<folder> — <the toolbar
/// pane's session>" and splits wrongly on a name with " — " in it.
@MainActor
struct ChatExportNameTests {
    /// Runs `body` with a chat (never started) in a scratch folder, cleaned up after.
    private func withChat(_ body: (ChatSessionView) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "chat-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.path(percentEncoded: false)
        let session = ChatSession(title: "Claude", containerName: "test-sandbox", workdir: path, home: path, mcpURL: nil)
        try body(ChatSessionView(session: session))
    }

    @Test(arguments: [("Refactor — part 2", "Refactor — part 2.md"), ("src/main fixes", "src-main fixes.md"),
                      ("", "Conversation.md")])
    func namedAfterTheSession(name: String, fileName: String) throws {
        try withChat { chat in
            chat.sessionName = { name }
            #expect(chat.exportName.heading == name)
            #expect(chat.exportName.fileName == fileName)
            #expect(chat.session.markdownExport(sessionName: chat.exportName.heading).hasPrefix("# \(name)\n"))
        }
    }

    /// Before the pane wires it, or once the session's gone: the agent's name.
    @Test(arguments: [false, true])
    func withoutASessionNameItsTheAgents(wired: Bool) throws {
        try withChat { chat in
            if wired { chat.sessionName = { nil } }
            #expect(chat.exportName.heading == "Claude")
            #expect(chat.exportName.fileName == "Claude.md")
        }
    }
}
