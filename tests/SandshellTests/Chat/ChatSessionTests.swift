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
        #expect(await web.debugRun("return (await post('cancel', {})).status === 200") != true)
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
        _ = await web.debugRun("return (await post('openFile', {path: '/tmp/x.swift', line: 7})).status === 200")
        #expect(await until { opened?.0 == URL(filePath: "/tmp/x.swift") && opened?.1 == 7 })
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

