import Foundation
import Testing
@testable import Sandshell

/// `ClaudeTranscriptTail.title(in:)` / `fork(_:upTo:newID:)`: Claude Code's own
/// title for a conversation (as 2.1.x writes it), and forking a transcript
/// without taking the source's title along.
struct ClaudeTranscriptTitleTests {
    private static let user = #"{"type":"user","sessionId":"s-1","message":{"role":"user","content":"fix the login bug"}}"#
    private static func assistant(_ text: String) -> String {
        #"{"type":"assistant","sessionId":"s-1","message":{"id":"m","role":"assistant","content":[{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn"}}"#
    }
    private static func aiTitle(_ title: String) -> String { #"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"s-1"}"# }
    private static func customTitle(_ title: String) -> String {
        #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"s-1"}"#
    }

    @Test func theGeneratedTitleIsTheLatestAiTitle() {
        let text = [Self.user, Self.aiTitle("Fix login"), Self.assistant("Done."), Self.aiTitle("Fix the login bug")]
            .joined(separator: "\n")
        #expect(ClaudeTranscriptTail.title(in: text) == "Fix the login bug")
    }

    @Test func aTitleSetInClaudeWinsOverTheGeneratedOne() {
        let text = [Self.customTitle("Login work"), Self.aiTitle("Fix the login bug")].joined(separator: "\n")
        #expect(ClaudeTranscriptTail.title(in: text) == "Login work")
    }

    @Test(.tags(.edgeCase), arguments: [
        "",
        user,
        #"{"type":"summary","summary":"Not what 2.1 writes"}"#,
        #"{"type":"ai-title","aiTitle":"   "}"#,
        #"{"type":"ai-title"}"#,
        #"{"type":"ai-title","aiTitle":"half a line"#,
        #"{"type":"user","message":{"role":"user","content":"about \"ai-title\" lines"}}"#,
    ])
    func noTitleWithoutATitleLine(text: String) {
        #expect(ClaudeTranscriptTail.title(in: text) == nil)
    }

    @Test(.tags(.fileSystem))
    func readsTheTitleFromAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("title-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try ([Self.user, Self.aiTitle("Fix the login bug")].joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(ClaudeTranscriptTail.title(at: url) == "Fix the login bug")
        #expect(ClaudeTranscriptTail.title(at: url.appendingPathExtension("missing")) == nil)
    }

    @Test func aForkCopiesUpToTheReplyUnderItsOwnIDWithoutTheSourcesTitles() throws {
        let text = [Self.user, Self.aiTitle("Fix the login bug"), Self.assistant("First reply ALPHA"),
                    Self.customTitle("Login"), Self.user, Self.assistant("Second reply BETA")].joined(separator: "\n")

        let fork = try #require(ClaudeTranscriptTail.fork(text, upTo: "First reply ALPHA\n", newID: "new-id"))

        #expect(fork.cut == 2)
        #expect(fork.lines == 6)
        let lines = fork.text.split(separator: "\n")
        #expect(lines.count == 2, "The user line and the reply; the title is left behind")
        #expect(lines.allSatisfy { $0.contains(#""sessionId":"new-id""#) })
        #expect(!fork.text.contains("BETA"))
        #expect(ClaudeTranscriptTail.title(in: fork.text) == nil)
    }

    @Test(.tags(.edgeCase), arguments: ["", "   ", "a reply nobody wrote"])
    func noForkWithoutTheReply(reply: String) {
        let text = [Self.user, Self.assistant("First reply ALPHA")].joined(separator: "\n")
        #expect(ClaudeTranscriptTail.fork(text, upTo: reply, newID: "new-id") == nil)
    }
}
