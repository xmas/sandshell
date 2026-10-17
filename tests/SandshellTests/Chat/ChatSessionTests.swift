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
