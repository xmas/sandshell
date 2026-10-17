import Foundation
import Testing
@testable import Sandshell

extension Tag {
    /// Inputs at the edges of what the transcript tail handles: partial or
    /// malformed lines, odd read offsets, missing fields.
    @Tag fileprivate static var tailEdgeCase: Self
    /// Tests that read and write real files in their own scratch directory.
    @Tag fileprivate static var tailFileSystem: Self
}

/// `ClaudeTranscriptTail`: turning lines another client appended to a Claude
/// transcript into chat events, and reading those lines off disk.
struct ClaudeTranscriptTailTests {}

// MARK: - Which lines count

extension ClaudeTranscriptTailTests {
    struct LineSelection {
        @Test(arguments: ["", "\n", "\n\n\n"])
        func emptyTextReadsNothing(text: String) {
            expectTailBatchIsEmpty(ClaudeTranscriptTail.parse(text))
        }

        @Test(.tags(.tailEdgeCase), arguments: [
            "not json at all",
            "[1, 2, 3]",
            #""just a string""#,
            #"{"type":"user","message":{"role":"user","content":"truncated"}"#,
            #"{"type":"system","subtype":"turn_duration","message":{"content":"x"}}"#,
            #"{"type":"summary","summary":"Fixing the build"}"#,
            #"{"type":"attachment","message":{"role":"user","content":"hello"}}"#,
            #"{"message":{"role":"user","content":"no type"}}"#,
            #"{"type":"user"}"#,
            #"{"type":"user","message":"not an object"}"#,
            #"{"type":"assistant","message":["not","an","object"]}"#,
        ])
        func nonConversationLinesAreIgnored(line: String) {
            expectTailBatchIsEmpty(ClaudeTranscriptTail.parse(line))
        }

        @Test(.tags(.tailEdgeCase))
        func malformedAndBlankLinesDoNotHideLaterOnes() {
            let text = "garbage\n\n\n" + TailLine.prompt("hello") + "\n\n"
            let batch = ClaudeTranscriptTail.parse(text)
            #expect(batch.events == [.user("hello")])
            #expect(batch.sawConversation)
        }

        @Test func sidechainLinesAreSkippedByDefault() {
            let text = TailLine.file([
                TailLine.assistant([TailBlock.text("from a subagent")], id: "sub", fields: [TailField.sidechain]),
                TailLine.assistant([TailBlock.text("from the session")], id: "main"),
            ])
            let batch = ClaudeTranscriptTail.parse(text)
            #expect(batch.events == [.text(messageID: "main", "from the session")])
        }

        @Test func onlySidechainLinesSeeNoConversation() {
            let line = TailLine.prompt("subagent task", fields: [TailField.sidechain, TailField.entrypoint("cli")])
            expectTailBatchIsEmpty(ClaudeTranscriptTail.parse(line))
        }

        @Test func sidechainsModeReadsSubagentLines() {
            let text = TailLine.file([
                TailLine.prompt("Find the config", fields: [TailField.sidechain]),
                TailLine.assistant([TailBlock.text("Found it.")], id: "sub", stop: "end_turn", fields: [TailField.sidechain]),
            ])
            let batch = ClaudeTranscriptTail.parse(text, sidechains: true)
            #expect(batch.events == [.user("Find the config"), .text(messageID: "sub", "Found it.")])
            #expect(batch.working == false)
        }

        @Test func lineMarkedAsMainChainIsRead() {
            let batch = ClaudeTranscriptTail.parse(TailLine.prompt("hello", fields: [TailField.mainChain]))
            #expect(batch.events == [.user("hello")])
        }

        @Test func skippedWritersLinesAreIgnoredEntirely() {
            let text = TailLine.file([
                TailLine.prompt("my own prompt", fields: [TailField.entrypoint("sdk-ts")]),
                TailLine.assistant([TailBlock.text("my own reply")], stop: "end_turn", fields: [TailField.entrypoint("sdk-ts")]),
            ])
            expectTailBatchIsEmpty(ClaudeTranscriptTail.parse(text, skippingEntrypoint: "sdk-ts"))
        }

        @Test func otherWritersAreReadWhileSkippingOne() {
            let text = TailLine.file([
                TailLine.prompt("mine", fields: [TailField.entrypoint("sdk-ts")]),
                TailLine.prompt("theirs", fields: [TailField.entrypoint("cli")]),
                TailLine.prompt("unattributed"),
            ])
            let batch = ClaudeTranscriptTail.parse(text, skippingEntrypoint: "sdk-ts")
            #expect(batch.events == [.user("theirs"), .user("unattributed")])
            #expect(batch.entrypoint == "cli", "a line without an entrypoint keeps the last writer")
        }

        @Test func writerIsReadWhenNothingIsSkipped() {
            let batch = ClaudeTranscriptTail.parse(TailLine.prompt("hi", fields: [TailField.entrypoint("sdk-ts")]))
            #expect(batch.events == [.user("hi")])
            #expect(batch.entrypoint == "sdk-ts")
        }

        @Test func latestWriterWins() {
            let text = TailLine.file([
                TailLine.prompt("one", fields: [TailField.entrypoint("cli")]),
                TailLine.prompt("two", fields: [TailField.entrypoint("claude-desktop")]),
                TailLine.prompt("three"),
            ])
            #expect(ClaudeTranscriptTail.parse(text).entrypoint == "claude-desktop")
        }

        /// The fixture the app's own self-test uses: prompts, replies and
        /// tools, with wrappers, meta lines and subagent lines left out.
        @Test func followsAConversationWrittenElsewhere() {
            let text = [
                #"{"type":"user","message":{"role":"user","content":"hello there"},"entrypoint":"claude-desktop"}"#,
                #"{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"[Image #1]"}]}}"#,
                #"{"type":"user","message":{"role":"user","content":"<task-notification>x</task-notification>"}}"#,
                #"{"type":"assistant","message":{"id":"m1","content":[{"type":"thinking","thinking":"","signature":"s"}],"stop_reason":"tool_use"}}"#,
                #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la"}}],"stop_reason":"tool_use"}}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a\nb","is_error":false}]}}"#,
                #"{"type":"assistant","isSidechain":true,"message":{"id":"m9","content":[{"type":"text","text":"subagent"}]}}"#,
                #"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"}}"#,
            ].joined(separator: "\n")

            let batch = ClaudeTranscriptTail.parse(text)

            let bash = ChatItem.ToolCall(id: "t1", title: "Bash ls -la", kind: "bash", status: "in_progress",
                                         output: "", diffs: [], input: "ls -la")
            #expect(batch.events == [
                .user("hello there"),
                .toolUse(bash),
                .toolResult(id: "t1", output: "a\nb", images: [], failed: false),
                .text(messageID: "m2", "Done."),
            ])
            #expect(batch.sawConversation)
            #expect(batch.working == false, "the last line ended the turn")
            #expect(batch.entrypoint == "claude-desktop")
        }
    }
}

// MARK: - Turn state

extension ClaudeTranscriptTailTests {
    struct TurnState {
        /// A nil stop reason leaves the key out, as a line still streaming does.
        @Test(arguments: [
            ("end_turn", false),
            ("stop_sequence", false),
            ("max_tokens", false),
            ("tool_use", true),
            ("pause_turn", true),
            (nil, true),
        ] as [(String?, Bool)])
        func stopReasonDecidesWhetherTheWriterIsWorking(stopReason: String?, working: Bool) {
            let line = TailLine.assistant([TailBlock.text("ok")], stop: stopReason)
            #expect(ClaudeTranscriptTail.parse(line).working == working)
        }

        @Test(.tags(.tailEdgeCase))
        func nullStopReasonMeansStillWorking() {
            let line = #"{"type":"assistant","message":{"id":"m","content":[{"type":"text","text":"streaming"}],"stop_reason":null}}"#
            #expect(ClaudeTranscriptTail.parse(line).working == true)
        }

        @Test(arguments: [
            TailLine.prompt("Go on"),
            TailLine.prompt("<command-name>/clear</command-name>"),
            TailLine.user(blocks: [TailBlock.toolResult(content: tailJSON("ok"))]),
        ])
        func anyUserLineMeansWorking(line: String) {
            #expect(ClaudeTranscriptTail.parse(line).working == true)
        }

        @Test(arguments: [
            (TailLine.file([TailLine.prompt("go"), TailLine.assistant([TailBlock.text("done")], stop: "end_turn")]), false),
            (TailLine.file([TailLine.assistant([TailBlock.text("done")], stop: "end_turn"), TailLine.prompt("again")]), true),
            (TailLine.file([TailLine.assistant([], stop: "end_turn"), TailLine.assistant([], stop: "tool_use")]), true),
            (TailLine.file([TailLine.assistant([], stop: "tool_use"), TailLine.assistant([], stop: "end_turn")]), false),
        ])
        func lastLineDecidesTheTurnState(text: String, working: Bool) {
            #expect(ClaudeTranscriptTail.parse(text).working == working)
        }

        @Test(.tags(.tailEdgeCase), arguments: ["refusal", "model_context_window_exceeded"])
        func refusalOrAFullContextEndsTheTurn(stopReason: String) {
            let line = TailLine.assistant([TailBlock.text("I can't help with that.")], stop: stopReason)
            #expect(ClaudeTranscriptTail.parse(line).working == false)
        }
    }
}

// MARK: - Assistant content

extension ClaudeTranscriptTailTests {
    struct AssistantContent {
        @Test func textBlocksBecomeTextEvents() {
            let line = TailLine.assistant([TailBlock.text("First."), TailBlock.text("Second.")], id: "msg_A", stop: "end_turn")
            let batch = ClaudeTranscriptTail.parse(line)
            #expect(batch.events == [.text(messageID: "msg_A", "First."), .text(messageID: "msg_A", "Second.")])
            #expect(batch.sawConversation)
        }

        @Test func thinkingBecomesAThought() {
            let line = TailLine.assistant([TailBlock.thinking("Checking the tests first.")], id: "msg_T")
            #expect(ClaudeTranscriptTail.parse(line).events == [.thought(messageID: "msg_T", "Checking the tests first.")])
        }

        @Test func emptyTextAndRedactedThinkingShowNothing() {
            let line = TailLine.assistant([TailBlock.thinking(""), TailBlock.text("")], stop: "tool_use")
            let batch = ClaudeTranscriptTail.parse(line)
            #expect(batch.events.isEmpty)
            #expect(batch.sawConversation, "the line still counts as conversation")
            #expect(batch.working == true)
        }

        @Test func blocksKeepTheirOrder() {
            let line = TailLine.assistant([
                TailBlock.thinking("plan"),
                TailBlock.text("Running it."),
                TailBlock.toolUse(id: "t1", name: "Bash", input: #"{"command":"make"}"#),
            ], id: "m")
            let make = ChatItem.ToolCall(id: "t1", title: "Bash make", kind: "bash", status: "in_progress",
                                         output: "", diffs: [], input: "make")
            #expect(ClaudeTranscriptTail.parse(line).events == [
                .thought(messageID: "m", "plan"),
                .text(messageID: "m", "Running it."),
                .toolUse(make),
            ])
        }

        @Test(.tags(.tailEdgeCase))
        func unknownBlockTypesAreIgnored() {
            let line = TailLine.assistant([
                #"{"type":"redacted_thinking","data":"abc"}"#,
                #"{"type":"server_tool_use","id":"s1","name":"web_search"}"#,
                #"{"text":"a block without a type"}"#,
                TailBlock.text("kept"),
            ], id: "m")
            #expect(ClaudeTranscriptTail.parse(line).events == [.text(messageID: "m", "kept")])
        }

        @Test(.tags(.tailEdgeCase))
        func contentThatIsNotABlockListShowsNothing() {
            let line = #"{"type":"assistant","message":{"id":"m","content":"plain text","stop_reason":"end_turn"}}"#
            let batch = ClaudeTranscriptTail.parse(line)
            #expect(batch.events.isEmpty)
            #expect(batch.sawConversation)
            #expect(batch.working == false)
        }

        /// The message's own ID wins; without one, the line's UUID stands in.
        @Test(arguments: [
            ("msg_1", "msg_1"),
            (nil, "line-uuid-1"),
        ] as [(String?, String)])
        func messageIDComesFromTheMessageThenTheLine(messageID: String?, expected: String) {
            let line = TailLine.assistant([TailBlock.text("hi")], id: messageID, fields: [TailField.uuid("line-uuid-1")])
            #expect(ClaudeTranscriptTail.parse(line).events == [.text(messageID: expected, "hi")])
        }

        @Test(.tags(.tailEdgeCase))
        func lineWithoutAnyIDGetsAFreshOne() throws {
            let text = TailLine.file([
                TailLine.assistant([TailBlock.text("a"), TailBlock.thinking("b")], id: nil),
                TailLine.assistant([TailBlock.text("c")], id: nil),
            ])
            let ids = tailMessageIDs(ClaudeTranscriptTail.parse(text).events)
            try #require(ids.count == 3)
            #expect(ids[0] == ids[1], "blocks of one line share an ID")
            #expect(ids[0] != ids[2], "each line without an ID gets its own")
            #expect(UUID(uuidString: ids[0]) != nil, "the fallback ID is a UUID")
        }
    }
}

// MARK: - Tool uses

extension ClaudeTranscriptTailTests {
    struct ToolUses {
        @Test func toolUseBecomesAnInProgressToolCall() {
            let line = TailLine.assistant([
                TailBlock.toolUse(id: "toolu_01", name: "Bash", input: #"{"command":"ls -la","description":"List files"}"#),
            ], stop: "tool_use")
            let expected = ChatItem.ToolCall(id: "toolu_01", title: "Bash ls -la", kind: "bash", status: "in_progress",
                                             output: "", diffs: [], input: "ls -la")
            let batch = ClaudeTranscriptTail.parse(line)
            #expect(batch.events == [.toolUse(expected)])
            #expect(batch.working == true)
        }

        @Test(.tags(.tailEdgeCase))
        func toolUseWithoutAnIDIsDropped() {
            let line = TailLine.assistant([
                TailBlock.toolUse(id: nil, name: "Bash", input: #"{"command":"ls"}"#),
                TailBlock.text("after"),
            ], id: "m")
            #expect(ClaudeTranscriptTail.parse(line).events == [.text(messageID: "m", "after")])
        }

        @Test(.tags(.tailEdgeCase))
        func toolUseWithoutANameIsCalledTool() throws {
            let call = try toolCall(named: nil, input: #"{"command":"ls"}"#)
            #expect(call.title == "Tool ls")
            #expect(call.kind == "tool")
        }

        @Test func toolUseWithoutInputIsTitledByName() throws {
            let call = try toolCall(named: "TodoWrite", input: nil)
            #expect(call.title == "TodoWrite")
            #expect(call.input == "")
        }

        @Test(arguments: [
            ("Bash", "bash"),
            ("WebFetch", "webfetch"),
            ("mcp__github__create_issue", "mcp__github__create_issue"),
        ])
        func kindIsTheLowercasedName(name: String, kind: String) throws {
            #expect(try toolCall(named: name, input: nil).kind == kind)
        }

        @Test(arguments: [
            ("cd /tmp\nmake test", "Bash cd /tmp"),
            ("\nmake", "Bash make"),
        ])
        func titleShowsTheFirstLineOfInput(command: String, title: String) throws {
            let call = try toolCall(input: #"{"command":\#(tailJSON(command))}"#)
            #expect(call.title == title)
            #expect(call.input == command, "the whole input is kept")
        }

        @Test(arguments: [1, 99, 100])
        func titleIncludesInputUpTo100Characters(length: Int) throws {
            let command = String(repeating: "x", count: length)
            let call = try toolCall(input: #"{"command":\#(tailJSON(command))}"#)
            #expect(call.title == "Bash \(command)")
        }

        @Test(.tags(.tailEdgeCase), arguments: [101, 500])
        func titleLeavesOutInputLongerThan100Characters(length: Int) throws {
            let command = String(repeating: "x", count: length)
            let call = try toolCall(input: #"{"command":\#(tailJSON(command))}"#)
            #expect(call.title == "Bash")
            #expect(call.input == command, "the whole input is still kept")
        }

        @Test(arguments: [
            (#"{"command":"ls","file_path":"/a"}"#, "ls"),
            (#"{"file_path":"/a.swift","path":"/b"}"#, "/a.swift"),
            (#"{"path":"/src","pattern":"*.swift"}"#, "/src"),
            (#"{"pattern":"TODO","url":"https://example.com"}"#, "TODO"),
            (#"{"url":"https://example.com","query":"swift"}"#, "https://example.com"),
            (#"{"query":"swift testing","description":"Search"}"#, "swift testing"),
            (#"{"description":"Explore the repo","prompt":"Look around"}"#, "Explore the repo"),
            (#"{"prompt":"Summarize the diff"}"#, "Summarize the diff"),
        ])
        func inputSummaryPicksTheMostTellingField(input: String, summary: String) throws {
            let call = try toolCall(input: input)
            #expect(call.input == summary)
            #expect(call.title == "Bash \(summary)")
        }

        @Test(.tags(.tailEdgeCase), arguments: [
            (#"{"command":"","path":"/b"}"#, "/b"),
            (#"{"command":42,"path":"/b"}"#, "/b"),
            (#"{"todos":[{"content":"x"}]}"#, ""),
            ("{}", ""),
            (#""not an object""#, ""),
        ])
        func inputSummarySkipsEmptyAndNonTextFields(input: String, summary: String) throws {
            let call = try toolCall(named: "Edit", input: input)
            #expect(call.input == summary)
            #expect(call.title == (summary.isEmpty ? "Edit" : "Edit \(summary)"))
        }

        /// The one tool call an assistant line holding a single `tool_use` block becomes.
        private func toolCall(named name: String? = "Bash", input: String?,
                              sourceLocation: SourceLocation = #_sourceLocation) throws -> ChatItem.ToolCall {
            let line = TailLine.assistant([TailBlock.toolUse(id: "toolu_1", name: name, input: input)], stop: "tool_use")
            let calls = tailToolCalls(ClaudeTranscriptTail.parse(line).events)
            return try #require(calls.first, "the line holds one tool call", sourceLocation: sourceLocation)
        }
    }
}

// MARK: - User content

extension ClaudeTranscriptTailTests {
    struct UserContent {
        @Test func promptIsTrimmed() {
            let batch = ClaudeTranscriptTail.parse(TailLine.prompt("  Fix the failing test \n"))
            #expect(batch.events == [.user("Fix the failing test")])
        }

        @Test(arguments: [
            "<command-name>/clear</command-name>",
            "<task-notification>done</task-notification>",
            "  \n<system-reminder>be brief</system-reminder>",
            "",
            "   \n\t ",
        ])
        func wrappersAndBlankPromptsAreNotShown(content: String) {
            let batch = ClaudeTranscriptTail.parse(TailLine.prompt(content))
            #expect(batch.events.isEmpty)
            #expect(batch.sawConversation)
            #expect(batch.working == true)
        }

        @Test func textBlocksJoinIntoOnePrompt() {
            let line = TailLine.user(blocks: [TailBlock.text("First line"), TailBlock.text("second line")])
            #expect(ClaudeTranscriptTail.parse(line).events == [.user("First line\nsecond line")])
        }

        @Test func imagesInAPromptAreLeftOut() {
            let line = TailLine.user(blocks: [TailBlock.image(base64: "AQID"), TailBlock.text("What is this?")])
            #expect(ClaudeTranscriptTail.parse(line).events == [.user("What is this?")])
        }

        @Test func metaLinesShowNothingAndLeaveTheTurnStateAlone() {
            let text = TailLine.file([
                TailLine.user(blocks: [TailBlock.text("[Image #1]")], fields: [TailField.meta]),
                TailLine.prompt("Caveat: messages below were generated locally", fields: [TailField.meta]),
            ])
            let batch = ClaudeTranscriptTail.parse(text)
            #expect(batch.events.isEmpty)
            #expect(batch.working == nil, "a meta line leaves the turn state as it was")
            #expect(batch.sawConversation, "a meta line is still a conversation line")
        }

        @Test(arguments: [(nil, false), (false, false), (true, true)] as [(Bool?, Bool)])
        func toolResultWithTextContent(isError: Bool?, failed: Bool) {
            let line = TailLine.user(blocks: [TailBlock.toolResult(id: "toolu_1", content: tailJSON("a\nb"), isError: isError)])
            let batch = ClaudeTranscriptTail.parse(line)
            #expect(batch.events == [.toolResult(id: "toolu_1", output: "a\nb", images: [], failed: failed)])
            #expect(batch.working == true)
        }

        @Test func toolResultPartsJoinTextAndDecodeImages() {
            let content = TailBlock.list([
                TailBlock.text("line 1"),
                TailBlock.image(base64: "AQID"),
                TailBlock.text("line 2"),
            ])
            let line = TailLine.user(blocks: [TailBlock.toolResult(id: "toolu_1", content: content)])
            #expect(ClaudeTranscriptTail.parse(line).events == [
                .toolResult(id: "toolu_1", output: "line 1\nline 2", images: [Data([1, 2, 3])], failed: false),
            ])
        }

        @Test(.tags(.tailEdgeCase))
        func undecodableImagesAreDropped() {
            let content = TailBlock.list([
                TailBlock.image(base64: "%%% not base64 %%%"),
                #"{"type":"image","source":{"type":"url","url":"https://example.com/a.png"}}"#,
                #"{"type":"image"}"#,
                TailBlock.text("caption"),
            ])
            let line = TailLine.user(blocks: [TailBlock.toolResult(id: "toolu_1", content: content)])
            #expect(ClaudeTranscriptTail.parse(line).events == [
                .toolResult(id: "toolu_1", output: "caption", images: [], failed: false),
            ])
        }

        @Test(.tags(.tailEdgeCase))
        func toolResultWithoutAnIDIsDropped() {
            let line = TailLine.user(blocks: [TailBlock.toolResult(id: nil, content: tailJSON("orphan"))])
            let batch = ClaudeTranscriptTail.parse(line)
            #expect(batch.events.isEmpty)
            #expect(batch.working == true)
        }

        @Test(.tags(.tailEdgeCase))
        func toolResultWithoutContentHasNoOutput() {
            let line = TailLine.user(blocks: [TailBlock.toolResult(id: "toolu_1", content: nil)])
            #expect(ClaudeTranscriptTail.parse(line).events == [
                .toolResult(id: "toolu_1", output: "", images: [], failed: false),
            ])
        }

        @Test func toolResultsComeBeforeTheLinesText() {
            let line = TailLine.user(blocks: [
                TailBlock.text("Also, check the docs"),
                TailBlock.toolResult(id: "toolu_9", content: tailJSON("done")),
            ])
            #expect(ClaudeTranscriptTail.parse(line).events == [
                .toolResult(id: "toolu_9", output: "done", images: [], failed: false),
                .user("Also, check the docs"),
            ])
        }

        /// A prompt sent with IDE context (or a reminder) arrives as several
        /// text blocks; only the person's own text should show.
        @Test(.tags(.tailEdgeCase), arguments: [
            ["<ide_opened_file>The user opened Foo.swift in the IDE.</ide_opened_file>", "Fix the build"],
            ["Fix the build", "<system-reminder>Be brief.</system-reminder>"],
        ])
        func harnessBlocksAreFilteredOneByOne(texts: [String]) {
            let batch = ClaudeTranscriptTail.parse(TailLine.user(blocks: texts.map(TailBlock.text)))
            #expect(batch.events == [.user("Fix the build")])
            #expect(batch.working == true)
        }

        @Test(.tags(.tailEdgeCase))
        func lineOfOnlyHarnessBlocksHasNoPrompt() {
            let texts = ["<ide_opened_file>Foo.swift</ide_opened_file>", "  ", "<system-reminder>Be brief.</system-reminder>"]
            let batch = ClaudeTranscriptTail.parse(TailLine.user(blocks: texts.map(TailBlock.text)))
            #expect(batch.events.isEmpty)
            #expect(batch.working == true, "It's still a user line: the turn goes on")
        }
    }
}

// MARK: - Writer names

extension ClaudeTranscriptTailTests {
    struct WriterNames {
        @Test(arguments: [
            ("claude-desktop", "the Claude app"),
            ("cli", "Claude Code in a terminal"),
            ("claude-vscode", "VS Code"),
            ("vscode", "VS Code"),
            ("sdk-ts", "another app"),
            ("CLI", "another app"),
            ("", "another app"),
            (nil, "another app"),
        ] as [(String?, String)])
        func writerIsNamedForItsEntrypoint(entrypoint: String?, name: String) {
            #expect(ClaudeTranscriptTail.writerName(entrypoint) == name)
        }
    }
}

// MARK: - Reading appended lines

extension ClaudeTranscriptTailTests {
    @Suite(.tags(.tailFileSystem))
    final class ReadingLines: Sendable {
        private let scratch: TailScratchDirectory

        init() throws {
            scratch = try TailScratchDirectory()
        }

        deinit {
            scratch.remove()
        }

        @Test func missingFileReadsNothing() {
            #expect(ClaudeTranscriptTail.readLines(scratch.missingFile, from: 0) == nil)
        }

        @Test func readsEveryCompleteLineFromTheStart() throws {
            let contents = "{\"a\":1}\n{\"b\":2}\n"
            let url = try scratch.file(contents)
            let (text, next) = try #require(ClaudeTranscriptTail.readLines(url, from: 0))
            #expect(text == contents)
            #expect(next == UInt64(contents.utf8.count))
        }

        @Test func lineStillBeingWrittenIsHeldBack() throws {
            let url = try scratch.file("one\ntwo\nthr")
            let (text, next) = try #require(ClaudeTranscriptTail.readLines(url, from: 0))
            #expect(text == "one\ntwo\n")
            #expect(next == 8, "the next read starts at the unfinished line")
        }

        @Test(.tags(.tailEdgeCase), arguments: ["", "no newline yet"])
        func fileWithoutACompleteLineReadsNothing(contents: String) throws {
            let url = try scratch.file(contents)
            #expect(ClaudeTranscriptTail.readLines(url, from: 0) == nil)
        }

        @Test(.tags(.tailEdgeCase), arguments: [UInt64(0), 1, 1_000])
        func offsetAtOrPastTheEndReadsNothing(beyondEnd: UInt64) throws {
            let contents = "one\ntwo\n"
            let url = try scratch.file(contents)
            #expect(ClaudeTranscriptTail.readLines(url, from: UInt64(contents.utf8.count) + beyondEnd) == nil)
        }

        @Test func readsFromALineBoundary() throws {
            let url = try scratch.file("one\ntwo\nthree\n")
            let (text, next) = try #require(ClaudeTranscriptTail.readLines(url, from: 4))
            #expect(text == "two\nthree\n")
            #expect(next == 14, "the next read starts at the end of the file")
        }

        @Test(.tags(.tailEdgeCase), arguments: [UInt64(1), 2, 3])
        func midLineOffsetSkipsToTheNextLine(offset: UInt64) throws {
            let url = try scratch.file("one\ntwo\n")
            let (text, next) = try #require(ClaudeTranscriptTail.readLines(url, from: offset))
            #expect(text == "two\n", "the partial first line is skipped")
            #expect(next == 8, "the next read starts at the end of the file")
        }

        /// After an in-place rewrite the offset can land inside a character.
        @Test(.tags(.tailEdgeCase))
        func offsetInsideAMultibyteCharacterSkipsToTheNextLine() throws {
            let second = #"{"b":1}"# + "\n"
            let contents = #"{"a":"x—y"}"# + "\n" + second
            let url = try scratch.file(contents)
            let insideDash = UInt64(#"{"a":"x"#.utf8.count) + 2   // the dash's last byte
            let (text, next) = try #require(ClaudeTranscriptTail.readLines(url, from: insideDash))
            #expect(text == second)
            #expect(next == UInt64(contents.utf8.count))
        }

        @Test(.tags(.tailEdgeCase), arguments: [
            ("one\ntwo", 4),   // at a line boundary, only an unfinished line follows
            ("one\ntwo", 5),   // mid-line, only an unfinished line follows
            ("one\n", 2),      // mid-line in the last complete line
        ] as [(String, UInt64)])
        func nothingCompleteAfterTheOffsetReadsNothing(contents: String, offset: UInt64) throws {
            let url = try scratch.file(contents)
            #expect(ClaudeTranscriptTail.readLines(url, from: offset) == nil)
        }

        @Test func lineFinishedLaterIsReadWhole() throws {
            let url = try scratch.file("first\nsec")
            let (firstRead, afterFirst) = try #require(ClaudeTranscriptTail.readLines(url, from: 0))
            #expect(firstRead == "first\n")

            try scratch.append("ond\n", to: url)
            let (secondRead, afterSecond) = try #require(ClaudeTranscriptTail.readLines(url, from: afterFirst))
            #expect(secondRead == "second\n", "the held-back line comes back whole")
            #expect(afterSecond == 13)
        }

        @Test func successiveReadsReturnOnlyNewLines() throws {
            let url = try scratch.file("a\n")
            let (first, afterFirst) = try #require(ClaudeTranscriptTail.readLines(url, from: 0))
            try scratch.append("b\nc\n", to: url)
            let (second, afterSecond) = try #require(ClaudeTranscriptTail.readLines(url, from: afterFirst))

            #expect(first == "a\n")
            #expect(second == "b\nc\n")
            #expect(ClaudeTranscriptTail.readLines(url, from: afterSecond) == nil, "nothing new since")
        }

        @Test func appendedTranscriptLinesParseIntoEvents() throws {
            let url = try scratch.file(TailLine.file([TailLine.prompt("Run the tests", fields: [TailField.entrypoint("cli")])]))
            let (initial, offset) = try #require(ClaudeTranscriptTail.readLines(url, from: 0))
            #expect(ClaudeTranscriptTail.parse(initial).events == [.user("Run the tests")])

            let reply = TailLine.assistant([TailBlock.text("All green.")], id: "msg_9", stop: "end_turn")
            try scratch.append(String(reply.prefix(20)), to: url)
            #expect(ClaudeTranscriptTail.readLines(url, from: offset) == nil, "a half-written line waits")

            try scratch.append(String(reply.dropFirst(20)) + "\n", to: url)
            let (appended, _) = try #require(ClaudeTranscriptTail.readLines(url, from: offset))
            let batch = ClaudeTranscriptTail.parse(appended)
            #expect(batch.events == [.text(messageID: "msg_9", "All green.")])
            #expect(batch.working == false)
        }
    }
}

// MARK: - File identity and size

extension ClaudeTranscriptTailTests {
    @Suite(.tags(.tailFileSystem))
    final class FileIdentity: Sendable {
        private let scratch: TailScratchDirectory

        init() throws {
            scratch = try TailScratchDirectory()
        }

        deinit {
            scratch.remove()
        }

        @Test func sizeOfAMissingFileIsZero() {
            #expect(ClaudeTranscriptTail.fileSize(scratch.missingFile) == 0)
        }

        @Test(arguments: ["", "x\n", "héllo — wörld\n"])
        func sizeCountsBytes(contents: String) throws {
            let url = try scratch.file(contents)
            #expect(ClaudeTranscriptTail.fileSize(url) == UInt64(contents.utf8.count))
        }

        @Test func idOfAMissingFileIsNil() {
            #expect(ClaudeTranscriptTail.fileID(scratch.missingFile) == nil)
        }

        @Test func idSurvivesAppending() throws {
            let url = try scratch.file("one\n")
            let before = try #require(ClaudeTranscriptTail.fileID(url))
            try scratch.append("two\n", to: url)
            #expect(ClaudeTranscriptTail.fileID(url) == before, "an append is the same file")
            #expect(ClaudeTranscriptTail.fileSize(url) == 8)
        }

        @Test func idChangesWhenTheFileIsReplaced() throws {
            let url = try scratch.file("one\n")
            let before = try #require(ClaudeTranscriptTail.fileID(url))
            try Data("rewritten\n".utf8).write(to: url, options: .atomic)
            let after = try #require(ClaudeTranscriptTail.fileID(url))
            #expect(after != before, "an atomic replace is a new file")
        }

        @Test func distinctFilesHaveDistinctIDs() throws {
            let first = try scratch.file("a\n")
            let second = try scratch.file("a\n")
            let firstID = try #require(ClaudeTranscriptTail.fileID(first))
            let secondID = try #require(ClaudeTranscriptTail.fileID(second))
            #expect(firstID != secondID)
        }
    }
}

// MARK: - Fixtures

/// A JSON string literal for `string`, escaped as a transcript writer would.
fileprivate func tailJSON(_ string: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    guard let data = try? encoder.encode(string) else { return "null" }
    return String(decoding: data, as: UTF8.self)
}

/// Top-level fields of a transcript line, each with its trailing comma.
fileprivate enum TailField {
    static let sidechain = #""isSidechain":true,"#
    static let mainChain = #""isSidechain":false,"#
    static let meta = #""isMeta":true,"#

    static func entrypoint(_ name: String) -> String {
        #""entrypoint":\#(tailJSON(name)),"#
    }

    static func uuid(_ id: String) -> String {
        #""uuid":\#(tailJSON(id)),"#
    }
}

/// Message content blocks, as JSON.
fileprivate enum TailBlock {
    static func text(_ text: String) -> String {
        #"{"type":"text","text":\#(tailJSON(text))}"#
    }

    /// Claude often writes only the signature, with the thinking text empty.
    static func thinking(_ text: String) -> String {
        #"{"type":"thinking","thinking":\#(tailJSON(text)),"signature":"c2ln"}"#
    }

    /// `input` is the tool's input as JSON; nil leaves a field out.
    static func toolUse(id: String? = "toolu_1", name: String? = "Bash", input: String? = nil) -> String {
        var fields = [#""type":"tool_use""#]
        if let id { fields.append(#""id":\#(tailJSON(id))"#) }
        if let name { fields.append(#""name":\#(tailJSON(name))"#) }
        if let input { fields.append(#""input":\#(input)"#) }
        return "{\(fields.joined(separator: ","))}"
    }

    /// `content` is the result's content as JSON (a string or a list of parts); nil leaves a field out.
    static func toolResult(id: String? = "toolu_1", content: String? = nil, isError: Bool? = nil) -> String {
        var fields = [#""type":"tool_result""#]
        if let id { fields.append(#""tool_use_id":\#(tailJSON(id))"#) }
        if let content { fields.append(#""content":\#(content)"#) }
        if let isError { fields.append(#""is_error":\#(isError)"#) }
        return "{\(fields.joined(separator: ","))}"
    }

    static func image(base64: String) -> String {
        #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":\#(tailJSON(base64))}}"#
    }

    static func list(_ blocks: [String]) -> String {
        "[\(blocks.joined(separator: ","))]"
    }
}

/// Whole transcript lines, shaped like Claude Code's JSONL.
fileprivate enum TailLine {
    /// A user line; `content` is the message content as JSON.
    static func user(content: String, fields: [String] = []) -> String {
        #"{"type":"user",\#(fields.joined())"message":{"role":"user","content":\#(content)}}"#
    }

    /// A user line whose content is a plain string.
    static func prompt(_ text: String, fields: [String] = []) -> String {
        user(content: tailJSON(text), fields: fields)
    }

    /// A user line whose content is a list of blocks.
    static func user(blocks: [String], fields: [String] = []) -> String {
        user(content: TailBlock.list(blocks), fields: fields)
    }

    /// An assistant line; a nil `id` or `stop` leaves that key out.
    static func assistant(_ blocks: [String], id: String? = "msg_1", stop: String? = nil, fields: [String] = []) -> String {
        var message = #""role":"assistant","content":\#(TailBlock.list(blocks))"#
        if let id { message = #""id":\#(tailJSON(id)),"# + message }
        if let stop { message += #","stop_reason":\#(tailJSON(stop))"# }
        return #"{"type":"assistant",\#(fields.joined())"message":{\#(message)}}"#
    }

    /// Lines as a transcript file holds them.
    static func file(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }
}

/// A directory of one test's own under the temporary directory.
fileprivate struct TailScratchDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptTailTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A path inside the directory that nothing was written to.
    var missingFile: URL {
        url.appendingPathComponent("missing.jsonl")
    }

    /// A new file holding `contents`.
    func file(_ contents: String) throws -> URL {
        let file = url.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try Data(contents.utf8).write(to: file)
        return file
    }

    /// Appends `text`, the way a transcript writer adds to the file in place.
    func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Expects a batch that read nothing: no events, no conversation, no turn state, no writer.
fileprivate func expectTailBatchIsEmpty(_ batch: ClaudeTranscriptTail.Batch,
                                        sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(batch.events.isEmpty, "no events", sourceLocation: sourceLocation)
    #expect(batch.sawConversation == false, "no conversation line", sourceLocation: sourceLocation)
    #expect(batch.working == nil, "turn state unchanged", sourceLocation: sourceLocation)
    #expect(batch.entrypoint == nil, "no writer", sourceLocation: sourceLocation)
}

/// The tool calls among `events`, in order.
fileprivate func tailToolCalls(_ events: [ClaudeTranscriptTail.Event]) -> [ChatItem.ToolCall] {
    events.compactMap { event -> ChatItem.ToolCall? in
        guard case .toolUse(let call) = event else { return nil }
        return call
    }
}

/// The message IDs of the text and thought events among `events`, in order.
fileprivate func tailMessageIDs(_ events: [ClaudeTranscriptTail.Event]) -> [String] {
    events.compactMap { event -> String? in
        switch event {
        case .text(let id, _), .thought(let id, _): return id
        default: return nil
        }
    }
}
