import Foundation
import Testing
@testable import Sandshell

extension Tag {
    /// Boundaries and odd transcript input for the background-task parser and
    /// the subagent progress reader.
    @Tag fileprivate static var backgroundTasksEdgeCase: Self
    /// Tests that read and write real files in their own scratch directory.
    @Tag fileprivate static var backgroundTasksFileSystem: Self
}

/// `BackgroundTask`, `BackgroundTaskParser` and `SubagentProgress`
/// (Sandshell/Workspace/BackgroundTasks.swift).
struct BackgroundTasksTests {}

// MARK: - BackgroundTask

extension BackgroundTasksTests {
    struct TaskValue {
        let start = BGStamp.date(0)

        @Test func newTaskIsRunningWithNothingToReport() {
            let task = BackgroundTask(id: "b1", kind: .shell, title: "Build", startedAt: start)
            #expect(task.state == .running)
            #expect(task.isRunning)
            #expect(task.detail == nil)
            #expect(task.finishedAt == nil)
            #expect(task.summary == nil)
            #expect(task.activity == nil)
            #expect(task.events == 0)
            #expect(task.outputPath == nil)
            #expect(task.runID == nil)
            #expect(task.orphaned == false)
        }

        @Test(arguments: [
            (BackgroundTask.State.running, true),
            (BackgroundTask.State.completed, false),
            (BackgroundTask.State.failed, false),
            (BackgroundTask.State.stopped, false),
        ])
        func isRunningOnlyWhileRunning(state: BackgroundTask.State, expected: Bool) {
            let task = BackgroundTask(id: "b1", kind: .shell, title: "Build", startedAt: start, state: state)
            #expect(task.isRunning == expected)
        }

        @Test(arguments: [0, 1.5, 90, 86_400] as [TimeInterval])
        func unfinishedTaskRunsUntilNow(elapsed: TimeInterval) {
            let task = BackgroundTask(id: "b1", kind: .shell, title: "Build", startedAt: start)
            #expect(task.duration(at: start.addingTimeInterval(elapsed)) == elapsed)
        }

        @Test(arguments: [0, 42, 1_000] as [TimeInterval])
        func finishedTaskDurationIgnoresNow(now: TimeInterval) {
            let task = BackgroundTask(id: "b1", kind: .shell, title: "Build", startedAt: start,
                                      finishedAt: start.addingTimeInterval(42))
            #expect(task.duration(at: start.addingTimeInterval(now)) == 42, "A finished task's duration ends at finishedAt")
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func nowBeforeTheStartGivesANegativeDuration() {
            let task = BackgroundTask(id: "b1", kind: .shell, title: "Build", startedAt: start)
            #expect(task.duration(at: start.addingTimeInterval(-5)) == -5)
        }

        @Test func durationDefaultsToTheCurrentTime() {
            let task = BackgroundTask(id: "b1", kind: .shell, title: "Build", startedAt: Date().addingTimeInterval(-60))
            let duration = task.duration()
            #expect((60..<120).contains(duration), "Started a minute ago, so about 60 s (got \(duration))")
        }

        /// One of a task's mutable fields, changed.
        enum Change: String, CaseIterable, Sendable {
            case title, detail, finishedAt, state, summary, activity, events, outputPath, runID, orphaned
        }

        @Test(arguments: Change.allCases)
        func tasksCompareByEveryField(change: Change) {
            let task = BackgroundTask(id: "m1", kind: .monitor, title: "Watch", detail: "tail -f log",
                                      startedAt: start, events: 2)
            var changed = task
            #expect(task == changed)
            switch change {
            case .title: changed.title = "Watch the log"
            case .detail: changed.detail = nil
            case .finishedAt: changed.finishedAt = start
            case .state: changed.state = .completed
            case .summary: changed.summary = "Done"
            case .activity: changed.activity = "ERROR: disk full"
            case .events: changed.events = 3
            case .outputPath: changed.outputPath = "/tmp/m1.output"
            case .runID: changed.runID = "wf_1"
            case .orphaned: changed.orphaned = true
            }
            #expect(task != changed, "A changed \(change.rawValue) must count as a change")
        }
    }
}

// MARK: - BackgroundTaskParser.oneLine

extension BackgroundTasksTests {
    struct OneLine {
        @Test(arguments: [
            ("", ""),
            ("plain", "plain"),
            ("keep   inner  spaces", "keep   inner  spaces"),
            ("  padded\t", "padded"),
            ("   ", ""),
            ("\n\n", ""),
            ("first\nsecond", "first \u{23CE} second"),
            ("  a  \n\n\t\n  b ", "a \u{23CE} b"),
            ("a\r\nb\rc", "a \u{23CE} b \u{23CE} c"),
            ("line\u{2028}separator", "line \u{23CE} separator"),
        ])
        func linesAreTrimmedAndJoinedWithAReturnSymbol(input: String, expected: String) {
            #expect(BackgroundTaskParser.oneLine(input) == expected)
        }

        @Test(arguments: [1, 299, 300])
        func upToThreeHundredCharactersIsKept(length: Int) {
            let text = String(repeating: "x", count: length)
            #expect(BackgroundTaskParser.oneLine(text) == text)
        }

        @Test(arguments: [301, 302, 5_000])
        func longerTextIsCutToThreeHundredWithAnEllipsis(length: Int) {
            let result = BackgroundTaskParser.oneLine(String(repeating: "x", count: length))
            #expect(result == String(repeating: "x", count: 299) + "\u{2026}")
            #expect(result.count == 300)
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func limitAppliesToTheJoinedText() {
            let input = String(repeating: "a", count: 150) + "\n" + String(repeating: "b", count: 150)
            let expected = String(repeating: "a", count: 150) + " \u{23CE} " + String(repeating: "b", count: 146) + "\u{2026}"
            #expect(BackgroundTaskParser.oneLine(input) == expected, "Two 150-character lines plus the separator exceed 300")
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func limitCountsCharactersNotBytes() {
            let emoji = String(repeating: "\u{1F44D}\u{1F3FD}", count: 300)
            #expect(BackgroundTaskParser.oneLine(emoji) == emoji, "300 emoji are 300 characters, however many bytes")
            let accents = String(repeating: "\u{E9}", count: 301)
            #expect(BackgroundTaskParser.oneLine(accents) == String(repeating: "\u{E9}", count: 299) + "\u{2026}")
        }
    }
}

// MARK: - BackgroundTaskParser: launches and results

extension BackgroundTasksTests {
    struct Launches {
        struct TitleCase: Sendable, CustomTestStringConvertible {
            let command: String?
            let description: String?
            let title: String
            let detail: String?
            var testDescription: String { "command \(command ?? "nil"), description \(description ?? "nil")" }
        }

        struct SubagentTitleCase: Sendable, CustomTestStringConvertible {
            let description: String?
            let subagentType: String?
            let title: String
            let detail: String?
            var testDescription: String { "description \(description ?? "nil"), type \(subagentType ?? "nil")" }
        }

        /// How a subagent's tool result says it went off on its own.
        enum AsyncSignal: String, CaseIterable, Sendable {
            case statusAsyncLaunched, isAsyncFlag, resultText
        }

        /// A `Bash` call's `run_in_background` that doesn't ask for the background.
        enum ForegroundFlag: String, CaseIterable, Sendable {
            case missing, falseValue, stringTrue
        }

        @Test func backgroundBashBecomesARunningShellTask() throws {
            let parser = try BGScenario.parse(BGScenario.shell("bash_7", at: 10, command: "npm test",
                                                                description: "Run the tests"))
            try #require(parser.tasks.count == 1)
            let task = try #require(parser.tasks.first)
            #expect(task.id == "bash_7")
            #expect(task.kind == .shell)
            #expect(task.title == "Run the tests")
            #expect(task.detail == "npm test")
            #expect(task.startedAt == BGStamp.date(10), "A task starts when the tool was called, not when its result arrived")
            #expect(task.outputPath == "/tmp/claude/tasks/bash_7.output")
            #expect(task.state == .running)
            #expect(task.finishedAt == nil)
            #expect(parser.justFinished.isEmpty)
        }

        @Test(arguments: ["b4x2k9", "bash_12", "A-b_C-9"])
        func shellIDFallsBackToTheResultText(id: String) throws {
            let lines = try [
                BGLine.assistant([BGBlock.bash(id: "toolu_1", command: "sleep 60")]),
                BGLine.results([BGBlock.result(id: "toolu_1",
                                               "Command running in background with ID: \(id). Output is being written to: /tmp/x.output")]),
            ]
            #expect(BGScenario.parse(lines).tasks.map(\.id) == [id])
        }

        @Test func shellIDFromTheToolUseResultWinsOverTheText() throws {
            let lines = try [
                BGLine.assistant([BGBlock.bash(id: "toolu_1", command: "sleep 60")]),
                BGLine.results([BGBlock.result(id: "toolu_1", "Command running in background with ID: fromText")],
                               toolUseResult: ["backgroundTaskId": "fromField"]),
            ]
            #expect(BGScenario.parse(lines).tasks.map(\.id) == ["fromField"])
        }

        @Test(arguments: [
            ("Output is being written to: /tmp/tasks/b1.output", "/tmp/tasks/b1.output"),
            ("Output is being written to: /tmp/tasks/b1.output.", "/tmp/tasks/b1.output"),
            ("Output is being written to: /tmp/tasks/b1.output\nRead it when it's done.", "/tmp/tasks/b1.output"),
            ("Output is being written to: /tmp/tasks/b1.output. Read it when it's done.", "/tmp/tasks/b1.output"),
            ("Output is being written to: /tmp/tasks/b1", "/tmp/tasks/b1"),
            ("", nil),
        ] as [(String, String?)])
        func outputPathComesFromTheResultText(tail: String, expected: String?) throws {
            let lines = try [
                BGLine.assistant([BGBlock.bash(id: "toolu_1", command: "make")]),
                BGLine.results([BGBlock.result(id: "toolu_1", "Command running in background with ID: b1. " + tail)],
                               toolUseResult: ["backgroundTaskId": "b1"]),
            ]
            let task = try #require(BGScenario.parse(lines).tasks.first)
            #expect(task.outputPath == expected, "A trailing full stop isn't part of the path")
        }

        @Test(arguments: [
            TitleCase(command: "npm test", description: "Run the tests", title: "Run the tests", detail: "npm test"),
            TitleCase(command: "npm test", description: nil, title: "npm test", detail: "npm test"),
            TitleCase(command: "npm test", description: "", title: "npm test", detail: "npm test"),
            TitleCase(command: "cd app &&\n  make build", description: nil,
                      title: "cd app && \u{23CE} make build", detail: "cd app && \u{23CE} make build"),
            TitleCase(command: nil, description: "Warm the cache", title: "Warm the cache", detail: nil),
            TitleCase(command: nil, description: nil, title: "Bash", detail: nil),
        ])
        func shellTitleIsTheDescriptionElseTheCommand(_ titleCase: TitleCase) throws {
            let lines = try [
                BGLine.assistant([BGBlock.bash(id: "toolu_1", command: titleCase.command,
                                               description: titleCase.description)]),
                BGLine.results([BGBlock.result(id: "toolu_1", "Started.")], toolUseResult: ["backgroundTaskId": "b1"]),
            ]
            let task = try #require(BGScenario.parse(lines).tasks.first)
            #expect(task.title == titleCase.title)
            #expect(task.detail == titleCase.detail)
        }

        @Test func monitorBecomesAMonitorTask() throws {
            let command = "tail -f build.log | grep --line-buffered ERROR"
            let lines = try [
                BGLine.assistant([BGBlock.toolUse(id: "toolu_m", name: "Monitor",
                                                  input: ["command": command, "description": "Watch for build errors"])],
                                 at: 5),
                BGLine.results([BGBlock.result(id: "toolu_m", blocks: [
                    "Monitor started (task mon_3, timeout 600000ms).", "You will be notified on each event.",
                ])], at: 6),
            ]
            let task = try #require(BGScenario.parse(lines).tasks.first)
            #expect(task.id == "mon_3")
            #expect(task.kind == .monitor)
            #expect(task.title == "Watch for build errors")
            #expect(task.detail == command)
            #expect(task.startedAt == BGStamp.date(5))
            #expect(task.outputPath == nil, "Only shells write to an output file")
        }

        @Test func monitorWithoutDescriptionOrCommandIsTitledMonitor() throws {
            let lines = try [
                BGLine.assistant([BGBlock.toolUse(id: "toolu_m", name: "Monitor", input: [:])]),
                BGLine.results([BGBlock.result(id: "toolu_m", "Monitor started (task mon_4, timeout 60000ms)")]),
            ]
            let task = try #require(BGScenario.parse(lines).tasks.first)
            #expect(task.title == "Monitor")
            #expect(task.detail == nil)
        }

        @Test(arguments: ["Agent", "Task"], AsyncSignal.allCases)
        func asyncSubagentBecomesAnAgentTask(tool: String, signal: AsyncSignal) throws {
            let toolUseResult: [String: Any]?
            let text: String
            switch signal {
            case .statusAsyncLaunched:
                toolUseResult = ["status": "async_launched", "agentId": "a1b2"]
                text = "Launched."
            case .isAsyncFlag:
                toolUseResult = ["isAsync": true, "agentId": "a1b2"]
                text = "Launched."
            case .resultText:
                toolUseResult = nil
                text = "Async agent launched successfully.\nagentId: a1b2 (internal ID - do not mention to user)\nThe agent is working in the background."
            }
            let lines = try [
                BGLine.assistant([BGBlock.agent(id: "toolu_a", tool: tool, description: "Explore the repo",
                                                subagentType: "Explore")], at: 3),
                BGLine.results([BGBlock.result(id: "toolu_a", text)], toolUseResult: toolUseResult, at: 4),
            ]
            let parser = BGScenario.parse(lines)
            try #require(parser.tasks.count == 1)
            let task = try #require(parser.tasks.first)
            #expect(task.id == "a1b2")
            #expect(task.kind == .agent)
            #expect(task.title == "Explore the repo")
            #expect(task.detail == "Explore", "A subagent's detail is its type")
            #expect(task.startedAt == BGStamp.date(3))
            #expect(task.outputPath == nil)
        }

        @Test(arguments: [
            SubagentTitleCase(description: "Explore the repo", subagentType: "Explore", title: "Explore the repo", detail: "Explore"),
            SubagentTitleCase(description: nil, subagentType: "general-purpose", title: "Subagent", detail: "general-purpose"),
            SubagentTitleCase(description: "", subagentType: nil, title: "Subagent", detail: nil),
        ])
        func subagentTitleIsTheDescriptionElseSubagent(_ titleCase: SubagentTitleCase) throws {
            let lines = try [
                BGLine.assistant([BGBlock.agent(id: "toolu_a", description: titleCase.description,
                                                subagentType: titleCase.subagentType)]),
                BGLine.results([BGBlock.result(id: "toolu_a", "Launched.")],
                               toolUseResult: ["status": "async_launched", "agentId": "a1"]),
            ]
            let task = try #require(BGScenario.parse(lines).tasks.first)
            #expect(task.title == titleCase.title)
            #expect(task.detail == titleCase.detail)
        }

        @Test func synchronousSubagentIsNotATask() throws {
            let lines = try [
                BGLine.assistant([BGBlock.agent(id: "toolu_a", description: "Find callers", subagentType: "Explore")]),
                BGLine.results([BGBlock.result(id: "toolu_a", "Found 3 call sites. agentId: a9")],
                               toolUseResult: ["status": "completed", "isAsync": false, "agentId": "a9"]),
            ]
            #expect(BGScenario.parse(lines).tasks.isEmpty, "A subagent that ran in the foreground never becomes a task")
        }

        @Test func workflowDetailsComeFromTheToolUseResult() throws {
            let lines = try [
                BGLine.assistant([BGBlock.toolUse(id: "toolu_w", name: "Workflow",
                                                  input: ["name": "review-tests", "script": "export default {}"])],
                                 at: 7),
                BGLine.results([BGBlock.result(id: "toolu_w",
                                               "Workflow launched in background. Task ID: fromText\nRun ID: wf_fromText\nSummary: From the text")],
                               toolUseResult: ["taskId": "wt_1", "runId": "wf_1", "workflowName": "Review tests",
                                               "summary": "Review every suite"],
                               at: 8),
            ]
            let task = try #require(BGScenario.parse(lines).tasks.first)
            #expect(task.id == "wt_1")
            #expect(task.kind == .workflow)
            #expect(task.title == "Review tests", "The script's own name arrives with the result")
            #expect(task.detail == "Review every suite")
            #expect(task.runID == "wf_1")
            #expect(task.startedAt == BGStamp.date(7))
            #expect(task.outputPath == nil)
        }

        @Test func workflowDetailsFallBackToTheResultText() throws {
            let lines = try [
                BGLine.assistant([BGBlock.toolUse(id: "toolu_w", name: "Workflow", input: ["name": "review-tests"])]),
                BGLine.results([BGBlock.result(id: "toolu_w", """
                    Workflow launched in background. Task ID: wt_2
                    Run ID: wf_2
                    Summary: Review every suite
                    You will be notified when it finishes.
                    """)]),
            ]
            let task = try #require(BGScenario.parse(lines).tasks.first)
            #expect(task.id == "wt_2")
            #expect(task.kind == .workflow)
            #expect(task.title == "review-tests", "Without a workflowName the call's own name stays")
            #expect(task.detail == "Review every suite", "The summary line, without the lines after it")
            #expect(task.runID == "wf_2")
        }

        @Test(arguments: [
            (nil, nil, "Workflow"),
            ("review-tests", nil, "review-tests"),
            (nil, "Review tests", "Review tests"),
            ("review-tests", "Review tests", "Review tests"),
        ] as [(String?, String?, String)])
        func workflowTitleIsItsNameElseWorkflow(inputName: String?, workflowName: String?, expected: String) throws {
            var input: [String: Any] = [:]
            if let inputName { input["name"] = inputName }
            var toolUseResult: [String: Any] = ["taskId": "wt_1"]
            if let workflowName { toolUseResult["workflowName"] = workflowName }
            let lines = try [
                BGLine.assistant([BGBlock.toolUse(id: "toolu_w", name: "Workflow", input: input)]),
                BGLine.results([BGBlock.result(id: "toolu_w", "Started.")], toolUseResult: toolUseResult),
            ]
            let task = try #require(BGScenario.parse(lines).tasks.first)
            #expect(task.title == expected)
            #expect(task.detail == nil, "No summary anywhere in the result, so no detail")
            #expect(task.runID == nil)
        }

        @Test(.tags(.backgroundTasksEdgeCase), arguments: [
            ("Run ID: wf_7Hk-2", "wf_7Hk-2"),
            ("Run ID: run_7", nil),
            ("", nil),
        ] as [(String, String?)])
        func workflowRunIDInTheTextMustBeAWorkflowRun(runLine: String, expected: String?) throws {
            let lines = try [
                BGLine.assistant([BGBlock.toolUse(id: "toolu_w", name: "Workflow", input: [:])]),
                BGLine.results([BGBlock.result(id: "toolu_w", "Workflow launched in background. Task ID: wt_1\n" + runLine)]),
            ]
            let task = try #require(BGScenario.parse(lines).tasks.first)
            #expect(task.runID == expected, "Only a wf_… id names a workflow run")
        }

        @Test(arguments: ForegroundFlag.allCases)
        func foregroundBashIsNotATask(flag: ForegroundFlag) throws {
            var input: [String: Any] = ["command": "npm test"]
            switch flag {
            case .missing: break
            case .falseValue: input["run_in_background"] = false
            case .stringTrue: input["run_in_background"] = "true"
            }
            let lines = try [
                BGLine.assistant([BGBlock.toolUse(id: "toolu_1", name: "Bash", input: input)]),
                BGLine.results([BGBlock.result(id: "toolu_1", "Command running in background with ID: b1")],
                               toolUseResult: ["backgroundTaskId": "b1"]),
            ]
            #expect(BGScenario.parse(lines).tasks.isEmpty)
        }

        @Test(arguments: ["Read", "BashOutput", "KillShell", "bash", "agent", "workflow", "WebFetch"])
        func otherToolsAreNeverTasks(tool: String) throws {
            let lines = try [
                BGLine.assistant([BGBlock.toolUse(id: "toolu_1", name: tool,
                                                  input: ["command": "x", "run_in_background": true, "description": "d"])]),
                BGLine.results([BGBlock.result(id: "toolu_1",
                                               "Command running in background with ID: x1. Async agent launched agentId: x2. Monitor started (task x3)")],
                               toolUseResult: ["backgroundTaskId": "x1", "status": "async_launched", "agentId": "x2"]),
            ]
            #expect(BGScenario.parse(lines).tasks.isEmpty)
        }

        @Test(arguments: ["Bash", "Agent", "Task", "Monitor", "Workflow"])
        func resultWithoutATaskIDAddsNothing(tool: String) throws {
            let input: [String: Any] = tool == "Bash"
                ? ["command": "npm test", "run_in_background": true]
                : ["command": "npm test", "description": "Something", "prompt": "Do it"]
            let lines = try [
                BGLine.assistant([BGBlock.toolUse(id: "toolu_1", name: tool, input: input)]),
                BGLine.results([BGBlock.result(id: "toolu_1", "Error: something went wrong")]),
            ]
            #expect(BGScenario.parse(lines).tasks.isEmpty)
        }

        @Test func sidechainLaunchesAreIgnored() throws {
            let lines = try [
                BGLine.assistant([BGBlock.bash(id: "toolu_1", command: "npm test")], sidechain: true),
                BGLine.results([BGBlock.result(id: "toolu_1", "Started.")], toolUseResult: ["backgroundTaskId": "b1"]),
            ]
            #expect(BGScenario.parse(lines).tasks.isEmpty, "A subagent's own background work isn't the session's")
        }

        @Test func sidechainResultsDoNotConsumeTheLaunch() throws {
            let lines = try [
                BGLine.assistant([BGBlock.bash(id: "toolu_1", command: "npm test")]),
                BGLine.results([BGBlock.result(id: "toolu_1", "Started.")], toolUseResult: ["backgroundTaskId": "side"],
                               sidechain: true),
                BGLine.results([BGBlock.result(id: "toolu_1", "Started.")], toolUseResult: ["backgroundTaskId": "main"]),
            ]
            #expect(BGScenario.parse(lines).tasks.map(\.id) == ["main"])
        }

        @Test func resultWithoutItsLaunchIsIgnored() throws {
            let lines = try [
                BGLine.results([BGBlock.result(id: "toolu_unknown", "Command running in background with ID: b1")],
                               toolUseResult: ["backgroundTaskId": "b1"]),
            ]
            #expect(BGScenario.parse(lines).tasks.isEmpty)
        }

        @Test func launchWithoutAResultIsNotATaskYet() throws {
            let lines = try [BGLine.assistant([BGBlock.bash(id: "toolu_1", command: "npm test")])]
            #expect(BGScenario.parse(lines).tasks.isEmpty, "The task id only arrives with the result")
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func onlyTheFirstResultOfALaunchCounts() throws {
            let lines = try [
                BGLine.assistant([BGBlock.bash(id: "toolu_1", command: "npm test")]),
                BGLine.results([BGBlock.result(id: "toolu_1", "Error: permission denied")]),
                BGLine.results([BGBlock.result(id: "toolu_1", "Started.")], toolUseResult: ["backgroundTaskId": "b1"]),
            ]
            #expect(BGScenario.parse(lines).tasks.isEmpty)
        }

        @Test func launchAndResultCanArriveInSeparateReads() throws {
            let lines = try BGScenario.shell("b1")
            var parser = BackgroundTaskParser()
            parser.consume(BGLine.file([lines[0]]))
            #expect(parser.tasks.isEmpty)
            parser.consume(BGLine.file([lines[1]]))
            #expect(parser.tasks.map(\.id) == ["b1"], "The pending launch carries over between reads")
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func aTaskIDIsOnlyAddedOnce() throws {
            let lines = try [
                BGLine.assistant([BGBlock.bash(id: "toolu_1", command: "a", description: "First")]),
                BGLine.results([BGBlock.result(id: "toolu_1", "Started.")], toolUseResult: ["backgroundTaskId": "b1"]),
                BGLine.assistant([BGBlock.bash(id: "toolu_2", command: "b", description: "Second")]),
                BGLine.results([BGBlock.result(id: "toolu_2", "Started.")], toolUseResult: ["backgroundTaskId": "b1"]),
            ]
            let parser = BGScenario.parse(lines)
            #expect(parser.tasks.map(\.title) == ["First"])
        }

        @Test func parallelLaunchesEachBecomeATaskInResultOrder() throws {
            let lines = try [
                BGLine.assistant([
                    BGBlock.text("Starting both."),
                    BGBlock.bash(id: "toolu_1", command: "npm run server", description: "Server"),
                    BGBlock.bash(id: "toolu_2", command: "npm run watch", description: "Watcher"),
                ]),
                BGLine.results([BGBlock.result(id: "toolu_2", "Started.")], toolUseResult: ["backgroundTaskId": "b2"], at: 1),
                BGLine.results([BGBlock.result(id: "toolu_1", "Started.")], toolUseResult: ["backgroundTaskId": "b1"], at: 2),
            ]
            let parser = BGScenario.parse(lines)
            #expect(parser.tasks.map(\.id) == ["b2", "b1"])
            #expect(parser.tasks.map(\.title) == ["Watcher", "Server"])
        }

        @Test(arguments: ["2026-01-01T00:00:00.000Z", "2026-01-01T00:00:00Z"])
        func timestampsWithOrWithoutFractionalSecondsAreRead(stamp: String) throws {
            let lines = try [
                BGLine.assistant([BGBlock.bash(id: "toolu_1", command: "npm test")], timestamp: stamp),
                BGLine.results([BGBlock.result(id: "toolu_1", "Started.")], toolUseResult: ["backgroundTaskId": "b1"]),
            ]
            let task = try #require(BGScenario.parse(lines).tasks.first)
            #expect(task.startedAt == Date(timeIntervalSince1970: 1_767_225_600))
        }

        @Test(.tags(.backgroundTasksEdgeCase), arguments: [nil, "", "yesterday"] as [String?])
        func unreadableTimestampMeansNow(stamp: String?) throws {
            let lines = try [
                BGLine.assistant([BGBlock.bash(id: "toolu_1", command: "npm test")], timestamp: stamp),
                BGLine.results([BGBlock.result(id: "toolu_1", "Started.")], toolUseResult: ["backgroundTaskId": "b1"]),
            ]
            let before = Date()
            let parser = BGScenario.parse(lines)
            let after = Date()
            let task = try #require(parser.tasks.first)
            #expect(task.startedAt >= before, "A line without a readable timestamp is dated when it's read")
            #expect(task.startedAt <= after)
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func malformedLinesDoNotHideLaterOnes() throws {
            let junk = [
                "tool_use but not JSON",
                #"["tool_use", "toolUseResult"]"#,
                #"{"type":"assistant","message":"tool_use"}"#,
                #"{"type":"user","message":{"content":"tool_use"}}"#,
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash""#,
                "",
            ].joined(separator: "\n")
            let text = try junk + "\n\n" + BGLine.file(BGScenario.shell("b1"))
            #expect(BGScenario.parse(text: text).tasks.map(\.id) == ["b1"])
        }
    }
}

// MARK: - BackgroundTaskParser: task notifications

extension BackgroundTasksTests {
    struct Notifications {
        /// Where a `<task-notification>` shows up in the transcript.
        enum Delivery: String, CaseIterable, Sendable {
            case queued, deliveredAsString, deliveredAsTextBlocks
        }

        /// Shell task `b1`, launched at 0 s (its result at 1 s).
        let launch: [String]

        init() throws {
            launch = try BGScenario.shell("b1", at: 0)
        }

        private func line(_ delivery: Delivery, _ content: String, at seconds: Int) throws -> String {
            switch delivery {
            case .queued: return try BGLine.queued(content, at: seconds)
            case .deliveredAsString: return try BGLine.delivered(content, at: seconds)
            case .deliveredAsTextBlocks: return try BGLine.delivered(textBlocks: [content], at: seconds)
            }
        }

        @Test func completionFinishesTheTask() throws {
            let summary = "Background command \"npm test\" completed (exit code 0)"
            let notice = BGNotice.body(taskID: "b1", status: "completed", summary: summary)
            let parser = try BGScenario.parse(launch + [BGLine.queued(notice, at: 30)])
            let task = try #require(parser.tasks.first)
            #expect(task.state == .completed)
            #expect(task.isRunning == false)
            #expect(task.finishedAt == BGStamp.date(30))
            #expect(task.summary == summary)
            #expect(parser.justFinished == [task], "The finished task is reported once, as it is now")
        }

        @Test(arguments: [
            ("completed", .completed), ("Completed", .completed), ("success", .completed), ("exited", .completed),
            ("failed", .failed), ("FAILED", .failed), ("error", .failed),
            ("killed", .stopped), ("Killed", .stopped), ("stopped", .stopped), ("cancelled", .stopped),
            ("canceled", .stopped), ("timeout", .stopped), ("timed_out", .stopped),
        ] as [(String, BackgroundTask.State)])
        func statusDecidesTheFinalState(status: String, expected: BackgroundTask.State) throws {
            let notice = BGNotice.body(taskID: "b1", status: status)
            let parser = try BGScenario.parse(launch + [BGLine.queued(notice, at: 30)])
            let task = try #require(parser.tasks.first)
            #expect(task.state == expected, "Statuses are case-insensitive; anything unrecognised counts as completed")
            #expect(task.finishedAt == BGStamp.date(30))
        }

        @Test(arguments: Delivery.allCases)
        func notificationsAreReadWhereverTheyAppear(delivery: Delivery) throws {
            let notice = BGNotice.body(taskID: "b1", status: "completed", summary: "Done")
            let parser = try BGScenario.parse(launch + [line(delivery, notice, at: 30)])
            let task = try #require(parser.tasks.first)
            #expect(task.state == .completed)
            #expect(task.summary == "Done")
        }

        @Test func queuedAndDeliveredCopiesCountOnce() throws {
            let notice = BGNotice.body(taskID: "b1", status: "completed", summary: "Done")
            let parser = try BGScenario.parse(launch + [
                BGLine.queued(notice, at: 30),
                BGLine.delivered("A background task finished:\n" + notice + "\nCarry on.", at: 31),
            ])
            #expect(parser.justFinished.map(\.id) == ["b1"], "The delivered copy repeats the queued one")
            #expect(parser.tasks.first?.finishedAt == BGStamp.date(30), "The finish time is the first copy's")
        }

        @Test func aCopyInALaterReadIsNotReportedAgain() throws {
            let notice = BGNotice.body(taskID: "b1", status: "completed", summary: "Done")
            var parser = BackgroundTaskParser()
            try parser.consume(BGLine.file(launch + [BGLine.queued(notice, at: 30)]))
            #expect(parser.justFinished.map(\.id) == ["b1"])
            try parser.consume(BGLine.file([BGLine.delivered(notice, at: 31)]))
            #expect(parser.justFinished.isEmpty)
            #expect(parser.tasks.first?.finishedAt == BGStamp.date(30))
        }

        @Test(arguments: ["", "\n", "{\"type\":\"assistant\"}\n"])
        func justFinishedOnlyCoversTheLatestRead(next: String) throws {
            let notice = BGNotice.body(taskID: "b1", status: "completed")
            var parser = try BGScenario.parse(launch + [BGLine.queued(notice, at: 30)])
            try #require(parser.justFinished.map(\.id) == ["b1"])
            parser.consume(next)
            #expect(parser.justFinished.isEmpty)
        }

        @Test func aFinishedTaskIgnoresLaterNotifications() throws {
            var parser = try BGScenario.parse(launch + [
                BGLine.queued(BGNotice.body(taskID: "b1", status: "completed", summary: "Done"), at: 30),
            ])
            try parser.consume(BGLine.file([
                BGLine.queued(BGNotice.body(taskID: "b1", status: "failed", summary: "Crashed"), at: 40),
            ]))
            let task = try #require(parser.tasks.first)
            #expect(task.state == .completed)
            #expect(task.summary == "Done")
            #expect(task.finishedAt == BGStamp.date(30))
            #expect(parser.justFinished.isEmpty)
        }

        @Test(arguments: ["b999", nil] as [String?])
        func notificationForAnUnknownTaskIsIgnored(taskID: String?) throws {
            let notice = BGNotice.body(taskID: taskID, status: "completed", summary: "Done")
            let parser = try BGScenario.parse(launch + [BGLine.queued(notice, at: 30)])
            let task = try #require(parser.tasks.first)
            #expect(task.isRunning)
            #expect(parser.justFinished.isEmpty)
        }

        @Test(arguments: [nil, "   "] as [String?])
        func notificationWithoutAStatusDoesNotFinish(status: String?) throws {
            let notice = BGNotice.body(taskID: "b1", status: status, summary: "Still going")
            let parser = try BGScenario.parse(launch + [BGLine.queued(notice, at: 30)])
            let task = try #require(parser.tasks.first)
            #expect(task.isRunning)
            #expect(task.finishedAt == nil)
            #expect(task.summary == nil, "A status-less notification changes nothing")
            #expect(parser.justFinished.isEmpty)
        }

        @Test(arguments: [
            (nil, nil),
            ("   ", nil),
            ("Exit code 1\n  stderr: boom ", "Exit code 1 \u{23CE} stderr: boom"),
        ] as [(String?, String?)])
        func summaryIsFlattenedAndBlankMeansNone(summary: String?, expected: String?) throws {
            let notice = BGNotice.body(taskID: "b1", status: "failed", summary: summary)
            let parser = try BGScenario.parse(launch + [BGLine.queued(notice, at: 30)])
            let task = try #require(parser.tasks.first)
            #expect(task.state == .failed)
            #expect(task.summary == expected)
        }

        @Test func oneTextCanCarrySeveralNotifications() throws {
            let content = BGNotice.body(taskID: "b1", status: "completed", summary: "Built")
                + "\n" + BGNotice.body(taskID: "b2", status: "failed", summary: "Tests failed")
            let parser = try BGScenario.parse(launch + BGScenario.shell("b2", at: 5) + [BGLine.queued(content, at: 30)])
            let first = try bgTask("b1", in: parser)
            let second = try bgTask("b2", in: parser)
            #expect(first.state == .completed)
            #expect(second.state == .failed)
            #expect(parser.justFinished.map(\.id) == ["b1", "b2"])
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func unclosedNotificationIsStillRead() throws {
            let content = "<task-notification><task-id>b1</task-id><status>completed</status>"
            let parser = try BGScenario.parse(launch + [BGLine.queued(content, at: 30)])
            #expect(parser.tasks.first?.state == .completed)
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func tagValuesAreTrimmed() throws {
            let content = "<task-notification>\n<task-id>\n  b1 \n</task-id>\n<status> Failed </status>\n"
                + "<summary>\n  Exit code 2\n</summary>\n</task-notification>"
            let parser = try BGScenario.parse(launch + [BGLine.queued(content, at: 30)])
            let task = try #require(parser.tasks.first)
            #expect(task.state == .failed)
            #expect(task.summary == "Exit code 2")
        }

        @Test func sidechainNotificationsAreIgnored() throws {
            let notice = BGNotice.body(taskID: "b1", status: "completed")
            let parser = try BGScenario.parse(launch + [BGLine.queued(notice, at: 30, sidechain: true)])
            #expect(parser.tasks.first?.isRunning == true)
        }
    }
}

// MARK: - BackgroundTaskParser: Monitor events

extension BackgroundTasksTests {
    struct MonitorEvents {
        /// Monitor task `mon_1`, launched at 0 s (its result at 1 s).
        let launch: [String]

        init() throws {
            launch = try BGScenario.monitor("mon_1", at: 0)
        }

        @Test func eventsAreCountedAndTheLatestIsTheActivity() throws {
            let parser = try BGScenario.parse(launch + [
                BGLine.queued(BGNotice.body(taskID: "mon_1", event: "ERROR: disk full"), at: 10),
                BGLine.queued(BGNotice.body(taskID: "mon_1", event: "WARN: retrying\n  attempt 2"), at: 20),
            ])
            let task = try #require(parser.tasks.first)
            #expect(task.events == 2)
            #expect(task.activity == "WARN: retrying \u{23CE} attempt 2")
            #expect(task.isRunning, "An event alone doesn't end the watch")
            #expect(task.finishedAt == nil)
            #expect(parser.justFinished.isEmpty)
        }

        @Test func eventWithAStatusCountsAndFinishes() throws {
            let notice = BGNotice.body(taskID: "mon_1", status: "completed", summary: "Build finished",
                                       event: "BUILD SUCCEEDED")
            let parser = try BGScenario.parse(launch + [BGLine.queued(notice, at: 40)])
            let task = try #require(parser.tasks.first)
            #expect(task.events == 1)
            #expect(task.activity == "BUILD SUCCEEDED")
            #expect(task.state == .completed)
            #expect(task.summary == "Build finished")
            #expect(task.finishedAt == BGStamp.date(40))
            #expect(parser.justFinished.map(\.id) == ["mon_1"])
        }

        @Test func expiryFinishesTheWatchWithoutCountingAnEvent() throws {
            let parser = try BGScenario.parse(launch + [
                BGLine.queued(BGNotice.body(taskID: "mon_1", event: "ERROR: one"), at: 10),
                BGLine.queued(BGNotice.body(taskID: "mon_1", event: "[Monitor expired after 30m]"), at: 1_800),
            ])
            let task = try #require(parser.tasks.first)
            #expect(task.events == 1, "The expiry notice isn't one of the watched lines")
            #expect(task.activity == "ERROR: one")
            #expect(task.state == .completed)
            #expect(task.summary == "Monitor expired after 30m", "The brackets are dropped")
            #expect(task.finishedAt == BGStamp.date(1_800))
            #expect(parser.justFinished.map(\.id) == ["mon_1"])
        }

        @Test func expiryWithAStatusUsesTheStatusAndSummary() throws {
            let notice = BGNotice.body(taskID: "mon_1", status: "timeout", summary: "Stopped watching",
                                       event: "[Monitor expired after 5m]")
            let parser = try BGScenario.parse(launch + [BGLine.queued(notice, at: 300)])
            let task = try #require(parser.tasks.first)
            #expect(task.events == 0)
            #expect(task.state == .stopped)
            #expect(task.summary == "Stopped watching")
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func repeatedIdenticalEventsEachCount() throws {
            let event = BGNotice.body(taskID: "mon_1", event: "ERROR: connection refused")
            let parser = try BGScenario.parse(launch + [
                // The first event, queued and then delivered…
                BGLine.queued(event, at: 10), BGLine.delivered(event, at: 11),
                // …and the same line again a minute later, queued and delivered.
                BGLine.queued(event, at: 70), BGLine.delivered(event, at: 71),
            ])
            let task = try #require(parser.tasks.first)
            #expect(task.events == 2, "Each delivered copy is the queued one's; the second queued line is a new event")
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func repeatedIdenticalEventsCountAcrossReads() throws {
            let event = BGNotice.body(taskID: "mon_1", event: "ERROR: connection refused")
            var parser = try BGScenario.parse(launch + [BGLine.queued(event, at: 10)])
            try parser.consume(BGLine.file([BGLine.delivered(event, at: 11), BGLine.queued(event, at: 70)]))
            try parser.consume(BGLine.file([BGLine.delivered(event, at: 71)]))
            #expect(parser.tasks.first?.events == 2)
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func eventsDeliveredWithoutBeingQueuedEachCount() throws {
            let event = BGNotice.body(taskID: "mon_1", event: "ERROR: connection refused")
            let parser = try BGScenario.parse(launch + [BGLine.delivered(event, at: 10), BGLine.delivered(event, at: 70)])
            #expect(parser.tasks.first?.events == 2)
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func queueEntryLeavingTheQueueIsNotANewEvent() throws {
            let event = BGNotice.body(taskID: "mon_1", event: "ERROR: connection refused")
            let leaving = try BGLine.json(["type": "queue-operation", "operation": "remove",
                                           "timestamp": BGStamp.iso(11), "content": event])
            let parser = try BGScenario.parse(launch + [BGLine.queued(event, at: 10), leaving, BGLine.delivered(event, at: 12)])
            #expect(parser.tasks.first?.events == 1)
        }
    }
}

// MARK: - BackgroundTaskParser: orphans, session end, activity

extension BackgroundTasksTests {
    struct Lifecycle {
        /// `b1` launched at 0 s and `b2` at 100 s, both running; `b3` launched
        /// at 50 s and completed ("Done") at 60 s.
        let parser: BackgroundTaskParser

        init() throws {
            parser = try BGScenario.parse(
                BGScenario.shell("b1", at: 0) + BGScenario.shell("b2", at: 100) + BGScenario.shell("b3", at: 50)
                    + [BGLine.queued(BGNotice.body(taskID: "b3", status: "completed", summary: "Done"), at: 60)])
        }

        @Test func orphansAreRunningTasksLaunchedBeforeTheCutoff() throws {
            var parser = self.parser
            parser.markOrphans(launchedBefore: BGStamp.date(100))

            let early = try bgTask("b1", in: parser)
            #expect(early.state == .stopped)
            #expect(early.orphaned)
            #expect(early.finishedAt == nil, "When an orphan ended is unknown")
            #expect(early.summary == nil)

            let atCutoff = try bgTask("b2", in: parser)
            #expect(atCutoff.isRunning, "Launched exactly at the cutoff isn't before it")
            #expect(atCutoff.orphaned == false)

            let finished = try bgTask("b3", in: parser)
            #expect(finished.state == .completed)
            #expect(finished.orphaned == false, "Only running tasks can be orphans")

            #expect(parser.justFinished.map(\.id) == ["b3"], "Marking orphans reports nothing as just finished")
        }

        @Test(arguments: [(9, false), (10, false), (11, true)])
        func orphanCutoffIsStrictlyAfterTheLaunch(cutoff: Int, orphaned: Bool) throws {
            var parser = try BGScenario.parse(BGScenario.shell("b1", at: 10))
            parser.markOrphans(launchedBefore: BGStamp.date(cutoff))
            let task = try bgTask("b1", in: parser)
            #expect(task.orphaned == orphaned)
            #expect(task.isRunning == (orphaned == false))
        }

        @Test func anOrphanIgnoresALateCompletion() throws {
            var parser = self.parser
            parser.markOrphans(launchedBefore: BGStamp.date(100))
            try parser.consume(BGLine.file([
                BGLine.queued(BGNotice.body(taskID: "b1", status: "completed", summary: "Done"), at: 200),
            ]))
            let task = try bgTask("b1", in: parser)
            #expect(task.state == .stopped)
            #expect(task.orphaned)
            #expect(parser.justFinished.isEmpty)
        }

        @Test func endAllStopsWhatIsStillRunning() throws {
            var parser = self.parser
            parser.endAll(at: BGStamp.date(500))
            for id in ["b1", "b2"] {
                let task = try bgTask(id, in: parser)
                #expect(task.state == .stopped, "\(id)")
                #expect(task.finishedAt == BGStamp.date(500), "\(id)")
                #expect(task.summary == "Ended with the session", "\(id)")
                #expect(task.orphaned == false, "\(id)")
            }
            let finished = try bgTask("b3", in: parser)
            #expect(finished.state == .completed)
            #expect(finished.finishedAt == BGStamp.date(60))
            #expect(finished.summary == "Done")
            #expect(parser.justFinished.map(\.id) == ["b3"], "Ending the session reports nothing as just finished")
        }

        @Test func endAllLeavesOrphansAsTheyAre() throws {
            var parser = self.parser
            parser.markOrphans(launchedBefore: BGStamp.date(100))
            parser.endAll(at: BGStamp.date(500))
            let orphan = try bgTask("b1", in: parser)
            #expect(orphan.orphaned)
            #expect(orphan.finishedAt == nil)
            #expect(orphan.summary == nil)
            #expect(try bgTask("b2", in: parser).finishedAt == BGStamp.date(500))
        }

        @Test func endAllDefaultsToNow() throws {
            var parser = self.parser
            let before = Date()
            parser.endAll()
            let after = Date()
            let finishedAt = try #require(try bgTask("b1", in: parser).finishedAt)
            #expect(finishedAt >= before)
            #expect(finishedAt <= after)
        }

        @Test func endingTwiceKeepsTheFirstEnd() throws {
            var parser = self.parser
            parser.endAll(at: BGStamp.date(500))
            parser.endAll(at: BGStamp.date(900))
            #expect(try bgTask("b1", in: parser).finishedAt == BGStamp.date(500))
        }

        @Test func setActivityUpdatesOnlyThatTask() throws {
            var parser = self.parser
            parser.setActivity("Grep: TODO", for: "b2")
            parser.setActivity("Read: /src/main.swift", for: "b2")
            #expect(try bgTask("b2", in: parser).activity == "Read: /src/main.swift", "The latest activity wins")
            #expect(try bgTask("b1", in: parser).activity == nil)
        }

        @Test func setActivityForAnUnknownTaskChangesNothing() {
            var parser = self.parser
            parser.setActivity("Read: /src/main.swift", for: "nope")
            #expect(parser.tasks == self.parser.tasks)
        }
    }
}

// MARK: - SubagentProgress.transcriptURL

extension BackgroundTasksTests {
    struct SubagentTranscriptLocation {
        @Test(arguments: [
            ("/nonexistent/projects/-work-app/0b1c2d3e.jsonl", "a1b2c3",
             "/nonexistent/projects/-work-app/0b1c2d3e/subagents/agent-a1b2c3.jsonl"),
            ("/nonexistent/projects/-work-app/session", "a1",
             "/nonexistent/projects/-work-app/session/subagents/agent-a1.jsonl"),
            ("/nonexistent/p/s.v2.jsonl", "x", "/nonexistent/p/s.v2/subagents/agent-x.jsonl"),
        ])
        func subagentTranscriptSitsInAFolderNamedAfterTheSession(transcript: String, agentID: String, expected: String) {
            let session = URL(filePath: transcript, directoryHint: .notDirectory)
            let url = SubagentProgress.transcriptURL(sessionTranscript: session, agentID: agentID)
            #expect(url.path(percentEncoded: false) == expected)
        }
    }
}

// MARK: - SubagentProgress.latestStep

extension BackgroundTasksTests {
    @Suite(.tags(.backgroundTasksFileSystem))
    struct SubagentLatestStep {
        @Test func missingTranscriptHasNoStep() {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "SandshellBackgroundTasksTests-\(UUID().uuidString)/agent-a1.jsonl",
                           directoryHint: .notDirectory)
            #expect(SubagentProgress.latestStep(in: url) == nil)
        }

        @Test func emptyTranscriptHasNoStep() throws {
            try withBGScratchFile(Data()) { url in
                #expect(SubagentProgress.latestStep(in: url) == nil)
            }
        }

        @Test func lastToolCallIsTheStep() throws {
            let lines = try [
                BGLine.assistant([BGBlock.text("Let me look around.")]),
                BGLine.assistant([
                    BGBlock.text("Checking the folder."),
                    BGBlock.toolUse(id: "toolu_1", name: "Bash", input: ["command": "ls -la", "description": "List the files"]),
                ]),
            ]
            try withBGScratchFile(lines: lines) { url in
                #expect(SubagentProgress.latestStep(in: url) == "Bash: List the files")
            }
        }

        @Test(arguments: [
            (#"{"description":"Find callers","file_path":"/src/a.swift","command":"grep"}"#, "Tool: Find callers"),
            (#"{"file_path":"/src/a.swift","command":"cat","pattern":"x"}"#, "Tool: /src/a.swift"),
            (#"{"command":"swift build","pattern":"x","url":"https://example.com"}"#, "Tool: swift build"),
            (#"{"pattern":"TODO","url":"https://example.com","query":"q"}"#, "Tool: TODO"),
            (#"{"url":"https://example.com/docs","query":"q"}"#, "Tool: https://example.com/docs"),
            (#"{"query":"swift testing traits"}"#, "Tool: swift testing traits"),
            (#"{"description":7,"command":"make"}"#, "Tool: make"),
            (#"{"path":"/src","limit":20}"#, "Tool"),
            (#"{}"#, "Tool"),
            ("null", "Tool"),
        ])
        func toolStepNamesTheToolAndItsMainInput(inputJSON: String, expected: String) throws {
            let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Tool","input":"#
                + inputJSON + "}]}}"
            try withBGScratchFile(lines: [line]) { url in
                #expect(SubagentProgress.latestStep(in: url) == expected)
            }
        }

        @Test func multilineInputIsFlattened() throws {
            let lines = try [
                BGLine.assistant([BGBlock.toolUse(id: "toolu_1", name: "Bash", input: ["command": "cd app\n  swift build"])]),
            ]
            try withBGScratchFile(lines: lines) { url in
                #expect(SubagentProgress.latestStep(in: url) == "Bash: cd app \u{23CE} swift build")
            }
        }

        @Test func textAfterTheToolCallWins() throws {
            let lines = try [
                BGLine.assistant([
                    BGBlock.toolUse(id: "toolu_1", name: "Read", input: ["file_path": "/src/a.swift"]),
                    BGBlock.text("All done."),
                ]),
            ]
            try withBGScratchFile(lines: lines) { url in
                #expect(SubagentProgress.latestStep(in: url) == "All done.", "The message's last block is the latest step")
            }
        }

        @Test func toolCallAfterTheTextWins() throws {
            let lines = try [
                BGLine.assistant([
                    BGBlock.text("Reading it."),
                    BGBlock.toolUse(id: "toolu_1", name: "Read", input: ["file_path": "/src/a.swift"]),
                ]),
            ]
            try withBGScratchFile(lines: lines) { url in
                #expect(SubagentProgress.latestStep(in: url) == "Read: /src/a.swift")
            }
        }

        @Test func toolCallWithoutANameIsSkipped() throws {
            let lines = try [
                BGLine.assistant([
                    BGBlock.text("Planning."),
                    ["type": "tool_use", "id": "toolu_1", "input": ["command": "ls"]],
                ]),
            ]
            try withBGScratchFile(lines: lines) { url in
                #expect(SubagentProgress.latestStep(in: url) == "Planning.")
            }
        }

        @Test func latestMessageWins() throws {
            let lines = try [
                BGLine.assistant([BGBlock.toolUse(id: "toolu_1", name: "Read", input: ["file_path": "/old.swift"])]),
                BGLine.assistant([BGBlock.toolUse(id: "toolu_2", name: "Edit", input: ["file_path": "/new.swift"])]),
            ]
            try withBGScratchFile(lines: lines) { url in
                #expect(SubagentProgress.latestStep(in: url) == "Edit: /new.swift")
            }
        }

        @Test func textStepIsFlattened() throws {
            let lines = try [BGLine.assistant([BGBlock.text("Summarizing what I found\n\nin three files")])]
            try withBGScratchFile(lines: lines) { url in
                #expect(SubagentProgress.latestStep(in: url) == "Summarizing what I found \u{23CE} in three files")
            }
        }

        @Test func linesWithoutAStepAreSkippedBackToAnEarlierOne() throws {
            let lines = try [
                BGLine.assistant([BGBlock.toolUse(id: "toolu_1", name: "Grep", input: ["pattern": "TODO"])]),
                BGLine.assistant([BGBlock.text("  \n\t ")]),
                BGLine.assistant([["type": "thinking", "thinking": "Hmm."]]),
                BGLine.assistant([]),
                BGLine.results([BGBlock.result(id: "toolu_1", "a.swift:3: TODO")]),
                BGLine.json(["type": "progress", "data": [
                    "type": "assistant",
                    "message": ["role": "assistant", "content": [
                        BGBlock.toolUse(id: "toolu_p", name: "Bash", input: ["command": "rm -rf build"]),
                    ]],
                ]]),
                #"{"type":"assistant","message":{"content":[{"type":"text","text":"cut off"#,
            ]
            try withBGScratchFile(lines: lines) { url in
                #expect(SubagentProgress.latestStep(in: url) == "Grep: TODO",
                        "Blank text, thinking, other line types and broken lines don't count as steps")
            }
        }

        @Test func transcriptWithoutAssistantStepsHasNoStep() throws {
            let lines = try [
                BGLine.delivered("Explore the repo"),
                BGLine.results([BGBlock.result(id: "toolu_1", "ok")]),
            ]
            try withBGScratchFile(lines: lines) { url in
                #expect(SubagentProgress.latestStep(in: url) == nil)
            }
        }

        @Test func onlyTheTailIsRead() throws {
            let lines = try [
                BGLine.assistant([BGBlock.toolUse(id: "toolu_1", name: "Read", input: ["file_path": "/early"])]),
                BGLine.delivered(String(repeating: "x", count: 400)),
            ]
            try withBGScratchFile(lines: lines) { url in
                #expect(SubagentProgress.latestStep(in: url) == "Read: /early", "The whole file fits the default window")
                #expect(SubagentProgress.latestStep(in: url, maxBytes: 100) == nil,
                        "The step is outside the last 100 bytes")
            }
        }

        @Test(.tags(.backgroundTasksEdgeCase), arguments: [
            (-100, "Read: /early"), (0, "Read: /early"), (1, nil),
        ] as [(Int, String?)])
        func windowCuttingALineSkipsIt(bytesCut: Int, expected: String?) throws {
            let lines = try [
                BGLine.assistant([BGBlock.toolUse(id: "toolu_1", name: "Read", input: ["file_path": "/early"])]),
                BGLine.assistant([BGBlock.text("   ")]),
            ]
            let size = Data(BGLine.file(lines).utf8).count
            try withBGScratchFile(lines: lines) { url in
                #expect(SubagentProgress.latestStep(in: url, maxBytes: size - bytesCut) == expected,
                        "Losing even the first byte leaves the step's line unparseable")
            }
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func zeroByteWindowReadsNothing() throws {
            let lines = try [BGLine.assistant([BGBlock.text("Working.")])]
            try withBGScratchFile(lines: lines) { url in
                #expect(SubagentProgress.latestStep(in: url, maxBytes: 0) == nil)
            }
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func windowStartingInsideAMultibyteCharacterStillFindsTheStep() throws {
            let step = try BGLine.assistant([BGBlock.toolUse(id: "toolu_1", name: "Read", input: ["file_path": "/late"])])
            var data = Data("\u{E9}\n".utf8)   // C3 A9 0A: a two-byte character on the first line
            data.append(Data((step + "\n").utf8))
            let window = data.count - 1           // starts at A9, the second byte of the character
            try withBGScratchFile(data) { url in
                try #require(SubagentProgress.latestStep(in: url) == "Read: /late", "Sanity check: the whole file reads")
                #expect(SubagentProgress.latestStep(in: url, maxBytes: window) == "Read: /late")
            }
        }

        @Test(.tags(.backgroundTasksEdgeCase), arguments: ["", "  ", "\n"])
        func blankDescriptionFallsThroughToTheNextInput(description: String) throws {
            let line = try BGLine.assistant([BGBlock.toolUse(id: "toolu_1", name: "Bash",
                                                             input: ["description": description, "command": "swift test"])])
            try withBGScratchFile(lines: [line]) { url in
                #expect(SubagentProgress.latestStep(in: url) == "Bash: swift test")
            }
        }

        @Test(.tags(.backgroundTasksEdgeCase))
        func onlyBlankInputsNameTheToolAlone() throws {
            let line = try BGLine.assistant([BGBlock.toolUse(id: "toolu_1", name: "Bash", input: ["description": "", "command": " "])])
            try withBGScratchFile(lines: [line]) { url in
                #expect(SubagentProgress.latestStep(in: url) == "Bash")
            }
        }
    }
}

// MARK: - Fixtures

/// Transcript times as offsets in seconds from 2026-01-01T00:00:00Z.
fileprivate enum BGStamp {
    static let origin = Date(timeIntervalSince1970: 1_767_225_600)

    static func date(_ seconds: Int) -> Date {
        origin.addingTimeInterval(TimeInterval(seconds))
    }

    /// The way Claude Code writes `timestamp`: ISO 8601 with milliseconds.
    static func iso(_ seconds: Int) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date(seconds))
    }
}

/// Content blocks of transcript messages.
fileprivate enum BGBlock {
    static func text(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    static func toolUse(id: String, name: String, input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    /// A `Bash` call, in the background unless `background` is false.
    static func bash(id: String, command: String?, description: String? = nil, background: Bool = true) -> [String: Any] {
        var input: [String: Any] = ["run_in_background": background]
        if let command { input["command"] = command }
        if let description { input["description"] = description }
        return toolUse(id: id, name: "Bash", input: input)
    }

    static func agent(id: String, tool: String = "Agent", description: String?, subagentType: String?) -> [String: Any] {
        var input: [String: Any] = ["prompt": "Look into it", "run_in_background": true]
        if let description { input["description"] = description }
        if let subagentType { input["subagent_type"] = subagentType }
        return toolUse(id: id, name: tool, input: input)
    }

    /// A tool result whose content is a string.
    static func result(id: String, _ text: String) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": id, "content": text]
    }

    /// A tool result whose content is text blocks.
    static func result(id: String, blocks texts: [String]) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": id, "content": texts.map { ["type": "text", "text": $0] }]
    }
}

/// Whole transcript lines (one JSON object each, no newline).
fileprivate enum BGLine {
    static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func assistant(_ blocks: [[String: Any]], at seconds: Int = 0, sidechain: Bool = false) throws -> String {
        try assistant(blocks, timestamp: BGStamp.iso(seconds), sidechain: sidechain)
    }

    /// An assistant message with a literal `timestamp` (nil leaves it out).
    static func assistant(_ blocks: [[String: Any]], timestamp: String?, sidechain: Bool = false) throws -> String {
        var object: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": blocks]]
        if let timestamp { object["timestamp"] = timestamp }
        if sidechain { object["isSidechain"] = true }
        return try json(object)
    }

    /// A user message carrying tool results, with the line's `toolUseResult`.
    static func results(_ blocks: [[String: Any]], toolUseResult: [String: Any]? = nil, at seconds: Int = 0,
                        sidechain: Bool = false) throws -> String {
        var object: [String: Any] = ["type": "user", "timestamp": BGStamp.iso(seconds),
                                     "message": ["role": "user", "content": blocks]]
        if let toolUseResult { object["toolUseResult"] = toolUseResult }
        if sidechain { object["isSidechain"] = true }
        return try json(object)
    }

    /// Claude Code queueing `content` (a task notification) for the conversation.
    static func queued(_ content: String, at seconds: Int = 0, sidechain: Bool = false) throws -> String {
        var object: [String: Any] = ["type": "queue-operation", "operation": "enqueue",
                                     "timestamp": BGStamp.iso(seconds), "content": content]
        if sidechain { object["isSidechain"] = true }
        return try json(object)
    }

    /// A user message whose content is a string.
    static func delivered(_ content: String, at seconds: Int = 0) throws -> String {
        try json(["type": "user", "timestamp": BGStamp.iso(seconds), "message": ["role": "user", "content": content]])
    }

    /// A user message whose content is text blocks.
    static func delivered(textBlocks texts: [String], at seconds: Int = 0) throws -> String {
        try json(["type": "user", "timestamp": BGStamp.iso(seconds),
                  "message": ["role": "user", "content": texts.map { ["type": "text", "text": $0] }]])
    }

    /// Lines as appended transcript text: each one newline-terminated.
    static func file(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }
}

/// `<task-notification>` texts.
fileprivate enum BGNotice {
    static func body(taskID: String?, status: String? = nil, summary: String? = nil, event: String? = nil) -> String {
        var body = ""
        if let taskID { body += "<task-id>\(taskID)</task-id>\n" }
        if let event { body += "<event>\(event)</event>\n" }
        if let status { body += "<status>\(status)</status>\n" }
        if let summary { body += "<summary>\(summary)</summary>\n" }
        return "<task-notification>\n\(body)</task-notification>"
    }
}

/// Ready-made launches and a parser fed with them.
fileprivate enum BGScenario {
    /// A background `Bash` call at `seconds` and, a second later, its result reporting task `id`.
    static func shell(_ id: String, at seconds: Int = 0, command: String = "npm test",
                      description: String? = nil) throws -> [String] {
        let use = "toolu_\(id)"
        return try [
            BGLine.assistant([BGBlock.bash(id: use, command: command, description: description)], at: seconds),
            BGLine.results([BGBlock.result(id: use, "Command running in background with ID: \(id). Output is being written to: /tmp/claude/tasks/\(id).output")],
                           toolUseResult: ["backgroundTaskId": id], at: seconds + 1),
        ]
    }

    /// A `Monitor` call at `seconds` and, a second later, its result reporting task `id`.
    static func monitor(_ id: String, at seconds: Int = 0) throws -> [String] {
        let use = "toolu_\(id)"
        return try [
            BGLine.assistant([BGBlock.toolUse(id: use, name: "Monitor",
                                              input: ["command": "tail -f /tmp/build.log", "description": "Watch the build"])],
                             at: seconds),
            BGLine.results([BGBlock.result(id: use, "Monitor started (task \(id), timeout 600000ms).")], at: seconds + 1),
        ]
    }

    static func parse(_ lines: [String]) -> BackgroundTaskParser {
        parse(text: BGLine.file(lines))
    }

    static func parse(text: String) -> BackgroundTaskParser {
        var parser = BackgroundTaskParser()
        parser.consume(text)
        return parser
    }
}

/// The parser's task with `id`, failing the test if there's none.
fileprivate func bgTask(_ id: String, in parser: BackgroundTaskParser,
                        sourceLocation: SourceLocation = #_sourceLocation) throws -> BackgroundTask {
    try #require(parser.tasks.first(where: { $0.id == id }), "No task \(id)", sourceLocation: sourceLocation)
}

/// Runs `body` with a file holding `contents` in a unique temporary folder,
/// removed afterwards.
fileprivate func withBGScratchFile(_ contents: Data, _ body: (URL) throws -> Void) throws {
    let fileManager = FileManager.default
    let folder = fileManager.temporaryDirectory
        .appending(component: "SandshellBackgroundTasksTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: folder) }
    let file = folder.appending(component: "agent-a1.jsonl", directoryHint: .notDirectory)
    try contents.write(to: file)
    try body(file)
}

fileprivate func withBGScratchFile(lines: [String], _ body: (URL) throws -> Void) throws {
    try withBGScratchFile(Data(BGLine.file(lines).utf8), body)
}
