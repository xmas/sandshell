#if DEBUG
import Foundation
import Testing
@testable import Sandshell

/// `ChatSession`: folding the agent's `session/update`s into transcript items
/// (on a chat that's never started), and what it says about credentials.
@MainActor
struct ChatSessionTests {
    /// A chat that never launches anything; its paths are never touched.
    private let session = ChatSession(title: "Claude", containerName: "test-sandbox", workdir: "/nonexistent/work",
                                      home: "/nonexistent/home", mcpURL: nil)

    private static func chunk(_ text: String, thought: Bool = false, messageID: String? = nil) -> JSONValue {
        var update: [String: JSONValue] = [
            "sessionUpdate": .string(thought ? "agent_thought_chunk" : "agent_message_chunk"),
            "content": ["type": "text", "text": .string(text)],
        ]
        if let messageID { update["messageId"] = .string(messageID) }
        return .object(update)
    }

    private static func toolCall(_ id: String) -> JSONValue {
        ["sessionUpdate": "tool_call", "toolCallId": .string(id), "title": "ls", "kind": "execute", "status": "completed"]
    }

    @Test(arguments: [false, true])
    func chunksWithoutAMessageIDJoinTheReplyTheyContinue(thought: Bool) {
        session.debugApply(Self.chunk("Hel", thought: thought))
        session.debugApply(Self.chunk("lo", thought: thought))
        #expect(session.items.count == 1)
        switch session.items.first {
        case .agentText(_, let text)?, .thought(_, let text)?: #expect(text == "Hello")
        default: Issue.record("Expected one reply, got \(session.items)")
        }
    }

    @Test(arguments: [false, true])
    func repliesWithoutAMessageIDEachGetTheirOwnID(thought: Bool) {
        session.debugApply(Self.chunk("Looking.", thought: thought))
        session.debugApply(Self.toolCall("t1"))
        session.debugApply(Self.chunk("Found it.", thought: thought))
        let ids = session.items.map(\.id)
        #expect(ids.count == 3)
        #expect(Set(ids).count == ids.count, "Every item has its own id: \(ids)")
    }

    @Test func chunksWithAMessageIDJoinOnlyTheirOwnMessage() {
        session.debugApply(Self.chunk("One", messageID: "m1"))
        session.debugApply(Self.chunk(" more", messageID: "m1"))
        session.debugApply(Self.chunk("Two", messageID: "m2"))
        #expect(session.items == [.agentText(id: "m1", text: "One more"), .agentText(id: "m2", text: "Two")])
    }

    @Test(.tags(.edgeCase))
    func aChunkWithoutAMessageIDStartsANewReplyAfterOneThatHasOne() {
        session.debugApply(Self.chunk("Agent's", messageID: "m1"))
        session.debugApply(Self.chunk("Unlabelled"))
        #expect(session.items.count == 2)
        #expect(session.items.first == .agentText(id: "m1", text: "Agent's"))
    }

    // MARK: Prompt suggestions

    @Test func aForwardedPromptSuggestionIsRead() {
        let params: JSONValue = ["sessionId": "s1", "message": [
            "type": "prompt_suggestion", "suggestion": "  Run the tests\n", "uuid": "u", "session_id": "s1"]]
        #expect(ChatSession.promptSuggestion(inSDKMessage: params) == "Run the tests")
    }

    @Test(arguments: [
        ["message": ["type": "result", "suggestion": "no"]],
        ["message": ["type": "prompt_suggestion", "suggestion": "  "]],
        ["message": ["type": "prompt_suggestion"]],
        [:],
    ] as [JSONValue])
    func otherSDKMessagesSuggestNothing(params: JSONValue) {
        #expect(ChatSession.promptSuggestion(inSDKMessage: params) == nil)
    }

    /// The adapter drops the SDK's suggestions unless it's asked to forward them.
    @Test func claudeSessionsAskForSuggestionsAndTheirForwarding() {
        let meta = ChatSession.claudeSessionMeta["claudeCode"]
        #expect(meta?["options"]?["promptSuggestions"]?.bool == true)
        #expect(meta?["emitRawSDKMessages"]?.array?.first?["type"]?.string == "prompt_suggestion")
    }

    // MARK: A mode, model or effort change whose request fails

    enum Change: String, CaseIterable, CustomTestStringConvertible {
        case mode, model, effort
        var testDescription: String { rawValue }
    }

    private func make(_ change: Change) {
        switch change {
        case .mode: session.setMode("plan")
        case .model: session.setModel("opus")
        case .effort: session.setEffort("high")
        }
    }

    /// An agent that never answers: `cat` echoes each request back (which
    /// reads as a request of its own) and exits when its stdin closes.
    private static func silentAgent() throws -> ACPConnection {
        let conn = ACPConnection(executable: "/bin/cat", arguments: [])
        try conn.start()
        return conn
    }

    /// Makes `change` on `conn`, waits until its request is out, runs `meanwhile`,
    /// then ends the agent and waits until the request has failed (the
    /// connection fails its requests before it finishes its stream) and the
    /// main actor has run what that resumed.
    private func makeAndFail(_ change: Change, on conn: ACPConnection, meanwhile: () -> Void = {}) async throws {
        var events = conn.incoming.makeAsyncIterator()
        make(change)
        let sent = try #require(await events.next(), "The request went out")
        guard case .request(_, let method, _) = sent else { Issue.record("Expected the echoed request, got \(sent)"); return }
        #expect(method.hasPrefix("session/set_"))
        meanwhile()
        conn.terminate()
        while await events.next() != nil {}
        await Task.yield()
    }

    @Test(arguments: Change.allCases)
    func aFailedChangeIsRolledBackWithANotice(change: Change) async throws {
        let conn = try Self.silentAgent()
        session.debugAttach(conn, sessionID: "s1")
        try await makeAndFail(change, on: conn)
        guard case .notice(_, let text, let isError)? = session.items.last else {
            Issue.record("Expected a notice, got \(session.items)"); return
        }
        #expect(isError)
        #expect(text.hasPrefix("Couldn’t"))
        #expect(session.currentMode == nil, "Back on the old mode")
        #expect(session.currentModel == nil, "Back on the old model")
    }

    /// Reloaded (or closed) while the request was out: its agent went away,
    /// which fails the request; the new session has its own mode and model.
    @Test(.tags(.edgeCase), arguments: Change.allCases)
    func aChangeThatFailsBecauseTheChatReloadedSaysNothing(change: Change) async throws {
        let conn = try Self.silentAgent()
        session.debugAttach(conn, sessionID: "s1")
        try await makeAndFail(change, on: conn) { session.debugAttach(nil, sessionID: nil) }
        #expect(session.items.isEmpty, "No notice on the reloaded chat: \(session.items)")
        switch change {
        case .mode: #expect(session.currentMode == "plan", "Nothing rolled back over the new session's mode")
        case .model: #expect(session.currentModel == "opus", "Nothing rolled back over the new session's model")
        case .effort: break
        }
    }

    @Test(arguments: [("claude", "anthropic"), ("codex", "openai"), ("gemini", "google"), ("copilot", nil), ("shell", nil)]
          as [(String, String?)])
    func eachAgentsCredentialHasItsSbxService(agent: String, service: String?) {
        let kind = AgentKind(rawValue: agent)
        #expect(ChatSession.credentialService(for: kind) == service)
        let help = ChatSession.credentialHelp(for: kind)
        if let service {
            #expect(help?.contains("sbx secret set \(service)") == true, "Says how to give sbx the credential")
            #expect(help?.hasSuffix("restart the chat.") == true, "Ends with the rebuild advice")
        } else {
            #expect(help == nil)
        }
    }
}
#endif
