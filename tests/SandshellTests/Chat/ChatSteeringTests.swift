import Foundation
import Testing
@testable import Sandshell

/// A message sent while Claude works goes into the running turn
/// (`_session/steering`), as in Claude Code — not into a queue until the turn
/// ends. Driven against `remote/fake-acp-agent.py`: no sandbox, no tokens.
@MainActor
struct ChatSteeringTests {
    private static let fakeAgent = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "remote/fake-acp-agent.py")

    private func chat(_ extra: [String] = []) throws -> ChatSession {
        try #require(FileManager.default.fileExists(atPath: Self.fakeAgent.path(percentEncoded: false)))
        let dir = FileManager.default.temporaryDirectory.appending(path: "sandshell-steering-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chat = ChatSession(title: "Fake agent", agent: .claude, containerName: "steering-test",
                               workdir: dir.path, home: dir.path, sessionID: UUID())
        chat.launchOverride = ("/usr/bin/python3", ["-I", Self.fakeAgent.path(percentEncoded: false)] + extra)
        return chat
    }

    private func wait(_ what: String, seconds: Double = 10, until done: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !done() {
            guard Date() < end else { Issue.record("Timed out waiting: \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func said(_ chat: ChatSession) -> String {
        chat.items.compactMap { if case .agentText(_, let t) = $0 { t } else { nil } }.joined(separator: "\n")
    }

    private func userMessages(_ chat: ChatSession) -> [String] {
        chat.items.compactMap { if case .user(_, let t, _) = $0 { t } else { nil } }
    }

    @Test func aMessageSentMidTurnIsReadAtOnce() async throws {
        let chat = try chat()
        defer { chat.close() }
        chat.start()
        try await wait("ready") { chat.phase == .ready }
        #expect(chat.submit(text: "slow", attachments: []))
        try await wait("working") { said(chat).contains("Working slowly") }

        #expect(chat.submit(text: "also check the tests", attachments: []))
        #expect(chat.queue.isEmpty, "Not queued behind the turn")
        #expect(userMessages(chat) == ["slow", "also check the tests"], "Shown in the transcript right away")
        try await wait("the agent read it") { said(chat).contains("Heard: also check the tests") }
        try await wait("the turn ended") { chat.phase == .ready }
        #expect(userMessages(chat) == ["slow", "also check the tests"], "Once, not again when the turn ends")
    }

    @Test func anAgentThatCantTakeItQueuesItForAfterTheTurn() async throws {
        let chat = try chat(["--no-steering"])
        defer { chat.close() }
        chat.start()
        try await wait("ready") { chat.phase == .ready }
        #expect(chat.submit(text: "slow", attachments: []))
        try await wait("working") { said(chat).contains("Working slowly") }

        #expect(chat.submit(text: "ping", attachments: []))
        try await wait("queued after the refusal") { !chat.queue.isEmpty }
        #expect(!chat.canSteer)
        #expect(userMessages(chat) == ["slow"], "Taken back out of the transcript while it waits")
        chat.cancel()
        try await wait("sent once the turn ended", seconds: 15) { said(chat).contains("pong: ping") }
        #expect(userMessages(chat) == ["slow", "ping"])
    }
}
