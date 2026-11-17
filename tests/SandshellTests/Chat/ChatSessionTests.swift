import AppKit
#if DEBUG
import Foundation
import Testing
@testable import Sandshell

/// `ChatItem.newID` / `id(_:isOfMessage:)`: one message's items, each with its own id.
struct ChatItemMessageIDTests {
    @Test(arguments: [
        ([], "m1"),
        ([ChatItem.agentText(id: "m1", text: "a")], "m1~2"),
        ([.agentText(id: "m1", text: "a"), .agentText(id: "m1~2", text: "b")], "m1~3"),
        // A thought of the same message doesn't take a text's id.
        ([.thought(id: "m1", text: "a")], "m1"),
        // Nor does another message whose id starts the same.
        ([.agentText(id: "m10", text: "a")], "m1"),
    ])
    func aNewTextGetsTheFirstFreeID(items: [ChatItem], expected: String) {
        #expect(ChatItem.newID(forMessage: "m1", thought: false, in: items) == expected)
    }

    @Test(arguments: [("m1", true), ("m1~2", true), ("m1~12", true), ("m10", false), ("m1~", false), ("m1~x", false), ("m", false)])
    func anIDIsItsMessagesOnlyWithANumberedSuffix(id: String, isOfM1: Bool) {
        #expect(ChatItem.id(id, isOfMessage: "m1") == isOfM1)
    }
}

/// `ChatSession`: folding the agent's `session/update`s into transcript items
/// (on a chat that's never started), and what it says about credentials.
@MainActor
struct ChatSessionTests {
    /// A chat that never launches anything; its paths are never touched.
    private let session = ChatSession(title: "Claude", containerName: "test-sandbox", workdir: "/nonexistent/work",
                                      home: "/nonexistent/home")

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

    /// Claude's "I'll read A" → tool → "and B" in one API message: one
    /// messageId, two items, each with its own id (a view keyed by id would
    /// otherwise show only the second).
    @Test(arguments: [false, true])
    func oneMessageOnBothSidesOfAToolCallIsTwoItemsWithTheirOwnIDs(thought: Bool) {
        session.debugApply(Self.chunk("I'll read A", thought: thought, messageID: "m1"))
        session.debugApply(Self.toolCall("t1"))
        session.debugApply(Self.chunk("and", thought: thought, messageID: "m1"))
        session.debugApply(Self.chunk(" B", thought: thought, messageID: "m1"))
        session.debugApply(Self.toolCall("t2"))
        session.debugApply(Self.chunk("done", thought: thought, messageID: "m1"))
        let make: (String, String) -> ChatItem = { thought ? .thought(id: $0, text: $1) : .agentText(id: $0, text: $1) }
        #expect(session.items.filter { if case .tool = $0 { false } else { true } }
                == [make("m1", "I'll read A"), make("m1~2", "and B"), make("m1~3", "done")])
        #expect(Set(session.items.map(\.id)).count == session.items.count)
    }

    @Test func aTurnFollowedFromAnotherAppKeepsEachTextsOwnID() {
        let read = ChatItem.ToolCall(id: "t1", title: "Read A", kind: "read", status: "pending", output: "", diffs: [])
        session.applyExternal(.init(events: [.text(messageID: "m1", "I'll read A"), .toolUse(read),
                                             .text(messageID: "m1", "and B"), .text(messageID: "m1", "and C")],
                                    sawConversation: true))
        let texts = session.items.compactMap { if case .agentText(let id, let t) = $0 { (id, t) } else { nil } }
        #expect(texts.map(\.0) == ["ext-m1", "ext-m1~2"])
        #expect(texts.map(\.1) == ["I'll read A", "and B\n\nand C"])
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
            if service == "anthropic" { #expect(help?.contains("--oauth") == false, "sbx's OAuth secret is OpenAI's only") }
        } else {
            #expect(help == nil)
        }
    }

    // MARK: The running turn's plan

    private static func plan(_ statuses: [String]) -> JSONValue {
        ["sessionUpdate": "plan",
         "entries": .array(statuses.enumerated().map {
             ["content": .string("Step \($0.offset + 1)"), "status": .string($0.element), "priority": "medium"]
         })]
    }

    @Test func aPlanSetDuringATurnIsTheTurnsPlan() {
        var reported: [PlanProgress?] = []
        session.onPlanProgress = { reported.append($0) }
        session.debugSetPhase(.running)
        session.debugApply(Self.plan(["completed", "in_progress", "pending"]))
        #expect(session.turnPlan?.map(\.status) == ["completed", "in_progress", "pending"])
        session.debugApply(Self.plan(["completed", "completed", "in_progress"]))
        #expect(reported.map { $0?.compact } == ["1/3", "2/3"])
        // One card in the transcript, updated in place.
        #expect(session.items.count { if case .plan = $0 { true } else { false } } == 1)

        session.debugSetPhase(.ready)
        #expect(session.turnPlan == nil, "The turn's plan goes when it ends")
        #expect(reported.last == .some(nil), "and the row hears it's gone")
    }

    @Test func aPlanOutsideATurnOnlyGoesInTheTranscript() {
        // A resumed conversation's history replays while it starts.
        session.debugApply(Self.plan(["completed", "pending"]))
        #expect(session.turnPlan == nil)
        #expect(session.items.contains { if case .plan = $0 { true } else { false } })
    }

    @Test func aNewTurnStartsWithoutTheLastOnesPlan() {
        session.debugSetPhase(.running)
        session.debugApply(Self.plan(["in_progress"]))
        session.debugSetPhase(.ready)
        session.debugSetPhase(.running)
        #expect(session.turnPlan == nil)
    }
}
#endif

/// A chat's transcript: the Remote Control web page in its transcript-only
/// mode (`ChatWebTranscript`).
@MainActor
struct ChatWebTranscriptTests {
    private let session = ChatSession(title: "Claude", containerName: "test-sandbox", workdir: "/nonexistent/work",
                                      home: "/nonexistent/home")

    private func chunk(_ text: String, messageID: String) -> JSONValue {
        ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(text)], "messageId": .string(messageID)]
    }

    private func showing(size: NSSize = NSSize(width: 700, height: 600)) async throws -> (ChatWebTranscript, NSWindow) {
        // A started chat: one still starting (replaying its history) has its items held.
        session.debugSetPhase(.ready)
        let web = ChatWebTranscript(source: session)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: 0), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        web.frame = window.contentView!.bounds
        window.contentView!.addSubview(web)
        window.orderFrontRegardless()
        let end = Date().addingTimeInterval(10)
        while !web.isReady, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        try #require(web.isReady, "The page loaded and said it's ready")
        return (web, window)
    }

    private func transcript(_ web: ChatWebTranscript, contains text: String) async throws -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if await web.debugTranscriptText().contains(text) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func thePageShowsTheChatAndFollowsIt() async throws {
        session.debugApply(chunk("Hello from the agent", messageID: "m1"))
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        #expect(try await transcript(web, contains: "Hello from the agent"), "The state")
        session.debugApply(chunk("And then some more", messageID: "m2"))
        #expect(try await transcript(web, contains: "And then some more"), "A patch")
    }

    @Test func aRunsLineStaysPutUntilItSaysSomethingElse() async throws {
        session.debugApply(chunk("Looking around", messageID: "m1"))
        session.debugApply(["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "git status", "kind": "execute",
                            "status": "in_progress"])
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        func line() async throws -> String? {
            try await web.webView.evaluateJavaScript(
                "(() => { const l = document.querySelector('.tool-group'); return l ? (l.dataset.mark || '') + '|' + l.textContent : null })()") as? String
        }
        let end = Date().addingTimeInterval(5)
        while try await line() == nil, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        _ = try await web.webView.evaluateJavaScript("document.querySelector('.tool-group').dataset.mark = 'same'; true")
        session.debugApply(chunk("Still going", messageID: "m2"))
        #expect(try await transcript(web, contains: "Still going"))
        #expect(try await line()?.hasPrefix("same|Running") == true, "a patch elsewhere leaves the line as it was")
        session.debugApply(["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"])
        let later = Date().addingTimeInterval(5)
        while try await line()?.hasPrefix("same|") == true, Date() < later { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try await line()?.hasPrefix("|Ran") == true, "the call finished: a new line that says so")
        #expect(try await web.webView.evaluateJavaScript("document.querySelectorAll('.tool-group').length") as? Int == 1)
    }

    @Test func aStreamingReplyRendersTheSameAsAWholeOne() async throws {
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        let reply = "First paragraph.\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\n1. one\n2. two\n\n> quoted\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nLast *one*."
        var rest = Substring(reply)
        while !rest.isEmpty {
            session.debugApply(chunk(String(rest.prefix(9)), messageID: "stream"))
            rest = rest.dropFirst(9)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(try await transcript(web, contains: "Last one."))
        try await Task.sleep(for: .milliseconds(300))
        let same = try await web.webView.evaluateJavaScript("""
            (() => {
              const id = [...state.items.values()].find(i => i.kind === "text" && (i.text || "").includes("Last *one*")).id;
              const c = state.nodes.get(id).cloneNode(true);
              c.querySelectorAll('.actions').forEach(b => b.remove());
              c.querySelectorAll('.code').forEach(w => { w.querySelector('button')?.remove(); w.replaceWith(...w.childNodes); });
              c.querySelectorAll('a.file').forEach(a => a.replaceWith(...a.childNodes));
              return c.innerHTML === markdown(state.items.get(id).text);
            })()
            """) as? Bool
        #expect(same == true, "rendered in pieces as it came, it's what the whole reply renders to")
    }

    @Test func aLongChatStartsAtItsLatestAndShowsTheRestWhenAsked() async throws {
        let count = ChatWebTranscript.initialItems + 20
        for i in 0..<count { session.debugApply(chunk("Message \(i) here", messageID: "long\(i)")) }
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        #expect(try await transcript(web, contains: "Message \(count - 1) here"))
        let first = await web.debugTranscriptText()
        #expect(!first.contains("Message 0 here"), "the earliest wait")
        #expect(first.contains("Show 20 Earlier Messages"))
        _ = try await web.webView.evaluateJavaScript("document.querySelector('.show-earlier').click(); true")
        #expect(try await transcript(web, contains: "Message 0 here"), "asked for, they come")
        #expect(web.showsEarlier)
    }

    @Test func aMessagesPastedImageShowsAsAPicture() async throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try #require(rep.representation(using: .png, properties: [:]))
        session.debugAddMessage("Look at this", attachments: [ChatAttachment(kind: .image(data: png, mimeType: "image/png", name: "Pasted image.png"))])
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        #expect(try await transcript(web, contains: "Look at this"))
        let end = Date().addingTimeInterval(5)
        var width = 0
        while width == 0, Date() < end {
            width = try await web.webView.evaluateJavaScript("document.querySelector('.chips .thumb')?.naturalWidth || 0") as? Int ?? 0
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(width == 300, "the picture, loaded from the chat")
    }

    @Test func aHiddenChatSkipsUpdatesAndCatchesUpWhenShown() async throws {
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        web.isHidden = true
        session.debugApply(chunk("Written while hidden", messageID: "m3"))
        try await Task.sleep(for: .milliseconds(400))
        #expect(web.missedUpdates, "not rendered while nobody could see it")
        #expect(!(await web.debugTranscriptText().contains("Written while hidden")))
        web.isHidden = false
        #expect(try await transcript(web, contains: "Written while hidden"), "shown again: it catches up")
        #expect(!web.missedUpdates)
    }

    /// The page's items: id and text (a thought's body, a tool's title).
    private func pageItems(_ web: ChatWebTranscript) async throws -> [String] {
        let js = """
            [...document.querySelectorAll('#transcript > .item')].map(n => {
              const c = n.cloneNode(true);
              c.querySelectorAll('.actions, button').forEach(b => b.remove());
              return n.dataset.id + '|' + (c.querySelector('.body') || c.querySelector('.title') || c).textContent.trim();
            })
            """
        return try await web.webView.evaluateJavaScript(js) as? [String] ?? []
    }

    /// What the page should show: every item, in order, with its text.
    private func expectedItems() -> [String] {
        RemoteWire.items(session.items, session: session.ownSessionID).map { item in
            let text = item.text ?? item.tool?.title ?? item.plan.map { "Plan" + $0.map(\.content).joined() } ?? ""
            return item.id + "|" + text.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Waits for the page to settle on what the chat has.
    private func settles(_ web: ChatWebTranscript) async throws -> (page: [String], chat: [String]) {
        let end = Date().addingTimeInterval(5)
        var page: [String] = []
        while Date() < end {
            page = try await pageItems(web)
            if page == expectedItems() { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return (page, expectedItems())
    }

    /// A Claude turn at streaming speed, many times over: thinking, text, a
    /// tool and its updates, text after it in the same message, a plan. At
    /// each pause the page must show exactly the chat's items and their text.
    @Test(.timeLimit(.minutes(2)))
    func aLongStreamedChatShowsEveryItemsText() async throws {
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        var rng = SystemRandomNumberGenerator()
        func pause() async throws { try await Task.sleep(for: .milliseconds(Int.random(in: 0...12, using: &rng))) }
        func stream(_ words: String, mid: String, thought: Bool = false) async throws {
            for word in words.split(separator: " ") {
                session.debugApply(["sessionUpdate": .string(thought ? "agent_thought_chunk" : "agent_message_chunk"),
                                    "content": ["type": "text", "text": .string(word + " ")], "messageId": .string(mid)])
                try await pause()
            }
        }
        for round in 0..<12 {
            let mid = "msg_\(round)"
            try await stream("Thinking about round \(round) and what to do next here", mid: mid, thought: true)
            try await stream("Round \(round): I'll read the first file and then the second one", mid: mid)
            let tool = "toolu_\(round)"
            session.debugApply(["sessionUpdate": "tool_call", "toolCallId": .string(tool), "title": .string("Read file \(round)"),
                                "kind": "read", "status": "pending"])
            try await pause()
            session.debugApply(["sessionUpdate": "tool_call_update", "toolCallId": .string(tool), "status": "in_progress"])
            try await pause()
            try await stream("and also round \(round) has a second look", mid: mid)
            session.debugApply(["sessionUpdate": "tool_call_update", "toolCallId": .string(tool), "status": "completed",
                                "content": [["type": "content", "content": ["type": "text", "text": "line one\nline two"]]]])
            session.debugApply(["sessionUpdate": "plan", "entries": [["content": .string("Step \(round)"), "status": "in_progress"]]])
            try await stream("Done with round \(round) and everything looks fine", mid: "msg_\(round)_end")
            if round % 3 == 2 {
                let (page, chat) = try await settles(web)
                let missing = chat.filter { !page.contains($0) }, extra = page.filter { !chat.contains($0) }
                if page != chat {
                    Issue.record("Round \(round), \(page.count) on the page, \(chat.count) in the chat. Missing: \(missing). Extra: \(extra)")
                }
                if page != chat { return }
            }
        }
    }

    /// A page that missed a patch (or couldn't apply one) asks for the state
    /// and shows the chat again, instead of staying wrong.
    @Test func aPageThatLostItsPlaceCatchesUp() async throws {
        session.debugApply(chunk("First reply", messageID: "m1"))
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        #expect(try await transcript(web, contains: "First reply"))
        // As if a patch went missing: the page is at a revision the Mac isn't.
        _ = try await web.webView.evaluateJavaScript("state.rev = -1; true")
        session.debugApply(chunk("Second reply", messageID: "m2"))
        let (page, chat) = try await settles(web)
        #expect(page == chat)
        // And one that throws while applying.
        _ = try await web.webView.evaluateJavaScript("window.__render = renderItem; renderItem = () => { throw new Error('boom') }; true")
        session.debugApply(chunk("Third reply", messageID: "m3"))
        try await Task.sleep(for: .milliseconds(300))
        _ = try await web.webView.evaluateJavaScript("renderItem = window.__render; true")
        session.debugApply(chunk(" and more", messageID: "m3"))
        let (after, now) = try await settles(web)
        #expect(after == now)
    }

    /// A resume replaying its history: the page keeps what it shows and gets
    /// the result once (as the native transcript does), not every step of it.
    @Test func aReplayIsShownOnceItsDone() async throws {
        session.debugApply(chunk("Before the replay", messageID: "m1"))
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        #expect(try await transcript(web, contains: "Before the replay"))
        session.debugSetPhase(.starting)
        session.debugApply(chunk("Replayed", messageID: "m2"))
        try await Task.sleep(for: .milliseconds(400))
        let held = try await pageItems(web)
        #expect(held == ["text-m1|Before the replay"], "Held while starting")
        session.debugSetPhase(.ready)
        let (page, chat) = try await settles(web)
        #expect(page == chat)
    }

    /// The page is the conversation alone: the window has the composer and cards.
    @Test func itShowsTheTranscriptAlone() async throws {
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        #expect(await web.debugRun("""
            return ['composer', 'cards'].every(id => getComputedStyle(document.getElementById(id)).display === 'none')
              && getComputedStyle(document.querySelector('#chat-pane > .bar')).display === 'none'
            """) == true)
        // Chat commands aren't the transcript's to send.
        #expect(await web.debugRun("return (await tellMac('cancel', {})).status === 200") != true)
    }

    /// Copy, Fork and Undo reach the window; a file link opens the file.
    @Test func itsButtonsReachTheWindow() async throws {
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        var forked: String?, undone: String?, opened: (URL, Int?)?
        web.onFork = { forked = $0 }
        web.onUndo = { undone = $0 }
        web.onOpenFile = { opened = ($0, $1) }
        web.pasteboard = NSPasteboard(name: NSPasteboard.Name("com.xmas.sandshell.test-\(UUID().uuidString)"))
        defer { web.pasteboard.releaseGlobally() }
        session.debugApply(chunk("The **answer**.", messageID: "m1"))
        session.debugApply(["sessionUpdate": "session_info_update", "_meta": ["jetbrains": ["air": ["agentFileChangeReport": [
            "status": "reported", "requestId": "turn-1", "paths": ["a.txt"]]]]]])
        #expect(try await transcript(web, contains: "The answer."))
        _ = await web.debugRun("document.querySelector('.item.text .act-copy').click(); return true")
        #expect(await until { web.pasteboard.string(forType: .string) == "The **answer**." }, "Copy: the reply's Markdown")
        _ = await web.debugRun("document.querySelector('.item.text .act-fork').click(); return true")
        #expect(await until { forked == "The **answer**." })
        if session.items.contains(where: { if case .fileChanges = $0 { true } else { false } }) {
            _ = await web.debugRun("document.querySelector('.act-undo')?.click(); return true")
            #expect(await until { undone == "turn-1" })
        }
        _ = await web.debugRun("return (await tellMac('openFile', {path: '/tmp/x.swift', line: 7})).status === 200")
        #expect(await until { opened?.0 == URL(filePath: "/tmp/x.swift") && opened?.1 == 7 })
    }

    /// The page's type is the app's: its three sizes come from `TypeRole`, and
    /// no rule names another (bar a glyph or two and the pairing code).
    @Test func thePageUsesTheAppsThreeSizes() async throws {
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        let sizes = ChatWebTranscript.Sizes.app
        func px(_ v: CGFloat) -> String { String(format: "%gpx", Double(v)) }
        let tokens = "const s = getComputedStyle(document.documentElement); return ['--t-small', '--t-ui', '--t-read'].map(n => s.getPropertyValue(n).trim())"
        #expect(await until { await web.debugValue(tokens) as? [String] == [px(sizes.small), px(sizes.ui), px(sizes.reading)] })
        let literals = """
            const out = new Set();
            for (const sheet of document.styleSheets) for (const rule of sheet.cssRules) {
              const walk = r => { if (r.cssRules) [...r.cssRules].forEach(walk);
                const v = r.style?.getPropertyValue('font-size'); if (v && !v.includes('var(') && v !== 'inherit') out.add(v); };
              walk(rule);
            }
            return [...out].sort();
            """
        let found = await web.debugValue(literals) as? [String]
        #expect(found == ["15px", "1em", "26px"],
                "Only the glyphs (26, 15), the pairing code (26) and headings at the text's own size: \(String(describing: found))")
        session.debugApply(chunk("A reply.", messageID: "m1"))
        #expect(try await transcript(web, contains: "A reply."))
        let reply = await web.debugValue("return getComputedStyle(document.querySelector('.item.text')).fontSize") as? String
        #expect(reply == px(sizes.reading))
    }

    /// A long message of yours shows its first lines, More for the rest; a
    /// short one is shown whole.
    @Test func aLongMessageOfYoursStartsFolded() async throws {
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        let long = (1...30).map { "Line \($0) of what I pasted" }.joined(separator: "\n")
        session.debugApply(["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": .string(long)]])
        session.debugApply(chunk("Got it.", messageID: "m1"))
        session.debugApply(["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "Thanks"]])
        #expect(try await transcript(web, contains: "Thanks"))
        let shape = """
            return [...document.querySelectorAll('.item.user .bubble')].map(b => {
              const said = b.querySelector('.said');
              return [b.classList.contains('folded'), said.scrollHeight > said.clientHeight + 1,
                      b.querySelector('.more')?.textContent ?? ''].join('|');
            })
            """
        #expect(await until { await web.debugValue(shape) as? [String] == ["true|true|More", "false|false|"] },
                "The long one folded with More, the short one whole")
        _ = await web.debugRun("document.querySelector('.bubble .more').click(); return true")
        #expect(await web.debugValue(shape) as? [String] == ["false|false|Less", "false|false|"], "More shows all of it")
        // It stays open as the chat goes on.
        session.debugApply(chunk("Anything else?", messageID: "m2"))
        #expect(try await transcript(web, contains: "Anything else?"))
        #expect(await web.debugValue(shape) as? [String] == ["false|false|Less", "false|false|"])
        _ = await web.debugRun("document.querySelector('.bubble .more').click(); return true")
        #expect(await web.debugValue(shape) as? [String] == ["true|true|More", "false|false|"], "Less folds it again")
        #expect(await web.debugTranscriptText().contains("Line 30 of what I pasted"), "Folded, the text is all there (Copy, find)")
    }

    /// A question card's buttons (a phone's): labelled, and they answer.
    @Test func aQuestionCardsButtonsWork() async throws {
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        let label = await web.debugValue("let hit = false; const b = button('Skip', '', () => { hit = true }); b.click(); return b.textContent + '|' + hit")
        #expect(label as? String == "Skip|true")
    }

    /// Paths the Mac finds on disk become links; others don't.
    @Test func fileLinksComeFromTheMac() async throws {
        let dir = URL.temporaryDirectory.appending(path: "sandshell-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "src"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appending(path: "src/app.swift"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        web.workdir = dir.path
        session.debugApply(chunk("Look at src/app.swift:12 and src/nope.swift.", messageID: "m1"))
        let found = await until(timeout: 5) {
            await web.debugValue("return [...document.querySelectorAll('a.file')].map(a => a.textContent + '|' + a.dataset.line)") as? [String]
                == ["src/app.swift|12"]
        }
        #expect(found)
    }

    /// Resizing the window while replies stream in, again and again: the page
    /// ends up with every item, each with its text, and paints it.
    @Test(.timeLimit(.minutes(2)))
    func resizingWhileStreamingLosesNoText() async throws {
        let (web, window) = try await showing()
        defer { window.orderOut(nil); window.close() }
        let sizes = [NSSize(width: 700, height: 600), NSSize(width: 360, height: 300), NSSize(width: 1400, height: 900),
                     NSSize(width: 520, height: 1200)]
        for round in 0..<6 {
            for (n, word) in "Round \(round) streams in word by word while the window keeps changing size".split(separator: " ").enumerated() {
                session.debugApply(chunk(String(word) + " ", messageID: "r\(round)"))
                window.setContentSize(sizes[(round + n) % sizes.count])
                try await Task.sleep(for: .milliseconds(Int.random(in: 0...15)))
            }
            session.debugApply(["sessionUpdate": "tool_call", "toolCallId": .string("t\(round)"), "title": .string("Read file \(round)"),
                                "kind": "read", "status": "completed"])
        }
        window.setContentSize(NSSize(width: 700, height: 600))
        let (page, chat) = try await settles(web)
        #expect(page == chat)
        // And painted: the end of the conversation, on screen, isn't blank.
        _ = await web.debugRun("document.getElementById('transcript').scrollTop = 1e9; return true")
        try await Task.sleep(for: .milliseconds(200))
        let shot = try await web.webView.takeSnapshot(configuration: nil)
        let rep = try #require(shot.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var inked = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5,
                   abs(c.brightnessComponent - 0.5) > 0.2 { inked += 1 }
            }
        }
        #expect(inked > 50, "text painted on screen (\(inked) inked samples)")
    }

    private func until(timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }
}

/// `FileLinks`: what in a chat's text names a file on this Mac.
struct FileLinksTests {
    private let files: Set<String> = ["/w/src/app.swift", "/w/My Folder/Read Me.txt", "/usr/bin/git", "/w/docs/notes.md"]

    private func find(_ text: String, code: [String] = []) -> [FileLinks.Link] {
        FileLinks.find(in: text, code: code, workdir: "/w") { files.contains($0) }
    }

    @Test func relativeAndAbsolutePathsThatExist() {
        let links = find("See src/app.swift:12, /usr/bin/git and src/missing.swift.")
        #expect(links == [FileLinks.Link(text: "src/app.swift", path: "/w/src/app.swift", line: 12),
                          FileLinks.Link(text: "/usr/bin/git", path: "/usr/bin/git", line: nil)])
    }

    @Test func urlsArentFiles() {
        #expect(find("https://example.com/docs/notes.md").isEmpty)
    }

    @Test(arguments: [
        ("In `My Folder/Read Me.txt:3` it says", ["My Folder/Read Me.txt:3"], "My Folder/Read Me.txt", 3),
        ("Quoted \"My Folder/Read Me.txt\" too", [], "My Folder/Read Me.txt", nil),
        ("Bare /w/My Folder/Read Me.txt, done", [], "/w/My Folder/Read Me.txt", nil),
        ("Escaped My\\ Folder/Read\\ Me.txt here", [], "My\\ Folder/Read\\ Me.txt", nil),
    ] as [(String, [String], String, Int?)])
    func pathsWithSpaces(text: String, code: [String], link: String, line: Int?) {
        let found = find(text, code: code)
        #expect(found.contains { $0.text == link && $0.path == "/w/My Folder/Read Me.txt" && $0.line == line }, "\(found)")
    }

    @Test func eachPathOnce() {
        #expect(find("docs/notes.md and docs/notes.md again").count == 1)
    }

    @Test func noFolderNoLinks() {
        #expect(FileLinks.find(in: "src/app.swift", workdir: "") { _ in true }.isEmpty)
    }
}


/// `ChatEmptyFact.facts`: what the empty chat says about where the agent works.
struct ChatEmptyFactTests {
    private static let system = SandboxSystem(probeOutput: "kernel=7.0.14\narch=aarch64\ndistro=Ubuntu 26.04.1 LTS\nmemkb=9332260")
    private static func git(branch: String?, changed: Int) -> GitStatus {
        GitStatus(repoRoot: "/r", branch: branch,
                  changes: Dictionary(uniqueKeysWithValues: (0..<changed).map { ("/r/f\($0)", .modified) }))
    }

    @Test func aRunningChatInARepoSaysAllFour() throws {
        let facts = ChatEmptyFact.facts(folder: "/r", access: .readWrite, git: Self.git(branch: "main", changed: 1),
                                        sandbox: "claude-r", system: Self.system, phase: .ready, mode: "Ask before edits")
        #expect(facts.map(\.id) == ["folder", "branch", "sandbox", "mode"])
        #expect(facts[0].detail == "Shared read-write")
        #expect(facts[1].title == "main")
        #expect(facts[1].detail == "1 file changed")
        #expect(facts[2].status == .running)
        let memory = try #require(Self.system?.memory)
        #expect(facts[2].detail == "Running · Ubuntu 26.04 · \(memory)")
        #expect(facts[3].title == "Ask before edits")
    }

    @Test func untilGitAnswersOrOutsideARepoThereIsNoBranch() {
        for git in [nil, GitStatus.empty] {
            let facts = ChatEmptyFact.facts(folder: "/r", access: nil, git: git, sandbox: "s", system: nil,
                                            phase: .starting, mode: nil)
            #expect(facts.map(\.id) == ["folder", "sandbox"])
        }
    }

    @Test(arguments: [(0, "No changes"), (1, "1 file changed"), (5, "5 files changed")])
    func theBranchCountsChangedFiles(changed: Int, detail: String) {
        let facts = ChatEmptyFact.facts(folder: "/r", access: .readOnly, git: Self.git(branch: "dev", changed: changed),
                                        sandbox: "s", system: nil, phase: .ready, mode: nil)
        #expect(facts.first { $0.id == "branch" }?.detail == detail)
    }

    @Test func aDetachedHeadSaysSo() {
        let facts = ChatEmptyFact.facts(folder: "/r", access: nil, git: Self.git(branch: nil, changed: 0),
                                        sandbox: "s", system: nil, phase: .ready, mode: nil)
        let branch = facts.first { $0.id == "branch" }
        #expect(branch?.title == "Detached HEAD")
        #expect(branch?.code == false)
    }

    @Test(arguments: [(ChatSession.Phase.starting, ChatEmptyFact.Status.starting, "Starting…"),
                      (.running, .running, "Running"),
                      (.closed("gone"), .stopped, "Stopped")])
    func theSandboxSaysWhereTheChatIs(phase: ChatSession.Phase, status: ChatEmptyFact.Status, detail: String) {
        let sandbox = ChatEmptyFact.facts(folder: "/r", access: nil, git: nil, sandbox: "s", system: nil,
                                          phase: phase, mode: nil).first { $0.id == "sandbox" }
        #expect(sandbox?.status == status)
        #expect(sandbox?.detail == detail)
    }

    @Test func aStartingSandboxDoesNotClaimItsSystemYet() {
        let sandbox = ChatEmptyFact.facts(folder: "/r", access: nil, git: nil, sandbox: "s", system: Self.system,
                                          phase: .starting, mode: nil).first { $0.id == "sandbox" }
        #expect(sandbox?.detail == "Starting…")
    }

    @Test func theFolderIsAbbreviatedAndSaysHowItIsShared() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let facts = ChatEmptyFact.facts(folder: home + "/Code/x", access: .notShared, git: nil, sandbox: "s",
                                        system: nil, phase: .ready, mode: nil)
        #expect(facts[0].title == "~/Code/x")
        #expect(facts[0].detail == "Not shared with the sandbox")
    }
}

/// `ChatTips`: the empty chat's tips, for the first few chats only.
struct ChatTipsTests {
    @Test func theTipsShowForTheFirstFewChatsThenStop() throws {
        let suite = "ChatTipsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tips = ChatTips(defaults: defaults)
        for _ in 0..<ChatTips.chats {
            #expect(tips.showing)
            tips.chatStarted()
        }
        #expect(!tips.showing)
        tips.chatStarted()
        #expect(defaults.integer(forKey: ChatTips.key) == ChatTips.chats, "the count stops at the limit")
    }
}

/// `SeaField`: the stir under the pointer, and the colors it refracts into.
struct SeaFieldTests {
    @Test func theStirIsMostUnderThePointerAndSettles() {
        #expect(SeaField.stirred(100, by: nil) == 0)
        #expect(SeaField.stirred(100, by: (x: 100, age: 0)) == 1)
        #expect(SeaField.stirred(150, by: (x: 100, age: 0)) < SeaField.stirred(110, by: (x: 100, age: 0)))
        #expect(SeaField.stirred(100, by: (x: 100, age: 3)) < 0.01)
    }

    @Test func farFromThePointerTheSpectrumLiesOnTheWater() {
        let stir = (x: 100.0, age: 0.0)
        let water = SeaField.level(500, time: 3, speed: 0.9, phase: 0, stir: stir)
        for split in [-1.0, 1] {
            #expect(abs(SeaField.level(500, time: 3, speed: 0.9, phase: 0, stir: stir, split: split) - water) < 0.01)
            #expect(SeaField.level(100, time: 3, speed: 0.9, phase: 0, stir: stir, split: split)
                    != SeaField.level(100, time: 3, speed: 0.9, phase: 0, stir: stir))
        }
    }

    @Test(arguments: [0.0, 10, 20, 30, 40])
    func theColorsStayInTheSea(time: Double) {
        for u in stride(from: 0.0, through: 1, by: 0.25) {
            #expect((0.4...0.7).contains(SeaField.hue(at: u, time: time, lift: 0)))
        }
    }
}

/// `!` and `&` in the composer: a line that's a command you run yourself —
/// `!` in the session's sandbox, `&` on the Mac — not a message to the agent.
@MainActor
struct LocalCommandTests {
    typealias Command = ChatSession.LocalCommand

    @Test(arguments: [
        ("!ls -la", Command.sandbox("ls -la")),
        ("  ! swift test  ", .sandbox("swift test")),
        ("&xcodegen generate", .mac("xcodegen generate")),
        ("& git push", .mac("git push")),
    ])
    func aLineStartingWithASigilIsACommand(text: String, command: Command) {
        #expect(ChatSession.localCommand(text) == command)
    }

    @Test(arguments: ["hello", "!", "&", "  &  ", "what about !this", "a & b"])
    func anythingElseIsAMessage(text: String) {
        #expect(ChatSession.localCommand(text) == nil)
    }

    @Test func theAgentIsToldWhatRanWhereAndItsOutput() {
        let said = ChatSession.commandContext(.sandbox("swift test"), status: 1, output: "1 test failed")
        #expect(said.contains("`swift test` in the sandbox (exit 1)") && said.contains("1 test failed"))
        let long = ChatSession.commandContext(.mac("yes"), status: 0, output: String(repeating: "y\n", count: 20_000))
        #expect(long.count < ChatSession.commandContextLimit + 200, "only the end of a long output")
    }

    @Test func aMacCommandWithNoMacFolderSaysWhyAndRunsNothing() throws {
        let dir = URL.temporaryDirectory.appending(path: "sandshell-commands-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = ChatSession(title: "Claude", containerName: "test-sandbox", workdir: "/nonexistent/work",
                                  home: "/nonexistent/home")
        session.commandLog = CommandLog(url: dir.appending(path: "commands.log"))
        #expect(session.submit(text: "&echo hi", attachments: []))
        guard case .tool(let card)? = session.items.last else { Issue.record("a card for it"); return }
        #expect(card.title == "& echo hi" && card.status == "failed")
        #expect(card.output.contains("only from Sandshell's window"))
        #expect(session.commandLog.entries().isEmpty, "nothing ran, nothing to audit")
    }

    /// A `&` command run in a temp folder, its card watched until `done`.
    private func runOnMac(_ command: String, until done: (ChatItem.ToolCall) -> Bool,
                          then act: ((ChatSession) -> Void)? = nil) async throws -> ChatItem.ToolCall {
        let dir = URL.temporaryDirectory.appending(path: "sandshell-commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = ChatSession(title: "Claude", containerName: "test-sandbox", workdir: "/nonexistent/work",
                                  home: "/nonexistent/home")
        session.commandLog = CommandLog(url: dir.appending(path: "commands.log"))
        session.macFolder = dir.path(percentEncoded: false)
        #expect(session.run(.mac(command)))
        act?(session)
        let end = Date.now.addingTimeInterval(10)
        while Date.now < end {
            if case .tool(let card)? = session.items.last, done(card) { return card }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out waiting on the card")
        throw CancellationError()
    }

    /// A flood of output fills the card to its limit, no more, and the command
    /// still finishes (the rest read and dropped, not left in a full pipe).
    @Test func aFloodOfOutputStopsAtTheLimit() async throws {
        let card = try await runOnMac("head -c 3000000 /dev/zero | tr '\\0' y", until: { $0.status != "in_progress" })
        #expect(card.status == "completed")
        #expect(card.output.utf8.count == ChatSession.commandOutputLimit)
    }

    /// Closing the chat ends a command still running (`& npm run dev`).
    @Test func closingTheChatEndsItsCommands() async throws {
        let started = Date.now
        let card = try await runOnMac("sleep 30", until: { $0.status != "in_progress" }) { session in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { session.close() }
        }
        #expect(card.status == "failed", "terminated")
        #expect(Date.now.timeIntervalSince(started) < 5)
    }

    @Test func theCommandLogKeepsOneLineAnEntryForYouAlone() throws {
        let dir = URL.temporaryDirectory.appending(path: "sandshell-commands-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = CommandLog(url: dir.appending(path: "Logs/commands.log"))
        log.record(["event": "ran", "sigil": "&", "command": "git push\nrm -rf x", "folder": "/Users/me/a b"])
        log.record(["event": "exited", "status": 0])
        let entries = log.entries()
        try #require(entries.count == 2)
        #expect(entries[0]["command"]?.string == "git push\nrm -rf x", "a multi-line command stays one entry")
        #expect(entries[0]["time"]?.string != nil && entries[0]["app"]?.string != nil)
        #expect(entries[1]["event"]?.string == "exited")
        let mode = try FileManager.default.attributesOfItem(atPath: log.url!.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func noCommandLogWritesNothing() {
        let log = CommandLog(url: nil)
        log.record(["event": "ran"])
        #expect(log.entries().isEmpty && log.created() == nil)
    }

    @Test func aPairedDeviceCantRunCommandsOnTheMac() {
        let session = ChatSession(title: "Claude", containerName: "test-sandbox", workdir: "/nonexistent/work",
                                  home: "/nonexistent/home")
        #expect(throws: RemoteHub.CommandError.self) { try RemoteHub.send(session, text: "&rm -rf ~", images: []) }
        #expect(session.items.isEmpty, "nothing ran, nothing shown")
    }
}

/// `ACPConnection` hears its process exit even when something it started
/// still holds its pipes (sbx's daemon, started by an `sbx exec`).
struct ACPConnectionExitTests {
    @Test func anExitIsHeardThoughAChildHoldsThePipes() async throws {
        // The background sleep keeps stdout and stderr open after the shell exits.
        let conn = ACPConnection(executable: "/bin/sh", arguments: ["-c", "echo '{\"jsonrpc\":\"2.0\",\"method\":\"hi\"}'; sleep 8 & exit 3"])
        try conn.start()
        let started = Date.now
        var saw: [String] = []
        var status: Int32?
        for await event in conn.incoming {
            switch event {
            case .notification(let method, _): saw.append(method)
            case .closed(let s): status = s
            default: break
            }
        }
        #expect(status == 3)
        #expect(saw == ["hi"], "what it wrote before exiting still arrives")
        #expect(Date.now.timeIntervalSince(started) < 5, "not after the child lets go (8 s)")
    }

    @Test func aRequestFailsWhenTheProcessExitsUnderAHeldPipe() async throws {
        let conn = ACPConnection(executable: "/bin/sh", arguments: ["-c", "sleep 8 & sleep 0.3; exit 0"])
        try conn.start()
        await #expect(throws: ACPConnection.RPCError.self) {
            _ = try await conn.request("initialize", [:])
        }
    }
}

/// The agent's stdout, read a line at a time (`ACPConnection.readLines`).
struct ACPLineReaderTests {
    @Test(.timeLimit(.minutes(1)))
    func linesComeWholeHoweverTheyArrive() async throws {
        let pipe = Pipe()
        let big = String(repeating: "x", count: 300_000)
        let pieces = ["a\nb", "b\n", String(big.prefix(70_000)), String(big.dropFirst(70_000)), "\n\nlast"]
        let writer = pipe.fileHandleForWriting
        let written = Task.detached {
            for piece in pieces {
                writer.write(Data(piece.utf8))
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? writer.close()
        }
        let fd = pipe.fileHandleForReading.fileDescriptor
        let lines = await Task.detached { () -> [String] in
            var out: [String] = []
            ACPConnection.readLines(fd: fd) { out.append(String(decoding: $0, as: UTF8.self)) }
            return out
        }.value
        await written.value
        #expect(lines.map(\.count) == [1, 2, 300_000, 4], "split lines joined, the empty one skipped, the last without its newline")
        #expect(lines.first == "a" && lines.last == "last")
    }
}
