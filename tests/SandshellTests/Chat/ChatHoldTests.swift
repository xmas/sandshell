import Foundation
import Testing
@testable import Sandshell

/// A chat whose agent kept running while Sandshell was away (`sandshell-hold`
/// in the kits): the launch that takes it up shows the turn so far, knows the
/// turn is still going, reaps by the agent's own tag, and hears it end.
/// Driven against `remote/fake-acp-agent.py --held-mid-turn`: no sandbox.
@MainActor
struct ChatHoldTests {
    private static let repo = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let fakeAgent = repo.appending(path: "remote/fake-acp-agent.py")

    private func chat(_ extra: [String] = [], resume: String? = "conv-1") throws -> ChatSession {
        try #require(FileManager.default.fileExists(atPath: Self.fakeAgent.path(percentEncoded: false)))
        let dir = FileManager.default.temporaryDirectory.appending(path: "sandshell-hold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chat = ChatSession(title: "Fake agent", agent: .claude, containerName: "hold-test",
                               workdir: dir.path, home: dir.path, resumeID: resume, sessionID: UUID())
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

    @Test func aTurnLeftRunningIsTakenUpWhereItIs() async throws {
        let launch = UUID()
        let chat = try chat(["--held-mid-turn", launch.uuidString])
        defer { chat.close() }
        var working: [Bool] = []
        chat.onWorkingChange = { working.append($0) }
        chat.start()
        try await wait("taken up") { chat.phase != .starting }
        #expect(chat.phase == .running, "the turn it was in is still going")
        #expect(chat.isHeld && chat.reattached)
        #expect(chat.processMatch == "SANDSHELL_LAUNCH=\(launch.uuidString)", "reaped by the tag the agent carries")
        #expect(chat.items.contains { if case .user(_, let t, _) = $0 { t == "build it" } else { false } },
                "what you said before quitting")
        #expect(said(chat) == "Building while you were away.")

        try await wait("the turn ended") { chat.phase == .ready }
        #expect(said(chat) == "Building while you were away. Done.", "the rest streams onto the same reply")
        #expect(working == [true, false], "working, then finished, as for a turn of its own")
    }

    @Test func aChatNotHeldClosesOnDetach() async throws {
        let chat = try chat(resume: nil)
        chat.start()
        try await wait("ready") { chat.phase == .ready }
        #expect(!chat.isHeld)
        #expect(chat.detach() == false, "nothing left running")
    }

    @Test func aHeldChatLeftMidTurnSaysSo() async throws {
        let chat = try chat(["--held-mid-turn", UUID().uuidString])
        chat.start()
        try await wait("taken up") { chat.phase == .running }
        #expect(chat.detach(), "its turn goes on in the sandbox")
    }

    /// Both kits ship the same supervisor and notify command, and install them.
    @Test(arguments: ["sandshell-hold", "sandshell-notify"])
    func bothKitsShipTheSame(_ name: String) throws {
        let claude = try String(contentsOf: Self.repo.appending(path: "kits/sandshell-claude/scripts/\(name).mjs"), encoding: .utf8)
        let codex = try String(contentsOf: Self.repo.appending(path: "kits/sandshell-codex/scripts/\(name).mjs"), encoding: .utf8)
        #expect(claude == codex, "kits/sandshell-codex/scripts/\(name).mjs is a copy of the Claude kit's")
        for kit in ["sandshell-claude", "sandshell-codex"] {
            let dockerfile = try String(contentsOf: Self.repo.appending(path: "kits/\(kit)/Dockerfile"), encoding: .utf8)
            #expect(dockerfile.contains("COPY scripts/\(name).mjs /opt/sandshell/\(name).mjs"), "\(kit) installs \(name)")
        }
    }
}
