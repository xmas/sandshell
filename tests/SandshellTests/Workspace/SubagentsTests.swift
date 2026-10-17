import Foundation
import Testing
@testable import Sandshell

extension Tag {
    /// Boundaries and malformed input in the subagent scanner.
    @Tag static var subagentsEdgeCase: Self
}

/// `SubagentInfo` and `SubagentScanner` (Sandshell/Workspace/Subagents.swift).
struct SubagentsTests {}

// MARK: - SubagentInfo

extension SubagentsTests {
    struct InfoState {
        @Test(arguments: [
            (SubagentInfo.State.running, true),
            (SubagentInfo.State.done, false),
            (SubagentInfo.State.failed, false),
            (SubagentInfo.State.stopped, false),
        ])
        func isRunningOnlyWhileRunning(state: SubagentInfo.State, expected: Bool) {
            let info = SubagentInfo(id: "a1", sessionID: UUID(), title: "Explore", agentType: "Explore",
                                    transcript: URL(filePath: "/nonexistent/session/subagents/agent-a1.jsonl"),
                                    startedAt: SubagentsFixture.epoch, lastWrite: SubagentsFixture.epoch, state: state)
            #expect(info.isRunning == expected)
        }
    }
}

// MARK: - scan(sessionID:transcript:known:now:)

extension SubagentsTests {
    struct Scanning {
        struct TitleCase: Sendable, CustomTestStringConvertible {
            /// The `agent-<id>.meta.json` contents; nil writes no meta file.
            let meta: String?
            let title: String
            let agentType: String?
            var testDescription: String { meta.map { $0.isEmpty ? "empty meta file" : $0 } ?? "no meta file" }
        }

        private let workspace: SubagentsWorkspace
        private let sessionID = UUID()

        init() throws {
            workspace = try SubagentsWorkspace()
        }

        private func scan(known: [String: BackgroundTask.State] = [:],
                          now: Date = SubagentsFixture.epoch) -> [SubagentInfo] {
            SubagentScanner.scan(sessionID: sessionID, transcript: workspace.transcript, known: known, now: now)
        }

        @Test func missingSubagentsFolderGivesNoSubagents() {
            #expect(scan().isEmpty)
        }

        @Test func emptySubagentsFolderGivesNoSubagents() throws {
            try workspace.makeSubagentsFolder()
            #expect(scan().isEmpty)
        }

        @Test func onlyAgentTranscriptsAreListed() throws {
            try workspace.addSubagent("a1", meta: SubagentsFixture.meta(["agentType": "Explore"]))
            let line = SubagentsFixture.jsonl([SubagentsFixture.unfinishedLine])
            for name in ["notes.jsonl", "agent-b2.txt", "xagent-c3.jsonl", "agent-d4.JSONL", "agent-e5.jsonl.bak"] {
                try workspace.addFile(named: name, contents: line)
            }
            #expect(scan().map(\.id) == ["a1"],
                    "Only agent-<id>.jsonl files are subagent transcripts, not their .meta.json or anything else")
        }

        @Test(arguments: [
            ("agent-abc123.jsonl", "abc123"),
            ("agent-a.b.jsonl", "a.b"),
            ("agent-agent-x.jsonl", "agent-x"),
            ("agent-.jsonl", ""),
        ])
        func idIsTheNameBetweenPrefixAndExtension(fileName: String, expectedID: String) throws {
            try workspace.addFile(named: fileName, contents: SubagentsFixture.jsonl([SubagentsFixture.unfinishedLine]))
            #expect(scan().map(\.id) == [expectedID])
        }

        @Test func subagentPointsAtItsTranscriptAndSession() throws {
            let url = try workspace.addSubagent("a1")
            let info = try #require(scan().first)
            #expect(info.sessionID == sessionID)
            #expect(info.transcript.path == url.path)
        }

        @Test func subagentsFolderBesideTheTranscriptIsIgnored() throws {
            let beside = workspace.root.appendingPathComponent("subagents", isDirectory: true)
            try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: true)
            try workspace.writeFile(named: "agent-a1.jsonl", contents: SubagentsFixture.jsonl([SubagentsFixture.unfinishedLine]),
                                    in: beside)
            #expect(scan().isEmpty, "Subagents live under <session>/subagents, not next to <session>.jsonl")
        }

        @Test(arguments: [
            TitleCase(meta: #"{"description":"Find the flaky test","agentType":"Explore"}"#,
                      title: "Find the flaky test", agentType: "Explore"),
            TitleCase(meta: #"{"description":"  Trim me\n ","agentType":"Explore"}"#,
                      title: "Trim me", agentType: "Explore"),
            TitleCase(meta: #"{"description":" \n\t ","agentType":"Plan"}"#,
                      title: "Plan", agentType: "Plan"),
            TitleCase(meta: #"{"description":"","agentType":"Plan"}"#,
                      title: "Plan", agentType: "Plan"),
            TitleCase(meta: #"{"agentType":"general-purpose"}"#,
                      title: "general-purpose", agentType: "general-purpose"),
            TitleCase(meta: #"{"description":"Only a description"}"#,
                      title: "Only a description", agentType: nil),
            TitleCase(meta: #"{"description":42,"agentType":7}"#,
                      title: "Subagent", agentType: nil),
            TitleCase(meta: "{}", title: "Subagent", agentType: nil),
            TitleCase(meta: "not json", title: "Subagent", agentType: nil),
            TitleCase(meta: #"["Explore"]"#, title: "Subagent", agentType: nil),
            TitleCase(meta: "", title: "Subagent", agentType: nil),
            TitleCase(meta: nil, title: "Subagent", agentType: nil),
        ])
        func titleComesFromTheMetaFile(_ testCase: TitleCase) throws {
            try workspace.addSubagent("a1", meta: testCase.meta)
            let info = try #require(scan().first)
            #expect(info.title == testCase.title)
            #expect(info.agentType == testCase.agentType)
        }

        @Test(.tags(.subagentsEdgeCase), arguments: ["", "   "])
        func blankAgentTypeWithoutDescriptionFallsBackToSubagent(agentType: String) throws {
            try workspace.addSubagent("a1", meta: SubagentsFixture.meta(["agentType": agentType]))
            let info = try #require(scan().first)
            withKnownIssue("""
                Subagents.swift:47 drops a blank description but uses agentType as the title without the same \
                check, so a blank agentType gives the sidebar row a blank title instead of "Subagent"
                """) {
                #expect(info.title == "Subagent")
            }
        }

        @Test func eachSubagentReadsItsOwnMetaFile() throws {
            try workspace.addSubagent("a1", meta: SubagentsFixture.meta(["description": "Map the codebase", "agentType": "Explore"]))
            try workspace.addSubagent("b2", meta: SubagentsFixture.meta(["description": "Draft a plan", "agentType": "Plan"]))
            let titles = Dictionary(uniqueKeysWithValues: scan().map { ($0.id, $0.title) })
            #expect(titles == ["a1": "Map the codebase", "b2": "Draft a plan"])
        }

        @Test func datesComeFromTheTranscriptFile() throws {
            let created = SubagentsFixture.epoch
            let modified = created.addingTimeInterval(42)
            try workspace.addSubagent("a1", created: created, modified: modified)
            let info = try #require(scan(now: modified).first)
            #expect(info.startedAt == created, "Started when its transcript was created")
            #expect(info.lastWrite == modified, "Last wrote when its transcript was modified")
        }

        @Test func subagentsAreListedOldestFirst() throws {
            let epoch = SubagentsFixture.epoch
            try workspace.addSubagent("b-newest", created: epoch.addingTimeInterval(20), modified: epoch.addingTimeInterval(25))
            try workspace.addSubagent("a-middle", created: epoch.addingTimeInterval(10), modified: epoch.addingTimeInterval(60))
            try workspace.addSubagent("c-oldest", created: epoch, modified: epoch.addingTimeInterval(5))
            #expect(scan().map(\.id) == ["c-oldest", "a-middle", "b-newest"],
                    "Sorted by start time, not by name or by last write")
        }

        @Test(arguments: [
            (BackgroundTask.State.completed, SubagentInfo.State.done),
            (BackgroundTask.State.failed, SubagentInfo.State.failed),
            (BackgroundTask.State.stopped, SubagentInfo.State.stopped),
        ])
        func knownFinalStateWinsOverALiveLookingTranscript(known: BackgroundTask.State,
                                                           expected: SubagentInfo.State) throws {
            let modified = SubagentsFixture.epoch
            try workspace.addSubagent("a1", lines: [SubagentsFixture.unfinishedLine], created: modified, modified: modified)
            let info = try #require(scan(known: ["a1": known], now: modified.addingTimeInterval(5)).first)
            #expect(info.state == expected, "Unfinished and written 5s ago would otherwise read as running")
        }

        @Test func knownRunningWinsOverAFinishedStaleTranscript() throws {
            let modified = SubagentsFixture.epoch
            try workspace.addSubagent("a1", lines: [SubagentsFixture.finishedLine], created: modified, modified: modified)
            let info = try #require(scan(known: ["a1": .running], now: modified.addingTimeInterval(3_600)).first)
            #expect(info.state == .running, "Finished and an hour old would otherwise read as done")
        }

        @Test func knownStateOfAnotherSubagentDoesNotApply() throws {
            let modified = SubagentsFixture.epoch
            try workspace.addSubagent("a1", lines: [SubagentsFixture.finishedLine], created: modified, modified: modified)
            let info = try #require(scan(known: ["someone-else": .running], now: modified.addingTimeInterval(5)).first)
            #expect(info.state == .done, "A known state applies only to the subagent with that id")
        }

        @Test func finishedTranscriptIsDoneEvenWhenJustWritten() throws {
            let modified = SubagentsFixture.epoch
            try workspace.addSubagent("a1", lines: [SubagentsFixture.userLine, SubagentsFixture.finishedLine],
                                      created: modified, modified: modified)
            let info = try #require(scan(now: modified).first)
            #expect(info.state == .done, "An ended turn means done without waiting out the 90s quiet period")
        }

        @Test(.tags(.subagentsEdgeCase), arguments: [
            (0.0, SubagentInfo.State.running),
            (45.0, SubagentInfo.State.running),
            (90.0, SubagentInfo.State.running),
            (91.0, SubagentInfo.State.done),
            (3_600.0, SubagentInfo.State.done),
            (-120.0, SubagentInfo.State.running),
        ])
        func unfinishedTranscriptRunsUntilNinetySecondsAfterItsLastWrite(age: TimeInterval,
                                                                       expected: SubagentInfo.State) throws {
            let modified = SubagentsFixture.epoch
            try workspace.addSubagent("a1", lines: [SubagentsFixture.unfinishedLine], created: modified, modified: modified)
            let info = try #require(scan(now: modified.addingTimeInterval(age)).first)
            #expect(info.state == expected, "\(age)s after its last write")
        }

        @Test func justStartedSubagentWithAnEmptyTranscriptIsRunning() throws {
            let modified = SubagentsFixture.epoch
            try workspace.addSubagent("a1", lines: [], created: modified, modified: modified)
            let info = try #require(scan(now: modified.addingTimeInterval(1)).first)
            #expect(info.state == .running, "No assistant message yet and written 1s ago")
        }
    }
}

// MARK: - finished(_:)

extension SubagentsTests {
    struct FinishedDetection {
        private let workspace: SubagentsWorkspace

        init() throws {
            workspace = try SubagentsWorkspace()
        }

        private func transcript(_ lines: [String]) throws -> URL {
            try workspace.writeFile(named: "agent-a1.jsonl", contents: SubagentsFixture.jsonl(lines))
        }

        @Test func missingFileIsNotFinished() {
            let url = workspace.root.appendingPathComponent("missing.jsonl")
            #expect(SubagentScanner.finished(url) == false)
        }

        @Test func emptyFileIsNotFinished() throws {
            let url = try transcript([])
            #expect(SubagentScanner.finished(url) == false)
        }

        @Test(arguments: ["end_turn", "stop_sequence", "max_tokens", "refusal", "model_context_window_exceeded"])
        func terminalStopReasonMeansFinished(stopReason: String) throws {
            let url = try transcript([SubagentsFixture.userLine, SubagentsFixture.assistantLine(stopReason: stopReason)])
            #expect(SubagentScanner.finished(url))
        }

        @Test(arguments: ["tool_use", "pause_turn", ""])
        func otherStopReasonsMeanStillWorking(stopReason: String) throws {
            let url = try transcript([SubagentsFixture.userLine, SubagentsFixture.assistantLine(stopReason: stopReason)])
            #expect(SubagentScanner.finished(url) == false)
        }

        @Test(arguments: [SubagentsFixture.lineWithoutStopReason, SubagentsFixture.assistantLine(stopReason: nil)])
        func missingOrNullStopReasonMeansStillWorking(line: String) throws {
            let url = try transcript([SubagentsFixture.userLine, line])
            #expect(SubagentScanner.finished(url) == false)
        }

        @Test func onlyTheLastAssistantMessageCounts() throws {
            let url = try transcript([SubagentsFixture.finishedLine, SubagentsFixture.userLine, SubagentsFixture.unfinishedLine])
            #expect(SubagentScanner.finished(url) == false, "An earlier end_turn doesn't count once the agent is working again")
        }

        @Test(.tags(.subagentsEdgeCase))
        func linesAfterTheLastAssistantMessageAreSkipped() throws {
            let url = try transcript([
                SubagentsFixture.unfinishedLine,
                SubagentsFixture.finishedLine,
                SubagentsFixture.userLine,
                #"{"type":"system","subtype":"informational"}"#,
                "not json",
                #"{"type":"assistant","message":"not an object"}"#,
                #"{"type":"assistant"}"#,
            ])
            #expect(SubagentScanner.finished(url), "User, system, unparsable and message-less lines are passed over")
        }

        @Test func transcriptWithoutAssistantMessagesIsNotFinished() throws {
            let url = try transcript([SubagentsFixture.userLine, SubagentsFixture.userLine])
            #expect(SubagentScanner.finished(url) == false)
        }

        @Test func lastLineWithoutTrailingNewlineIsRead() throws {
            let url = try workspace.writeFile(named: "agent-a1.jsonl",
                                              contents: SubagentsFixture.userLine + "\n" + SubagentsFixture.finishedLine)
            #expect(SubagentScanner.finished(url))
        }

        @Test(.tags(.subagentsEdgeCase), arguments: [16_383, 16_384, 16_385, 100_000])
        func finalLineIsFoundWhereverTheTailWindowStarts(fileSize: Int) throws {
            let tail = SubagentsFixture.finishedLine + "\n"
            let paddingSize = fileSize - tail.utf8.count
            try #require(paddingSize > 1)
            let padding = String(repeating: "x", count: paddingSize - 1) + "\n"
            let url = try workspace.writeFile(named: "agent-a1.jsonl", contents: padding + tail)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try #require((attributes[.size] as? NSNumber)?.intValue == fileSize)
            #expect(SubagentScanner.finished(url))
        }

        @Test(.tags(.subagentsEdgeCase))
        func finalAssistantMessageLongerThanTheTailWindowCountsAsFinished() throws {
            let report = String(repeating: "a", count: 20_000)
            let url = try transcript([SubagentsFixture.userLine,
                                      SubagentsFixture.assistantLine(stopReason: "end_turn", text: report)])
            withKnownIssue("""
                finished(_:) reads only the last 16 KiB (Subagents.swift:58), so a final assistant line longer \
                than that is cut mid-JSON and skipped: a subagent that ended its turn with a long report reads \
                as unfinished (and scan() shows it running until 90s after its last write)
                """) {
                #expect(SubagentScanner.finished(url))
            }
        }
    }
}

// MARK: - items(_:)

extension SubagentsTests {
    struct TranscriptItems {
        private let workspace: SubagentsWorkspace

        init() throws {
            workspace = try SubagentsWorkspace()
        }

        @Test func missingFileGivesNoItems() {
            #expect(SubagentScanner.items(workspace.root.appendingPathComponent("missing.jsonl")).isEmpty)
        }

        @Test func emptyFileGivesNoItems() throws {
            let url = try workspace.writeFile(named: "agent-a1.jsonl", contents: "")
            #expect(SubagentScanner.items(url).isEmpty)
        }

        @Test func subagentTranscriptBecomesChatItems() throws {
            // Every line of a subagent's own transcript is a sidechain.
            let lines = [
                #"{"type":"user","isSidechain":true,"agentId":"a1","message":{"role":"user","content":"Find the TODOs"}}"#,
                #"{"type":"assistant","isSidechain":true,"agentId":"a1","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Searching."}],"stop_reason":null}}"#,
                #"{"type":"assistant","isSidechain":true,"agentId":"a1","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Grep","input":{"pattern":"TODO"}}],"stop_reason":"tool_use"}}"#,
                #"{"type":"user","isSidechain":true,"agentId":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"a.swift:3"}]}}"#,
                #"{"type":"assistant","isSidechain":true,"agentId":"a1","message":{"id":"msg_2","role":"assistant","content":[{"type":"text","text":"One TODO, in a.swift."}],"stop_reason":"end_turn"}}"#,
            ]
            let url = try workspace.writeFile(named: "agent-a1.jsonl", contents: SubagentsFixture.jsonl(lines))

            let items = SubagentScanner.items(url)

            try #require(items.count == 4, "The prompt, two replies and one tool call (sidechain lines included)")
            let prompt = try #require(SubagentsFixture.userMessage(items[0]))
            #expect(prompt.text == "Find the TODOs")
            let grep = ChatItem.ToolCall(id: "toolu_1", title: "Grep TODO", kind: "grep", status: "completed",
                                         output: "a.swift:3", diffs: [], input: "TODO")
            #expect(Array(items.dropFirst()) == [
                .agentText(id: "msg_1", text: "Searching."),
                .tool(grep),
                .agentText(id: "msg_2", text: "One TODO, in a.swift."),
            ])
        }
    }
}

// MARK: - items(from:)

extension SubagentsTests {
    struct EventFolding {
        private func fold(_ events: [ClaudeTranscriptTail.Event]) -> [ChatItem] {
            SubagentScanner.items(from: events)
        }

        @Test func noEventsGiveNoItems() {
            #expect(fold([]).isEmpty)
        }

        @Test func promptBecomesAUserItemWithoutAttachments() throws {
            let items = fold([.user("Find the flaky test")])
            try #require(items.count == 1)
            let user = try #require(SubagentsFixture.userMessage(items[0]))
            #expect(user.text == "Find the flaky test")
            #expect(user.attachments.isEmpty)
        }

        @Test func eachPromptGetsItsOwnID() throws {
            let items = fold([.user("one"), .user("two")])
            try #require(items.count == 2)
            let first = try #require(SubagentsFixture.userMessage(items[0]))
            let second = try #require(SubagentsFixture.userMessage(items[1]))
            #expect(first.text == "one")
            #expect(second.text == "two")
            #expect(first.id != second.id)
        }

        @Test func textOfOneMessageIsJoinedIntoOneReply() {
            let items = fold([
                .text(messageID: "m1", "First."),
                .text(messageID: "m1", "Second."),
                .text(messageID: "m1", "Third."),
            ])
            #expect(items == [.agentText(id: "m1", text: "First.\n\nSecond.\n\nThird.")])
        }

        @Test func textOfDifferentMessagesStaysSeparate() {
            let items = fold([.text(messageID: "m1", "First."), .text(messageID: "m2", "Second.")])
            #expect(items == [.agentText(id: "m1", text: "First."), .agentText(id: "m2", text: "Second.")])
        }

        @Test func textIsOnlyJoinedOntoTheItemRightBeforeIt() {
            let call = SubagentsFixture.toolCall(id: "t1")
            let items = fold([.text(messageID: "m1", "Before."), .toolUse(call), .text(messageID: "m1", "After.")])
            #expect(items == [.agentText(id: "m1", text: "Before."), .tool(call), .agentText(id: "m1", text: "After.")])
        }

        @Test func thoughtsAreNeverJoinedAndAreNumberedByPosition() {
            let items = fold([
                .text(messageID: "m0", "Hi."),
                .thought(messageID: "m1", "Hmm."),
                .thought(messageID: "m1", "Aha."),
            ])
            #expect(items == [
                .agentText(id: "m0", text: "Hi."),
                .thought(id: "m1-1", text: "Hmm."),
                .thought(id: "m1-2", text: "Aha."),
            ])
        }

        @Test func textAfterAThoughtStartsANewReply() {
            let items = fold([.thought(messageID: "m1", "Hmm."), .text(messageID: "m1", "Answer.")])
            #expect(items == [.thought(id: "m1-0", text: "Hmm."), .agentText(id: "m1", text: "Answer.")])
        }

        @Test func toolUseIsAddedAsIs() {
            let call = SubagentsFixture.toolCall(id: "t1")
            #expect(fold([.toolUse(call)]) == [.tool(call)])
        }

        @Test(arguments: [(false, "completed"), (true, "failed")])
        func toolResultCompletesItsCall(failed: Bool, expectedStatus: String) {
            let call = SubagentsFixture.toolCall(id: "t1")
            let image = Data([0x89, 0x50, 0x4E, 0x47])
            let items = fold([.toolUse(call), .toolResult(id: "t1", output: "a.swift\nb.swift", images: [image], failed: failed)])
            var expected = call
            expected.status = expectedStatus
            expected.output = "a.swift\nb.swift"
            expected.images = [image]
            #expect(items == [.tool(expected)], "Only status, output and images change; title, kind, diffs and input stay")
        }

        @Test func resultUpdatesTheMatchingCallInPlace() {
            let first = SubagentsFixture.toolCall(id: "t1")
            let second = SubagentsFixture.toolCall(id: "t2", title: "Read a.swift")
            let items = fold([
                .toolUse(first),
                .toolUse(second),
                .text(messageID: "m1", "Checking."),
                .text(messageID: "m1", "Still checking."),
                .toolResult(id: "t1", output: "ok", images: [], failed: false),
            ])
            var done = first
            done.status = "completed"
            done.output = "ok"
            #expect(items == [.tool(done), .tool(second), .agentText(id: "m1", text: "Checking.\n\nStill checking.")])
        }

        @Test(.tags(.subagentsEdgeCase))
        func resultForAnUnknownCallIsIgnored() {
            let call = SubagentsFixture.toolCall(id: "t1")
            let items = fold([.toolUse(call), .toolResult(id: "zzz", output: "stray", images: [], failed: true)])
            #expect(items == [.tool(call)], "A result whose id matches no call changes nothing")
        }

        @Test(.tags(.subagentsEdgeCase))
        func resultBeforeItsCallIsIgnored() {
            let call = SubagentsFixture.toolCall(id: "t1")
            let items = fold([.toolResult(id: "t1", output: "early", images: [], failed: false), .toolUse(call)])
            #expect(items == [.tool(call)], "The call stays in progress")
        }

        @Test(.tags(.subagentsEdgeCase))
        func laterResultForTheSameCallWins() {
            let call = SubagentsFixture.toolCall(id: "t1")
            let items = fold([
                .toolUse(call),
                .toolResult(id: "t1", output: "first try", images: [Data([1])], failed: true),
                .toolResult(id: "t1", output: "second try", images: [], failed: false),
            ])
            var expected = call
            expected.status = "completed"
            expected.output = "second try"
            expected.images = []
            #expect(items == [.tool(expected)])
        }
    }
}

// MARK: - Fixtures

fileprivate enum SubagentsFixture {
    /// A whole-second date, so it survives the round trip through file timestamps exactly.
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static let userLine = #"{"type":"user","message":{"role":"user","content":"Keep going"}}"#
    static let finishedLine = assistantLine(stopReason: "end_turn")
    static let unfinishedLine = assistantLine(stopReason: "tool_use")
    static let lineWithoutStopReason =
        #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Thinking it over."}]}}"#

    /// An assistant transcript line; a nil `stopReason` writes `null`. `text` must need no JSON escaping.
    static func assistantLine(stopReason: String?, text: String = "Done.") -> String {
        let stop = stopReason.map { "\"\($0)\"" } ?? "null"
        return #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"\#(text)"}],"stop_reason":\#(stop)}}"#
    }

    /// JSONL: each line newline-terminated.
    static func jsonl(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    /// An `agent-<id>.meta.json` body.
    static func meta(_ fields: [String: String]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }

    static func toolCall(id: String, title: String = "Bash swift test") -> ChatItem.ToolCall {
        ChatItem.ToolCall(id: id, title: title, kind: "bash", status: "in_progress", output: "",
                          diffs: [ChatItem.Diff(path: "a.swift", oldText: "old", newText: "new")],
                          input: "swift test")
    }

    static func userMessage(_ item: ChatItem?) -> (id: UUID, text: String, attachments: [String])? {
        guard case .user(let id, let text, let attachments)? = item else { return nil }
        return (id, text, attachments)
    }
}

/// A fresh temporary folder holding a session transcript path (`session.jsonl`) and,
/// on demand, its `session/subagents/` folder; removed when the owning test ends.
fileprivate final class SubagentsWorkspace: Sendable {
    let root: URL
    let transcript: URL
    let subagentsFolder: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandshellSubagentsTests-\(UUID().uuidString)", isDirectory: true)
        transcript = root.appendingPathComponent("session.jsonl")
        subagentsFolder = root.appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeSubagentsFolder() throws {
        try FileManager.default.createDirectory(at: subagentsFolder, withIntermediateDirectories: true)
    }

    /// Writes `contents` to `name` in `folder` (default: the root).
    @discardableResult
    func writeFile(named name: String, contents: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? root).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Writes `contents` to `name` in the subagents folder.
    @discardableResult
    func addFile(named name: String, contents: String) throws -> URL {
        try makeSubagentsFolder()
        return try writeFile(named: name, contents: contents, in: subagentsFolder)
    }

    /// `agent-<id>.jsonl` (plus `agent-<id>.meta.json` when `meta` is given), with its
    /// creation and modification dates set when given (creation first, so it stays the earlier).
    @discardableResult
    func addSubagent(_ id: String, lines: [String] = [SubagentsFixture.unfinishedLine], meta: String? = nil,
                     created: Date? = nil, modified: Date? = nil) throws -> URL {
        let url = try addFile(named: "agent-\(id).jsonl", contents: SubagentsFixture.jsonl(lines))
        if let meta {
            try addFile(named: "agent-\(id).meta.json", contents: meta)
        }
        if let created {
            try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        }
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }
}
